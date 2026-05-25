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
const vulkan = @import("vulkan");
const vk = vulkan.c;

const Device = vulkan.Device;
const DescriptorPool = vulkan.DescriptorPool;

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

/// Maximum descriptor sets a single pipeline can address. The
/// preprocessor in `shaders.zig` bins resources into 3 sets (UBO=0,
/// sampler=1, storage=2), so 3 is sufficient. Bump if/when a fourth
/// resource class is introduced.
pub const MAX_DESCRIPTOR_SETS: usize = 3;

pub const Options = struct {
    device: *const Device,

    /// Optional descriptor pool. If provided, `Pipeline.init`
    /// allocates one descriptor set per non-null entry in
    /// `descriptor_set_layouts` and stores them on
    /// `Pipeline.descriptor_sets[i]`, indexed by set number.
    /// `RenderPass.step` updates + binds them per frame.
    descriptor_pool: ?*DescriptorPool = null,

    /// Shader modules. The caller owns these — Pipeline does not
    /// destroy them on deinit (they're typically reused across
    /// multiple pipelines and outlive any one of them).
    vertex_module: vk.VkShaderModule,
    fragment_module: vk.VkShaderModule,

    /// Optional vertex input. `null` ⇒ no vertex bindings.
    vertex_input: ?VertexInput = null,

    /// Per-set descriptor layouts. Element i corresponds to `set = i`
    /// in the shader. `null` slots are placeholders for sets the
    /// pipeline doesn't actually use — Vulkan requires the pipeline
    /// layout's `pSetLayouts` to be contiguous up to the max used
    /// set number, so we substitute `empty_set_layout` for nulls.
    descriptor_set_layouts: []const ?vk.VkDescriptorSetLayout = &.{},

    /// 0-binding placeholder layout used to fill `null` entries in
    /// `descriptor_set_layouts`. Required when any entry is null;
    /// can stay null when every entry is non-null. Owned by the
    /// caller (`Shaders.init` caches one and reuses it).
    empty_set_layout: vk.VkDescriptorSetLayout = null,

    /// Push constant ranges referenced by the shaders.
    push_constant_ranges: []const vk.VkPushConstantRange = &.{},

    /// Default sampler the pipeline owns and uses for every
    /// combined-image-sampler binding the caller doesn't supply a
    /// sampler for. Lets the renderer pass plain `textures` (parallel
    /// to OpenGL's per-texture `glBindTextureUnit` model) without
    /// having to also track per-binding samplers; the pipeline knows
    /// the right sampler for its own atlases (e.g. cell_text uses
    /// unnormalized coords for `sampler2D` standing in for the old
    /// `sampler2DRect`). The handle is borrowed, not owned by
    /// `Pipeline` — `Shaders.init` owns the lifetime.
    sampler: vk.VkSampler = null,

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

/// Descriptor sets allocated from `opts.descriptor_pool`, indexed by
/// set number. `descriptor_sets[i]` is the set bound at `set = i` in
/// the shader; `null` means the pipeline doesn't use that set (so
/// `RenderPass.step` skips updating/binding it). `set_count` is one
/// past the last non-null index, matching what
/// `vkCmdBindDescriptorSets` needs as `setCount`.
///
/// HOT-PATH NOTE: these sets are SHARED across all `step()` calls
/// that bind this pipeline within a single command buffer, but
/// `vkCmdDraw` reads descriptors at submit time, so re-using the
/// same pipeline twice with different per-call resources would
/// cause both draws to see the LAST update's bindings.
/// `RenderPass.step` defends against this by allocating a fresh
/// per-call set from the pass's `step_pool` whenever the per-step
/// resources differ; these `descriptor_sets[i]` slots act as
/// pre-warmed defaults (used only when the call site is
/// single-step-per-pipeline like bg_color / cell_bg).
descriptor_sets: [MAX_DESCRIPTOR_SETS]vk.VkDescriptorSet = .{ null, null, null },
set_count: u32 = 0,

/// Descriptor set layouts associated with this pipeline, indexed by
/// set number. `null` matches a `null` slot in `descriptor_sets`.
/// Stored so `RenderPass.step` can allocate per-call sets from the
/// pass's per-frame descriptor pool without round-tripping through
/// the original `Shaders.init` layout-creation code path.
descriptor_set_layouts: [MAX_DESCRIPTOR_SETS]vk.VkDescriptorSetLayout = .{ null, null, null },

/// Binding number that `Step.uniforms` writes to within set 0.
/// Defaults to 1 to match `common.glsl`'s
/// `layout(binding = 1, std140) uniform Globals`. Override per
/// pipeline if a different shader uses a different slot.
uniforms_binding: u32 = 1,

/// Pipeline-owned fallback sampler. See `Options.sampler`.
sampler: vk.VkSampler = null,

/// Vertex buffer stride (bytes). Needed so `RenderPass.step` can
/// bind a vertex buffer with the right per-instance/per-vertex
/// stride. Defaults to 0 (no vertex buffer); set automatically when
/// `Options.vertex_input` is non-null.
vertex_stride: u32 = 0,

pub fn init(opts: Options) Error!Self {
    const dev = opts.device;

    if (opts.descriptor_set_layouts.len > MAX_DESCRIPTOR_SETS) {
        log.err(
            "Pipeline.init: {} descriptor sets exceeds MAX_DESCRIPTOR_SETS={}",
            .{ opts.descriptor_set_layouts.len, MAX_DESCRIPTOR_SETS },
        );
        return error.VulkanFailed;
    }

    // ---- pipeline layout ---------------------------------------
    //
    // Build a flat array of VkDescriptorSetLayout where index i is
    // the layout for set=i. Null entries in `opts.descriptor_set_layouts`
    // get substituted with `opts.empty_set_layout` — Vulkan rejects
    // VK_NULL_HANDLE in `pSetLayouts`. `Shaders.init` always supplies
    // an empty layout when any null appears.
    var flat_dsls: [MAX_DESCRIPTOR_SETS]vk.VkDescriptorSetLayout = .{ null, null, null };
    for (opts.descriptor_set_layouts, 0..) |maybe_dsl, i| {
        if (maybe_dsl) |dsl| {
            flat_dsls[i] = dsl;
        } else if (opts.empty_set_layout != null) {
            flat_dsls[i] = opts.empty_set_layout;
        } else {
            log.err(
                "Pipeline.init: set {} is null but no empty_set_layout was provided",
                .{i},
            );
            return error.VulkanFailed;
        }
    }
    const layout_info: vk.VkPipelineLayoutCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .setLayoutCount = @intCast(opts.descriptor_set_layouts.len),
        .pSetLayouts = if (opts.descriptor_set_layouts.len > 0) &flat_dsls else null,
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
    errdefer dev.dispatch.destroyPipeline(dev.device, pipeline, null);

    // Allocate one descriptor set per non-null entry in
    // `opts.descriptor_set_layouts`. Null entries are placeholders
    // (the shader's set=i isn't actually used) — nothing to allocate.
    // Also remember the layouts on `Self` so `RenderPass.step` can
    // allocate fresh per-call sets from a per-frame pool without
    // re-creating layouts.
    var dsets: [MAX_DESCRIPTOR_SETS]vk.VkDescriptorSet = .{ null, null, null };
    var dsls: [MAX_DESCRIPTOR_SETS]vk.VkDescriptorSetLayout = .{ null, null, null };
    if (opts.descriptor_pool) |pool_ptr| {
        for (opts.descriptor_set_layouts, 0..) |maybe_dsl, i| {
            if (maybe_dsl) |dsl| {
                dsls[i] = dsl;
                dsets[i] = pool_ptr.allocate(dsl) catch |err| {
                    log.err(
                        "Pipeline.init: descriptor set {} allocation failed: {}",
                        .{ i, err },
                    );
                    return error.VulkanFailed;
                };
            }
        }
    } else {
        for (opts.descriptor_set_layouts, 0..) |maybe_dsl, i| {
            if (maybe_dsl) |dsl| dsls[i] = dsl;
        }
    }

    return .{
        .device = dev,
        .pipeline = pipeline,
        .layout = layout,
        .descriptor_sets = dsets,
        .descriptor_set_layouts = dsls,
        .set_count = @intCast(opts.descriptor_set_layouts.len),
        .sampler = opts.sampler,
        .vertex_stride = if (opts.vertex_input) |vi| vi.stride else 0,
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
