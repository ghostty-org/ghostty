const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const macos = @import("macos");
const objc = @import("objc");
const math = @import("../../math.zig");

const mtl = @import("api.zig");

const log = std.log.scoped(.metal);

/// This contains the state for the shaders used by the Metal renderer.
pub const Shaders = struct {
    library: objc.Object,

    /// The cell shader is the shader used to render the terminal cells.
    /// It is a single shader that is used for both the background and
    /// foreground.
    cell_pipeline: objc.Object,

    /// The image shader is the shader used to render images for things
    /// like the Kitty image protocol.
    image_pipeline: objc.Object,

    /// Custom shaders to run against the final drawable texture. This
    /// can be used to apply a lot of effects. Each shader is run in sequence
    /// against the output of the previous shader.
    post_pipelines: []const objc.Object,

    /// Initialize our shader set.
    ///
    /// "post_shaders" is an optional list of postprocess shaders to run
    /// against the final drawable texture. This is an array of shader source
    /// code, not file paths.
    pub fn init(
        alloc: Allocator,
        device: objc.Object,
        post_shaders: []const [:0]const u8,
    ) !Shaders {
        const library = try initLibrary(device);
        errdefer library.msgSend(void, objc.sel("release"), .{});

        const cell_pipeline = try initCellPipeline(device, library);
        errdefer cell_pipeline.msgSend(void, objc.sel("release"), .{});

        const image_pipeline = try initImagePipeline(device, library);
        errdefer image_pipeline.msgSend(void, objc.sel("release"), .{});

        const post_pipelines: []const objc.Object = initPostPipelines(
            alloc,
            device,
            library,
            post_shaders,
        ) catch |err| err: {
            // If an error happens while building postprocess shaders we
            // want to just not use any postprocess shaders since we don't
            // want to block Ghostty from working.
            log.warn("error initializing postprocess shaders err={}", .{err});
            break :err &.{};
        };
        errdefer if (post_pipelines.len > 0) {
            for (post_pipelines) |pipeline| pipeline.msgSend(void, objc.sel("release"), .{});
            alloc.free(post_pipelines);
        };

        return .{
            .library = library,
            .cell_pipeline = cell_pipeline,
            .image_pipeline = image_pipeline,
            .post_pipelines = post_pipelines,
        };
    }

    pub fn deinit(self: *Shaders, alloc: Allocator) void {
        // Release our primary shaders
        self.cell_pipeline.msgSend(void, objc.sel("release"), .{});
        self.image_pipeline.msgSend(void, objc.sel("release"), .{});
        self.library.msgSend(void, objc.sel("release"), .{});

        // Release our postprocess shaders
        if (self.post_pipelines.len > 0) {
            for (self.post_pipelines) |pipeline| {
                pipeline.msgSend(void, objc.sel("release"), .{});
            }
            alloc.free(self.post_pipelines);
        }
    }
};

/// This is a single parameter for the terminal cell shader.
pub const Cell = extern struct {
    mode: Mode,
    grid_pos: [2]f32,
    glyph_pos: [2]u32 = .{ 0, 0 },
    glyph_size: [2]u32 = .{ 0, 0 },
    glyph_offset: [2]i32 = .{ 0, 0 },
    color: [4]u8,
    cell_width: u8,

    pub const Mode = enum(u8) {
        bg = 1,
        fg = 2,
        fg_color = 7,
        strikethrough = 8,
    };
};

/// Single parameter for the image shader. See shader for field details.
pub const Image = extern struct {
    grid_pos: [2]f32,
    cell_offset: [2]f32,
    source_rect: [4]f32,
    dest_size: [2]f32,
};

/// The uniforms that are passed to the terminal cell shader.
pub const Uniforms = extern struct {
    /// The projection matrix for turning world coordinates to normalized.
    /// This is calculated based on the size of the screen.
    projection_matrix: math.Mat,

    /// Size of a single cell in pixels, unscaled.
    cell_size: [2]f32,

    /// Metrics for underline/strikethrough
    strikethrough_position: f32,
    strikethrough_thickness: f32,
};

/// The uniforms used for custom postprocess shaders.
pub const PostUniforms = extern struct {
    // Note: all of the explicit aligmnments are copied from the
    // MSL developer reference just so that we can be sure that we got
    // it all exactly right.
    resolution: [3]f32 align(16),
    time: f32 align(4),
    time_delta: f32 align(4),
    frame_rate: f32 align(4),
    frame: i32 align(4),
    channel_time: [4][4]f32 align(16),
    channel_resolution: [4][4]f32 align(16),
    mouse: [4]f32 align(16),
    date: [4]f32 align(16),
    sample_rate: f32 align(4),
};

/// Initialize the MTLLibrary. A MTLLibrary is a collection of shaders.
fn initLibrary(device: objc.Object) !objc.Object {
    // Hardcoded since this file isn't meant to be reusable.
    const data = @embedFile("../shaders/cell.metal");
    const source = try macos.foundation.String.createWithBytes(
        data,
        .utf8,
        false,
    );
    defer source.release();

    var err: ?*anyopaque = null;
    const library = device.msgSend(
        objc.Object,
        objc.sel("newLibraryWithSource:options:error:"),
        .{
            source,
            @as(?*anyopaque, null),
            &err,
        },
    );
    try checkError(err);

    return library;
}

/// Initialize our custom shader pipelines. The shaders argument is a
/// set of shader source code, not file paths.
fn initPostPipelines(
    alloc: Allocator,
    device: objc.Object,
    library: objc.Object,
    shaders: []const [:0]const u8,
) ![]const objc.Object {
    // If we have no shaders, do nothing.
    if (shaders.len == 0) return &.{};

    // Keeps track of how many shaders we successfully wrote.
    var i: usize = 0;

    // Initialize our result set. If any error happens, we undo everything.
    var pipelines = try alloc.alloc(objc.Object, shaders.len);
    errdefer {
        for (pipelines[0..i]) |pipeline| {
            pipeline.msgSend(void, objc.sel("release"), .{});
        }
        alloc.free(pipelines);
    }

    // Build each shader. Note we don't use "0.." to build our index
    // because we need to keep track of our length to clean up above.
    for (shaders) |source| {
        pipelines[i] = try initPostPipeline(device, library, source);
        i += 1;
    }

    return pipelines;
}

/// Initialize a single custom shader pipeline from shader source.
fn initPostPipeline(
    device: objc.Object,
    library: objc.Object,
    data: [:0]const u8,
) !objc.Object {
    // Create our library which has the shader source
    const post_library = library: {
        const source = try macos.foundation.String.createWithBytes(
            data,
            .utf8,
            false,
        );
        defer source.release();

        var err: ?*anyopaque = null;
        const post_library = device.msgSend(
            objc.Object,
            objc.sel("newLibraryWithSource:options:error:"),
            .{ source, @as(?*anyopaque, null), &err },
        );
        try checkError(err);
        errdefer post_library.msgSend(void, objc.sel("release"), .{});

        break :library post_library;
    };
    defer post_library.msgSend(void, objc.sel("release"), .{});

    // Get our vertex and fragment functions
    const func_vert = func_vert: {
        const str = try macos.foundation.String.createWithBytes(
            "post_vertex",
            .utf8,
            false,
        );
        defer str.release();

        const ptr = library.msgSend(?*anyopaque, objc.sel("newFunctionWithName:"), .{str});
        break :func_vert objc.Object.fromId(ptr.?);
    };
    const func_frag = func_frag: {
        const str = try macos.foundation.String.createWithBytes(
            "main0",
            .utf8,
            false,
        );
        defer str.release();

        const ptr = post_library.msgSend(?*anyopaque, objc.sel("newFunctionWithName:"), .{str});
        break :func_frag objc.Object.fromId(ptr.?);
    };
    defer func_vert.msgSend(void, objc.sel("release"), .{});
    defer func_frag.msgSend(void, objc.sel("release"), .{});

    // Create our descriptor
    const desc = init: {
        const Class = objc.getClass("MTLRenderPipelineDescriptor").?;
        const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
        const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
        break :init id_init;
    };
    defer desc.msgSend(void, objc.sel("release"), .{});
    desc.setProperty("vertexFunction", func_vert);
    desc.setProperty("fragmentFunction", func_frag);

    // Set our color attachment
    const attachments = objc.Object.fromId(desc.getProperty(?*anyopaque, "colorAttachments"));
    {
        const attachment = attachments.msgSend(
            objc.Object,
            objc.sel("objectAtIndexedSubscript:"),
            .{@as(c_ulong, 0)},
        );

        // Value is MTLPixelFormatBGRA8Unorm
        attachment.setProperty("pixelFormat", @as(c_ulong, 80));
    }

    // Make our state
    var err: ?*anyopaque = null;
    const pipeline_state = device.msgSend(
        objc.Object,
        objc.sel("newRenderPipelineStateWithDescriptor:error:"),
        .{ desc, &err },
    );
    try checkError(err);

    return pipeline_state;
}

/// Initialize the cell render pipeline for our shader library.
fn initCellPipeline(device: objc.Object, library: objc.Object) !objc.Object {
    // Get our vertex and fragment functions
    const func_vert = func_vert: {
        const str = try macos.foundation.String.createWithBytes(
            "uber_vertex",
            .utf8,
            false,
        );
        defer str.release();

        const ptr = library.msgSend(?*anyopaque, objc.sel("newFunctionWithName:"), .{str});
        break :func_vert objc.Object.fromId(ptr.?);
    };
    const func_frag = func_frag: {
        const str = try macos.foundation.String.createWithBytes(
            "uber_fragment",
            .utf8,
            false,
        );
        defer str.release();

        const ptr = library.msgSend(?*anyopaque, objc.sel("newFunctionWithName:"), .{str});
        break :func_frag objc.Object.fromId(ptr.?);
    };
    defer func_vert.msgSend(void, objc.sel("release"), .{});
    defer func_frag.msgSend(void, objc.sel("release"), .{});

    // Create the vertex descriptor. The vertex descriptor describes the
    // data layout of the vertex inputs. We use indexed (or "instanced")
    // rendering, so this makes it so that each instance gets a single
    // Cell as input.
    const vertex_desc = vertex_desc: {
        const desc = init: {
            const Class = objc.getClass("MTLVertexDescriptor").?;
            const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
            const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
            break :init id_init;
        };

        // Our attributes are the fields of the input
        const attrs = objc.Object.fromId(desc.getProperty(?*anyopaque, "attributes"));
        {
            const attr = attrs.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 0)},
            );

            attr.setProperty("format", @intFromEnum(mtl.MTLVertexFormat.uchar));
            attr.setProperty("offset", @as(c_ulong, @offsetOf(Cell, "mode")));
            attr.setProperty("bufferIndex", @as(c_ulong, 0));
        }
        {
            const attr = attrs.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 1)},
            );

            attr.setProperty("format", @intFromEnum(mtl.MTLVertexFormat.float2));
            attr.setProperty("offset", @as(c_ulong, @offsetOf(Cell, "grid_pos")));
            attr.setProperty("bufferIndex", @as(c_ulong, 0));
        }
        {
            const attr = attrs.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 2)},
            );

            attr.setProperty("format", @intFromEnum(mtl.MTLVertexFormat.uint2));
            attr.setProperty("offset", @as(c_ulong, @offsetOf(Cell, "glyph_pos")));
            attr.setProperty("bufferIndex", @as(c_ulong, 0));
        }
        {
            const attr = attrs.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 3)},
            );

            attr.setProperty("format", @intFromEnum(mtl.MTLVertexFormat.uint2));
            attr.setProperty("offset", @as(c_ulong, @offsetOf(Cell, "glyph_size")));
            attr.setProperty("bufferIndex", @as(c_ulong, 0));
        }
        {
            const attr = attrs.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 4)},
            );

            attr.setProperty("format", @intFromEnum(mtl.MTLVertexFormat.int2));
            attr.setProperty("offset", @as(c_ulong, @offsetOf(Cell, "glyph_offset")));
            attr.setProperty("bufferIndex", @as(c_ulong, 0));
        }
        {
            const attr = attrs.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 5)},
            );

            attr.setProperty("format", @intFromEnum(mtl.MTLVertexFormat.uchar4));
            attr.setProperty("offset", @as(c_ulong, @offsetOf(Cell, "color")));
            attr.setProperty("bufferIndex", @as(c_ulong, 0));
        }
        {
            const attr = attrs.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 6)},
            );

            attr.setProperty("format", @intFromEnum(mtl.MTLVertexFormat.uchar));
            attr.setProperty("offset", @as(c_ulong, @offsetOf(Cell, "cell_width")));
            attr.setProperty("bufferIndex", @as(c_ulong, 0));
        }

        // The layout describes how and when we fetch the next vertex input.
        const layouts = objc.Object.fromId(desc.getProperty(?*anyopaque, "layouts"));
        {
            const layout = layouts.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 0)},
            );

            // Access each Cell per instance, not per vertex.
            layout.setProperty("stepFunction", @intFromEnum(mtl.MTLVertexStepFunction.per_instance));
            layout.setProperty("stride", @as(c_ulong, @sizeOf(Cell)));
        }

        break :vertex_desc desc;
    };
    defer vertex_desc.msgSend(void, objc.sel("release"), .{});

    // Create our descriptor
    const desc = init: {
        const Class = objc.getClass("MTLRenderPipelineDescriptor").?;
        const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
        const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
        break :init id_init;
    };
    defer desc.msgSend(void, objc.sel("release"), .{});

    // Set our properties
    desc.setProperty("vertexFunction", func_vert);
    desc.setProperty("fragmentFunction", func_frag);
    desc.setProperty("vertexDescriptor", vertex_desc);

    // Set our color attachment
    const attachments = objc.Object.fromId(desc.getProperty(?*anyopaque, "colorAttachments"));
    {
        const attachment = attachments.msgSend(
            objc.Object,
            objc.sel("objectAtIndexedSubscript:"),
            .{@as(c_ulong, 0)},
        );

        // Value is MTLPixelFormatBGRA8Unorm
        attachment.setProperty("pixelFormat", @as(c_ulong, 80));

        // Blending. This is required so that our text we render on top
        // of our drawable properly blends into the bg.
        attachment.setProperty("blendingEnabled", true);
        attachment.setProperty("rgbBlendOperation", @intFromEnum(mtl.MTLBlendOperation.add));
        attachment.setProperty("alphaBlendOperation", @intFromEnum(mtl.MTLBlendOperation.add));
        attachment.setProperty("sourceRGBBlendFactor", @intFromEnum(mtl.MTLBlendFactor.one));
        attachment.setProperty("sourceAlphaBlendFactor", @intFromEnum(mtl.MTLBlendFactor.one));
        attachment.setProperty("destinationRGBBlendFactor", @intFromEnum(mtl.MTLBlendFactor.one_minus_source_alpha));
        attachment.setProperty("destinationAlphaBlendFactor", @intFromEnum(mtl.MTLBlendFactor.one_minus_source_alpha));
    }

    // Make our state
    var err: ?*anyopaque = null;
    const pipeline_state = device.msgSend(
        objc.Object,
        objc.sel("newRenderPipelineStateWithDescriptor:error:"),
        .{ desc, &err },
    );
    try checkError(err);
    errdefer pipeline_state.msgSend(void, objc.sel("release"), .{});

    return pipeline_state;
}

/// Initialize the image render pipeline for our shader library.
fn initImagePipeline(device: objc.Object, library: objc.Object) !objc.Object {
    // Get our vertex and fragment functions
    const func_vert = func_vert: {
        const str = try macos.foundation.String.createWithBytes(
            "image_vertex",
            .utf8,
            false,
        );
        defer str.release();

        const ptr = library.msgSend(?*anyopaque, objc.sel("newFunctionWithName:"), .{str});
        break :func_vert objc.Object.fromId(ptr.?);
    };
    const func_frag = func_frag: {
        const str = try macos.foundation.String.createWithBytes(
            "image_fragment",
            .utf8,
            false,
        );
        defer str.release();

        const ptr = library.msgSend(?*anyopaque, objc.sel("newFunctionWithName:"), .{str});
        break :func_frag objc.Object.fromId(ptr.?);
    };
    defer func_vert.msgSend(void, objc.sel("release"), .{});
    defer func_frag.msgSend(void, objc.sel("release"), .{});

    // Create the vertex descriptor. The vertex descriptor describes the
    // data layout of the vertex inputs. We use indexed (or "instanced")
    // rendering, so this makes it so that each instance gets a single
    // Image as input.
    const vertex_desc = vertex_desc: {
        const desc = init: {
            const Class = objc.getClass("MTLVertexDescriptor").?;
            const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
            const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
            break :init id_init;
        };

        // Our attributes are the fields of the input
        const attrs = objc.Object.fromId(desc.getProperty(?*anyopaque, "attributes"));
        {
            const attr = attrs.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 1)},
            );

            attr.setProperty("format", @intFromEnum(mtl.MTLVertexFormat.float2));
            attr.setProperty("offset", @as(c_ulong, @offsetOf(Image, "grid_pos")));
            attr.setProperty("bufferIndex", @as(c_ulong, 0));
        }
        {
            const attr = attrs.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 2)},
            );

            attr.setProperty("format", @intFromEnum(mtl.MTLVertexFormat.float2));
            attr.setProperty("offset", @as(c_ulong, @offsetOf(Image, "cell_offset")));
            attr.setProperty("bufferIndex", @as(c_ulong, 0));
        }
        {
            const attr = attrs.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 3)},
            );

            attr.setProperty("format", @intFromEnum(mtl.MTLVertexFormat.float4));
            attr.setProperty("offset", @as(c_ulong, @offsetOf(Image, "source_rect")));
            attr.setProperty("bufferIndex", @as(c_ulong, 0));
        }
        {
            const attr = attrs.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 4)},
            );

            attr.setProperty("format", @intFromEnum(mtl.MTLVertexFormat.float2));
            attr.setProperty("offset", @as(c_ulong, @offsetOf(Image, "dest_size")));
            attr.setProperty("bufferIndex", @as(c_ulong, 0));
        }

        // The layout describes how and when we fetch the next vertex input.
        const layouts = objc.Object.fromId(desc.getProperty(?*anyopaque, "layouts"));
        {
            const layout = layouts.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 0)},
            );

            // Access each Image per instance, not per vertex.
            layout.setProperty("stepFunction", @intFromEnum(mtl.MTLVertexStepFunction.per_instance));
            layout.setProperty("stride", @as(c_ulong, @sizeOf(Image)));
        }

        break :vertex_desc desc;
    };
    defer vertex_desc.msgSend(void, objc.sel("release"), .{});

    // Create our descriptor
    const desc = init: {
        const Class = objc.getClass("MTLRenderPipelineDescriptor").?;
        const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
        const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
        break :init id_init;
    };
    defer desc.msgSend(void, objc.sel("release"), .{});

    // Set our properties
    desc.setProperty("vertexFunction", func_vert);
    desc.setProperty("fragmentFunction", func_frag);
    desc.setProperty("vertexDescriptor", vertex_desc);

    // Set our color attachment
    const attachments = objc.Object.fromId(desc.getProperty(?*anyopaque, "colorAttachments"));
    {
        const attachment = attachments.msgSend(
            objc.Object,
            objc.sel("objectAtIndexedSubscript:"),
            .{@as(c_ulong, 0)},
        );

        // Value is MTLPixelFormatBGRA8Unorm
        attachment.setProperty("pixelFormat", @as(c_ulong, 80));

        // Blending. This is required so that our text we render on top
        // of our drawable properly blends into the bg.
        attachment.setProperty("blendingEnabled", true);
        attachment.setProperty("rgbBlendOperation", @intFromEnum(mtl.MTLBlendOperation.add));
        attachment.setProperty("alphaBlendOperation", @intFromEnum(mtl.MTLBlendOperation.add));
        attachment.setProperty("sourceRGBBlendFactor", @intFromEnum(mtl.MTLBlendFactor.one));
        attachment.setProperty("sourceAlphaBlendFactor", @intFromEnum(mtl.MTLBlendFactor.one));
        attachment.setProperty("destinationRGBBlendFactor", @intFromEnum(mtl.MTLBlendFactor.one_minus_source_alpha));
        attachment.setProperty("destinationAlphaBlendFactor", @intFromEnum(mtl.MTLBlendFactor.one_minus_source_alpha));
    }

    // Make our state
    var err: ?*anyopaque = null;
    const pipeline_state = device.msgSend(
        objc.Object,
        objc.sel("newRenderPipelineStateWithDescriptor:error:"),
        .{ desc, &err },
    );
    try checkError(err);

    return pipeline_state;
}

fn checkError(err_: ?*anyopaque) !void {
    const nserr = objc.Object.fromId(err_ orelse return);
    const str = @as(
        *macos.foundation.String,
        @ptrCast(nserr.getProperty(?*anyopaque, "localizedDescription").?),
    );

    log.err("metal error={s}", .{str.cstringPtr(.ascii).?});
    return error.MetalFailed;
}

// Intel macOS 13 doesn't like it when any field in a vertex buffer is not
// aligned on the alignment of the struct. I don't understand it, I think
// this must be some macOS 13 Metal GPU driver bug because it doesn't matter
// on macOS 12 or Apple Silicon macOS 13.
//
// To be safe, we put this test in here.
test "Cell offsets" {
    const testing = std.testing;
    const alignment = @alignOf(Cell);
    inline for (@typeInfo(Cell).Struct.fields) |field| {
        const offset = @offsetOf(Cell, field.name);
        try testing.expectEqual(0, @mod(offset, alignment));
    }
}
