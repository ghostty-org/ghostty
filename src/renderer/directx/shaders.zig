const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const math = @import("../../math.zig");

const Pipeline = @import("Pipeline.zig");
const d3d11 = @import("d3d11.zig");

const log = std.log.scoped(.directx);

const pipeline_descs: []const struct { [:0]const u8, PipelineDescription } =
    &.{
        .{ "bg_color", .{
            .vertex_fn = loadShaderCode("../shaders/hlsl/full_screen.vs.hlsl"),
            .fragment_fn = loadShaderCode("../shaders/hlsl/bg_color.ps.hlsl"),
            .blending_enabled = false,
        } },
        .{ "cell_bg", .{
            .vertex_fn = loadShaderCode("../shaders/hlsl/full_screen.vs.hlsl"),
            .fragment_fn = loadShaderCode("../shaders/hlsl/cell_bg.ps.hlsl"),
            .blending_enabled = true,
        } },
        .{ "cell_text", .{
            .vertex_attributes = CellText,
            .vertex_fn = loadShaderCode("../shaders/hlsl/cell_text.vs.hlsl"),
            .fragment_fn = loadShaderCode("../shaders/hlsl/cell_text.ps.hlsl"),
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
        .{ "image", .{
            .vertex_attributes = Image,
            .vertex_fn = loadShaderCode("../shaders/hlsl/image.vs.hlsl"),
            .fragment_fn = loadShaderCode("../shaders/hlsl/image.ps.hlsl"),
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
        .{ "bg_image", .{
            .vertex_attributes = BgImage,
            .vertex_fn = loadShaderCode("../shaders/hlsl/bg_image.vs.hlsl"),
            .fragment_fn = loadShaderCode("../shaders/hlsl/bg_image.ps.hlsl"),
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
    };

/// All the comptime-known info about a pipeline.
const PipelineDescription = struct {
    vertex_attributes: ?type = null,
    vertex_fn: [:0]const u8,
    fragment_fn: [:0]const u8,
    step_fn: Pipeline.Options.StepFunction = .per_vertex,
    blending_enabled: bool = true,

    fn initPipeline(self: PipelineDescription, device: d3d11.ID3D11Device) !Pipeline {
        return try Pipeline.init(self.vertex_attributes, .{
            .device = device,
            .vertex_fn = self.vertex_fn,
            .fragment_fn = self.fragment_fn,
            .step_fn = self.step_fn,
            .blending_enabled = self.blending_enabled,
        });
    }
};

/// We create a type for the pipeline collection based on our desc array.
const PipelineCollection = t: {
    var fields: [pipeline_descs.len]std.builtin.Type.StructField = undefined;
    for (pipeline_descs, 0..) |pipeline, i| {
        fields[i] = .{
            .name = pipeline[0],
            .type = Pipeline,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(Pipeline),
        };
    }
    break :t @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
};

/// This contains the state for the shaders used by the DirectX renderer.
pub const Shaders = struct {
    /// Collection of available render pipelines.
    pipelines: PipelineCollection,

    /// Custom shaders to run against the final drawable texture.
    post_pipelines: []const Pipeline,

    /// Set to true when deinited.
    defunct: bool = false,

    pub fn init(
        alloc: Allocator,
        device: d3d11.ID3D11Device,
        post_shaders: []const [:0]const u8,
    ) !Shaders {
        var pipelines: PipelineCollection = undefined;

        var initialized_pipelines: usize = 0;

        errdefer inline for (pipeline_descs, 0..) |pipeline, i| {
            if (i < initialized_pipelines) {
                @field(pipelines, pipeline[0]).deinit();
            }
        };

        inline for (pipeline_descs) |pipeline| {
            @field(pipelines, pipeline[0]) = try pipeline[1].initPipeline(device);
            initialized_pipelines += 1;
        }

        const post_pipelines = try initPostPipelines(alloc, device, post_shaders);
        errdefer {
            for (post_pipelines) |p| p.deinit();
            alloc.free(post_pipelines);
        }

        return .{
            .pipelines = pipelines,
            .post_pipelines = post_pipelines,
        };
    }

    pub fn deinit(self: *Shaders, alloc: Allocator) void {
        if (self.defunct) return;
        self.defunct = true;

        inline for (pipeline_descs) |pipeline| {
            @field(self.pipelines, pipeline[0]).deinit();
        }

        for (self.post_pipelines) |p| {
            p.deinit();
        }
        if (self.post_pipelines.len > 0) {
            alloc.free(self.post_pipelines);
        }
    }
};

/// Initialize custom post-processing shader pipelines from HLSL source.
fn initPostPipelines(
    alloc: Allocator,
    device: d3d11.ID3D11Device,
    post_shaders: []const [:0]const u8,
) ![]const Pipeline {
    if (post_shaders.len == 0) return &.{};

    var i: usize = 0;
    var pipelines = try alloc.alloc(Pipeline, post_shaders.len);
    errdefer {
        for (pipelines[0..i]) |p| p.deinit();
        alloc.free(pipelines);
    }

    for (post_shaders) |source| {
        pipelines[i] = try Pipeline.init(null, .{
            .device = device,
            .vertex_fn = loadShaderCode("../shaders/hlsl/full_screen.vs.hlsl"),
            .fragment_fn = source,
            .blending_enabled = false,
            .ps_entry = "main",
        });
        i += 1;
    }

    return pipelines;
}

/// Load shader code from the target path, processing `#include` directives.
fn loadShaderCode(comptime path: []const u8) [:0]const u8 {
    return comptime processIncludes(@embedFile(path), std.fs.path.dirname(path).?);
}

/// Used by loadShaderCode
fn processIncludes(contents: [:0]const u8, basedir: []const u8) [:0]const u8 {
    @setEvalBranchQuota(100_000);
    var i: usize = 0;
    while (i < contents.len) {
        if (std.mem.startsWith(u8, contents[i..], "#include")) {
            const prefix = "#include \"";
            std.debug.assert(std.mem.startsWith(u8, contents[i..], prefix));
            const start = i + prefix.len;
            const end = std.mem.indexOfScalarPos(u8, contents, start, '"').?;
            return std.fmt.comptimePrint(
                "{s}{s}{s}",
                .{
                    contents[0..i],
                    @embedFile(basedir ++ "/" ++ contents[start..end]),
                    processIncludes(contents[end + 1 ..], basedir),
                },
            );
        }
        if (std.mem.indexOfPos(u8, contents, i, "\n#")) |j| {
            i = (j + 1);
        } else {
            break;
        }
    }
    return contents;
}

/// The uniforms that are passed to our shaders.
pub const Uniforms = extern struct {
    projection_matrix: math.Mat align(16),
    screen_size: [2]f32 align(8),
    cell_size: [2]f32 align(8),
    grid_size: [2]u16 align(4),
    grid_padding: [4]f32 align(16),
    padding_extend: PaddingExtend align(4),
    min_contrast: f32 align(4),
    cursor_pos: [2]u16 align(4),
    cursor_color: [4]u8 align(4),
    bg_color: [4]u8 align(4),
    bools: Bools align(4),

    const Bools = packed struct(u32) {
        cursor_wide: bool,
        use_display_p3: bool,
        use_linear_blending: bool,
        use_linear_correction: bool = false,
        _padding: u28 = 0,
    };

    const PaddingExtend = packed struct(u32) {
        left: bool = false,
        right: bool = false,
        up: bool = false,
        down: bool = false,
        _padding: u28 = 0,
    };
};

/// Single parameter for the terminal cell shader.
pub const CellText = extern struct {
    glyph_pos: [2]u32 align(8) = .{ 0, 0 },
    glyph_size: [2]u32 align(8) = .{ 0, 0 },
    bearings: [2]i16 align(4) = .{ 0, 0 },
    grid_pos: [2]u16 align(4),
    color: [4]u8 align(4),
    atlas: Atlas align(1),
    bools: packed struct(u8) {
        no_min_contrast: bool = false,
        is_cursor_glyph: bool = false,
        _padding: u6 = 0,
    } align(1) = .{},

    pub const Atlas = enum(u8) {
        grayscale = 0,
        color = 1,
    };
};

/// Single parameter for the cell bg shader.
pub const CellBg = [4]u8;

/// Single parameter for the image shader.
pub const Image = extern struct {
    grid_pos: [2]f32 align(8),
    cell_offset: [2]f32 align(8),
    source_rect: [4]f32 align(16),
    dest_size: [2]f32 align(8),
};

/// Single parameter for the bg image shader.
pub const BgImage = extern struct {
    opacity: f32 align(4),
    info: Info align(1),

    pub const Info = packed struct(u8) {
        position: Position,
        fit: Fit,
        repeat: bool,
        _padding: u1 = 0,

        pub const Position = enum(u4) {
            tl = 0,
            tc = 1,
            tr = 2,
            ml = 3,
            mc = 4,
            mr = 5,
            bl = 6,
            bc = 7,
            br = 8,
        };

        pub const Fit = enum(u2) {
            contain = 0,
            cover = 1,
            stretch = 2,
            none = 3,
        };
    };
};
