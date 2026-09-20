const std = @import("std");
const c = @import("api.zig").c;
const Context = @import("Context.zig");
const shadertoy = @import("../shadertoy.zig");

const log = std.log.scoped(.vulkan_shader);

pub fn module(
    context: *Context,
    alloc: std.mem.Allocator,
    source: [:0]const u8,
    stage: shadertoy.ShaderStage,
) !c.VkShaderModule {
    const transformed = try transform(alloc, source);
    defer alloc.free(transformed);

    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    var errlog: shadertoy.SpirvLog = .{ .alloc = alloc };
    defer errlog.deinit();
    shadertoy.spirvFromGlslStage(&output.writer, &errlog, transformed, stage) catch |err| {
        log.err("GLSL to SPIR-V failed stage={} info={s} debug={s}", .{ stage, errlog.info, errlog.debug });
        log.debug("failed shader source:\n{s}", .{transformed});
        return err;
    };
    const bytes = output.written();
    if (bytes.len % @sizeOf(u32) != 0) return error.InvalidSpirv;

    var info = std.mem.zeroes(c.VkShaderModuleCreateInfo);
    info.sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    info.codeSize = bytes.len;
    info.pCode = @ptrCast(@alignCast(bytes.ptr));
    var result: c.VkShaderModule = null;
    try Context.result(c.vkCreateShaderModule(context.device, &info, null, &result));
    return result;
}

fn transform(alloc: std.mem.Allocator, source: [:0]const u8) ![:0]u8 {
    var value = try alloc.dupeZ(u8, source);
    errdefer alloc.free(value);

    const replacements = [_]struct { []const u8, []const u8 }{
        .{ "#version 330 core", "#version 450" },
        .{ "#version 430 core", "#version 450" },
        .{ "layout(binding = 1, std140)", "layout(set = 0, binding = 0, std140)" },
        .{ "layout(binding = 1, std430)", "layout(set = 0, binding = 1, std430)" },
        .{ "layout(binding = 1) uniform sampler", "layout(set = 0, binding = 3) uniform sampler" },
        .{ "layout(binding = 0) uniform sampler", "layout(set = 0, binding = 2) uniform sampler" },
        .{ "sampler2DRect", "sampler2D" },
        .{ "gl_VertexID", "gl_VertexIndex" },
        .{ "layout(origin_upper_left) in vec4 gl_FragCoord;", "" },
        .{ "layout(location = 0) in vec4 gl_FragCoord;", "" },
        .{ "out CellTextVertexOut", "layout(location = 0) out CellTextVertexOut" },
        .{ "in CellTextVertexOut", "layout(location = 0) in CellTextVertexOut" },
        .{ "out vec2 tex_coord;", "layout(location = 0) out vec2 tex_coord;" },
        .{ "in vec2 tex_coord;", "layout(location = 0) in vec2 tex_coord;" },
        .{ "flat out vec4 bg_color;", "layout(location = 0) flat out vec4 bg_color;" },
        .{ "flat out vec2 offset;", "layout(location = 1) flat out vec2 offset;" },
        .{ "flat out vec2 scale;", "layout(location = 2) flat out vec2 scale;" },
        .{ "flat out float opacity;", "layout(location = 3) flat out float opacity;" },
        .{ "flat out uint repeat;", "layout(location = 4) flat out uint repeat;" },
        .{ "flat in vec4 bg_color;", "layout(location = 0) flat in vec4 bg_color;" },
        .{ "flat in vec2 offset;", "layout(location = 1) flat in vec2 offset;" },
        .{ "flat in vec2 scale;", "layout(location = 2) flat in vec2 scale;" },
        .{ "flat in float opacity;", "layout(location = 3) flat in float opacity;" },
        .{ "flat in uint repeat;", "layout(location = 4) flat in uint repeat;" },
    };
    for (replacements) |replacement| {
        const next = try replaceOwned(alloc, value, replacement[0], replacement[1]);
        alloc.free(value);
        value = next;
    }
    return value;
}

fn replaceOwned(alloc: std.mem.Allocator, input: [:0]const u8, needle: []const u8, replacement: []const u8) ![:0]u8 {
    var writer: std.Io.Writer.Allocating = .init(alloc);
    errdefer writer.deinit();
    var rest: []const u8 = input;
    while (std.mem.indexOf(u8, rest, needle)) |index| {
        try writer.writer.writeAll(rest[0..index]);
        try writer.writer.writeAll(replacement);
        rest = rest[index + needle.len ..];
    }
    try writer.writer.writeAll(rest);
    try writer.writer.writeByte(0);
    const written = try writer.toOwnedSlice();
    return written[0 .. written.len - 1 :0];
}

test "transform GLSL resource bindings and builtins for Vulkan" {
    const source =
        \\#version 430 core
        \\layout(binding = 1, std140) uniform Globals { vec4 value; };
        \\layout(binding = 1, std430) readonly buffer Cells { vec4 cells[]; };
        \\layout(binding = 0) uniform sampler2DRect atlas;
        \\layout(location = 0) in vec4 gl_FragCoord;
        \\void main() { vec4 v = texture(atlas, vec2(gl_VertexID)); }
    ;
    const transformed = try transform(std.testing.allocator, source);
    defer std.testing.allocator.free(transformed);

    try std.testing.expect(std.mem.startsWith(u8, transformed, "#version 450"));
    try std.testing.expect(std.mem.indexOf(u8, transformed, "layout(set = 0, binding = 0, std140)") != null);
    try std.testing.expect(std.mem.indexOf(u8, transformed, "layout(set = 0, binding = 1, std430)") != null);
    try std.testing.expect(std.mem.indexOf(u8, transformed, "layout(set = 0, binding = 2) uniform sampler2D atlas") != null);
    try std.testing.expect(std.mem.indexOf(u8, transformed, "gl_VertexIndex") != null);
    try std.testing.expect(std.mem.indexOf(u8, transformed, "layout(location = 0) in vec4 gl_FragCoord") == null);
}
