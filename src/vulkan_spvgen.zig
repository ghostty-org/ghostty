//! Build-time tool: compiles one of `src/renderer/vulkan/shaders.zig`'s
//! `source.*` constants to SPIR-V and writes the bytes to stdout.
//!
//! Invoked by `src/build/VulkanSpv.zig` once per (shader_name, stage)
//! pair so the renderer can `@embedFile` the resulting .spv blobs
//! and call `Module.initFromSpirv` for built-ins instead of going
//! through `glslang.vk.compileToSpv` at runtime. The runtime path
//! is what populates glslang's per-thread `TPoolAllocator`, which
//! never releases its high-water-mark pages (Zig pthreads don't
//! run C++ thread_local destructors) — heaptrack attributed ~10 MB
//! to that residual leak on the Vulkan variant, exactly the delta
//! over OpenGL (which never invokes glslang for its built-ins
//! because the GPU driver compiles GLSL natively).
//!
//! Usage:
//!   vulkan_spvgen <shader_name> <stage>
//!
//! Where `shader_name` is one of the public decls of
//! `vulkan.shaders.source` (e.g. `bg_color_frag`, `cell_text_vert`)
//! and `stage` is `vertex` or `fragment`.
//!
//! On success: writes binary SPIR-V to stdout, exits 0.
//! On failure: writes a diagnostic to stderr, exits 1.

const std = @import("std");
const shaders = @import("renderer/vulkan/shaders.zig");
const glslang = @import("glslang");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len != 3) {
        std.debug.print(
            "usage: {s} <shader_name> <vertex|fragment>\n",
            .{args[0]},
        );
        std.process.exit(1);
    }
    const name = args[1];
    const stage = std.meta.stringToEnum(shaders.Stage, args[2]) orelse {
        std.debug.print("invalid stage: {s}\n", .{args[2]});
        std.process.exit(1);
    };

    try glslang.init();
    defer glslang.finalize();

    // Resolve the source by name. The runtime renderer accesses
    // `shaders.source.bg_color_frag` etc. directly; we look up the
    // matching decl by name at comptime so the build step can pass
    // any of the 9 built-ins by string argv.
    const src: [:0]const u8 = src: {
        inline for (@typeInfo(shaders.source).@"struct".decls) |decl| {
            if (std.mem.eql(u8, decl.name, name)) {
                break :src @field(shaders.source, decl.name);
            }
        }
        std.debug.print("unknown shader: {s}\n", .{name});
        std.process.exit(1);
    };

    // Vulkan-flavor rewrite (gl_VertexID → gl_VertexIndex, multi-set
    // descriptor layout, etc.). Same path the runtime took before
    // this precompile change.
    const translated = try shaders.vulkanizeGlsl(alloc, src);
    defer alloc.free(translated);

    const spv = try glslang.vk.compileToSpv(
        alloc,
        translated,
        stage.vkBindingStage(),
    );
    defer alloc.free(spv);

    // Write the raw SPIR-V words (u32 little-endian on every host
    // we build for; Vulkan loaders accept the in-memory byte order
    // of the platform). The build step captures stdout into a .spv
    // file the renderer @embedFiles at compile time.
    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writerStreaming(&buf);
    try stdout.interface.writeAll(std.mem.sliceAsBytes(spv));
    try stdout.end();
}
