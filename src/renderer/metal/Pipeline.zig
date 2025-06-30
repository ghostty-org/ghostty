//! Wrapper for handling render pipelines.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const builtin = @import("builtin");
const macos = @import("macos");
const objc = @import("objc");

const mtl = @import("api.zig");
const Texture = @import("Texture.zig");
const Metal = @import("../Metal.zig");

const log = std.log.scoped(.metal);

/// Options for initializing a render pipeline.
pub const Options = struct {
    /// MTLDevice
    device: objc.Object,

    /// Name of the vertex function
    vertex_fn: []const u8,
    /// Name of the fragment function
    fragment_fn: []const u8,

    /// MTLLibrary to get the vertex function from
    vertex_library: objc.Object,
    /// MTLLibrary to get the fragment function from
    fragment_library: objc.Object,

    /// Vertex step function
    step_fn: mtl.MTLVertexStepFunction = .per_vertex,

    /// Info about the color attachments used by this render pipeline.
    attachments: []const Attachment,

    /// Describes a color attachment.
    pub const Attachment = struct {
        pixel_format: mtl.MTLPixelFormat,
        blending_enabled: bool = true,
    };
};

/// MTLRenderPipelineState
state: objc.Object,

pub fn init(comptime VertexAttributes: ?type, opts: Options) !Self {
    // Create our descriptor
    const desc = init: {
        const Class = objc.getClass("MTLRenderPipelineDescriptor").?;
        const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
        const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
        break :init id_init;
    };
    defer desc.msgSend(void, objc.sel("release"), .{});

    // Get our vertex and fragment functions and add them to the descriptor.
    {
        const str = try macos.foundation.String.createWithBytes(
            opts.vertex_fn,
            .utf8,
            false,
        );
        defer str.release();

        const ptr = opts.vertex_library.msgSend(?*anyopaque, objc.sel("newFunctionWithName:"), .{str});
        const func_vert = objc.Object.fromId(ptr.?);
        defer func_vert.msgSend(void, objc.sel("release"), .{});

        desc.setProperty("vertexFunction", func_vert);
    }
    {
        const str = try macos.foundation.String.createWithBytes(
            opts.fragment_fn,
            .utf8,
            false,
        );
        defer str.release();

        const ptr = opts.fragment_library.msgSend(?*anyopaque, objc.sel("newFunctionWithName:"), .{str});
        const func_frag = objc.Object.fromId(ptr.?);
        defer func_frag.msgSend(void, objc.sel("release"), .{});

        desc.setProperty("fragmentFunction", func_frag);
    }

    // If we have vertex attributes, create and add a vertex descriptor.
    if (VertexAttributes) |V| {
        const vertex_desc = init: {
            const Class = objc.getClass("MTLVertexDescriptor").?;
            const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
            const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
            break :init id_init;
        };
        defer vertex_desc.msgSend(void, objc.sel("release"), .{});

        // Our attributes are the fields of the input
        const attrs = objc.Object.fromId(vertex_desc.getProperty(?*anyopaque, "attributes"));
        autoAttribute(V, attrs);

        // The layout describes how and when we fetch the next vertex input.
        const layouts = objc.Object.fromId(vertex_desc.getProperty(?*anyopaque, "layouts"));
        {
            const layout = layouts.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, 0)},
            );

            layout.setProperty("stepFunction", @intFromEnum(opts.step_fn));
            layout.setProperty("stride", @as(c_ulong, @sizeOf(V)));
        }

        desc.setProperty("vertexDescriptor", vertex_desc);
    }

    // Set our color attachment
    const attachments = objc.Object.fromId(desc.getProperty(?*anyopaque, "colorAttachments"));
    for (opts.attachments, 0..) |at, i| {
        const attachment = attachments.msgSend(
            objc.Object,
            objc.sel("objectAtIndexedSubscript:"),
            .{@as(c_ulong, i)},
        );

        attachment.setProperty("pixelFormat", @intFromEnum(at.pixel_format));

        attachment.setProperty("blendingEnabled", at.blending_enabled);
        // We always use premultiplied alpha blending for now.
        if (at.blending_enabled) {
            attachment.setProperty("rgbBlendOperation", @intFromEnum(mtl.MTLBlendOperation.add));
            attachment.setProperty("alphaBlendOperation", @intFromEnum(mtl.MTLBlendOperation.add));
            attachment.setProperty("sourceRGBBlendFactor", @intFromEnum(mtl.MTLBlendFactor.one));
            attachment.setProperty("sourceAlphaBlendFactor", @intFromEnum(mtl.MTLBlendFactor.one));
            attachment.setProperty("destinationRGBBlendFactor", @intFromEnum(mtl.MTLBlendFactor.one_minus_source_alpha));
            attachment.setProperty("destinationAlphaBlendFactor", @intFromEnum(mtl.MTLBlendFactor.one_minus_source_alpha));
        }
    }

    // Make our state
    var err: ?*anyopaque = null;
    const pipeline_state = opts.device.msgSend(
        objc.Object,
        objc.sel("newRenderPipelineStateWithDescriptor:error:"),
        .{ desc, &err },
    );
    try checkError(err);
    errdefer pipeline_state.release();

    return .{ .state = pipeline_state };
}

pub fn deinit(self: *const Self) void {
    self.state.release();
}

fn autoAttribute(T: type, attrs: objc.Object) void {
    inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
        const offset = @offsetOf(T, field.name);

        const FT = switch (@typeInfo(field.type)) {
            .@"struct" => |e| e.backing_integer.?,
            .@"enum" => |e| e.tag_type,
            else => field.type,
        };

        // Very incomplete list, expand as necessary.
        const format = switch (FT) {
            [4]u8 => mtl.MTLVertexFormat.uchar4,
            [2]u16 => mtl.MTLVertexFormat.ushort2,
            [2]i16 => mtl.MTLVertexFormat.short2,
            f32 => mtl.MTLVertexFormat.float,
            [2]f32 => mtl.MTLVertexFormat.float2,
            [4]f32 => mtl.MTLVertexFormat.float4,
            i32 => mtl.MTLVertexFormat.int,
            [2]i32 => mtl.MTLVertexFormat.int2,
            [4]i32 => mtl.MTLVertexFormat.int2,
            u32 => mtl.MTLVertexFormat.uint,
            [2]u32 => mtl.MTLVertexFormat.uint2,
            [4]u32 => mtl.MTLVertexFormat.uint4,
            u8 => mtl.MTLVertexFormat.uchar,
            i8 => mtl.MTLVertexFormat.char,
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
