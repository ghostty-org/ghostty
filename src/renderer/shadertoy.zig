const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const glslang = @import("glslang");
const spvcross = @import("spirv_cross");
const configpkg = @import("../config.zig");

const log = std.log.scoped(.shadertoy);

/// The uniform struct used for shadertoy shaders.
pub const Uniforms = extern struct {
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
    current_cursor: [4]f32 align(16),
    previous_cursor: [4]f32 align(16),
    current_cursor_color: [4]f32 align(16),
    previous_cursor_color: [4]f32 align(16),
    current_cursor_style: i32 align(4),
    previous_cursor_style: i32 align(4),
    cursor_visible: i32 align(4),
    cursor_change_time: f32 align(4),
    time_focus: f32 align(4),
    focus: i32 align(4),
    palette: [256][4]f32 align(16),
    background_color: [4]f32 align(16),
    foreground_color: [4]f32 align(16),
    cursor_color: [4]f32 align(16),
    cursor_text: [4]f32 align(16),
    selection_background_color: [4]f32 align(16),
    selection_foreground_color: [4]f32 align(16),
};

/// The target to load shaders for.
///
///   - `.glsl`: roundtripped through SPIR-V back to GLSL via
///     spirv-cross. Normalizes/validates the source. The OpenGL
///     backend consumes this.
///   - `.msl`: spirv-cross translation to Metal Shading Language.
///   - `.spv`: raw SPIR-V binary (no spirv-cross roundtrip). The
///     Vulkan backend consumes this — Vulkan compiles GLSL → SPIR-V
///     itself via glslang for its built-in shaders, and feeding
///     the user shader through GLSL→SPIR-V→GLSL→SPIR-V again costs
///     2× the compile work AND loses the original source structure
///     (which broke our `gl_FragCoord` Y-flip rewrite when the
///     spirv-cross-emitted main() didn't match the upstream prefix).
pub const Target = enum { glsl, msl, spv };

/// Optional GLSL → GLSL rewriter applied between the prefix splice
/// and the SPIR-V compile. Vulkan plugs in `vulkanizeGlsl` here so
/// SPIR-V output uses the renderer's multi-set descriptor layout;
/// other backends pass `null`. Owns its allocation under the
/// caller's allocator (`shadertoy.loadFromFile` runs it inside an
/// arena that's torn down at function exit, so the rewriter's
/// returned slice may be arena-owned).
pub const Rewriter = *const fn (
    alloc: Allocator,
    src: []const u8,
) Allocator.Error![:0]const u8;

/// What `loadFromFile`/`loadFromFiles` need beyond the path itself.
/// Keeps the function decoupled from any specific backend — every
/// backend-flavored knob becomes an explicit field, and `shadertoy`
/// itself reaches into no other backend's submodules.
pub const LoadOptions = struct {
    /// Output language / format. See `Target` for the per-variant
    /// rationale.
    target: Target,

    /// `#define <body>` lines injected after the prefix's
    /// `#version` directive. Vulkan passes
    /// `&.{"GHASTTY_VULKAN 1"}` so the prefix's `main()` flips
    /// `gl_FragCoord.y` and wraps `texture()` for upper-left
    /// sampling; OpenGL/MSL pass `&.{}`.
    extra_defines: []const []const u8 = &.{},

    /// Optional second-pass GLSL transform run between the prefix
    /// splice and the SPIR-V compile. Vulkan installs
    /// `vulkan/shaders.zig:vulkanizeGlsl` here for the multi-set
    /// descriptor layout rewrite; other backends leave it null.
    rewrite: ?Rewriter = null,
};

/// Load a set of shaders from files and convert them to the target
/// format. The shader order is preserved.
///
/// Result element type depends on `opts.target`: `.glsl`/`.msl`
/// produce null-terminated UTF-8 source strings; `.spv` produces
/// SPIR-V binary bytes (4-byte-aligned, no trailing null). We unify
/// the return type as `[]const []const u8` and have the caller cast/
/// reinterpret as needed.
pub fn loadFromFiles(
    alloc_gpa: Allocator,
    paths: configpkg.RepeatablePath,
    opts: LoadOptions,
) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(alloc_gpa);
    errdefer for (list.items) |shader| alloc_gpa.free(shader);

    for (paths.value.items) |item| {
        const path, const optional = switch (item) {
            .optional => |path| .{ path, true },
            .required => |path| .{ path, false },
        };

        const shader = loadFromFile(alloc_gpa, path, opts) catch |err| {
            if (err == error.FileNotFound and optional) {
                continue;
            }

            return err;
        };
        // Take ownership of `shader` immediately. If the subsequent
        // `list.append` itself OOMs, the freshly-loaded slice would
        // leak — `errdefer` at the function level only iterates
        // `list.items`, and `shader` isn't in `list` yet. Free it
        // explicitly on the error path before propagating.
        errdefer alloc_gpa.free(shader);
        log.info("loaded custom shader path={s}", .{path});
        try list.append(alloc_gpa, shader);
    }

    return try list.toOwnedSlice(alloc_gpa);
}

/// Load a single shader from a file and convert it to the target language
/// ready to be used with renderers.
///
/// For `.glsl` / `.msl` the returned slice is a null-terminated UTF-8
/// source string; the underlying allocation is `[:0]const u8` and
/// callers that need the sentinel may safely cast. For `.spv` the
/// returned slice is raw SPIR-V bytes — no terminator, 4-byte aligned.
pub fn loadFromFile(
    alloc_gpa: Allocator,
    path: []const u8,
    opts: LoadOptions,
) ![]const u8 {
    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Read it all into memory -- we don't expect shaders to be large.
    const src = src: {
        // Load the shader file
        const cwd = std.fs.cwd();
        const file = try cwd.openFile(path, .{});
        defer file.close();

        break :src try file.readToEndAlloc(
            alloc,
            4 * 1024 * 1024, // 4MB
        );
    };

    // Convert to full GLSL. `opts.extra_defines` lets a backend
    // inject `#define <body>` lines after the prefix's `#version`
    // directive — Vulkan uses this to flip `gl_FragCoord.y` and
    // wrap `texture()` for upper-left sampling so `mainImage` sees
    // shadertoy-convention coords; OpenGL/MSL pass `&.{}` and use
    // the GL-native paths unchanged.
    const glsl_raw: [:0]const u8 = glsl: {
        var stream: std.Io.Writer.Allocating = .init(alloc);
        try glslFromShader(&stream.writer, src, opts.extra_defines);
        try stream.writer.writeByte(0);
        break :glsl stream.written()[0 .. stream.written().len - 1 :0];
    };

    // Optional second-pass GLSL transform. Vulkan installs
    // `vulkanizeGlsl` here so the resulting SPIR-V uses the
    // renderer's multi-set descriptor layout (UBO=set 0,
    // samplers=set 1, storage=set 2). Without that rewrite,
    // glslang assigns everything to `set 0` and the post pipeline's
    // descriptor set layout points at the wrong slots — the
    // shader's `iChannel0` ends up at set 0 binding 0 while the
    // pipeline binds it at set 1 binding 0, sampling returns
    // garbage / zero, output is transparent.
    const glsl: [:0]const u8 = if (opts.rewrite) |f|
        try f(alloc, glsl_raw)
    else
        glsl_raw;

    // Convert to SPIR-V
    const spirv: []const u8 = spirv: {
        var stream: std.Io.Writer.Allocating = .init(alloc);
        var errlog: SpirvLog = .{ .alloc = alloc };
        defer errlog.deinit();
        spirvFromGlsl(&stream.writer, &errlog, glsl) catch |err| {
            if (errlog.info.len > 0 or errlog.debug.len > 0) {
                log.warn("spirv error path={s} info={s} debug={s}", .{
                    path,
                    errlog.info,
                    errlog.debug,
                });
            }

            return err;
        };

        // SpirV pointer must be aligned to 4 bytes since we expect
        // a slice of words.
        var list: std.ArrayListAligned(u8, .of(u32)) = .empty;
        try list.appendSlice(alloc, stream.written());
        break :spirv list.items;
    };

    // Validate the SPIR-V regardless of target. glslang has succeeded
    // at this point but a zero-length output would crash
    // `vkCreateShaderModule` on the Vulkan path AND would make
    // `glslFromSpv` / `mslFromSpv` produce empty/garbage GLSL/MSL
    // with poor diagnostics. Hoist the checks above the switch so
    // every backend gets the same defensive validation.
    if (spirv.len < 4) {
        std.log.warn(
            "shadertoy: empty SPIR-V output (size={})",
            .{spirv.len},
        );
        return error.InvalidShader;
    }
    // First 4 bytes are the SPIR-V magic word 0x07230203
    // (little-endian). Reject anything else loudly.
    const magic = std.mem.readInt(u32, spirv[0..4], .little);
    if (magic != 0x07230203) {
        std.log.warn(
            "shadertoy: SPIR-V output missing magic word " ++
                "(got 0x{x:0>8}, expected 0x07230203)",
            .{magic},
        );
        return error.InvalidShader;
    }

    // Important: using the alloc_gpa here on purpose because this is
    // the final result that will be returned to the caller (the arena
    // gets torn down on function exit).
    return switch (opts.target) {
        .glsl => try glslFromSpv(alloc_gpa, spirv),
        .msl => try mslFromSpv(alloc_gpa, spirv),
        .spv => spv: {
            // Copy the SPIR-V binary out of the arena into a
            // 4-byte-aligned allocation under `alloc_gpa`. Vulkan
            // expects `pCode: []const u32`, so over-aligning is safe;
            // we return as `[]const u8` to share the unified return
            // type with the GLSL/MSL paths.
            const dst = try alloc_gpa.alignedAlloc(u8, .of(u32), spirv.len);
            @memcpy(dst, spirv);
            break :spv dst;
        },
    };
}

/// Convert a ShaderToy shader into valid GLSL.
///
/// ShaderToy shaders aren't full shaders, they're just implementing a
/// mainImage function and don't define any of the uniforms. This function
/// will convert the ShaderToy shader into a valid GLSL shader that can be
/// compiled and linked.
pub fn glslFromShader(
    writer: *std.Io.Writer,
    src: []const u8,
    /// Macros to inject as `#define <body>` lines after the prefix's
    /// `#version` directive (GLSL requires `#version` first, so we
    /// can't simply prepend). Empty for the default OpenGL/MSL paths;
    /// the Vulkan SPV path uses this to flag the prefix's `main()`
    /// to Y-flip `gl_FragCoord`.
    defines: []const []const u8,
) !void {
    const prefix = @embedFile("shaders/shadertoy_prefix.glsl");
    if (defines.len == 0) {
        try writer.writeAll(prefix);
    } else {
        // GLSL requires `#version` to be the first non-blank line,
        // so we can't simply prepend defines. Find the first
        // newline after `#version …` and inject defines on the
        // following line.
        //
        // The prefix is `@embedFile`'d at comptime, so its bytes
        // are known to the compiler — assert it has a newline once
        // here rather than threading branchy fallback paths
        // through the runtime. A future prefix edit that loses its
        // trailing newline will fail at comptime, not silently at
        // runtime.
        comptime {
            if (std.mem.indexOfScalar(u8, prefix, '\n') == null) {
                @compileError(
                    "shadertoy_prefix.glsl must contain at least one newline " ++
                        "for `#define` injection — see glslFromShader",
                );
            }
            if (!std.mem.startsWith(u8, prefix, "#version")) {
                @compileError(
                    "shadertoy_prefix.glsl must start with `#version` " ++
                        "(GLSL spec requirement) — see glslFromShader",
                );
            }
        }
        const first_nl = comptime std.mem.indexOfScalar(u8, prefix, '\n').?;
        try writer.writeAll(prefix[0 .. first_nl + 1]);
        for (defines) |def| {
            try writer.writeAll("#define ");
            try writer.writeAll(def);
            try writer.writeAll("\n");
        }
        try writer.writeAll(prefix[first_nl + 1 ..]);
    }
    try writer.writeAll("\n\n");
    try writer.writeAll(src);
}

/// Process-wide cache of compiled SPIR-V keyed by GLSL source bytes.
/// The C-API glslang path (`Shader.create` / `program.spirvGenerate`)
/// used below pulls allocations from glslang's thread-local
/// TPoolAllocator on every call — pages that are never released
/// because Zig pthreads don't run C++ thread_local destructors. With
/// N tabs each calling `loadFromFiles` → `loadFromFile` →
/// `spirvFromGlsl` for the same custom shader file, that's N
/// renderer threads each leaking a per-thread pool. Caching the SPV
/// bytes lets every call after the first short-circuit without
/// touching glslang.
///
/// Same problem and same fix as the C++ shim's spv_cache in
/// pkg/glslang/override/ghastty_vk_shim.cpp; this one covers the
/// C-API path that the shim doesn't see.
var spv_cache_mutex: std.Thread.Mutex = .{};
var spv_cache: std.StringHashMapUnmanaged([]const u8) = .empty;

/// Convert a GLSL shader into SPIR-V assembly.
pub fn spirvFromGlsl(
    writer: *std.Io.Writer,
    errlog: ?*SpirvLog,
    src: [:0]const u8,
) !void {
    // Cache check. On hit, write the cached SPV to the writer and
    // return without entering glslang. Strict-equality keying on
    // the source bytes (incl. the NUL terminator) — the input is
    // deterministically generated upstream from a stable shader
    // file + a small set of `#define` lines, so identical sources
    // produce identical SPV.
    {
        spv_cache_mutex.lock();
        defer spv_cache_mutex.unlock();
        const key: []const u8 = src[0..src.len];
        if (spv_cache.get(key)) |cached| {
            try writer.writeAll(cached);
            return;
        }
    }

    // So we can run unit tests without fear.
    if (builtin.is_test) try glslang.testing.ensureInit();

    const c = glslang.c;
    const input: c.glslang_input_t = .{
        .language = c.GLSLANG_SOURCE_GLSL,
        .stage = c.GLSLANG_STAGE_FRAGMENT,
        .client = c.GLSLANG_CLIENT_VULKAN,
        .client_version = c.GLSLANG_TARGET_VULKAN_1_2,
        .target_language = c.GLSLANG_TARGET_SPV,
        .target_language_version = c.GLSLANG_TARGET_SPV_1_5,
        .code = src.ptr,
        .default_version = 100,
        .default_profile = c.GLSLANG_NO_PROFILE,
        .force_default_version_and_profile = 0,
        .forward_compatible = 0,
        .messages = c.GLSLANG_MSG_DEFAULT_BIT,
        .resource = c.glslang_default_resource(),
    };

    const shader = try glslang.Shader.create(&input);
    defer shader.delete();

    shader.preprocess(&input) catch |err| {
        if (errlog) |ptr| ptr.fromShader(shader) catch {};
        return err;
    };
    shader.parse(&input) catch |err| {
        if (errlog) |ptr| ptr.fromShader(shader) catch {};
        return err;
    };

    const program = try glslang.Program.create();
    defer program.delete();
    program.addShader(shader);
    program.link(
        c.GLSLANG_MSG_SPV_RULES_BIT |
            c.GLSLANG_MSG_VULKAN_RULES_BIT,
    ) catch |err| {
        if (errlog) |ptr| ptr.fromProgram(program) catch {};
        return err;
    };
    program.spirvGenerate(c.GLSLANG_STAGE_FRAGMENT);
    const size = program.spirvGetSize();
    const ptr = try program.spirvGetPtr();
    const ptr_u8: [*]u8 = @ptrCast(ptr);
    const slice_u8: []u8 = ptr_u8[0 .. size * 4];
    try writer.writeAll(slice_u8);

    // Populate the cache so the next surface's compile of the same
    // source short-circuits. Allocations are process-lifetime
    // (smp_allocator, never freed) — the keys + values are bounded
    // by the number of distinct shaders the user has configured,
    // which is small (typically 1-3); even at 100 KB per shader
    // the total cache cost is negligible against the per-tab pool
    // pages we'd otherwise leak.
    spv_cache_mutex.lock();
    defer spv_cache_mutex.unlock();
    const key: []const u8 = src[0..src.len];
    if (!spv_cache.contains(key)) {
        const key_copy = std.heap.smp_allocator.dupe(u8, key) catch return;
        errdefer std.heap.smp_allocator.free(key_copy);
        const spv_copy = std.heap.smp_allocator.dupe(u8, slice_u8) catch return;
        spv_cache.put(std.heap.smp_allocator, key_copy, spv_copy) catch {
            std.heap.smp_allocator.free(spv_copy);
            return;
        };
    }
}

/// Retrieve errors from spirv compilation.
pub const SpirvLog = struct {
    alloc: Allocator,
    info: [:0]const u8 = "",
    debug: [:0]const u8 = "",

    pub fn deinit(self: *const SpirvLog) void {
        if (self.info.len > 0) self.alloc.free(self.info);
        if (self.debug.len > 0) self.alloc.free(self.debug);
    }

    fn fromShader(self: *SpirvLog, shader: *glslang.Shader) !void {
        const info = try shader.getInfoLog();
        const debug = try shader.getDebugInfoLog();
        self.info = "";
        self.debug = "";
        if (info.len > 0) self.info = try self.alloc.dupeZ(u8, info);
        if (debug.len > 0) self.debug = try self.alloc.dupeZ(u8, debug);
    }

    fn fromProgram(self: *SpirvLog, program: *glslang.Program) !void {
        const info = try program.getInfoLog();
        const debug = try program.getDebugInfoLog();
        self.info = "";
        self.debug = "";
        if (info.len > 0) self.info = try self.alloc.dupeZ(u8, info);
        if (debug.len > 0) self.debug = try self.alloc.dupeZ(u8, debug);
    }
};

/// Convert SPIR-V binary to MSL.
pub fn mslFromSpv(alloc: Allocator, spv: []const u8) ![:0]const u8 {
    const c = spvcross.c;
    return try spvCross(alloc, spvcross.c.SPVC_BACKEND_MSL, spv, (struct {
        fn setOptions(options: c.spvc_compiler_options) error{SpvcFailed}!void {
            // We enable decoration binding, because we need this
            // to properly locate the uniform block to index 1.
            if (c.spvc_compiler_options_set_bool(
                options,
                c.SPVC_COMPILER_OPTION_MSL_ENABLE_DECORATION_BINDING,
                c.SPVC_TRUE,
            ) != c.SPVC_SUCCESS) {
                return error.SpvcFailed;
            }
        }
    }).setOptions);
}

/// Convert SPIR-V binary to GLSL.
pub fn glslFromSpv(alloc: Allocator, spv: []const u8) ![:0]const u8 {
    const GLSL_VERSION = 430;

    const c = spvcross.c;
    return try spvCross(alloc, c.SPVC_BACKEND_GLSL, spv, (struct {
        fn setOptions(options: c.spvc_compiler_options) error{SpvcFailed}!void {
            if (c.spvc_compiler_options_set_uint(
                options,
                c.SPVC_COMPILER_OPTION_GLSL_VERSION,
                GLSL_VERSION,
            ) != c.SPVC_SUCCESS) {
                return error.SpvcFailed;
            }
        }
    }).setOptions);
}

fn spvCross(
    alloc: Allocator,
    backend: spvcross.c.spvc_backend,
    spv: []const u8,
    comptime optionsFn_: ?*const fn (c: spvcross.c.spvc_compiler_options) error{SpvcFailed}!void,
) ![:0]const u8 {
    // Spir-V is always a multiple of 4 because it is written as a series of words
    if (@mod(spv.len, 4) != 0) return error.SpirvInvalid;

    // Compiler context
    const c = spvcross.c;
    var ctx: c.spvc_context = undefined;
    if (c.spvc_context_create(&ctx) != c.SPVC_SUCCESS) return error.SpvcFailed;
    defer c.spvc_context_destroy(ctx);

    // It would be better to get this out into an output parameter to
    // show users but for now we can just log it.
    c.spvc_context_set_error_callback(ctx, @ptrCast(&(struct {
        fn callback(_: ?*anyopaque, msg_ptr: [*c]const u8) callconv(.c) void {
            const msg = std.mem.sliceTo(msg_ptr, 0);
            std.log.warn("spirv-cross error message={s}", .{msg});
        }
    }).callback), null);

    // Parse the Spir-V binary to an IR
    var ir: c.spvc_parsed_ir = undefined;
    if (c.spvc_context_parse_spirv(
        ctx,
        @ptrCast(@alignCast(spv.ptr)),
        spv.len / 4,
        &ir,
    ) != c.SPVC_SUCCESS) {
        return error.SpvcFailed;
    }

    // Build our compiler to GLSL
    var compiler: c.spvc_compiler = undefined;
    if (c.spvc_context_create_compiler(
        ctx,
        backend,
        ir,
        c.SPVC_CAPTURE_MODE_TAKE_OWNERSHIP,
        &compiler,
    ) != c.SPVC_SUCCESS) {
        return error.SpvcFailed;
    }

    // Setup our options if we have any
    if (optionsFn_) |optionsFn| {
        var options: c.spvc_compiler_options = undefined;
        if (c.spvc_compiler_create_compiler_options(compiler, &options) != c.SPVC_SUCCESS) {
            return error.SpvcFailed;
        }

        try optionsFn(options);

        if (c.spvc_compiler_install_compiler_options(compiler, options) != c.SPVC_SUCCESS) {
            return error.SpvcFailed;
        }
    }

    // Compile the resulting string. This string pointer is owned by the
    // context so we don't need to free it.
    var result: [*:0]const u8 = undefined;
    if (c.spvc_compiler_compile(compiler, @ptrCast(&result)) != c.SPVC_SUCCESS) {
        return error.SpvcFailed;
    }

    return try alloc.dupeZ(u8, std.mem.sliceTo(result, 0));
}

/// Convert ShaderToy shader to null-terminated glsl for testing.
fn testGlslZ(alloc: Allocator, src: []const u8) ![:0]const u8 {
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try glslFromShader(&buf.writer, src, &.{});
    return try buf.toOwnedSliceSentinel(0);
}

test "spirv" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const src = try testGlslZ(alloc, test_crt);
    defer alloc.free(src);

    var buf: [4096 * 4]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try spirvFromGlsl(&writer, null, src);
}

test "spirv invalid" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const src = try testGlslZ(alloc, test_invalid);
    defer alloc.free(src);

    var buf: [4096 * 4]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    var errlog: SpirvLog = .{ .alloc = alloc };
    defer errlog.deinit();
    try testing.expectError(error.GlslangFailed, spirvFromGlsl(&writer, &errlog, src));
    try testing.expect(errlog.info.len > 0);
}

test "shadertoy to msl" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const src = try testGlslZ(alloc, test_crt);
    defer alloc.free(src);

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try spirvFromGlsl(&buf.writer, null, src);

    // TODO: Replace this with an aligned version of Writer.Allocating
    var spvlist: std.ArrayListAligned(u8, .of(u32)) = .empty;
    defer spvlist.deinit(alloc);
    try spvlist.appendSlice(alloc, buf.written());

    const msl = try mslFromSpv(alloc, spvlist.items);
    defer alloc.free(msl);
}

test "shadertoy to glsl" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const src = try testGlslZ(alloc, test_crt);
    defer alloc.free(src);

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try spirvFromGlsl(&buf.writer, null, src);

    // TODO: Replace this with an aligned version of Writer.Allocating
    var spvlist: std.ArrayListAligned(u8, .of(u32)) = .empty;
    defer spvlist.deinit(alloc);
    try spvlist.appendSlice(alloc, buf.written());

    const glsl = try glslFromSpv(alloc, spvlist.items);
    defer alloc.free(glsl);

    // log.warn("glsl={s}", .{glsl});
}

const test_crt = @embedFile("shaders/test_shadertoy_crt.glsl");
const test_invalid = @embedFile("shaders/test_shadertoy_invalid.glsl");
