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
