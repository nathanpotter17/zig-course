# Lecture 10: A window and a GPU

The last lecture puts everything together in the kind of program Zig was made for: one that talks to the operating system and the hardware directly. SDL3 opens a window and gives us a Vulkan surface; Vulkan, the low-level graphics API, draws a spinning triangle into it, sixty times a second. The same code also runs without any window, rendering into an image and writing it to a file, which is how the tests check it.

Vulkan is verbose by design: nothing happens implicitly, and every object is created with a struct that describes it. That makes it a good fit for Zig (explicit allocation, explicit errors, no hidden control flow) and a good capstone: the program uses the build system, packages, translate-c, C interop, error unions, file structs, slices, `defer`/`errdefer` and tests, all from the earlier lectures, in service of something you can see.

- **A fetched package:** SDL3 from the Zig package manager, built from source as part of our build.
- **The system's Vulkan:** headers translated with translate-c, the loader linked as a system library, the validation layer enabled on request.
- **Shaders compiled during the build:** `glslc` run as a build step, its SPIR-V output embedded with `@embedFile`.
- **Vulkan's object model in Zig:** instance, physical and logical device, queue, command pool, swapchain, image views, pipeline, command buffers, fences and semaphores, each created and destroyed in order.
- **Modern Vulkan (1.3):** dynamic rendering instead of render passes, synchronization2 barriers, push constants.
- **A frame loop** with two frames in flight, and swapchain recreation on resize.
- **Headless rendering:** an offscreen image, read back to the CPU and saved, used by the test suite.

The files:
```text
lecture_10/
  build.zig, build.zig.zon       the SDL dependency, translate-c, glslc steps, tests
  c/vk_sdl.h                     the header translate-c reads: Vulkan, then SDL
  shaders/triangle.vert, .frag   GLSL, compiled at build time
  src/vk.zig                     helpers: results to errors, C strings, small objects
  src/Context.zig                instance, device, queue, command pool
  src/Swapchain.zig              the window's images
  src/Pipeline.zig               shaders + fixed-function state
  src/draw.zig                   barriers and the draw commands
  src/Offscreen.zig              a render target without a window
  src/main.zig                   the frame loop, the headless path, the program
```
Requirements beyond Zig: the Vulkan headers and loader (`libvulkan-dev` on Debian/Ubuntu, or the Vulkan SDK), `glslc` (the `glslc` package or the SDK), a GPU driver with Vulkan 1.3, and, for the first build, network access to fetch SDL. The validation layer (`vulkan-validationlayers`) is optional.

## 10.1 The build

### Why
This build does four things the earlier ones didn't: it depends on a package fetched from the internet, translates a header that comes partly from the system and partly from that package, runs an external compiler (`glslc`) as a step and embeds its output, and links a system library. Each is a few lines in `build.zig`.

### How
- **The dependency.** `zig fetch --save git+https://github.com/castholm/SDL.git#v0.6.1+3.4.20` added the `.sdl` entry to `build.zig.zon`: a URL pinned to a commit, and a hash of the contents. `b.dependency("sdl", .{ .target, .optimize })` in `build.zig` runs that package's own `build.zig` with our target, and `.artifact("SDL3")` is the library it produces: SDL compiled from C source by the Zig compiler, in about ten seconds, with no system SDL involved. In 0.17 the fetched package is unpacked into `zig-pkg/` next to `build.zig` (it's in `.gitignore`); the global cache keeps the archive.
- **The header.** `c/vk_sdl.h` includes `<vulkan/vulkan.h>` and then SDL's headers. Order matters: `SDL_vulkan.h` declares its own `VkInstance` and `VkSurfaceKHR` unless Vulkan's header came first, and we want one set of types. The translate step gets `sdl.path("include")` for the SDL headers; the Vulkan headers are found through the system include path, which Zig uses for the native target.
- **Shaders.** `b.addSystemCommand(&.{"glslc"})` is a run step for any program on the PATH; `addFileArg` passes the GLSL file, `addOutputFileArg` names an output in the cache and returns its `LazyPath`. `addAnonymousImport("triangle_vert", .{ .root_source_file = spirv })` makes that file an import of the program, and `@embedFile("triangle_vert")` in `Pipeline.zig` reads it. The shader is recompiled only when its source changes.
- **Linking.** `linkLibrary(sdl_lib)` links the SDL we built; `linkSystemLibrary("vulkan", .{})` links the system's `libvulkan.so`, the loader that finds the GPU drivers at run time.
- **The test** runs the program headless for three frames at a small size, writing into the cache, and checks that it reported success. It needs a Vulkan device, but any will do, including Mesa's software one.

### Code
`lecture_10/build.zig`:
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // SDL3, from the package manager: build.zig.zon names the git tag and the content hash, and
    // the first build fetches it into zig-pkg/ and compiles it from source for the target.
    const sdl = b.dependency("sdl", .{ .target = target, .optimize = optimize });
    const sdl_lib = sdl.artifact("SDL3");

    // Vulkan and SDL declarations, translated together into one module (lecture 9's technique).
    // The Vulkan headers come from the system (the libvulkan-dev package), the SDL headers from
    // the package we just fetched.
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("c/vk_sdl.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(sdl.path("include"));

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = translate.createModule() },
        },
    });

    // Shaders: GLSL compiled to SPIR-V by glslc while building, and embedded into the program.
    // Each compiled file becomes a named import that @embedFile can read.
    const shaders = [_]struct { import: []const u8, file: []const u8 }{
        .{ .import = "triangle_vert", .file = "triangle.vert" },
        .{ .import = "triangle_frag", .file = "triangle.frag" },
    };
    for (shaders) |shader| {
        const glslc = b.addSystemCommand(&.{"glslc"});
        glslc.addFileArg(b.path(b.fmt("shaders/{s}", .{shader.file})));
        glslc.addArg("-o");
        const spirv = glslc.addOutputFileArg(b.fmt("{s}.spv", .{shader.file}));
        exe_module.addAnonymousImport(shader.import, .{ .root_source_file = spirv });
    }

    const exe = b.addExecutable(.{ .name = "lecture_10", .root_module = exe_module });
    // SDL is linked statically from the artifact we built; the Vulkan loader is the system's.
    exe.root_module.linkLibrary(sdl_lib);
    exe.root_module.linkSystemLibrary("vulkan", .{});
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Open the window; options after --").dependOn(&run.step);

    // Tests: the unit tests, then a headless render of three frames into the cache. The second
    // needs a Vulkan device (a software one like lavapipe is enough).
    const test_step = b.step("test", "Run the unit tests and a headless render");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = exe_module })).step);

    const headless = b.addRunArtifact(exe);
    headless.addArgs(&.{ "--headless", "--frames", "3", "--size", "320x200", "--out" });
    _ = headless.addOutputFileArg("frame.ppm");
    headless.addCheck(.{ .expect_stdout_match = "wrote" });
    test_step.dependOn(&headless.step);
}
```
`lecture_10/build.zig.zon`:
```zig
.{
    .name = .lecture_10,
    .version = "0.10.0",
    .fingerprint = 0x2b876d7cc5f33b0a, // Changing this has security and trust implications.
    .minimum_zig_version = "0.17.1",
    .dependencies = .{
        .sdl = .{
            .url = "git+https://github.com/castholm/SDL.git?ref=v0.6.1+3.4.20#ce475292f172d506468218f939ef607d9be5e083",
            .hash = "sdl-0.6.1+3.4.20-SDL--rskqQH3W9l4AJX-kdZ93M9XuhsqLrUsd2fnUE_X",
        },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src", "shaders" },
}
```
`c/vk_sdl.h`:
```c
/* One header for translate-c: Vulkan first, so SDL_vulkan.h sees VULKAN_CORE_H_ and reuses
   Vulkan's own handle types instead of declaring its own. */
#include <vulkan/vulkan.h>
#include <SDL3/SDL.h>
#include <SDL3/SDL_vulkan.h>
```

## 10.2 Vulkan in Zig

### Why
The translated Vulkan header is thirty thousand lines of declarations with C types. A handful of conventions make them pleasant from Zig: every function returns a `VkResult` that should become an error union; handles are optional pointers, so `null` is the null handle; every struct has defaults, so you set only the fields that matter; and the many `VK_*` constants are plain integers that coerce where they're used. `vk.zig` collects the helpers the other files share.

### How
- **Results.** `vk.check(result)` switches on the `c_int` codes and returns Zig errors, so every Vulkan call is `try vk.check(c.vkSomething(...))`. `VK_SUBOPTIMAL_KHR` is a success (the swapchain works, but could match the surface better) and passes through; the frame loop checks for it separately.
- **Handles** like `VkInstance` translate to `?*struct_VkInstance_T`: pointers to opaque types, nullable. `var instance: c.VkInstance = null;` then `&instance` as the out-parameter is the pattern for every create call.
- **Structs** translate to `extern struct`s with every field defaulted (`sType` to zero, pointers to `null`), so `c.VkFenceCreateInfo{ .sType = ..., .flags = ... }` leaves the rest at their zero values, which is what Vulkan expects of unused fields.
- **Enums and flags** are `c_uint` (or `u64` for the `*2` flags) fields, and the constants are `c_int` or typed consts; comptime-known values coerce, so `.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR` just works, and `a | b` on two constants is still comptime.
- **`[256]u8` names** (`deviceName`, `layerName`) are fixed arrays with a 0 terminator somewhere inside: `std.mem.sliceTo(&name, 0)`.

### Code
`src/vk.zig`:
```zig
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
```

## 10.3 Instance and device

### Why
Vulkan's first two objects are the *instance*, the connection to the loader and the drivers it finds, and the *device*, our handle to one GPU. Between them sits a choice: which *physical device* (the machine here has three: an integrated Intel GPU, a discrete NVIDIA one, and Mesa's software renderer), and which *queue family* (GPUs expose several queues with different abilities; we need one that can do graphics and, with a window, present to its surface). The window's surface has to exist before that choice, and the surface needs the instance; hence `Context` is built in two steps with the surface created between them.

### How
- **Layers and extensions.** Layers wrap the API (the validation layer checks every call against the spec and prints violations); extensions add functions (the window system's surface extension, the swapchain extension). Both are requested by name, as C strings, in arrays whose pointers go into the create-info structs: `[_][*c]const u8{...}` and `&layers`.
- **`pNext` chains.** Newer features are requested through structs chained off `pNext`: `VkPhysicalDeviceVulkan13Features` with `dynamicRendering` and `synchronization2` set, pointed to by `VkDeviceCreateInfo.pNext`. The pointer type is `?*const anyopaque`, so any struct pointer coerces; Vulkan reads `sType` to know what it got.
- **Choosing a device.** Every device is listed (with index, name, API version and type) so `--device N` has something to refer to; `score` prefers discrete over integrated over software, and `preferred` overrides it. A device without a usable queue family is marked and skipped. On a machine whose discrete GPU is busy with other work, `--device 0` keeps this program on the integrated one.
- **Two-step enumeration** is Vulkan's pattern for arrays: call with a null pointer to get the count, allocate, call again to fill. `vkEnumeratePhysicalDevices`, `vkGetPhysicalDeviceQueueFamilyProperties`, `vkEnumerateInstanceLayerProperties` and the swapchain queries all work this way, and `gpa.alloc` + `defer free` fits it exactly.
- **Teardown order.** Objects created from the device must be destroyed before the device, the device before the instance, and nothing while the GPU is still working: `deinit` waits for idle, then reverses the creation order. The callers' `defer`s run in reverse order too, so swapchain, pipeline and frame objects are gone before `ctx.deinit()` runs.
- **Memory types.** Vulkan separates objects from the memory behind them, and a GPU has several memory types (device-local and fast, host-visible and slow, ...). `findMemoryType` finds one that the resource accepts and that has the properties asked for; the offscreen target uses it twice.

### Code
`src/Context.zig`:
```zig
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
```

## 10.4 The swapchain

### Why
A window doesn't give you one image to draw into; it gives you a *swapchain*, a small ring of images owned by the presentation engine. Each frame you *acquire* one, draw into it, and *present* it; the display shows the previous one meanwhile, so there's never a half-drawn frame on screen. The swapchain's size is the window's, so when the window is resized the swapchain is thrown away and made again.

### How
- **Capabilities, formats, present modes** are queried from the surface. The format chosen is sRGB BGRA when offered (so the values the shader writes are treated as perceptual colors); the extent is the surface's current extent unless it leaves the choice to us; the image count is one more than the minimum, so the driver always has a spare and we never stall on it.
- **`VK_PRESENT_MODE_FIFO_KHR`** is vsync: frames are shown in order at the monitor's rate, never tearing. It's the only mode Vulkan guarantees, so it needs no fallback. (`MAILBOX` would render as fast as possible and show the latest.)
- **Images and views.** The swapchain owns its images; we get their handles and make a `VkImageView` for each, which is what rendering binds to. Both arrays are allocated with the `gpa` and freed in `deinit`.
- **`oldSwapchain`** on recreation lets the driver reuse what it can; the old swapchain is destroyed *after* the new one exists.
- **`errdefer`** covers the partially built state: if a view fails to create, the swapchain and arrays made so far are released. (Views already created would leak in that case; a loop with a counter and an `errdefer` over the prefix is the full fix, left as an exercise.)

### Code
`src/Swapchain.zig`:
```zig
//! The swapchain: the set of images the window system shows, in turn. We acquire one, draw into
//! it, and present it; meanwhile the display shows the previous one. It is recreated whenever
//! the window changes size.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vk = @import("vk.zig");
const c = vk.c;
const Context = @import("Context.zig");

const Swapchain = @This();

gpa: Allocator,
device: c.VkDevice,
handle: c.VkSwapchainKHR,
format: c.VkFormat,
extent: c.VkExtent2D,
images: []c.VkImage,
views: []c.VkImageView,

/// `width` and `height` are the window's size in pixels, used when the surface leaves the choice
/// to us. `old` is the previous swapchain during a resize, which lets the driver reuse resources.
pub fn init(gpa: Allocator, ctx: *const Context, width: u32, height: u32, old: c.VkSwapchainKHR) !Swapchain {
    var caps: c.VkSurfaceCapabilitiesKHR = .{};
    try vk.check(c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(ctx.physical, ctx.surface, &caps));

    // The format: sRGB BGRA if the surface offers it (it almost always does), else whatever is first.
    var format_count: u32 = 0;
    try vk.check(c.vkGetPhysicalDeviceSurfaceFormatsKHR(ctx.physical, ctx.surface, &format_count, null));
    const formats = try gpa.alloc(c.VkSurfaceFormatKHR, format_count);
    defer gpa.free(formats);
    try vk.check(c.vkGetPhysicalDeviceSurfaceFormatsKHR(ctx.physical, ctx.surface, &format_count, formats.ptr));
    var chosen = formats[0];
    for (formats) |f| {
        if (f.format == c.VK_FORMAT_B8G8R8A8_SRGB and f.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) chosen = f;
    }

    // The size: the surface's current extent, unless it says "you choose" with the maximum value.
    const extent = if (caps.currentExtent.width != std.math.maxInt(u32))
        caps.currentExtent
    else
        c.VkExtent2D{
            .width = std.math.clamp(width, caps.minImageExtent.width, caps.maxImageExtent.width),
            .height = std.math.clamp(height, caps.minImageExtent.height, caps.maxImageExtent.height),
        };

    // One more image than the minimum, so we never wait for the driver to release one.
    var image_count = caps.minImageCount + 1;
    if (caps.maxImageCount > 0) image_count = @min(image_count, caps.maxImageCount);

    const info = c.VkSwapchainCreateInfoKHR{
        .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = ctx.surface,
        .minImageCount = image_count,
        .imageFormat = chosen.format,
        .imageColorSpace = chosen.colorSpace,
        .imageExtent = extent,
        .imageArrayLayers = 1,
        .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        .preTransform = caps.currentTransform,
        .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        // FIFO is vsync: always available, never tears. The frame rate becomes the monitor's.
        .presentMode = c.VK_PRESENT_MODE_FIFO_KHR,
        .clipped = c.VK_TRUE,
        .oldSwapchain = old,
    };
    var handle: c.VkSwapchainKHR = null;
    try vk.check(c.vkCreateSwapchainKHR(ctx.device, &info, null, &handle));
    errdefer c.vkDestroySwapchainKHR(ctx.device, handle, null);

    // The images belong to the swapchain; we only get handles to them, and make a view of each.
    var count: u32 = 0;
    try vk.check(c.vkGetSwapchainImagesKHR(ctx.device, handle, &count, null));
    const images = try gpa.alloc(c.VkImage, count);
    errdefer gpa.free(images);
    try vk.check(c.vkGetSwapchainImagesKHR(ctx.device, handle, &count, images.ptr));
    const views = try gpa.alloc(c.VkImageView, count);
    errdefer gpa.free(views);
    for (images, views) |image, *view| view.* = try vk.createImageView(ctx.device, image, chosen.format);

    return .{
        .gpa = gpa,
        .device = ctx.device,
        .handle = handle,
        .format = chosen.format,
        .extent = extent,
        .images = images,
        .views = views,
    };
}

pub fn deinit(self: *Swapchain) void {
    for (self.views) |view| c.vkDestroyImageView(self.device, view, null);
    c.vkDestroySwapchainKHR(self.device, self.handle, null);
    self.gpa.free(self.views);
    self.gpa.free(self.images);
    self.* = undefined;
}
```

## 10.5 Shaders and the pipeline

### Why
The GPU runs two small programs per triangle: the *vertex shader*, once per vertex, which decides where on screen it goes, and the *fragment shader*, once per pixel covered, which decides its color. They're written in GLSL and compiled to SPIR-V, a binary intermediate form, which is what Vulkan accepts. Around them, the *pipeline* fixes every other setting of the drawing process (how vertices are assembled, how triangles are rasterized, how colors are blended) in one object, created up front so the driver can compile it all at once. This triangle needs no vertex buffer: the three positions and colors live in the vertex shader itself, indexed by `gl_VertexIndex`.

### How
- **Push constants** are the smallest way to get data to a shader: a few bytes recorded into the command buffer. The GLSL `layout(push_constant) uniform Push { float angle; float aspect; }` and the Zig `extern struct { angle: f32, aspect: f32 }` must agree byte for byte; a test checks the size and offsets. The pipeline *layout* declares the range (8 bytes, vertex stage).
- **Embedding SPIR-V.** `@embedFile("triangle_vert")` returns a pointer to a byte array; `.*` copies it into a `const` declared `align(4)`, because SPIR-V is read as 32-bit words and the bytes must be aligned for that. `std.mem.bytesAsSlice(u32, ...)` reinterprets them.
- **Dynamic rendering** (Vulkan 1.3) does away with render pass and framebuffer objects. The pipeline is told the attachment format through `VkPipelineRenderingCreateInfo` in its `pNext`, and `renderPass` stays null. At draw time, `vkCmdBeginRendering` names the image view directly.
- **Dynamic state.** The viewport and scissor are marked dynamic, so one pipeline serves every window size; they're set per frame with `vkCmdSetViewport` and `vkCmdSetScissor`.
- **Shader modules are temporary:** once the pipeline is created they can be destroyed, so they're `defer`red inside `init`.
- **Cull mode none** means the triangle stays visible whichever way it spins (after half a turn its winding order flips, and back-face culling would hide it).

### Code
`shaders/triangle.vert`:
```glsl
#version 450
// The vertex shader: three vertices, positions and colors built in, rotated by the angle the
// program pushes each frame. gl_VertexIndex is 0, 1, 2 for the three invocations of a draw of 3.

layout(push_constant) uniform Push {
    float angle;
    float aspect;
} push;

layout(location = 0) out vec3 color;

const vec2 positions[3] = vec2[](vec2(0.0, -0.6), vec2(0.55, 0.5), vec2(-0.55, 0.5));
const vec3 colors[3] = vec3[](vec3(1.0, 0.2, 0.2), vec3(0.2, 1.0, 0.3), vec3(0.3, 0.4, 1.0));

void main() {
    float c = cos(push.angle);
    float s = sin(push.angle);
    vec2 p = positions[gl_VertexIndex];
    vec2 rotated = vec2(c * p.x - s * p.y, s * p.x + c * p.y);
    // Divide x by the aspect ratio so the triangle isn't stretched by a non-square window.
    gl_Position = vec4(rotated.x / push.aspect, rotated.y, 0.0, 1.0);
    color = colors[gl_VertexIndex];
}
```
`shaders/triangle.frag`:
```glsl
#version 450
// The fragment shader: the color interpolated across the triangle from the three vertices.

layout(location = 0) in vec3 color;
layout(location = 0) out vec4 out_color;

void main() {
    out_color = vec4(color, 1.0);
}
```
`src/Pipeline.zig`:
```zig
//! The graphics pipeline: the two shaders plus every fixed-function setting between them, baked
//! into one object. Vulkan wants all of it up front so the driver can compile the whole thing
//! once; the only things left dynamic here are the viewport and scissor (they follow the window
//! size) and the push constants (new values every frame).

const std = @import("std");
const vk = @import("vk.zig");
const c = vk.c;

const Pipeline = @This();

device: c.VkDevice,
layout: c.VkPipelineLayout,
handle: c.VkPipeline,

/// What the vertex shader receives each frame. extern struct: its layout must match the GLSL
/// `layout(push_constant) uniform Push { float angle; float aspect; }` byte for byte.
pub const PushConstants = extern struct {
    angle: f32,
    aspect: f32,
};

// The SPIR-V the build compiled from shaders/*.glsl, as bytes in the executable. SPIR-V is a
// stream of 32-bit words, so the bytes must sit at a 4-byte boundary: align(4) on the copy.
const vertex_spirv align(4) = @embedFile("triangle_vert").*;
const fragment_spirv align(4) = @embedFile("triangle_frag").*;

/// `color_format` is the format of the images this pipeline will draw into: with dynamic
/// rendering there is no render pass object, the pipeline just needs to know the format.
pub fn init(device: c.VkDevice, color_format: c.VkFormat) !Pipeline {
    const vertex = try createShaderModule(device, &vertex_spirv);
    defer c.vkDestroyShaderModule(device, vertex, null);
    const fragment = try createShaderModule(device, &fragment_spirv);
    defer c.vkDestroyShaderModule(device, fragment, null);

    // The layout describes what the shaders can read from outside: here only the push constants.
    const push_range = c.VkPushConstantRange{
        .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT,
        .offset = 0,
        .size = @sizeOf(PushConstants),
    };
    const layout_info = c.VkPipelineLayoutCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push_range,
    };
    var layout: c.VkPipelineLayout = null;
    try vk.check(c.vkCreatePipelineLayout(device, &layout_info, null, &layout));
    errdefer c.vkDestroyPipelineLayout(device, layout, null);

    const stages = [_]c.VkPipelineShaderStageCreateInfo{
        .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = vertex, .pName = "main" },
        .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = fragment, .pName = "main" },
    };
    // No vertex buffers: the vertex shader has the three positions built in.
    const vertex_input = c.VkPipelineVertexInputStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    };
    const input_assembly = c.VkPipelineInputAssemblyStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
    };
    // One viewport and one scissor, set at draw time (see the dynamic states below).
    const viewport_state = c.VkPipelineViewportStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1,
        .scissorCount = 1,
    };
    const rasterization = c.VkPipelineRasterizationStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = c.VK_POLYGON_MODE_FILL,
        .cullMode = c.VK_CULL_MODE_NONE,
        .frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE,
        .lineWidth = 1.0,
    };
    const multisample = c.VkPipelineMultisampleStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT,
    };
    // Write all four channels, no blending: the triangle simply replaces what's underneath.
    const blend_attachment = c.VkPipelineColorBlendAttachmentState{
        .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
    };
    const color_blend = c.VkPipelineColorBlendStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .attachmentCount = 1,
        .pAttachments = &blend_attachment,
    };
    const dynamic_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
    const dynamic = c.VkPipelineDynamicStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .dynamicStateCount = dynamic_states.len,
        .pDynamicStates = &dynamic_states,
    };
    // Dynamic rendering (Vulkan 1.3): instead of a render pass object, the pipeline is told the
    // attachment formats through this struct in the pNext chain, and renderPass stays null.
    const rendering = c.VkPipelineRenderingCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
        .colorAttachmentCount = 1,
        .pColorAttachmentFormats = &color_format,
    };
    const info = c.VkGraphicsPipelineCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .pNext = &rendering,
        .stageCount = stages.len,
        .pStages = &stages,
        .pVertexInputState = &vertex_input,
        .pInputAssemblyState = &input_assembly,
        .pViewportState = &viewport_state,
        .pRasterizationState = &rasterization,
        .pMultisampleState = &multisample,
        .pColorBlendState = &color_blend,
        .pDynamicState = &dynamic,
        .layout = layout,
        .renderPass = null,
    };
    var handle: c.VkPipeline = null;
    try vk.check(c.vkCreateGraphicsPipelines(device, null, 1, &info, null, &handle));
    return .{ .device = device, .layout = layout, .handle = handle };
}

pub fn deinit(self: *Pipeline) void {
    c.vkDestroyPipeline(self.device, self.handle, null);
    c.vkDestroyPipelineLayout(self.device, self.layout, null);
    self.* = undefined;
}

/// A shader module is SPIR-V handed to the driver. The bytes are reinterpreted as u32 words,
/// which is why the embedded copies are 4-byte aligned.
fn createShaderModule(device: c.VkDevice, spirv: []align(4) const u8) !c.VkShaderModule {
    const words = std.mem.bytesAsSlice(u32, spirv);
    const info = c.VkShaderModuleCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = spirv.len,
        .pCode = words.ptr,
    };
    var module: c.VkShaderModule = null;
    try vk.check(c.vkCreateShaderModule(device, &info, null, &module));
    return module;
}

// Tests

test "the embedded shaders are SPIR-V" {
    // Every SPIR-V module starts with the magic number 0x07230203.
    const vertex_words = std.mem.bytesAsSlice(u32, &vertex_spirv);
    const fragment_words = std.mem.bytesAsSlice(u32, &fragment_spirv);
    try std.testing.expectEqual(0x07230203, vertex_words[0]);
    try std.testing.expectEqual(0x07230203, fragment_words[0]);
    try std.testing.expectEqual(0, vertex_spirv.len % 4);
}

test "push constants have the layout the shader expects" {
    try std.testing.expectEqual(8, @sizeOf(PushConstants));
    try std.testing.expectEqual(0, @offsetOf(PushConstants, "angle"));
    try std.testing.expectEqual(4, @offsetOf(PushConstants, "aspect"));
}
```

## 10.6 Recording a frame

### Why
Vulkan never draws when you call it. Drawing commands are *recorded* into a command buffer, and the buffer is *submitted* to a queue, where the GPU executes it later, asynchronously. Two things go into ours each frame: *barriers*, which move the image between layouts (an image is stored differently depending on whether it's being drawn into, presented, or copied from, and the transition must be explicit), and the drawing itself: begin rendering with a clear, bind the pipeline, set viewport and scissor, push the constants, draw three vertices, end.

### How
- **`VkImageMemoryBarrier2`** says: everything in `srcStageMask` that does `srcAccessMask` to this image must finish; then the layout changes from `oldLayout` to `newLayout`; then `dstStageMask` may start doing `dstAccessMask`. The first barrier of a frame goes from `UNDEFINED` (we don't care what was there; it's about to be cleared) to `COLOR_ATTACHMENT_OPTIMAL`; the last from that to `PRESENT_SRC_KHR` (for the window) or `TRANSFER_SRC_OPTIMAL` (for the readback). Synchronization2 is the Vulkan 1.3 form, with 64-bit stage and access masks and one `VkDependencyInfo` carrying the barriers.
- **`vkCmdBeginRendering`** takes a `VkRenderingInfo` naming the attachments: our one color attachment, with `loadOp = CLEAR` (the clear color is applied as the image is loaded, for free) and `storeOp = STORE`.
- **Push constants and the draw.** `vkCmdPushConstants` copies the 8 bytes into the command stream; `vkCmdDraw(cb, 3, 1, 0, 0)` is three vertices, one instance. The vertex shader runs three times with `gl_VertexIndex` 0, 1, 2.
- **`pushConstantsFor`** derives the angle from elapsed time and the aspect ratio from the extent, and is pure, so it has a test.

### Code
`src/draw.zig`:
```zig
//! Recording the drawing: the commands that go into a command buffer each frame. Vulkan doesn't
//! draw when you call these; it records them, and the GPU executes the buffer when it's submitted.

const std = @import("std");
const vk = @import("vk.zig");
const c = vk.c;
const Pipeline = @import("Pipeline.zig");

/// The background color.
pub const clear_color = [4]f32{ 0.05, 0.06, 0.10, 1.0 };

/// An image layout transition with a pipeline barrier (synchronization2 form). Images live in
/// layouts optimized for a purpose (being drawn into, being presented, being copied from), and
/// every change of purpose is a barrier: "everything in `src_stage` that touches this image
/// finishes, the layout changes, then `dst_stage` may begin".
pub fn transition(
    cb: c.VkCommandBuffer,
    image: c.VkImage,
    old_layout: c.VkImageLayout,
    new_layout: c.VkImageLayout,
    src_stage: c.VkPipelineStageFlags2,
    src_access: c.VkAccessFlags2,
    dst_stage: c.VkPipelineStageFlags2,
    dst_access: c.VkAccessFlags2,
) void {
    const barrier = c.VkImageMemoryBarrier2{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .srcStageMask = src_stage,
        .srcAccessMask = src_access,
        .dstStageMask = dst_stage,
        .dstAccessMask = dst_access,
        .oldLayout = old_layout,
        .newLayout = new_layout,
        .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    const dependency = c.VkDependencyInfo{
        .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
        .imageMemoryBarrierCount = 1,
        .pImageMemoryBarriers = &barrier,
    };
    c.vkCmdPipelineBarrier2(cb, &dependency);
}

/// Clears the image and draws the triangle into it. The image must already be in
/// COLOR_ATTACHMENT_OPTIMAL layout; it stays there.
pub fn triangle(cb: c.VkCommandBuffer, pipeline: Pipeline, view: c.VkImageView, extent: c.VkExtent2D, push: Pipeline.PushConstants) void {
    // Dynamic rendering: say which image to draw into, how to start (clear) and how to end (store).
    const attachment = c.VkRenderingAttachmentInfo{
        .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
        .imageView = view,
        .imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
        .clearValue = .{ .color = .{ .float32 = clear_color } },
    };
    const rendering = c.VkRenderingInfo{
        .sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO,
        .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent },
        .layerCount = 1,
        .colorAttachmentCount = 1,
        .pColorAttachments = &attachment,
    };
    c.vkCmdBeginRendering(cb, &rendering);

    c.vkCmdBindPipeline(cb, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.handle);
    // The two dynamic states: the whole image, whatever its size this frame.
    const viewport = c.VkViewport{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(extent.width),
        .height = @floatFromInt(extent.height),
        .minDepth = 0,
        .maxDepth = 1,
    };
    c.vkCmdSetViewport(cb, 0, 1, &viewport);
    const scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = extent };
    c.vkCmdSetScissor(cb, 0, 1, &scissor);
    // Push constants: a few bytes sent along with the commands, the cheapest way to get a value
    // to a shader. Three vertices, one instance.
    c.vkCmdPushConstants(cb, pipeline.layout, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(Pipeline.PushConstants), &push);
    c.vkCmdDraw(cb, 3, 1, 0, 0);

    c.vkCmdEndRendering(cb);
}

/// The push constants for a frame: the rotation angle from the time, the aspect ratio from the size.
pub fn pushConstantsFor(seconds: f32, extent: c.VkExtent2D) Pipeline.PushConstants {
    return .{
        .angle = seconds * 0.8,
        .aspect = @as(f32, @floatFromInt(extent.width)) / @as(f32, @floatFromInt(@max(extent.height, 1))),
    };
}

test "push constants follow the window" {
    const square = pushConstantsFor(0, .{ .width = 400, .height = 400 });
    try std.testing.expectEqual(1.0, square.aspect);
    try std.testing.expectEqual(0.0, square.angle);
    const wide = pushConstantsFor(2.0, .{ .width = 800, .height = 400 });
    try std.testing.expectEqual(2.0, wide.aspect);
    try std.testing.expectApproxEqAbs(1.6, wide.angle, 1e-6);
}
```

## 10.7 The frame loop: frames in flight

### Why
The CPU and GPU run in parallel, and the point of a frame loop is to keep both busy: while the GPU draws frame N, the CPU records frame N+1. That needs two of everything the CPU touches per frame (command buffer, fence, acquire semaphore), and a way to know when the GPU is done with each: *fences* (GPU signals, CPU waits) and *semaphores* (GPU signals, GPU waits). Three synchronization points govern every frame: don't record into a command buffer the GPU is still reading (fence); don't draw into an image the presentation engine hasn't released (acquire semaphore); don't present an image that isn't finished (render-finished semaphore).

### How
- **Two in flight.** `Frames` has arrays of two command buffers, fences and `image_available` semaphores, indexed by `current`, which alternates. The fences start *signaled* so the first wait returns at once. `render_finished` has one semaphore per swapchain image, because presentation keeps hold of the semaphore until the image is shown, and images and frames don't line up one-to-one.
- **The sequence** in `render`: wait for this slot's fence (the GPU finished with this slot's previous frame); acquire an image, with the slot's semaphore to be signaled when it's free; reset the fence; reset and record the command buffer; submit, waiting on `image_available` at the color-output stage (earlier stages can run before the image is ready) and signaling `render_finished[image]` and the fence; present, waiting on `render_finished[image]`.
- **Out of date.** When the window is resized, acquire or present reports `VK_ERROR_OUT_OF_DATE_KHR` (or `SUBOPTIMAL`): the swapchain no longer matches the surface. The loop then waits for the device to go idle, builds a new swapchain from the old, destroys the old, recreates the per-image semaphores (the image count may have changed), and tries again. SDL's `SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED` triggers the same path proactively. A minimized window has size 0 and is skipped.
- **Events** come from `SDL_PollEvent` in a loop until it returns false; `SDL_Event` is a C union whose `type` field says which member is valid, so `event.key.scancode` is read only for key events.
- **Shutdown:** `vkDeviceWaitIdle` before the `defer`s start destroying things the GPU might still be using.

### Code
`src/main.zig`, part 1 of 3 (the window path):
```zig
//! Lecture 10: a window and a GPU. SDL3 opens the window and hands us a Vulkan surface; Vulkan
//! draws a spinning triangle into it. Or, without a window, into an image that's written to a file.
//!
//!   zig build run                                  a window, until closed (or Escape)
//!   zig build run -- --frames 300                  a window, 300 frames, then exit
//!   zig build run -- --headless --out frame.ppm    no window: render and save one frame
//!   options: --device N  --validate  --size WxH

const std = @import("std");
const vk = @import("vk.zig");
const c = vk.c;
const Context = @import("Context.zig");
const Swapchain = @import("Swapchain.zig");
const Pipeline = @import("Pipeline.zig");
const Offscreen = @import("Offscreen.zig");
const draw = @import("draw.zig");

test {
    _ = vk;
    _ = Context;
    _ = Pipeline;
    _ = draw;
}

const Options = struct {
    headless: bool = false,
    /// How many frames to render; 0 means until the window is closed (1 when headless).
    frames: u32 = 0,
    device: ?u32 = null,
    validate: bool = false,
    width: u32 = 960,
    height: u32 = 640,
    out: [:0]const u8 = "frame.ppm",
};

fn parseArgs(args: []const [:0]const u8) !Options {
    var options = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const value: ?[:0]const u8 = if (i + 1 < args.len) args[i + 1] else null;
        if (std.mem.eql(u8, arg, "--headless")) {
            options.headless = true;
        } else if (std.mem.eql(u8, arg, "--validate")) {
            options.validate = true;
        } else if (std.mem.eql(u8, arg, "--frames")) {
            options.frames = try std.fmt.parseInt(u32, value orelse return error.MissingValue, 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--device")) {
            options.device = try std.fmt.parseInt(u32, value orelse return error.MissingValue, 10);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--out")) {
            options.out = value orelse return error.MissingValue;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--size")) {
            const w, const h = std.mem.cutScalar(u8, value orelse return error.MissingValue, 'x') orelse return error.BadSize;
            options.width = try std.fmt.parseInt(u32, w, 10);
            options.height = try std.fmt.parseInt(u32, h, 10);
            i += 1;
        } else {
            return error.UnknownOption;
        }
    }
    return options;
}

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = parseArgs(args) catch {
        std.debug.print("usage: lecture_10 [--headless] [--frames N] [--device N] [--validate] [--size WxH] [--out FILE]\n", .{});
        return 2;
    };
    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};
    if (options.headless) {
        try runHeadless(init, options, out);
    } else {
        try runWindow(init, options, out);
    }
    return 0;
}

/// The window path: SDL for the window, surface and events; Vulkan for everything else.
fn runWindow(init: std.process.Init, options: Options, out: *std.Io.Writer) !void {
    const gpa = init.gpa;

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return sdlError("SDL_Init");
    defer c.SDL_Quit();
    const window = c.SDL_CreateWindow("Zig + Vulkan", @intCast(options.width), @intCast(options.height), c.SDL_WINDOW_VULKAN | c.SDL_WINDOW_RESIZABLE) orelse return sdlError("SDL_CreateWindow");
    defer c.SDL_DestroyWindow(window);

    // SDL knows which instance extensions this window system needs (VK_KHR_surface and the
    // platform's, VK_KHR_wayland_surface or VK_KHR_xcb_surface here).
    var extension_count: u32 = 0;
    const extension_names = c.SDL_Vulkan_GetInstanceExtensions(&extension_count);
    if (extension_names == null) return sdlError("SDL_Vulkan_GetInstanceExtensions");
    var ctx = try Context.init(gpa, .{ .instance_extensions = extension_names[0..extension_count], .validation = options.validate });
    defer ctx.deinit();

    // The surface is the window as Vulkan sees it. SDL creates it, since it knows the window system.
    var surface: c.VkSurfaceKHR = null;
    if (!c.SDL_Vulkan_CreateSurface(window, ctx.instance, null, &surface)) return sdlError("SDL_Vulkan_CreateSurface");
    try ctx.initDevice(surface, options.device, out);
    try out.print("rendering on {s}\n", .{ctx.deviceName()});
    try out.flush();

    var pixel_width: c_int = 0;
    var pixel_height: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(window, &pixel_width, &pixel_height);
    var swapchain = try Swapchain.init(gpa, &ctx, @intCast(pixel_width), @intCast(pixel_height), null);
    defer swapchain.deinit();
    var pipeline = try Pipeline.init(ctx.device, swapchain.format);
    defer pipeline.deinit();
    var frames = try Frames.init(gpa, &ctx, swapchain.images.len);
    defer frames.deinit();

    const start = c.SDL_GetTicksNS();
    var frame_count: u32 = 0;
    var resized = false;
    main_loop: while (options.frames == 0 or frame_count < options.frames) {
        // Events first: the window system's messages since the last frame.
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => break :main_loop,
                c.SDL_EVENT_KEY_DOWN => if (event.key.scancode == c.SDL_SCANCODE_ESCAPE) break :main_loop,
                c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => resized = true,
                else => {},
            }
        }

        const seconds = @as(f32, @floatFromInt(c.SDL_GetTicksNS() - start)) / 1e9;
        const outcome = frames.render(&ctx, &swapchain, pipeline, draw.pushConstantsFor(seconds, swapchain.extent)) catch |err| switch (err) {
            error.OutOfDate => Frames.Outcome.needs_recreate,
            else => return err,
        };
        if (outcome == .needs_recreate or resized) {
            resized = false;
            _ = c.SDL_GetWindowSizeInPixels(window, &pixel_width, &pixel_height);
            if (pixel_width == 0 or pixel_height == 0) continue; // minimized: nothing to draw into
            try recreateSwapchain(gpa, &ctx, &swapchain, &frames, @intCast(pixel_width), @intCast(pixel_height));
            continue;
        }
        frame_count += 1;
    }
    try vk.check(c.vkDeviceWaitIdle(ctx.device));

    const elapsed = @as(f64, @floatFromInt(c.SDL_GetTicksNS() - start)) / 1e9;
    try out.print("{d} frames in {d:.2} s ({d:.1} per second, vsync)\n", .{ frame_count, elapsed, @as(f64, @floatFromInt(frame_count)) / @max(elapsed, 1e-9) });
}

/// A swapchain is immutable: a new size means a new swapchain (and new views, and semaphores for
/// its images). The old one is passed in so the driver can hand over what it can.
fn recreateSwapchain(gpa: std.mem.Allocator, ctx: *Context, swapchain: *Swapchain, frames: *Frames, width: u32, height: u32) !void {
    try vk.check(c.vkDeviceWaitIdle(ctx.device));
    var replacement = try Swapchain.init(gpa, ctx, width, height, swapchain.handle);
    swapchain.deinit();
    swapchain.* = replacement;
    replacement = undefined;
    try frames.resetImageSemaphores(ctx, swapchain.images.len);
}
```
`extension_names[0..extension_count]` slices a C pointer (`[*c]const [*c]const u8`) into a Zig slice of C strings, which is the `[]const [*c]const u8` the context wants; a C pointer supports slicing like a many-item pointer.

`src/main.zig`, part 2 of 3 (the frames):
```zig
/// Per-frame state, with two frames in flight: while the GPU draws frame N, the CPU records
/// frame N+1. Each in-flight frame has its own command buffer, fence and "image acquired"
/// semaphore; each swapchain image has its own "rendering finished" semaphore.
const Frames = struct {
    const in_flight = 2;

    gpa: std.mem.Allocator,
    device: c.VkDevice,
    command_buffers: [in_flight]c.VkCommandBuffer = .{ null, null },
    /// Signaled by the GPU when the frame's commands have finished; the CPU waits on it before
    /// reusing the frame's command buffer.
    fences: [in_flight]c.VkFence = .{ null, null },
    /// Signaled by the presentation engine when the acquired image is free to draw into.
    image_available: [in_flight]c.VkSemaphore = .{ null, null },
    /// Signaled when drawing into that image is done; presentation waits for it.
    render_finished: []c.VkSemaphore,
    current: usize = 0,

    const Outcome = enum { presented, needs_recreate };

    fn init(gpa: std.mem.Allocator, ctx: *const Context, image_count: usize) !Frames {
        var self = Frames{ .gpa = gpa, .device = ctx.device, .render_finished = &.{} };
        try ctx.allocateCommandBuffers(&self.command_buffers);
        for (&self.fences) |*fence| fence.* = try vk.createFence(ctx.device, true);
        for (&self.image_available) |*semaphore| semaphore.* = try vk.createSemaphore(ctx.device);
        try self.resetImageSemaphores(ctx, image_count);
        return self;
    }

    fn resetImageSemaphores(self: *Frames, ctx: *const Context, image_count: usize) !void {
        for (self.render_finished) |semaphore| c.vkDestroySemaphore(ctx.device, semaphore, null);
        self.gpa.free(self.render_finished);
        self.render_finished = try self.gpa.alloc(c.VkSemaphore, image_count);
        for (self.render_finished) |*semaphore| semaphore.* = try vk.createSemaphore(ctx.device);
    }

    /// One frame: wait for this slot's previous frame, acquire an image, record, submit, present.
    fn render(self: *Frames, ctx: *const Context, swapchain: *const Swapchain, pipeline: Pipeline, push: Pipeline.PushConstants) !Outcome {
        const device = ctx.device;
        const slot = self.current;
        try vk.check(c.vkWaitForFences(device, 1, &self.fences[slot], c.VK_TRUE, std.math.maxInt(u64)));

        // Which image to draw into this time. The semaphore is signaled when it's actually free.
        var image_index: u32 = 0;
        const acquire = c.vkAcquireNextImageKHR(device, swapchain.handle, std.math.maxInt(u64), self.image_available[slot], null, &image_index);
        if (acquire == c.VK_ERROR_OUT_OF_DATE_KHR) return .needs_recreate;
        try vk.check(acquire);
        try vk.check(c.vkResetFences(device, 1, &self.fences[slot]));

        // Record: undefined -> color attachment, draw, color attachment -> present.
        const cb = self.command_buffers[slot];
        try vk.check(c.vkResetCommandBuffer(cb, 0));
        const begin = c.VkCommandBufferBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        };
        try vk.check(c.vkBeginCommandBuffer(cb, &begin));
        const image = swapchain.images[image_index];
        draw.transition(cb, image, c.VK_IMAGE_LAYOUT_UNDEFINED, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT, 0, c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT);
        draw.triangle(cb, pipeline, swapchain.views[image_index], swapchain.extent, push);
        draw.transition(cb, image, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT, c.VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT, 0);
        try vk.check(c.vkEndCommandBuffer(cb));

        // Submit: wait for the image (at the stage that writes to it), signal when done, and
        // signal the fence so the CPU knows when this slot is free again.
        const wait_info = c.VkSemaphoreSubmitInfo{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
            .semaphore = self.image_available[slot],
            .stageMask = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
        };
        const signal_info = c.VkSemaphoreSubmitInfo{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
            .semaphore = self.render_finished[image_index],
            .stageMask = c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
        };
        const cb_info = c.VkCommandBufferSubmitInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
            .commandBuffer = cb,
        };
        const submit = c.VkSubmitInfo2{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
            .waitSemaphoreInfoCount = 1,
            .pWaitSemaphoreInfos = &wait_info,
            .commandBufferInfoCount = 1,
            .pCommandBufferInfos = &cb_info,
            .signalSemaphoreInfoCount = 1,
            .pSignalSemaphoreInfos = &signal_info,
        };
        try vk.check(c.vkQueueSubmit2(ctx.queue, 1, &submit, self.fences[slot]));

        // Present: show the image once rendering into it has finished.
        const present = c.VkPresentInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &self.render_finished[image_index],
            .swapchainCount = 1,
            .pSwapchains = &swapchain.handle,
            .pImageIndices = &image_index,
        };
        const presented = c.vkQueuePresentKHR(ctx.queue, &present);
        self.current = (slot + 1) % in_flight;
        if (presented == c.VK_ERROR_OUT_OF_DATE_KHR or presented == c.VK_SUBOPTIMAL_KHR) return .needs_recreate;
        try vk.check(presented);
        return .presented;
    }

    /// Runs before the context's deinit (defers run in reverse order), while the device still exists.
    fn deinit(self: *Frames) void {
        for (self.render_finished) |semaphore| c.vkDestroySemaphore(self.device, semaphore, null);
        self.gpa.free(self.render_finished);
        for (self.image_available) |semaphore| c.vkDestroySemaphore(self.device, semaphore, null);
        for (self.fences) |fence| c.vkDestroyFence(self.device, fence, null);
        self.* = undefined;
    }
};
```

## 10.8 Headless: an offscreen target

### Why
Everything above can run without a window. An image we create ourselves takes the swapchain image's place; after drawing, a barrier moves it to a transfer layout and `vkCmdCopyImageToBuffer` copies the pixels into a buffer in host-visible memory, which is mapped once and read after the fence signals. The result is written as a PPM file (a text header and raw RGB bytes). This path has no SDL in it at all, which makes it the version that runs in the test suite, on a build server, or on Mesa's software renderer.

### How
- **An image and its memory.** `vkCreateImage` makes the object; `vkGetImageMemoryRequirements` says how much memory of which types it accepts; `findMemoryType` picks a device-local one; `vkAllocateMemory` + `vkBindImageMemory` connect them. The same three steps for the buffer, with host-visible, host-coherent memory. `errdefer` at each step undoes what's done if a later one fails.
- **Mapping.** `vkMapMemory` gives a `?*anyopaque` to the buffer's memory; `@ptrCast` to `[*]u8` and a slice of the right length make it `pixels: []u8`, valid until `vkUnmapMemory` in `deinit`. With coherent memory and a fence wait after the submit, the GPU's writes are visible there without further ado.
- **The frame** in `runHeadless` is the window frame with the last barrier changed (to `TRANSFER_SRC_OPTIMAL`, for the transfer stage with read access) and the copy appended, submitted with a fence instead of semaphores, and waited for synchronously. The angle advances per frame instead of per second.
- **`writePpm`** takes a `std.Io.Dir`, so the test can write into a temporary directory and read the file back; `main` passes the current directory.

### Code
`src/Offscreen.zig`:
```zig
//! An offscreen render target: an image to draw into that no window ever shows, plus a buffer
//! the CPU can read the pixels back from. This is how the program runs without a display, and
//! how the tests check that rendering works.

const std = @import("std");
const vk = @import("vk.zig");
const c = vk.c;
const Context = @import("Context.zig");

const Offscreen = @This();

pub const format: c.VkFormat = c.VK_FORMAT_R8G8B8A8_UNORM;
pub const bytes_per_pixel = 4;

device: c.VkDevice,
extent: c.VkExtent2D,
image: c.VkImage,
image_memory: c.VkDeviceMemory,
view: c.VkImageView,
buffer: c.VkBuffer,
buffer_memory: c.VkDeviceMemory,
/// The readback buffer's memory, mapped into our address space for as long as the object lives.
pixels: []u8,

pub fn init(ctx: *const Context, width: u32, height: u32) !Offscreen {
    const device = ctx.device;
    const extent = c.VkExtent2D{ .width = width, .height = height };

    // The image: drawn into (COLOR_ATTACHMENT) and copied from (TRANSFER_SRC), in device memory.
    const image_info = c.VkImageCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = c.VK_IMAGE_TYPE_2D,
        .format = format,
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .tiling = c.VK_IMAGE_TILING_OPTIMAL,
        .usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
    };
    var image: c.VkImage = null;
    try vk.check(c.vkCreateImage(device, &image_info, null, &image));
    errdefer c.vkDestroyImage(device, image, null);

    // Vulkan separates objects from memory: ask what the image needs, allocate it, bind the two.
    var image_requirements: c.VkMemoryRequirements = .{};
    c.vkGetImageMemoryRequirements(device, image, &image_requirements);
    const image_memory = try allocate(ctx, image_requirements, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    errdefer c.vkFreeMemory(device, image_memory, null);
    try vk.check(c.vkBindImageMemory(device, image, image_memory, 0));

    const view = try vk.createImageView(device, image, format);
    errdefer c.vkDestroyImageView(device, view, null);

    // The readback buffer: copied into (TRANSFER_DST), in memory the host can map. HOST_COHERENT
    // means no explicit flush/invalidate is needed to see the device's writes.
    const size: c.VkDeviceSize = @as(u64, width) * height * bytes_per_pixel;
    const buffer_info = c.VkBufferCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = size,
        .usage = c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
    };
    var buffer: c.VkBuffer = null;
    try vk.check(c.vkCreateBuffer(device, &buffer_info, null, &buffer));
    errdefer c.vkDestroyBuffer(device, buffer, null);
    var buffer_requirements: c.VkMemoryRequirements = .{};
    c.vkGetBufferMemoryRequirements(device, buffer, &buffer_requirements);
    const buffer_memory = try allocate(ctx, buffer_requirements, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    errdefer c.vkFreeMemory(device, buffer_memory, null);
    try vk.check(c.vkBindBufferMemory(device, buffer, buffer_memory, 0));

    var mapped: ?*anyopaque = null;
    try vk.check(c.vkMapMemory(device, buffer_memory, 0, size, 0, &mapped));
    const pixels: [*]u8 = @ptrCast(mapped.?);

    return .{
        .device = device,
        .extent = extent,
        .image = image,
        .image_memory = image_memory,
        .view = view,
        .buffer = buffer,
        .buffer_memory = buffer_memory,
        .pixels = pixels[0..size],
    };
}

pub fn deinit(self: *Offscreen) void {
    c.vkUnmapMemory(self.device, self.buffer_memory);
    c.vkDestroyBuffer(self.device, self.buffer, null);
    c.vkFreeMemory(self.device, self.buffer_memory, null);
    c.vkDestroyImageView(self.device, self.view, null);
    c.vkDestroyImage(self.device, self.image, null);
    c.vkFreeMemory(self.device, self.image_memory, null);
    self.* = undefined;
}

/// Records the copy from the image (which must be in TRANSFER_SRC_OPTIMAL layout) to the buffer.
pub fn recordReadback(self: *const Offscreen, cb: c.VkCommandBuffer) void {
    const region = c.VkBufferImageCopy{
        .bufferOffset = 0,
        .bufferRowLength = 0, // tightly packed
        .bufferImageHeight = 0,
        .imageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
        .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
        .imageExtent = .{ .width = self.extent.width, .height = self.extent.height, .depth = 1 },
    };
    c.vkCmdCopyImageToBuffer(cb, self.image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, self.buffer, 1, &region);
}

fn allocate(ctx: *const Context, requirements: c.VkMemoryRequirements, properties: c.VkMemoryPropertyFlags) !c.VkDeviceMemory {
    const info = c.VkMemoryAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = requirements.size,
        .memoryTypeIndex = try ctx.findMemoryType(requirements.memoryTypeBits, properties),
    };
    var memory: c.VkDeviceMemory = null;
    try vk.check(c.vkAllocateMemory(ctx.device, &info, null, &memory));
    return memory;
}
```
`src/main.zig`, part 3 of 3 (the headless path, the PPM writer, and the tests):
```zig
/// The headless path: the same pipeline and drawing, into an offscreen image, copied back to the
/// CPU and written as a PPM file. No SDL at all.
fn runHeadless(init: std.process.Init, options: Options, out: *std.Io.Writer) !void {
    const gpa = init.gpa;
    var ctx = try Context.init(gpa, .{ .validation = options.validate });
    defer ctx.deinit();
    try ctx.initDevice(null, options.device, out);
    try out.print("rendering on {s}\n", .{ctx.deviceName()});

    var target = try Offscreen.init(&ctx, options.width, options.height);
    defer target.deinit();
    var pipeline = try Pipeline.init(ctx.device, Offscreen.format);
    defer pipeline.deinit();

    var command_buffers: [1]c.VkCommandBuffer = .{null};
    try ctx.allocateCommandBuffers(&command_buffers);
    const cb = command_buffers[0];
    const fence = try vk.createFence(ctx.device, false);
    defer c.vkDestroyFence(ctx.device, fence, null);

    const frame_count = @max(options.frames, 1);
    for (0..frame_count) |frame| {
        try vk.check(c.vkResetCommandBuffer(cb, 0));
        const begin = c.VkCommandBufferBeginInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
        try vk.check(c.vkBeginCommandBuffer(cb, &begin));
        draw.transition(cb, target.image, c.VK_IMAGE_LAYOUT_UNDEFINED, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, c.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT, 0, c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT);
        // Without a clock to follow, the angle advances a tenth of a radian per frame.
        draw.triangle(cb, pipeline, target.view, target.extent, draw.pushConstantsFor(@as(f32, @floatFromInt(frame)) * 0.125, target.extent));
        // Then: color attachment -> transfer source, and copy the pixels out.
        draw.transition(cb, target.image, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT, c.VK_PIPELINE_STAGE_2_TRANSFER_BIT, c.VK_ACCESS_2_TRANSFER_READ_BIT);
        target.recordReadback(cb);
        try vk.check(c.vkEndCommandBuffer(cb));

        const cb_info = c.VkCommandBufferSubmitInfo{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO, .commandBuffer = cb };
        const submit = c.VkSubmitInfo2{ .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2, .commandBufferInfoCount = 1, .pCommandBufferInfos = &cb_info };
        try vk.check(c.vkQueueSubmit2(ctx.queue, 1, &submit, fence));
        // The fence wait is also what makes the GPU's writes visible to the CPU.
        try vk.check(c.vkWaitForFences(ctx.device, 1, &fence, c.VK_TRUE, std.math.maxInt(u64)));
        try vk.check(c.vkResetFences(ctx.device, 1, &fence));
    }

    try writePpm(init.io, std.Io.Dir.cwd(), options.out, target.extent.width, target.extent.height, target.pixels);
    try out.print("wrote {s}: {d}x{d}, after {d} frames\n", .{ options.out, target.extent.width, target.extent.height, frame_count });
}

/// PPM: the simplest image format there is. A text header, then raw RGB bytes.
fn writePpm(io: std.Io, dir: std.Io.Dir, path: []const u8, width: u32, height: u32, rgba: []const u8) !void {
    const file = try dir.createFile(io, path, .{});
    defer file.close(io);
    var buffer: [8192]u8 = undefined;
    var writer = file.writer(io, &buffer);
    const out = &writer.interface;
    try out.print("P6\n{d} {d}\n255\n", .{ width, height });
    var i: usize = 0;
    while (i < rgba.len) : (i += Offscreen.bytes_per_pixel) try out.writeAll(rgba[i..][0..3]);
    try out.flush();
}

fn sdlError(what: []const u8) error{SdlFailed} {
    std.debug.print("{s} failed: {s}\n", .{ what, vk.cString(c.SDL_GetError()) });
    return error.SdlFailed;
}

// Tests

test "argument parsing" {
    const defaults = try parseArgs(&.{"lecture_10"});
    try std.testing.expect(!defaults.headless);
    try std.testing.expectEqual(0, defaults.frames);
    try std.testing.expectEqual(null, defaults.device);

    const custom = try parseArgs(&.{ "lecture_10", "--headless", "--frames", "3", "--device", "1", "--size", "320x200", "--out", "x.ppm", "--validate" });
    try std.testing.expect(custom.headless and custom.validate);
    try std.testing.expectEqual(3, custom.frames);
    try std.testing.expectEqual(1, custom.device);
    try std.testing.expectEqual(320, custom.width);
    try std.testing.expectEqual(200, custom.height);
    try std.testing.expectEqualStrings("x.ppm", custom.out);

    try std.testing.expectError(error.UnknownOption, parseArgs(&.{ "lecture_10", "--bogus" }));
    try std.testing.expectError(error.MissingValue, parseArgs(&.{ "lecture_10", "--frames" }));
    try std.testing.expectError(error.BadSize, parseArgs(&.{ "lecture_10", "--size", "320" }));
}

test "PPM output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    // Two pixels, RGBA: red and blue. The alpha bytes must not make it into the file.
    const rgba = [_]u8{ 255, 0, 0, 255, 0, 0, 255, 255 };
    try writePpm(io, tmp.dir, "two.ppm", 2, 1, &rgba);
    const written = try tmp.dir.readFileAlloc(io, "two.ppm", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualSlices(u8, "P6\n2 1\n255\n" ++ [_]u8{ 255, 0, 0, 0, 0, 255 }, written);
}
```

## 10.9 Running it

### How
From `lecture_10/`. The first `zig build` fetches SDL (a few seconds on a normal connection) and compiles it (about ten seconds); everything after that is cached.
```bash
zig build run
```
A 960x640 window titled "Zig + Vulkan" opens with a slowly spinning triangle, red, green and blue at its corners, on a near-black background. Resize it: the triangle keeps its proportions, because the aspect ratio is pushed every frame and the swapchain is recreated behind the scenes. Close it, or press Escape, and the program reports what it did. With a frame budget it exits on its own:
```bash
zig build run -- --frames 90 --validate
```
```text
  device 0: Intel(R) Graphics (ARL) (Vulkan 1.4.335, integrated)
  device 1: NVIDIA GeForce RTX 5070 Laptop GPU (Vulkan 1.4.351, discrete)
  device 2: llvmpipe (LLVM 21.1.8, 256 bits) (Vulkan 1.4.335, software)
rendering on NVIDIA GeForce RTX 5070 Laptop GPU
90 frames in 1.82 s (49.3 per second, vsync)
```
The rate is below 60 because the elapsed time includes creating the swapchain and pipeline; the steady state is the monitor's refresh rate. `--validate` turned on the Khronos validation layer, which printed nothing: every call conformed to the specification. To see what a violation looks like, change the first transition's old layout from `UNDEFINED` to `COLOR_ATTACHMENT_OPTIMAL` in `runHeadless` and run headless with `--validate`: the layer reports `VUID-vkCmdBeginRendering-pRenderingInfo-09592` at `vkQueueSubmit2`, explaining that the command buffer expects the image in `COLOR_ATTACHMENT_OPTIMAL` but its current layout is `UNDEFINED`, with a link to the paragraph of the specification. The program still runs (the driver happened to cope); without the layer you'd never know. `--device 0` runs on the integrated GPU instead, useful when the discrete one is busy with other work.

Without a window:
```bash
zig build run -- --headless --out frame.ppm
```
```text
  device 0: ...
rendering on NVIDIA GeForce RTX 5070 Laptop GPU
wrote frame.ppm: 960x640, after 1 frames
```
`frame.ppm` opens in any image viewer, and lecture 9's tool reads it too: `../lecture_9/zig-out/bin/lecture_9 process frame.ppm frame.png` converts it to PNG (stb_image reads binary PPM). The same frame rendered on all three devices (`--device 0`, `1`, `2`) is the same triangle, which is the point of a standard: the software renderer is slower, not different.

The tests:
```bash
zig build test --summary all
```
```text
Build Summary: 12/12 steps succeeded; 10/10 tests passed
test success
+- run test 10 pass (10 total) 8ms MaxRSS:7M
|  +- compile test debug native success 275ms MaxRSS:212M
|     +- WriteFile SDL3 cached
|     |  +- configure cmake header include/build_config/SDL_revision.h.cmake to SDL3/SDL_revision.h cached
|     +- compile lib SDL3 debug native cached 10ms MaxRSS:41M
|     ...
|     +- translate-c cached 8ms MaxRSS:40M
|     +- run glslc (triangle.vert.spv) cached
|     +- run glslc (triangle.frag.spv) cached
+- run exe lecture_10 (frame.ppm) success 205ms
   +- compile exe lecture_10 debug native cached 8ms MaxRSS:40M
   ...
```
Ten unit tests (results, versions, C strings, device scoring, SPIR-V magic numbers, push-constant layout, push-constant math, argument parsing, PPM output), then a real headless render of three frames at 320x200. The tree shows the SDL build (with its cmake-style config headers), the translation and the two shader compilations as dependencies of both runs.

Experiments. Change the clear color in `draw.zig`, or the vertex colors in the shader: both are picked up by the next `zig build run`, the shader by way of `glslc`. Set `.presentMode` to `VK_PRESENT_MODE_MAILBOX_KHR` (if the driver offers it; query `vkGetPhysicalDeviceSurfacePresentModesKHR` to check) and watch the frame rate leave the monitor's behind. Make it a square: six vertices, two triangles, in the shader's arrays and `vkCmdDraw`. Then the real step: a vertex buffer. Create a `VkBuffer` with `VERTEX_BUFFER` usage in host-visible memory (as `Offscreen.zig` does for its readback buffer), write positions and colors into the mapped memory, describe them in `VkPipelineVertexInputStateCreateInfo`, bind it with `vkCmdBindVertexBuffers`, and the geometry is data instead of code.
