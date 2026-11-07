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
