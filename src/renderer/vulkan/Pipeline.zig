const Self = @This();

const std = @import("std");
const c = @import("api.zig").c;
const Context = @import("Context.zig");
const shader_compile = @import("shader_compile.zig");

pub const Options = struct {
    context: *Context,
    vertex_fn: [:0]const u8,
    fragment_fn: [:0]const u8,
    step_fn: StepFunction = .per_vertex,
    topology: c.VkPrimitiveTopology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
    blending_enabled: bool = true,
    format: c.VkFormat,

    pub const StepFunction = enum { constant, per_vertex, per_instance };
};

context: *Context,
pipeline: c.VkPipeline,
stride: usize,

pub fn init(comptime VertexAttributes: ?type, opts: Options) !Self {
    const alloc = std.heap.c_allocator;
    const vertex = try shader_compile.module(opts.context, alloc, opts.vertex_fn, .vertex);
    defer c.vkDestroyShaderModule(opts.context.device, vertex, null);
    const fragment = try shader_compile.module(opts.context, alloc, opts.fragment_fn, .fragment);
    defer c.vkDestroyShaderModule(opts.context.device, fragment, null);

    const stages = [_]c.VkPipelineShaderStageCreateInfo{
        shaderStage(c.VK_SHADER_STAGE_VERTEX_BIT, vertex),
        shaderStage(c.VK_SHADER_STAGE_FRAGMENT_BIT, fragment),
    };

    var attribute_storage: [16]c.VkVertexInputAttributeDescription = undefined;
    const attribute_count: u32 = if (VertexAttributes) |T| count: {
        inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
            attribute_storage[i] = .{
                .location = i,
                .binding = 0,
                .format = vertexFormat(field.type),
                .offset = @offsetOf(T, field.name),
            };
        }
        break :count @typeInfo(T).@"struct".fields.len;
    } else 0;

    var binding = std.mem.zeroes(c.VkVertexInputBindingDescription);
    if (VertexAttributes) |T| {
        binding.binding = 0;
        binding.stride = @sizeOf(T);
        binding.inputRate = switch (opts.step_fn) {
            .per_instance, .constant => c.VK_VERTEX_INPUT_RATE_INSTANCE,
            .per_vertex => c.VK_VERTEX_INPUT_RATE_VERTEX,
        };
    }

    var vertex_input = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
    vertex_input.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    vertex_input.vertexBindingDescriptionCount = if (VertexAttributes == null) 0 else 1;
    vertex_input.pVertexBindingDescriptions = if (VertexAttributes == null) null else &binding;
    vertex_input.vertexAttributeDescriptionCount = attribute_count;
    vertex_input.pVertexAttributeDescriptions = if (attribute_count == 0) null else &attribute_storage;

    var input_assembly = std.mem.zeroes(c.VkPipelineInputAssemblyStateCreateInfo);
    input_assembly.sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    input_assembly.topology = opts.topology;

    var viewport_state = std.mem.zeroes(c.VkPipelineViewportStateCreateInfo);
    viewport_state.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    viewport_state.viewportCount = 1;
    viewport_state.scissorCount = 1;

    var rasterization = std.mem.zeroes(c.VkPipelineRasterizationStateCreateInfo);
    rasterization.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    rasterization.polygonMode = c.VK_POLYGON_MODE_FILL;
    rasterization.cullMode = c.VK_CULL_MODE_NONE;
    rasterization.frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE;
    rasterization.lineWidth = 1;

    var multisample = std.mem.zeroes(c.VkPipelineMultisampleStateCreateInfo);
    multisample.sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    multisample.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;

    var blend_attachment = std.mem.zeroes(c.VkPipelineColorBlendAttachmentState);
    blend_attachment.blendEnable = if (opts.blending_enabled) c.VK_TRUE else c.VK_FALSE;
    blend_attachment.srcColorBlendFactor = c.VK_BLEND_FACTOR_ONE;
    blend_attachment.dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    blend_attachment.colorBlendOp = c.VK_BLEND_OP_ADD;
    blend_attachment.srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE;
    blend_attachment.dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    blend_attachment.alphaBlendOp = c.VK_BLEND_OP_ADD;
    blend_attachment.colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT |
        c.VK_COLOR_COMPONENT_G_BIT |
        c.VK_COLOR_COMPONENT_B_BIT |
        c.VK_COLOR_COMPONENT_A_BIT;

    var color_blend = std.mem.zeroes(c.VkPipelineColorBlendStateCreateInfo);
    color_blend.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    color_blend.attachmentCount = 1;
    color_blend.pAttachments = &blend_attachment;

    const dynamic_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
    var dynamic = std.mem.zeroes(c.VkPipelineDynamicStateCreateInfo);
    dynamic.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    dynamic.dynamicStateCount = dynamic_states.len;
    dynamic.pDynamicStates = &dynamic_states;

    var rendering = std.mem.zeroes(c.VkPipelineRenderingCreateInfo);
    rendering.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO;
    rendering.colorAttachmentCount = 1;
    rendering.pColorAttachmentFormats = &opts.format;

    var info = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
    info.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    info.pNext = &rendering;
    info.stageCount = stages.len;
    info.pStages = &stages;
    info.pVertexInputState = &vertex_input;
    info.pInputAssemblyState = &input_assembly;
    info.pViewportState = &viewport_state;
    info.pRasterizationState = &rasterization;
    info.pMultisampleState = &multisample;
    info.pColorBlendState = &color_blend;
    info.pDynamicState = &dynamic;
    info.layout = opts.context.pipeline_layout;

    var pipeline: c.VkPipeline = null;
    try Context.result(c.vkCreateGraphicsPipelines(opts.context.device, null, 1, &info, null, &pipeline));
    return .{
        .context = opts.context,
        .pipeline = pipeline,
        .stride = if (VertexAttributes) |T| @sizeOf(T) else 0,
    };
}

pub fn deinit(self: Self) void {
    c.vkDestroyPipeline(self.context.device, self.pipeline, null);
}

fn shaderStage(stage: c.VkShaderStageFlagBits, module_: c.VkShaderModule) c.VkPipelineShaderStageCreateInfo {
    var info = std.mem.zeroes(c.VkPipelineShaderStageCreateInfo);
    info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    info.stage = stage;
    info.module = module_;
    info.pName = "main";
    return info;
}

fn vertexFormat(comptime T_: type) c.VkFormat {
    const T = switch (@typeInfo(T_)) {
        .@"struct" => |s| s.backing_integer.?,
        .@"enum" => |e| e.tag_type,
        else => T_,
    };
    const len, const Child = switch (@typeInfo(T)) {
        .array => |array| .{ array.len, array.child },
        else => .{ 1, T },
    };
    return switch (Child) {
        u8 => switch (len) {
            1 => c.VK_FORMAT_R8_UINT,
            2 => c.VK_FORMAT_R8G8_UINT,
            4 => c.VK_FORMAT_R8G8B8A8_UINT,
            else => unreachable,
        },
        i8 => switch (len) {
            1 => c.VK_FORMAT_R8_SINT,
            2 => c.VK_FORMAT_R8G8_SINT,
            4 => c.VK_FORMAT_R8G8B8A8_SINT,
            else => unreachable,
        },
        u16 => switch (len) {
            1 => c.VK_FORMAT_R16_UINT,
            2 => c.VK_FORMAT_R16G16_UINT,
            4 => c.VK_FORMAT_R16G16B16A16_UINT,
            else => unreachable,
        },
        i16 => switch (len) {
            1 => c.VK_FORMAT_R16_SINT,
            2 => c.VK_FORMAT_R16G16_SINT,
            4 => c.VK_FORMAT_R16G16B16A16_SINT,
            else => unreachable,
        },
        u32 => switch (len) {
            1 => c.VK_FORMAT_R32_UINT,
            2 => c.VK_FORMAT_R32G32_UINT,
            4 => c.VK_FORMAT_R32G32B32A32_UINT,
            else => unreachable,
        },
        i32 => switch (len) {
            1 => c.VK_FORMAT_R32_SINT,
            2 => c.VK_FORMAT_R32G32_SINT,
            4 => c.VK_FORMAT_R32G32B32A32_SINT,
            else => unreachable,
        },
        f32 => switch (len) {
            1 => c.VK_FORMAT_R32_SFLOAT,
            2 => c.VK_FORMAT_R32G32_SFLOAT,
            4 => c.VK_FORMAT_R32G32B32A32_SFLOAT,
            else => unreachable,
        },
        else => unreachable,
    };
}
