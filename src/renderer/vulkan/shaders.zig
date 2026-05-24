//! GLSL → SPIR-V → `VkShaderModule` pipeline.
//!
//! Approach: runtime compilation. The 10 GLSL sources in
//! `src/renderer/shaders/glsl/` are `@embedFile`'d and compiled via
//! the already-vendored `glslang` package (also used by
//! `shadertoy.zig` for custom user shaders). Compiled SPIR-V is fed
//! into `vkCreateShaderModule` to produce the handles that
//! `Pipeline.zig` will reference.
//!
//! Why not build-time compilation? It would be cleaner (no startup
//! cost, no glslang at runtime in the Vulkan binary) but requires
//! wiring glslang into `build.zig` as a build step, which is a
//! sizable detour. Runtime compilation reuses the existing glslang
//! integration verbatim. The startup cost is ~50ms total across all
//! shaders, acceptable for a terminal that starts rarely. Migrating
//! to build-time SPIR-V is a contained follow-up: swap the
//! `Module.init` call sites for `Module.initFromSpirv` of
//! `@embedFile`'d `.spv` blobs and delete the glslang import here.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const vk = @import("vulkan").c;
const glslang = @import("glslang");

const Device = @import("Device.zig");
const Pipeline = @import("Pipeline.zig");
const math = @import("../../math.zig");

const log = std.log.scoped(.vulkan);

/// Sources for the renderer's built-in shaders. Mirrors the table in
/// `opengl/shaders.zig`. Each entry is `@embedFile`'d so the binary
/// is self-contained.
///
/// Note: `common.glsl` is shared content `#include`'d by the others;
/// it is not a compilation unit and is not listed here. (The other
/// shaders are expected to splice it in via their existing
/// preprocessor pattern, the same way `opengl/shaders.zig` does.)
pub const source = struct {
    // Each source is the file with all `#include "..."` directives
    // expanded at comptime. glslang's preprocessor doesn't handle
    // GLSL includes without `GL_GOOGLE_include_directive`; rather
    // than enable that and provide a callback, we splice the
    // include contents inline — same approach `opengl/shaders.zig`
    // uses via its `loadShaderCode`.
    pub const bg_color_frag = processIncludes(@embedFile("../shaders/glsl/bg_color.f.glsl"));
    pub const bg_image_frag = processIncludes(@embedFile("../shaders/glsl/bg_image.f.glsl"));
    pub const bg_image_vert = processIncludes(@embedFile("../shaders/glsl/bg_image.v.glsl"));
    pub const cell_bg_frag = processIncludes(@embedFile("../shaders/glsl/cell_bg.f.glsl"));
    pub const cell_text_frag = processIncludes(@embedFile("../shaders/glsl/cell_text.f.glsl"));
    pub const cell_text_vert = processIncludes(@embedFile("../shaders/glsl/cell_text.v.glsl"));
    pub const full_screen_vert = processIncludes(@embedFile("../shaders/glsl/full_screen.v.glsl"));
    pub const image_frag = processIncludes(@embedFile("../shaders/glsl/image.f.glsl"));
    pub const image_vert = processIncludes(@embedFile("../shaders/glsl/image.v.glsl"));
};

/// Comptime `#include` preprocessor. Mirrors `opengl/shaders.zig`'s
/// `processIncludes` but specialized to the single `common.glsl`
/// include the renderer's shaders all use (so it doesn't need to
/// take a `basedir` parameter).
fn processIncludes(comptime contents: [:0]const u8) [:0]const u8 {
    @setEvalBranchQuota(100_000);
    var i: usize = 0;
    while (i < contents.len) {
        if (std.mem.startsWith(u8, contents[i..], "#include")) {
            std.debug.assert(std.mem.startsWith(u8, contents[i..], "#include \""));
            const start = i + "#include \"".len;
            const end = std.mem.indexOfScalarPos(u8, contents, start, '"').?;
            return std.fmt.comptimePrint("{s}{s}{s}", .{
                contents[0..i],
                @embedFile("../shaders/glsl/" ++ contents[start..end]),
                processIncludes(contents[end + 1 ..]),
            });
        }
        if (std.mem.indexOfPos(u8, contents, i, "\n#")) |j| {
            i = (j + 1);
        } else {
            break;
        }
    }
    return contents;
}

pub const Stage = enum {
    vertex,
    fragment,

    fn glslangStage(self: Stage) c_uint {
        return switch (self) {
            .vertex => glslang.c.GLSLANG_STAGE_VERTEX,
            .fragment => glslang.c.GLSLANG_STAGE_FRAGMENT,
        };
    }

    fn vkStage(self: Stage) vk.VkShaderStageFlagBits {
        return switch (self) {
            .vertex => vk.VK_SHADER_STAGE_VERTEX_BIT,
            .fragment => vk.VK_SHADER_STAGE_FRAGMENT_BIT,
        };
    }
};

pub const Error = error{
    /// `glslang_shader_preprocess` / `_parse` / `_program_link` /
    /// `_program_SPIRV_generate` failed. Detailed errors are logged
    /// via `std.log.err` with the glslang info / debug strings.
    GlslangFailed,
    /// `vkCreateShaderModule` returned a non-success status.
    VulkanFailed,
} || std.mem.Allocator.Error;

/// Translate OpenGL-flavored GLSL to its Vulkan equivalent in the
/// places glslang doesn't auto-translate. Currently:
///
///   - `gl_VertexID` → `gl_VertexIndex`
///   - `gl_InstanceID` → `gl_InstanceIndex`
///
/// glslang's source/target environment system handles a lot but NOT
/// these builtin renames — they're an OpenGL-vs-Vulkan source-level
/// difference, not a compile flag. Matches what
/// `glslangValidator -V` would require the user to do manually, and
/// what Qt's QShaderBaker users do in their GLSL-flavored sources.
///
/// Caller frees the returned buffer with the same allocator.
fn vulkanizeGlsl(
    alloc: std.mem.Allocator,
    src: []const u8,
) std.mem.Allocator.Error![:0]const u8 {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < src.len) {
        // Find the start of an identifier. Replacements are
        // boundary-aware so `my_gl_VertexID_x` doesn't match.
        const c = src[i];
        const is_ident = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_';

        if (is_ident) {
            // Step past the whole identifier.
            const start = i;
            while (i < src.len) {
                const cc = src[i];
                const cont = (cc >= 'a' and cc <= 'z') or
                    (cc >= 'A' and cc <= 'Z') or
                    (cc >= '0' and cc <= '9') or
                    cc == '_';
                if (!cont) break;
                i += 1;
            }
            const ident = src[start..i];
            if (std.mem.eql(u8, ident, "gl_VertexID")) {
                try out.appendSlice(alloc, "gl_VertexIndex");
            } else if (std.mem.eql(u8, ident, "gl_InstanceID")) {
                try out.appendSlice(alloc, "gl_InstanceIndex");
            } else {
                try out.appendSlice(alloc, ident);
            }
        } else {
            try out.append(alloc, c);
            i += 1;
        }
    }

    return try out.toOwnedSliceSentinel(alloc, 0);
}

/// A compiled `VkShaderModule` plus its stage flag.
pub const Module = struct {
    handle: vk.VkShaderModule,
    stage: vk.VkShaderStageFlagBits,
    device: *const Device,

    /// Compile GLSL → SPIR-V → `VkShaderModule` in a single pass.
    ///
    /// The source is run through `vulkanizeGlsl` to swap OpenGL-only
    /// builtins for their Vulkan equivalents (`gl_VertexID` →
    /// `gl_VertexIndex`, `gl_InstanceID` → `gl_InstanceIndex`); then
    /// the Ghastty Vulkan compile shim
    /// (`pkg/glslang/override/ghastty_vk_shim.cpp`) finishes the job
    /// with auto-map bindings / locations enabled. Same path covers
    /// the renderer's built-in shaders AND user-supplied custom
    /// shaders, so the OpenGL-flavored GLSL Ghostty already speaks
    /// keeps working.
    pub fn init(
        alloc: std.mem.Allocator,
        device: *const Device,
        src: [:0]const u8,
        stage: Stage,
    ) Error!Module {
        // Mirror shadertoy.zig — tests don't call `glslang.init`
        // themselves.
        if (builtin.is_test) glslang.testing.ensureInit() catch {
            return error.GlslangFailed;
        };

        const translated = vulkanizeGlsl(alloc, src) catch {
            return error.GlslangFailed;
        };
        defer alloc.free(translated);

        const c = glslang.c;
        const c_stage: c.ghastty_glslang_stage_t = switch (stage) {
            .vertex => c.GHASTTY_GLSLANG_STAGE_VERTEX,
            .fragment => c.GHASTTY_GLSLANG_STAGE_FRAGMENT,
        };

        var spv_ptr: [*c]u32 = undefined;
        var spv_len: usize = 0;
        var err_ptr: [*c]u8 = undefined;
        const rc = c.ghastty_glslang_compile_vulkan(
            translated.ptr,
            c_stage,
            &spv_ptr,
            &spv_len,
            &err_ptr,
        );
        if (rc != 0) {
            if (err_ptr != null) {
                log.err("ghastty_glslang_compile_vulkan: {s}", .{
                    std.mem.span(@as([*:0]const u8, @ptrCast(err_ptr))),
                });
                c.ghastty_glslang_free_error(err_ptr);
            } else {
                log.err("ghastty_glslang_compile_vulkan: unspecified failure", .{});
            }
            return error.GlslangFailed;
        }
        defer c.ghastty_glslang_free_spirv(spv_ptr);

        const spv: []const u32 = spv_ptr[0..spv_len];
        return try initFromSpirv(device, spv, stage);
    }

    /// Wrap pre-compiled SPIR-V as a `VkShaderModule`. Useful for the
    /// eventual build-time-blob path, and as the lower half of `init`.
    pub fn initFromSpirv(
        device: *const Device,
        spirv: []const u32,
        stage: Stage,
    ) Error!Module {
        const info: vk.VkShaderModuleCreateInfo = .{
            .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = spirv.len * @sizeOf(u32),
            .pCode = spirv.ptr,
        };
        var handle: vk.VkShaderModule = undefined;
        const r = device.dispatch.createShaderModule(
            device.device,
            &info,
            null,
            &handle,
        );
        if (r != vk.VK_SUCCESS) {
            log.err("vkCreateShaderModule failed: result={}", .{r});
            return error.VulkanFailed;
        }
        return .{
            .handle = handle,
            .stage = stage.vkStage(),
            .device = device,
        };
    }

    pub fn deinit(self: Module) void {
        self.device.dispatch.destroyShaderModule(
            self.device.device,
            self.handle,
            null,
        );
    }
};

// ---- shader data types ----------------------------------------------
//
// These mirror the same-named declarations in `opengl/shaders.zig`
// and `metal/shaders.zig`. The structs describe memory layouts the
// GLSL source consumes verbatim — same shader sources are compiled
// for every backend, so the struct layouts must agree.

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

    pub const Bools = packed struct(u32) {
        cursor_wide: bool,
        use_display_p3: bool,
        use_linear_blending: bool,
        use_linear_correction: bool = false,
        _padding: u28 = 0,
    };

    pub const PaddingExtend = packed struct(u32) {
        left: bool = false,
        right: bool = false,
        up: bool = false,
        down: bool = false,
        _padding: u28 = 0,
    };
};

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

pub const CellBg = [4]u8;

pub const Image = extern struct {
    grid_pos: [2]f32 align(8),
    cell_offset: [2]f32 align(8),
    source_rect: [4]f32 align(16),
    dest_size: [2]f32 align(8),
};

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

// ---- Shaders collection ---------------------------------------------

/// Pipeline collection shape (matches `opengl/shaders.zig`). Each
/// field is the Vulkan `Pipeline` instance for that named shader.
pub const PipelineCollection = struct {
    bg_color: Pipeline = undefined,
    cell_bg: Pipeline = undefined,
    cell_text: Pipeline = undefined,
    image: Pipeline = undefined,
    bg_image: Pipeline = undefined,
};

/// Top-level renderer shader state. Same shape as
/// `opengl/shaders.zig`'s `Shaders` so the generic renderer's call
/// sites work without per-backend branching.
///
/// What's wired:
///   - Compiles all 9 built-in GLSL sources at init time via
///     `Module.init` (which runs the glslang shim — same code path
///     user shaders go through). The compiled `VkShaderModule`
///     handles are held in `modules` for the lifetime of the
///     `Shaders` struct.
///
/// What's stubbed:
///   - `pipelines` is still `undefined`. Building real pipelines
///     needs the per-pipeline descriptor-set layout (which depends
///     on what `setAutoMapBindings` picked) and the vertex input
///     description for the instanced pipelines. Constructed in a
///     follow-up commit once the rest of the integration is wired.
pub const Shaders = struct {
    pipelines: PipelineCollection,
    post_pipelines: []const Pipeline,
    modules: Modules,
    defunct: bool = false,

    /// The compiled `VkShaderModule`s for the renderer's built-in
    /// shaders. One entry per source file. Held by `Shaders` so the
    /// (eventual) per-pipeline `Pipeline.init` can reference them
    /// without re-compiling on every assemble.
    pub const Modules = struct {
        bg_color_frag: Module,
        bg_image_frag: Module,
        bg_image_vert: Module,
        cell_bg_frag: Module,
        cell_text_frag: Module,
        cell_text_vert: Module,
        full_screen_vert: Module,
        image_frag: Module,
        image_vert: Module,
    };

    pub fn init(
        alloc: Allocator,
        device: *const @import("Device.zig"),
        post_shaders: []const [:0]const u8,
    ) !Shaders {
        _ = post_shaders;

        // Compile each built-in shader. Errors are fatal — the
        // renderer can't run without these. The `errdefer` chain
        // tears down any successfully-compiled modules if a later
        // one fails so we don't leak `VkShaderModule` handles on
        // partial failure.
        var modules: Modules = undefined;
        modules.bg_color_frag = try Module.init(alloc, device, source.bg_color_frag, .fragment);
        errdefer modules.bg_color_frag.deinit();
        modules.bg_image_frag = try Module.init(alloc, device, source.bg_image_frag, .fragment);
        errdefer modules.bg_image_frag.deinit();
        modules.bg_image_vert = try Module.init(alloc, device, source.bg_image_vert, .vertex);
        errdefer modules.bg_image_vert.deinit();
        modules.cell_bg_frag = try Module.init(alloc, device, source.cell_bg_frag, .fragment);
        errdefer modules.cell_bg_frag.deinit();
        modules.cell_text_frag = try Module.init(alloc, device, source.cell_text_frag, .fragment);
        errdefer modules.cell_text_frag.deinit();
        modules.cell_text_vert = try Module.init(alloc, device, source.cell_text_vert, .vertex);
        errdefer modules.cell_text_vert.deinit();
        modules.full_screen_vert = try Module.init(alloc, device, source.full_screen_vert, .vertex);
        errdefer modules.full_screen_vert.deinit();
        modules.image_frag = try Module.init(alloc, device, source.image_frag, .fragment);
        errdefer modules.image_frag.deinit();
        modules.image_vert = try Module.init(alloc, device, source.image_vert, .vertex);

        return .{
            .pipelines = .{},
            .post_pipelines = &.{},
            .modules = modules,
        };
    }

    pub fn deinit(self: *Shaders, alloc: Allocator) void {
        _ = alloc;
        if (self.defunct) return;
        self.defunct = true;

        // Destroy every compiled module.
        self.modules.bg_color_frag.deinit();
        self.modules.bg_image_frag.deinit();
        self.modules.bg_image_vert.deinit();
        self.modules.cell_bg_frag.deinit();
        self.modules.cell_text_frag.deinit();
        self.modules.cell_text_vert.deinit();
        self.modules.full_screen_vert.deinit();
        self.modules.image_frag.deinit();
        self.modules.image_vert.deinit();

        // No pipeline destruction yet — `init` doesn't construct
        // real pipelines. Real `deinit` will iterate `inline for`
        // over PipelineCollection's fields once those exist.
    }
};

test {
    std.testing.refAllDecls(@This());
}
