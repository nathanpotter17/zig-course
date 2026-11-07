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
