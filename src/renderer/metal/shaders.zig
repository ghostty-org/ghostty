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

    /// Renders cell foreground elements (text, decorations).
    cell_text_pipeline: objc.Object,

    /// The cell background shader is the shader used to render the
    /// background of terminal cells.
    cell_bg_pipeline: objc.Object,

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
        pixel_format: mtl.MTLPixelFormat,
    ) !Shaders {
        const library = try initLibrary(device);
        errdefer library.msgSend(void, objc.sel("release"), .{});

        const cell_text_pipeline = try initCellTextPipeline(device, library, pixel_format);
        errdefer cell_text_pipeline.msgSend(void, objc.sel("release"), .{});

        const cell_bg_pipeline = try initCellBgPipeline(device, library, pixel_format);
        errdefer cell_bg_pipeline.msgSend(void, objc.sel("release"), .{});

        const image_pipeline = try initImagePipeline(device, library, pixel_format);
        errdefer image_pipeline.msgSend(void, objc.sel("release"), .{});

        const post_pipelines: []const objc.Object = initPostPipelines(
            alloc,
            device,
            library,
            post_shaders,
            pixel_format,
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
            .cell_text_pipeline = cell_text_pipeline,
            .cell_bg_pipeline = cell_bg_pipeline,
            .image_pipeline = image_pipeline,
            .post_pipelines = post_pipelines,
        };
    }

    pub fn deinit(self: *Shaders, alloc: Allocator) void {
        // Release our primary shaders
        self.cell_text_pipeline.msgSend(void, objc.sel("release"), .{});
        self.cell_bg_pipeline.msgSend(void, objc.sel("release"), .{});
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

/// Single parameter for the image shader. See shader for field details.
pub const Image = extern struct {
    grid_pos: [2]f32,
    cell_offset: [2]f32,
    source_rect: [4]f32,
    dest_size: [2]f32,
};

/// The uniforms that are passed to the terminal cell shader.
pub const Uniforms = extern struct {
    // Note: all of the explicit aligmnments are copied from the
    // MSL developer reference just so that we can be sure that we got
    // it all exactly right.

    /// The projection matrix for turning world coordinates to normalized.
    /// This is calculated based on the size of the screen.
    projection_matrix: math.Mat align(16),

    /// Size of a single cell in pixels, unscaled.
    cell_size: [2]f32 align(8),

    /// Size of the grid in columns and rows.
    grid_size: [2]u16 align(4),

    /// The padding around the terminal grid in pixels. In order:
    /// top, right, bottom, left.
    grid_padding: [4]f32 align(16),

    /// Bit mask defining which directions to
    /// extend cell colors in to the padding.
    /// Order, LSB first: left, right, up, down
    padding_extend: PaddingExtend align(1),

    /// The minimum contrast ratio for text. The contrast ratio is calculated
    /// according to the WCAG 2.0 spec.
    min_contrast: f32 align(4),

    /// The cursor position and color.
    cursor_pos: [2]u16 align(4),
    cursor_color: [4]u8 align(4),

    /// The background color for the whole surface.
    bg_color: [4]u8 align(4),

    /// Whether the cursor is 2 cells wide.
    cursor_wide: bool align(1),

    /// Indicates that colors provided to the shader are already in
    /// the P3 color space, so they don't need to be converted from
    /// sRGB.
    use_display_p3: bool align(1),

    /// Indicates that the color attachments for the shaders have
    /// an `*_srgb` pixel format, which means the shaders need to
    /// output linear RGB colors rather than gamma encoded colors,
    /// since blending will be performed in linear space and then
    /// Metal itself will re-encode the colors for storage.
    use_linear_blending: bool align(1),

    /// Enables a weight correction step that makes text rendered
    /// with linear alpha blending have a similar apparent weight
    /// (thickness) to gamma-incorrect blending.
    use_linear_correction: bool align(1) = false,

    const PaddingExtend = packed struct(u8) {
        left: bool = false,
        right: bool = false,
        up: bool = false,
        down: bool = false,
        _padding: u4 = 0,
    };
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
    const start = try std.time.Instant.now();

    const data = try macos.dispatch.Data.create(
        @embedFile("ghostty_metallib"),
        macos.dispatch.queue.getMain(),
        macos.dispatch.Data.DESTRUCTOR_DEFAULT,
    );
    defer data.release();

    var err: ?*anyopaque = null;
    const library = device.msgSend(
        objc.Object,
        objc.sel("newLibraryWithData:error:"),
        .{
            data,
            &err,
        },
    );
    try checkError(err);

    const end = try std.time.Instant.now();
    log.debug("shader library loaded time={}us", .{end.since(start) / std.time.ns_per_us});

    return library;
}

/// Initialize our custom shader pipelines. The shaders argument is a
/// set of shader source code, not file paths.
fn initPostPipelines(
    alloc: Allocator,
    device: objc.Object,
    library: objc.Object,
    shaders: []const [:0]const u8,
    pixel_format: mtl.MTLPixelFormat,
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
        pipelines[i] = try initPostPipeline(
            device,
            library,
            source,
            pixel_format,
        );
        i += 1;
    }

    return pipelines;
}

/// Initialize a single custom shader pipeline from shader source.
fn initPostPipeline(
    device: objc.Object,
    library: objc.Object,
    data: [:0]const u8,
    pixel_format: mtl.MTLPixelFormat,
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
            "full_screen_vertex",
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

        attachment.setProperty("pixelFormat", @intFromEnum(pixel_format));
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

/// This is a single parameter for the terminal cell shader.
pub const CellText = extern struct {
    glyph_pos: [2]u32 align(8) = .{ 0, 0 },
    glyph_size: [2]u32 align(8) = .{ 0, 0 },
    bearings: [2]i16 align(4) = .{ 0, 0 },
    grid_pos: [2]u16 align(4),
    color: [4]u8 align(4),
    mode: Mode align(1),
    constraint_width: u8 align(1) = 0,

    pub const Mode = enum(u8) {
        fg = 1,
        fg_constrained = 2,
        fg_color = 3,
        cursor = 4,
        fg_powerline = 5,
    };

    test {
        // Minimizing the size of this struct is important,
        // so we test it in order to be aware of any changes.
        try std.testing.expectEqual(32, @sizeOf(CellText));
    }
};

/// Initialize the cell render pipeline for our shader library.
fn initCellTextPipeline(
    device: objc.Object,
    library: objc.Object,
    pixel_format: mtl.MTLPixelFormat,
) !objc.Object {
    // Get our vertex and fragment functions
    const func_vert = func_vert: {
        const str = try macos.foundation.String.createWithBytes(
            "cell_text_vertex",
            .utf8,
            false,
        );
        defer str.release();

        const ptr = library.msgSend(?*anyopaque, objc.sel("newFunctionWithName:"), .{str});
        break :func_vert objc.Object.fromId(ptr.?);
    };
    const func_frag = func_frag: {
        const str = try macos.foundation.String.createWithBytes(
            "cell_text_fragment",
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
        autoAttribute(CellText, attrs);

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
            layout.setProperty("stride", @as(c_ulong, @sizeOf(CellText)));
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

        attachment.setProperty("pixelFormat", @intFromEnum(pixel_format));

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

/// This is a single parameter for the cell bg shader.
pub const CellBg = [4]u8;

/// Initialize the cell background render pipeline for our shader library.
fn initCellBgPipeline(
    device: objc.Object,
    library: objc.Object,
    pixel_format: mtl.MTLPixelFormat,
) !objc.Object {
    // Get our vertex and fragment functions
    const func_vert = func_vert: {
        const str = try macos.foundation.String.createWithBytes(
            "cell_bg_vertex",
            .utf8,
            false,
        );
        defer str.release();

        const ptr = library.msgSend(?*anyopaque, objc.sel("newFunctionWithName:"), .{str});
        break :func_vert objc.Object.fromId(ptr.?);
    };
    defer func_vert.msgSend(void, objc.sel("release"), .{});
    const func_frag = func_frag: {
        const str = try macos.foundation.String.createWithBytes(
            "cell_bg_fragment",
            .utf8,
            false,
        );
        defer str.release();

        const ptr = library.msgSend(?*anyopaque, objc.sel("newFunctionWithName:"), .{str});
        break :func_frag objc.Object.fromId(ptr.?);
    };
    defer func_frag.msgSend(void, objc.sel("release"), .{});

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

    // Set our color attachment
    const attachments = objc.Object.fromId(desc.getProperty(?*anyopaque, "colorAttachments"));
    {
        const attachment = attachments.msgSend(
            objc.Object,
            objc.sel("objectAtIndexedSubscript:"),
            .{@as(c_ulong, 0)},
        );

        attachment.setProperty("pixelFormat", @intFromEnum(pixel_format));

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
fn initImagePipeline(
    device: objc.Object,
    library: objc.Object,
    pixel_format: mtl.MTLPixelFormat,
) !objc.Object {
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
        autoAttribute(Image, attrs);

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

        attachment.setProperty("pixelFormat", @intFromEnum(pixel_format));

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

fn autoAttribute(T: type, attrs: objc.Object) void {
    inline for (@typeInfo(T).Struct.fields, 0..) |field, i| {
        const offset = @offsetOf(T, field.name);

        const FT = switch (@typeInfo(field.type)) {
            .Enum => |e| e.tag_type,
            else => field.type,
        };

        const format = switch (FT) {
            [4]u8 => mtl.MTLVertexFormat.uchar4,
            [2]u16 => mtl.MTLVertexFormat.ushort2,
            [2]i16 => mtl.MTLVertexFormat.short2,
            [2]f32 => mtl.MTLVertexFormat.float2,
            [4]f32 => mtl.MTLVertexFormat.float4,
            [2]i32 => mtl.MTLVertexFormat.int2,
            u32 => mtl.MTLVertexFormat.uint,
            [2]u32 => mtl.MTLVertexFormat.uint2,
            [4]u32 => mtl.MTLVertexFormat.uint4,
            u8 => mtl.MTLVertexFormat.uchar,
            else => comptime unreachable,
        };

        const attr = attrs.msgSend(
            objc.Object,
            objc.sel("objectAtIndexedSubscript:"),
            .{@as(c_ulong, i)},
        );

        attr.setProperty("format", @intFromEnum(format));
        attr.setProperty("offset", @as(c_ulong, offset));
        attr.setProperty("bufferIndex", @as(c_ulong, 0));
    }
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
