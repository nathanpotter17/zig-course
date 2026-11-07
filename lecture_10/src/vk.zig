//! Small helpers over the translated Vulkan declarations: results as error unions, C strings as
//! slices, and the two or three object kinds every other file creates.

const std = @import("std");
pub const c = @import("c");

pub const Error = error{
    OutOfHostMemory,
    OutOfDeviceMemory,
    InitializationFailed,
    DeviceLost,
    LayerNotPresent,
    ExtensionNotPresent,
    FeatureNotPresent,
    IncompatibleDriver,
    SurfaceLost,
    OutOfDate,
    VulkanFailed,
};

/// Every Vulkan call returns a VkResult; this turns the failures into Zig errors so `try` works.
/// VK_SUBOPTIMAL_KHR is a success code: the swapchain still works, just not perfectly.
pub fn check(result: c.VkResult) Error!void {
    return switch (result) {
        c.VK_SUCCESS, c.VK_SUBOPTIMAL_KHR => {},
        c.VK_ERROR_OUT_OF_HOST_MEMORY => error.OutOfHostMemory,
        c.VK_ERROR_OUT_OF_DEVICE_MEMORY => error.OutOfDeviceMemory,
        c.VK_ERROR_INITIALIZATION_FAILED => error.InitializationFailed,
        c.VK_ERROR_DEVICE_LOST => error.DeviceLost,
        c.VK_ERROR_LAYER_NOT_PRESENT => error.LayerNotPresent,
        c.VK_ERROR_EXTENSION_NOT_PRESENT => error.ExtensionNotPresent,
        c.VK_ERROR_FEATURE_NOT_PRESENT => error.FeatureNotPresent,
        c.VK_ERROR_INCOMPATIBLE_DRIVER => error.IncompatibleDriver,
        c.VK_ERROR_SURFACE_LOST_KHR => error.SurfaceLost,
        c.VK_ERROR_OUT_OF_DATE_KHR => error.OutOfDate,
        else => error.VulkanFailed,
    };
}

/// A C string (possibly null) as a slice.
pub fn cString(ptr: [*c]const u8) []const u8 {
    const maybe: ?[*:0]const u8 = ptr;
    return std.mem.span(maybe orelse return "");
}

/// Vulkan packs a version into a u32: 7 bits of major, 10 of minor, 12 of patch.
pub fn versionString(buffer: []u8, version: u32) []const u8 {
    return std.fmt.bufPrint(buffer, "{d}.{d}.{d}", .{ (version >> 22) & 0x7f, (version >> 12) & 0x3ff, version & 0xfff }) catch "?";
}

/// A view of a 2D color image, the form in which rendering and presentation refer to an image.
pub fn createImageView(device: c.VkDevice, image: c.VkImage, format: c.VkFormat) Error!c.VkImageView {
    const info = c.VkImageViewCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = image,
        .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
        .format = format,
        .subresourceRange = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    var view: c.VkImageView = null;
    try check(c.vkCreateImageView(device, &info, null, &view));
    return view;
}

pub fn createSemaphore(device: c.VkDevice) Error!c.VkSemaphore {
    const info = c.VkSemaphoreCreateInfo{ .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
    var semaphore: c.VkSemaphore = null;
    try check(c.vkCreateSemaphore(device, &info, null, &semaphore));
    return semaphore;
}

/// A fence, created already signaled when `signaled` is set, so the first wait on it returns at once.
pub fn createFence(device: c.VkDevice, signaled: bool) Error!c.VkFence {
    const info = c.VkFenceCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .flags = if (signaled) c.VK_FENCE_CREATE_SIGNALED_BIT else 0,
    };
    var fence: c.VkFence = null;
    try check(c.vkCreateFence(device, &info, null, &fence));
    return fence;
}

// Tests

test "results become errors" {
    try check(c.VK_SUCCESS);
    try check(c.VK_SUBOPTIMAL_KHR);
    try std.testing.expectError(error.OutOfDate, check(c.VK_ERROR_OUT_OF_DATE_KHR));
    try std.testing.expectError(error.DeviceLost, check(c.VK_ERROR_DEVICE_LOST));
    try std.testing.expectError(error.VulkanFailed, check(c.VK_ERROR_UNKNOWN));
}

test "version strings" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1.3.0", versionString(&buffer, c.VK_API_VERSION_1_3));
    try std.testing.expectEqualStrings("1.4.335", versionString(&buffer, (1 << 22) | (4 << 12) | 335));
}

test "C strings" {
    try std.testing.expectEqualStrings("hello", cString("hello"));
    try std.testing.expectEqualStrings("", cString(null));
}
