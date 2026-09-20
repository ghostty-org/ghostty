//! Vulkan graphics API backend for the GTK renderer.
pub const Vulkan = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const c = @import("vulkan/api.zig").c;

const configpkg = @import("../config.zig");
const font = @import("../font/main.zig");
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(Vulkan);
const shadertoy = @import("shadertoy.zig");
const Dmabuf = @import("Dmabuf.zig");

const Context = @import("vulkan/Context.zig");
const bufferpkg = @import("vulkan/buffer.zig");

pub const GraphicsAPI = Vulkan;
pub const Target = @import("vulkan/Target.zig");
pub const Frame = @import("vulkan/Frame.zig");
pub const RenderPass = @import("vulkan/RenderPass.zig");
pub const Pipeline = @import("vulkan/Pipeline.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("vulkan/Sampler.zig");
pub const Texture = @import("vulkan/Texture.zig");
pub const shaders = @import("vulkan/shaders.zig");

pub const custom_shader_target: shadertoy.Target = .glsl;
pub const custom_shader_y_is_down = true;
pub const swap_chain_count = 3;

alloc: Allocator,
context: *Context,
blending: configpkg.Config.AlphaBlending,
surface_width: u32,
surface_height: u32,

pub fn init(alloc: Allocator, opts: rendererpkg.Options) !Vulkan {
    if (comptime builtin.os.tag != .linux) {
        @compileError("the Vulkan renderer currently supports Linux only");
    }

    return .{
        .alloc = alloc,
        .context = try Context.init(alloc),
        .blending = opts.config.blending,
        .surface_width = opts.size.screen.width,
        .surface_height = opts.size.screen.height,
    };
}

pub fn deinit(self: *Vulkan) void {
    self.context.deinit(self.alloc);
}

pub fn surfaceSize(self: *const Vulkan) !struct { width: u32, height: u32 } {
    return .{ .width = self.surface_width, .height = self.surface_height };
}

pub fn setViewport(self: *Vulkan, width: u32, height: u32) void {
    self.surface_width = width;
    self.surface_height = height;
}

pub fn drawFrameStart(self: *Vulkan) void {
    _ = self;
}

pub fn drawFrameEnd(self: *Vulkan) void {
    _ = self;
}

pub fn initShaders(self: *const Vulkan, alloc: Allocator, custom_shaders: []const [:0]const u8) !shaders.Shaders {
    return .init(alloc, self.context, custom_shaders, self.targetFormat());
}

pub fn initTarget(self: *const Vulkan, width: usize, height: usize) !Target {
    return .init(.{
        .context = self.context,
        .width = width,
        .height = height,
        .format = self.targetFormat(),
    });
}

pub fn present(self: *Vulkan, target: Target) !ExportedFrame {
    if (target.exportDmabuf()) |dmabuf| return .{ .dmabuf = dmabuf } else |err| {
        std.log.scoped(.vulkan).warn("DMA-BUF presentation failed, using memory fallback err={}", .{err});
    }
    return .{ .memory = .{
        .width = @intCast(target.width),
        .height = @intCast(target.height),
        .pixels = try target.readPixelsAlloc(self.alloc),
        .alloc = self.alloc,
    } };
}

pub const ExportedFrame = union(enum) {
    dmabuf: Dmabuf,
    memory: Memory,

    pub const Memory = struct {
        width: u32,
        height: u32,
        pixels: []u8,
        alloc: Allocator,

        pub fn deinit(self: Memory) void {
            self.alloc.free(self.pixels);
        }
    };

    pub fn deinit(self: ExportedFrame) void {
        switch (self) {
            .dmabuf => |value| value.deinit(),
            .memory => |value| value.deinit(),
        }
    }
};

pub inline fn bufferOptions(self: Vulkan) bufferpkg.Options {
    return .{
        .context = self.context,
        .usage = c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT |
            c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT |
            c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
    };
}

pub const instanceBufferOptions = bufferOptions;
pub const uniformBufferOptions = bufferOptions;
pub const fgBufferOptions = bufferOptions;
pub const bgBufferOptions = bufferOptions;
pub const imageBufferOptions = bufferOptions;
pub const bgImageBufferOptions = bufferOptions;

pub inline fn textureOptions(self: Vulkan) Texture.Options {
    return .{
        .context = self.context,
        .format = self.targetFormat(),
        .upload_format = .rgba,
        .min_filter = c.VK_FILTER_LINEAR,
        .mag_filter = c.VK_FILTER_LINEAR,
        .address_mode = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
    };
}

pub inline fn samplerOptions(self: Vulkan) Sampler.Options {
    return .{
        .context = self.context,
        .min_filter = c.VK_FILTER_LINEAR,
        .mag_filter = c.VK_FILTER_LINEAR,
        .address_mode = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
    };
}

pub const ImageTextureFormat = enum { gray, rgba, bgra };

pub inline fn imageTextureOptions(self: Vulkan, format: ImageTextureFormat, srgb: bool) Texture.Options {
    return .{
        .context = self.context,
        .format = switch (format) {
            .gray => c.VK_FORMAT_R8_UNORM,
            .rgba => if (srgb) c.VK_FORMAT_R8G8B8A8_SRGB else c.VK_FORMAT_R8G8B8A8_UNORM,
            .bgra => if (srgb) c.VK_FORMAT_B8G8R8A8_SRGB else c.VK_FORMAT_B8G8R8A8_UNORM,
        },
        .upload_format = switch (format) {
            .gray => .gray,
            .rgba => .rgba,
            .bgra => .bgra,
        },
        .min_filter = c.VK_FILTER_LINEAR,
        .mag_filter = c.VK_FILTER_LINEAR,
        .address_mode = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
    };
}

pub fn initAtlasTexture(self: *const Vulkan, atlas: *const font.Atlas) Texture.Error!Texture {
    const format: c.VkFormat, const upload_format: Texture.PixelFormat = switch (atlas.format) {
        .grayscale => .{ c.VK_FORMAT_R8_UNORM, .gray },
        .bgra => .{ c.VK_FORMAT_B8G8R8A8_SRGB, .bgra },
        else => @panic("unsupported atlas format for Vulkan texture"),
    };
    return .init(.{
        .context = self.context,
        .format = format,
        .upload_format = upload_format,
        .min_filter = c.VK_FILTER_NEAREST,
        .mag_filter = c.VK_FILTER_NEAREST,
        .address_mode = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .unnormalized_coordinates = true,
    }, atlas.size, atlas.size, null);
}

pub inline fn beginFrame(self: *const Vulkan, renderer: *Renderer, target: *Target) !Frame {
    _ = self;
    return .begin(.{}, renderer, target);
}

fn targetFormat(self: *const Vulkan) c.VkFormat {
    return if (self.blending.isLinear()) c.VK_FORMAT_R8G8B8A8_SRGB else c.VK_FORMAT_R8G8B8A8_UNORM;
}
