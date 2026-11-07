//! The Vulkan context: the instance (the connection to the Vulkan loader and its drivers), the
//! physical device (a GPU), the logical device (our handle for talking to it), one queue, and a
//! command pool. Created in two steps, because the window's surface has to be made between them:
//! the surface needs the instance, and choosing a device needs the surface.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vk = @import("vk.zig");
const c = vk.c;

const Context = @This();

gpa: Allocator,
instance: c.VkInstance = null,
surface: c.VkSurfaceKHR = null,
physical: c.VkPhysicalDevice = null,
properties: c.VkPhysicalDeviceProperties = .{},
queue_family: u32 = 0,
device: c.VkDevice = null,
queue: c.VkQueue = null,
command_pool: c.VkCommandPool = null,

pub const Options = struct {
    /// Instance extensions the window system needs (SDL supplies them); none when headless.
    instance_extensions: []const [*c]const u8 = &.{},
    /// Enable the Khronos validation layer, if it's installed. It checks every call against the
    /// specification and prints what's wrong: slow, and indispensable while developing.
    validation: bool = false,
};

/// Step one: the instance.
pub fn init(gpa: Allocator, options: Options) !Context {
    var self = Context{ .gpa = gpa };

    const validation_layer: [*c]const u8 = "VK_LAYER_KHRONOS_validation";
    const layers = [_][*c]const u8{validation_layer};
    var layer_count: u32 = 0;
    if (options.validation) {
        if (try hasLayer(gpa, validation_layer)) {
            layer_count = 1;
        } else {
            std.log.warn("the validation layer is not installed; running without it", .{});
        }
    }

    // Vulkan structs start with sType (which struct this is) and pNext (a chain of extension
    // structs); the translated declarations give every field a default, so only what matters is set.
    const app_info = c.VkApplicationInfo{
        .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "zig-mastery lecture 10",
        .applicationVersion = 1,
        .pEngineName = "none",
        .engineVersion = 1,
        .apiVersion = c.VK_API_VERSION_1_3,
    };
    const create_info = c.VkInstanceCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app_info,
        .enabledLayerCount = layer_count,
        .ppEnabledLayerNames = &layers,
        .enabledExtensionCount = @intCast(options.instance_extensions.len),
        .ppEnabledExtensionNames = options.instance_extensions.ptr,
    };
    try vk.check(c.vkCreateInstance(&create_info, null, &self.instance));
    return self;
}

/// Step two: pick a GPU, create the logical device, get its queue, make a command pool. With a
/// surface, the queue family must be able to present to it; `preferred` forces a device index.
/// Every device found is listed on `out`, so the index to pass is easy to find.
pub fn initDevice(self: *Context, surface: c.VkSurfaceKHR, preferred: ?u32, out: *std.Io.Writer) !void {
    self.surface = surface;

    var count: u32 = 0;
    try vk.check(c.vkEnumeratePhysicalDevices(self.instance, &count, null));
    if (count == 0) return error.NoVulkanDevice;
    const devices = try self.gpa.alloc(c.VkPhysicalDevice, count);
    defer self.gpa.free(devices);
    try vk.check(c.vkEnumeratePhysicalDevices(self.instance, &count, devices.ptr));

    // List them all (so --device has something to refer to) and keep the best, or the one asked for.
    var best_score: u32 = 0;
    var best: ?usize = null;
    for (devices, 0..) |device, i| {
        var properties: c.VkPhysicalDeviceProperties = .{};
        c.vkGetPhysicalDeviceProperties(device, &properties);
        var version: [32]u8 = undefined;
        const family = findQueueFamily(self.gpa, device, surface) catch null;
        try out.print("  device {d}: {s} (Vulkan {s}, {s}){s}\n", .{
            i,
            std.mem.sliceTo(&properties.deviceName, 0),
            vk.versionString(&version, properties.apiVersion),
            deviceTypeName(properties.deviceType),
            if (family == null) ", unusable here" else "",
        });
        if (family == null) continue;
        const s = score(properties);
        const wanted = if (preferred) |p| p == i else s > best_score;
        if (wanted) {
            best_score = s;
            best = i;
        }
    }
    const index = best orelse return error.NoSuitableDevice;
    self.physical = devices[index];
    c.vkGetPhysicalDeviceProperties(self.physical, &self.properties);
    self.queue_family = (try findQueueFamily(self.gpa, self.physical, surface)).?;

    // The device: one queue from the chosen family, the swapchain extension if we present, and
    // two Vulkan 1.3 features this program relies on. They go in pNext, the extension chain.
    var features13 = c.VkPhysicalDeviceVulkan13Features{
        .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
        .dynamicRendering = c.VK_TRUE,
        .synchronization2 = c.VK_TRUE,
    };
    const priority: f32 = 1.0;
    const queue_info = c.VkDeviceQueueCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = self.queue_family,
        .queueCount = 1,
        .pQueuePriorities = &priority,
    };
    const extensions = [_][*c]const u8{c.VK_KHR_SWAPCHAIN_EXTENSION_NAME};
    const device_info = c.VkDeviceCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = &features13,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_info,
        .enabledExtensionCount = if (surface != null) 1 else 0,
        .ppEnabledExtensionNames = &extensions,
    };
    try vk.check(c.vkCreateDevice(self.physical, &device_info, null, &self.device));
    c.vkGetDeviceQueue(self.device, self.queue_family, 0, &self.queue);

    const pool_info = c.VkCommandPoolCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        // Lets individual command buffers be reset and re-recorded, which the frame loop does.
        .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = self.queue_family,
    };
    try vk.check(c.vkCreateCommandPool(self.device, &pool_info, null, &self.command_pool));
}

/// Destroys in reverse order of creation. Everything created from the device must be gone first.
pub fn deinit(self: *Context) void {
    if (self.device != null) {
        _ = c.vkDeviceWaitIdle(self.device);
        c.vkDestroyCommandPool(self.device, self.command_pool, null);
        c.vkDestroyDevice(self.device, null);
    }
    if (self.surface != null) c.vkDestroySurfaceKHR(self.instance, self.surface, null);
    c.vkDestroyInstance(self.instance, null);
    self.* = undefined;
}

pub fn deviceName(self: *const Context) []const u8 {
    return std.mem.sliceTo(&self.properties.deviceName, 0);
}

/// Command buffers come from the pool, `count` at a time.
pub fn allocateCommandBuffers(self: *const Context, buffers: []c.VkCommandBuffer) !void {
    const info = c.VkCommandBufferAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = self.command_pool,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = @intCast(buffers.len),
    };
    try vk.check(c.vkAllocateCommandBuffers(self.device, &info, buffers.ptr));
}

/// Which kind of device memory to allocate: the first type that the resource accepts (a bit in
/// `type_bits`) and that has the properties we need (device-local, or visible to the host).
pub fn findMemoryType(self: *const Context, type_bits: u32, properties: c.VkMemoryPropertyFlags) !u32 {
    var memory: c.VkPhysicalDeviceMemoryProperties = .{};
    c.vkGetPhysicalDeviceMemoryProperties(self.physical, &memory);
    for (0..memory.memoryTypeCount) |i| {
        const accepted = type_bits & (@as(u32, 1) << @intCast(i)) != 0;
        const suitable = memory.memoryTypes[i].propertyFlags & properties == properties;
        if (accepted and suitable) return @intCast(i);
    }
    return error.NoSuitableMemory;
}

/// Discrete GPUs first, then integrated, then whatever else (a software renderer scores lowest).
pub fn score(properties: c.VkPhysicalDeviceProperties) u32 {
    return switch (properties.deviceType) {
        c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU => 4,
        c.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU => 3,
        c.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU => 2,
        c.VK_PHYSICAL_DEVICE_TYPE_CPU => 1,
        else => 0,
    };
}

fn deviceTypeName(device_type: c.VkPhysicalDeviceType) []const u8 {
    return switch (device_type) {
        c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU => "discrete",
        c.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU => "integrated",
        c.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU => "virtual",
        c.VK_PHYSICAL_DEVICE_TYPE_CPU => "software",
        else => "other",
    };
}

/// The first queue family that does graphics and, if there's a surface, can present to it.
fn findQueueFamily(gpa: Allocator, device: c.VkPhysicalDevice, surface: c.VkSurfaceKHR) !?u32 {
    var count: u32 = 0;
    c.vkGetPhysicalDeviceQueueFamilyProperties(device, &count, null);
    const families = try gpa.alloc(c.VkQueueFamilyProperties, count);
    defer gpa.free(families);
    c.vkGetPhysicalDeviceQueueFamilyProperties(device, &count, families.ptr);
    for (families, 0..) |family, i| {
        if (family.queueFlags & c.VK_QUEUE_GRAPHICS_BIT == 0) continue;
        if (surface != null) {
            var supported: c.VkBool32 = c.VK_FALSE;
            try vk.check(c.vkGetPhysicalDeviceSurfaceSupportKHR(device, @intCast(i), surface, &supported));
            if (supported == c.VK_FALSE) continue;
        }
        return @intCast(i);
    }
    return null;
}

fn hasLayer(gpa: Allocator, name: [*c]const u8) !bool {
    var count: u32 = 0;
    try vk.check(c.vkEnumerateInstanceLayerProperties(&count, null));
    const layers = try gpa.alloc(c.VkLayerProperties, count);
    defer gpa.free(layers);
    try vk.check(c.vkEnumerateInstanceLayerProperties(&count, layers.ptr));
    for (layers) |layer| {
        if (std.mem.eql(u8, std.mem.sliceTo(&layer.layerName, 0), vk.cString(name))) return true;
    }
    return false;
}

// Tests

test "a discrete GPU outscores an integrated one, which outscores software" {
    var discrete: c.VkPhysicalDeviceProperties = .{};
    discrete.deviceType = c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU;
    var integrated: c.VkPhysicalDeviceProperties = .{};
    integrated.deviceType = c.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU;
    var software: c.VkPhysicalDeviceProperties = .{};
    software.deviceType = c.VK_PHYSICAL_DEVICE_TYPE_CPU;
    try std.testing.expect(score(discrete) > score(integrated));
    try std.testing.expect(score(integrated) > score(software));
    try std.testing.expect(score(software) > score(.{}));
}
