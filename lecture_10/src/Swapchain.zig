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
