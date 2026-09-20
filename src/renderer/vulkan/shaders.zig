const std = @import("std");
const c = @import("api.zig").c;
const Context = @import("Context.zig");
const Pipeline = @import("Pipeline.zig");
const base = @import("../opengl/shaders.zig");

const assert = @import("../../quirks.zig").inlineAssert;
const log = std.log.scoped(.vulkan_shader);

pub const Uniforms = base.Uniforms;
pub const CellText = base.CellText;
pub const CellBg = base.CellBg;
pub const Image = base.Image;
pub const BgImage = base.BgImage;

const PipelineDescription = struct {
    vertex_attributes: ?type = null,
    vertex_fn: [:0]const u8,
    fragment_fn: [:0]const u8,
    step_fn: Pipeline.Options.StepFunction = .per_vertex,
    topology: c.VkPrimitiveTopology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
    blending_enabled: bool = true,

    fn initPipeline(self: PipelineDescription, context: *Context, format: c.VkFormat) !Pipeline {
        return Pipeline.init(self.vertex_attributes, .{
            .context = context,
            .vertex_fn = self.vertex_fn,
            .fragment_fn = self.fragment_fn,
            .step_fn = self.step_fn,
            .topology = self.topology,
            .blending_enabled = self.blending_enabled,
            .format = format,
        });
    }
};

const pipeline_descs: []const struct { [:0]const u8, PipelineDescription } = &.{
    .{ "bg_color", .{
        .vertex_fn = loadShaderCode("../shaders/glsl/full_screen.v.glsl"),
        .fragment_fn = loadShaderCode("../shaders/glsl/bg_color.f.glsl"),
        .blending_enabled = false,
    } },
    .{ "cell_bg", .{
        .vertex_fn = loadShaderCode("../shaders/glsl/full_screen.v.glsl"),
        .fragment_fn = loadShaderCode("../shaders/glsl/cell_bg.f.glsl"),
    } },
    .{ "cell_text", .{
        .vertex_attributes = CellText,
        .vertex_fn = loadShaderCode("../shaders/glsl/cell_text.v.glsl"),
        .fragment_fn = loadShaderCode("../shaders/glsl/cell_text.f.glsl"),
        .step_fn = .per_instance,
        .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP,
    } },
    .{ "image", .{
        .vertex_attributes = Image,
        .vertex_fn = loadShaderCode("../shaders/glsl/image.v.glsl"),
        .fragment_fn = loadShaderCode("../shaders/glsl/image.f.glsl"),
        .step_fn = .per_instance,
        .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP,
    } },
    .{ "bg_image", .{
        .vertex_attributes = BgImage,
        .vertex_fn = loadShaderCode("../shaders/glsl/bg_image.v.glsl"),
        .fragment_fn = loadShaderCode("../shaders/glsl/bg_image.f.glsl"),
        .step_fn = .per_instance,
    } },
};

const PipelineCollection = collection: {
    const StructField = std.builtin.Type.StructField;
    var names: [pipeline_descs.len][]const u8 = undefined;
    var types = [_]type{Pipeline} ** pipeline_descs.len;
    var attrs = [_]StructField.Attributes{.{ .@"align" = @alignOf(Pipeline) }} ** pipeline_descs.len;
    for (pipeline_descs, &names) |desc, *name| name.* = desc[0];
    break :collection @Struct(.auto, null, &names, &types, &attrs);
};

pub const Shaders = struct {
    pipelines: PipelineCollection,
    post_pipelines: []const Pipeline,
    defunct: bool = false,

    pub const uninit: Shaders = .{
        .pipelines = undefined,
        .post_pipelines = &.{},
        .defunct = true,
    };

    pub fn init(
        alloc: std.mem.Allocator,
        context: *Context,
        post_shaders: []const [:0]const u8,
        format: c.VkFormat,
    ) !Shaders {
        var pipelines: PipelineCollection = undefined;
        var initialized: usize = 0;
        errdefer inline for (pipeline_descs, 0..) |desc, i| {
            if (i < initialized) @field(pipelines, desc[0]).deinit();
        };
        inline for (pipeline_descs) |desc| {
            @field(pipelines, desc[0]) = try desc[1].initPipeline(context, format);
            initialized += 1;
        }

        const post_pipelines = initPostPipelines(alloc, context, post_shaders, format) catch |err| fallback: {
            log.warn("error initializing postprocess shaders err={}", .{err});
            break :fallback &.{};
        };
        errdefer if (post_pipelines.len > 0) {
            for (post_pipelines) |pipeline| pipeline.deinit();
            alloc.free(post_pipelines);
        };
        return .{ .pipelines = pipelines, .post_pipelines = post_pipelines };
    }

    pub fn deinit(self: *Shaders, alloc: std.mem.Allocator) void {
        if (self.defunct) return;
        self.defunct = true;
        inline for (pipeline_descs) |desc| @field(self.pipelines, desc[0]).deinit();
        if (self.post_pipelines.len > 0) {
            for (self.post_pipelines) |pipeline| pipeline.deinit();
            alloc.free(self.post_pipelines);
        }
    }
};

fn initPostPipelines(
    alloc: std.mem.Allocator,
    context: *Context,
    sources: []const [:0]const u8,
    format: c.VkFormat,
) ![]const Pipeline {
    if (sources.len == 0) return &.{};
    const pipelines = try alloc.alloc(Pipeline, sources.len);
    var initialized: usize = 0;
    errdefer {
        for (pipelines[0..initialized]) |pipeline| pipeline.deinit();
        alloc.free(pipelines);
    }
    for (sources) |source| {
        pipelines[initialized] = try Pipeline.init(null, .{
            .context = context,
            .vertex_fn = loadShaderCode("../shaders/glsl/full_screen.v.glsl"),
            .fragment_fn = source,
            .format = format,
        });
        initialized += 1;
    }
    return pipelines;
}

fn loadShaderCode(comptime path: []const u8) [:0]const u8 {
    return comptime processIncludes(@embedFile(path), std.fs.path.dirname(path).?);
}

fn processIncludes(contents: [:0]const u8, basedir: []const u8) [:0]const u8 {
    @setEvalBranchQuota(100_000);
    var i: usize = 0;
    while (i < contents.len) {
        if (std.mem.startsWith(u8, contents[i..], "#include")) {
            assert(std.mem.startsWith(u8, contents[i..], "#include \""));
            const start = i + "#include \"".len;
            const end = std.mem.indexOfScalarPos(u8, contents, start, '"').?;
            return std.fmt.comptimePrint("{s}{s}{s}", .{
                contents[0..i],
                @embedFile(basedir ++ "/" ++ contents[start..end]),
                processIncludes(contents[end + 1 ..], basedir),
            });
        }
        if (std.mem.indexOfPos(u8, contents, i, "\n#")) |j| i = j + 1 else break;
    }
    return contents;
}
