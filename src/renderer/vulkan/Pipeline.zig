//! `VkPipeline` (graphics) + the `VkPipelineLayout` that backs it.
//!
//! Vulkan 1.3 with **dynamic rendering**: we use
//! `VkPipelineRenderingCreateInfo` (chained into the pipeline create
//! info via `pNext`) instead of constructing a `VkRenderPass` + a
//! framebuffer per target. This removes the entire RenderPass /
//! Framebuffer object lifecycle the OpenGL backend never had to
//! think about — saves significant boilerplate.
//!
//! Wrapper scope: the renderer-level "what shaders + what attachment
//! format" lives in `vulkan/shaders.zig`'s eventual `Shaders` struct
//! (mirroring `opengl/shaders.zig`). This file is the bare
//! `VkPipeline` wrapper that takes everything explicitly:
//! pre-compiled shader modules, descriptor set layouts, push
//! constant ranges, vertex input description, color attachment
//! format. The renderer's pipeline-collection assembly layer is
//! responsible for plumbing those together — Pipeline.zig has no
//! per-shader knowledge.
//!
//! Counterpart: `src/renderer/opengl/Pipeline.zig`.

const Self = @This();

const std = @import("std");
const vk = @import("vulkan").c;

const Device = @import("Device.zig");

const log = std.log.scoped(.vulkan);

pub const StepFunction = enum {
    /// Constant value across all vertices (no vertex input).
    constant,
    /// One per vertex.
    per_vertex,
    /// One per instance (`VK_VERTEX_INPUT_RATE_INSTANCE`).
    per_instance,
};

/// Vertex input description. Pass `null` for shaders that don't read
/// vertex attributes (e.g. screen-quad shaders that derive position
/// from `gl_VertexIndex`).
pub const VertexInput = struct {
    /// Byte stride of the vertex buffer.
    stride: u32,

    /// Whether the buffer is stepped per-vertex or per-instance.
    step_fn: StepFunction = .per_vertex,

    /// `binding = 0` attribute descriptions describing each field of
    /// the vertex struct. The caller is responsible for building
    /// these (offsets, formats) — Pipeline doesn't introspect.
    attributes: []const vk.VkVertexInputAttributeDescription,
};

pub const Options = struct {
    device: *const Device,

    /// Shader modules. The caller owns these — Pipeline does not
    /// destroy them on deinit (they're typically reused across
    /// multiple pipelines and outlive any one of them).
    vertex_module: vk.VkShaderModule,
    fragment_module: vk.VkShaderModule,

    /// Optional vertex input. `null` ⇒ no vertex bindings.
    vertex_input: ?VertexInput = null,

    /// Descriptor set layouts referenced by the shaders.
    descriptor_set_layouts: []const vk.VkDescriptorSetLayout = &.{},

    /// Push constant ranges referenced by the shaders.
    push_constant_ranges: []const vk.VkPushConstantRange = &.{},

    /// Color attachment format. With dynamic rendering this must
    /// match the format of the image the renderer eventually targets
    /// in `vkCmdBeginRendering`.
    color_format: vk.VkFormat,

    /// Pre-multiplied-alpha source-over blending. Disable for
    /// the bg_color pass (full opaque background).
    blending_enabled: bool = true,

    /// Primitive topology. The renderer's shaders use TRIANGLE_STRIP
    /// for the full-screen quad and TRIANGLE_LIST for instanced cells.
    topology: vk.VkPrimitiveTopology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
};

pub const Error = error{
    /// `vkCreatePipelineLayout` or `vkCreateGraphicsPipelines`
    /// returned a non-success status.
    VulkanFailed,
};

device: *const Device,
pipeline: vk.VkPipeline,
layout: vk.VkPipelineLayout,

pub fn init(opts: Options) Error!Self {
    const dev = opts.device;

    // ---- pipeline layout ---------------------------------------
    const layout_info: vk.VkPipelineLayoutCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .setLayoutCount = @intCast(opts.descriptor_set_layouts.len),
        .pSetLayouts = if (opts.descriptor_set_layouts.len > 0)
            opts.descriptor_set_layouts.ptr
        else
            null,
        .pushConstantRangeCount = @intCast(opts.push_constant_ranges.len),
        .pPushConstantRanges = if (opts.push_constant_ranges.len > 0)
            opts.push_constant_ranges.ptr
        else
            null,
    };
    var layout: vk.VkPipelineLayout = undefined;
    {
        const r = dev.dispatch.createPipelineLayout(dev.device, &layout_info, null, &layout);
        if (r != vk.VK_SUCCESS) {
            log.err("vkCreatePipelineLayout failed: result={}", .{r});
            return error.VulkanFailed;
        }
    }
    errdefer dev.dispatch.destroyPipelineLayout(dev.device, layout, null);

    // ---- shader stages -----------------------------------------
    const stages: [2]vk.VkPipelineShaderStageCreateInfo = .{
        .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = vk.VK_SHADER_STAGE_VERTEX_BIT,
            .module = opts.vertex_module,
            .pName = "main",
            .pSpecializationInfo = null,
        },
        .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .module = opts.fragment_module,
            .pName = "main",
            .pSpecializationInfo = null,
        },
    };

    // ---- vertex input -------------------------------------------
    var vi_binding: vk.VkVertexInputBindingDescription = undefined;
    const vertex_input: vk.VkPipelineVertexInputStateCreateInfo = if (opts.vertex_input) |vi| blk: {
        vi_binding = .{
            .binding = 0,
            .stride = vi.stride,
            .inputRate = switch (vi.step_fn) {
                .constant, .per_vertex => vk.VK_VERTEX_INPUT_RATE_VERTEX,
                .per_instance => vk.VK_VERTEX_INPUT_RATE_INSTANCE,
            },
        };
        break :blk .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .vertexBindingDescriptionCount = 1,
            .pVertexBindingDescriptions = &vi_binding,
            .vertexAttributeDescriptionCount = @intCast(vi.attributes.len),
            .pVertexAttributeDescriptions = vi.attributes.ptr,
        };
    } else .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .vertexBindingDescriptionCount = 0,
        .pVertexBindingDescriptions = null,
        .vertexAttributeDescriptionCount = 0,
        .pVertexAttributeDescriptions = null,
    };

    // ---- input assembly + viewport (dynamic) + raster + ms ------
    const input_assembly: vk.VkPipelineInputAssemblyStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .topology = opts.topology,
        .primitiveRestartEnable = vk.VK_FALSE,
    };
    const viewport_state: vk.VkPipelineViewportStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .viewportCount = 1,
        .pViewports = null,
        .scissorCount = 1,
        .pScissors = null,
    };
    const rasterization: vk.VkPipelineRasterizationStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .depthClampEnable = vk.VK_FALSE,
        .rasterizerDiscardEnable = vk.VK_FALSE,
        .polygonMode = vk.VK_POLYGON_MODE_FILL,
        .cullMode = vk.VK_CULL_MODE_NONE,
        .frontFace = vk.VK_FRONT_FACE_COUNTER_CLOCKWISE,
        .depthBiasEnable = vk.VK_FALSE,
        .depthBiasConstantFactor = 0,
        .depthBiasClamp = 0,
        .depthBiasSlopeFactor = 0,
        .lineWidth = 1.0,
    };
    const multisample: vk.VkPipelineMultisampleStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .rasterizationSamples = vk.VK_SAMPLE_COUNT_1_BIT,
        .sampleShadingEnable = vk.VK_FALSE,
        .minSampleShading = 0,
        .pSampleMask = null,
        .alphaToCoverageEnable = vk.VK_FALSE,
        .alphaToOneEnable = vk.VK_FALSE,
    };

    // ---- color blend --------------------------------------------
    // Pre-multiplied alpha source-over: out = src + dst*(1-src.a).
    // Same as the OpenGL backend's default blend (and what the
    // shaders are written to produce).
    const blend_attachment: vk.VkPipelineColorBlendAttachmentState = .{
        .blendEnable = if (opts.blending_enabled) vk.VK_TRUE else vk.VK_FALSE,
        .srcColorBlendFactor = vk.VK_BLEND_FACTOR_ONE,
        .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .colorBlendOp = vk.VK_BLEND_OP_ADD,
        .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
        .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .alphaBlendOp = vk.VK_BLEND_OP_ADD,
        .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT |
            vk.VK_COLOR_COMPONENT_G_BIT |
            vk.VK_COLOR_COMPONENT_B_BIT |
            vk.VK_COLOR_COMPONENT_A_BIT,
    };
    const blend_state: vk.VkPipelineColorBlendStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .logicOpEnable = vk.VK_FALSE,
        .logicOp = vk.VK_LOGIC_OP_COPY,
        .attachmentCount = 1,
        .pAttachments = &blend_attachment,
        .blendConstants = .{ 0, 0, 0, 0 },
    };

    // ---- dynamic state -----------------------------------------
    const dynamic_states = [_]vk.VkDynamicState{
        vk.VK_DYNAMIC_STATE_VIEWPORT,
        vk.VK_DYNAMIC_STATE_SCISSOR,
    };
    const dynamic_state: vk.VkPipelineDynamicStateCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .dynamicStateCount = @intCast(dynamic_states.len),
        .pDynamicStates = &dynamic_states,
    };

    // ---- dynamic rendering info (chained via pNext) ------------
    var color_format = opts.color_format;
    const rendering_info: vk.VkPipelineRenderingCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
        .pNext = null,
        .viewMask = 0,
        .colorAttachmentCount = 1,
        .pColorAttachmentFormats = &color_format,
        .depthAttachmentFormat = vk.VK_FORMAT_UNDEFINED,
        .stencilAttachmentFormat = vk.VK_FORMAT_UNDEFINED,
    };

    // ---- assemble + create -------------------------------------
    const pipeline_info: vk.VkGraphicsPipelineCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .pNext = &rendering_info,
        .flags = 0,
        .stageCount = stages.len,
        .pStages = &stages,
        .pVertexInputState = &vertex_input,
        .pInputAssemblyState = &input_assembly,
        .pTessellationState = null,
        .pViewportState = &viewport_state,
        .pRasterizationState = &rasterization,
        .pMultisampleState = &multisample,
        .pDepthStencilState = null,
        .pColorBlendState = &blend_state,
        .pDynamicState = &dynamic_state,
        .layout = layout,
        // renderPass / subpass intentionally null — dynamic rendering.
        .renderPass = null,
        .subpass = 0,
        .basePipelineHandle = null,
        .basePipelineIndex = -1,
    };
    var pipeline: vk.VkPipeline = undefined;
    {
        const r = dev.dispatch.createGraphicsPipelines(
            dev.device,
            null, // pipeline cache
            1,
            &pipeline_info,
            null,
            &pipeline,
        );
        if (r != vk.VK_SUCCESS) {
            log.err("vkCreateGraphicsPipelines failed: result={}", .{r});
            return error.VulkanFailed;
        }
    }

    return .{
        .device = dev,
        .pipeline = pipeline,
        .layout = layout,
    };
}

pub fn deinit(self: *const Self) void {
    const dev = self.device;
    dev.dispatch.destroyPipeline(dev.device, self.pipeline, null);
    dev.dispatch.destroyPipelineLayout(dev.device, self.layout, null);
}

test {
    std.testing.refAllDecls(@This());
}
