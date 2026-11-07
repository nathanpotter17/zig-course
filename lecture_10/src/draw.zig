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
