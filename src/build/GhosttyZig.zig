//! GhosttyZig generates the Zig modules that Ghostty exports
//! for downstream usage.
const GhosttyZig = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");
const TerminalBuildOptions = @import("../terminal/build_options.zig").Options;
const translate_c = @import("translate_c");

/// The `_c`-suffixed modules are built with the C ABI enabled.
vt: *std.Build.Module,
vt_c: *std.Build.Module,

/// The libghostty-vt version
version: std.SemanticVersion,

/// Static library paths for vendored SIMD dependencies. Populated
/// only when the dependencies are built from source (not provided
/// by the system via -Dsystem-integration). Used to produce a
/// combined static archive for downstream consumers.
simd_libs: SharedDeps.LazyPathList,

pub fn init(
    b: *std.Build,
    cfg: *const Config,
    deps: *const SharedDeps,
) !GhosttyZig {
    return initInner(b, cfg, deps, "ghostty-vt", "ghostty-vt-c");
}

/// Create a new GhosttyZig with modules retargeted to a different
/// architecture. Used to produce universal (fat) binaries on macOS.
pub fn retarget(
    self: *const GhosttyZig,
    b: *std.Build,
    cfg: *const Config,
    deps: *const SharedDeps,
    target: std.Build.ResolvedTarget,
) !GhosttyZig {
    _ = self;
    const retargeted_config = try b.allocator.create(Config);
    retargeted_config.* = cfg.*;
    retargeted_config.target = target;

    const retargeted_deps = try b.allocator.create(SharedDeps);
    retargeted_deps.* = try deps.retarget(b, target);

    return initInner(
        b,
        retargeted_config,
        retargeted_deps,
        null,
        null,
    );
}

fn initInner(
    b: *std.Build,
    cfg: *const Config,
    deps: *const SharedDeps,
    vt_name: ?[]const u8,
    vt_c_name: ?[]const u8,
) !GhosttyZig {
    const vt_options = vtOptions(cfg);
    var simd_libs: SharedDeps.LazyPathList = .empty;

    const vt_c = try initVt(
        vt_c_name,
        b,
        cfg,
        deps,
        vtCOptions(cfg),
        &simd_libs,
    );

    // Every libghostty-vt artifact (shared, static, wasm and each
    // xcframework slice) is built from the C ABI module, so setting
    // -Dstrip here covers all of them. The Zig module is left alone.
    // It is compiled into whatever program imports it, and that
    // program's own build decides whether to strip.
    vt_c.strip = cfg.strip_lib_vt;

    return .{
        .vt = try initVt(
            vt_name,
            b,
            cfg,
            deps,
            vt_options,
            null,
        ),

        .vt_c = vt_c,

        .version = cfg.lib_version,

        .simd_libs = simd_libs,
    };
}

/// Create the root module for the libghostty-vt C API tests.
///
/// This is the `vt_c` module with one addition: the C headers, translated
/// into Zig and importable as `ghostty/vt.h`. The header parity tests in
/// `src/terminal/c/abi_test.zig` use that import to compare every public C
/// type against its Zig implementation.
///
/// It is a separate module so the library itself never pays for the
/// translation. Only the test step builds it:
///
/// ```zig
/// const test_exe = b.addTest(.{
///     .name = "ghostty-vt-c-test",
///     .root_module = try GhosttyZig.initVtCTest(b, &config, &deps),
/// });
/// ```
pub fn initVtCTest(
    b: *std.Build,
    cfg: *const Config,
    deps: *const SharedDeps,
) !*std.Build.Module {
    const mod = try initVt(null, b, cfg, deps, vtCOptions(cfg), null);
    try translate_c.addImportToModule(b, "ghostty/vt.h", mod, .{
        .source = .{ .includes = .{ .files = &.{
            .{ .path = "ghostty/vt.h" },
        } } },
        .target = cfg.target,
        .optimize = cfg.optimize,
        // Link libc only if the module already does. The headers need
        // nothing beyond stdint.h, stddef.h and stdbool.h, which the
        // compiler provides. Turning libc on would also change the module
        // itself. On wasm32-wasi, for example, it switches `std.posix` to
        // the libc definitions and breaks the build.
        .link_libc = mod.link_libc orelse false,
        .system_include_paths = &.{b.path("include")},
    });
    return mod;
}

/// The terminal build options shared by every libghostty-vt module.
fn vtOptions(cfg: *const Config) TerminalBuildOptions {
    var vt_options = cfg.terminalOptions(.lib, cfg.optimize);
    vt_options.artifact = .lib;
    // We presently don't allow Oniguruma in our Zig module at all.
    // We should expose this as a build option in the future so we can
    // conditionally do this.
    vt_options.oniguruma = false;
    return vt_options;
}

/// `vtOptions` with the C ABI enabled, for the `_c` modules.
fn vtCOptions(cfg: *const Config) TerminalBuildOptions {
    var vt_options = vtOptions(cfg);
    vt_options.c_abi = true;
    return vt_options;
}

fn initVt(
    name: ?[]const u8,
    b: *std.Build,
    cfg: *const Config,
    deps: *const SharedDeps,
    vt_options: TerminalBuildOptions,
    simd_libs: ?*SharedDeps.LazyPathList,
) !*std.Build.Module {
    // General build options
    const general_options = b.addOptions();
    try cfg.addOptions(general_options);

    const options: std.Build.Module.CreateOptions = .{
        .root_source_file = b.path("src/lib_vt.zig"),
        .target = cfg.target,
        .optimize = cfg.optimize,

        // SIMD requires libc. Vendored C++ dependencies are built with
        // no-libcxx mode (HWY_NO_LIBCXX / SIMDUTF_NO_LIBCXX) so we
        // don't need libcpp. System-provided simdutf headers still
        // use C++ stdlib headers, so we need libcpp in that case.
        .link_libc = if (cfg.simd) true else null,
        .link_libcpp = if (cfg.simd and
            b.systemIntegrationOption("simdutf", .{}) and
            cfg.target.result.abi != .msvc) true else null,
    };
    const vt = if (name) |module_name|
        b.addModule(module_name, options)
    else
        b.createModule(options);
    vt.addOptions("build_options", general_options);
    vt_options.add(b, vt);

    // We always need unicode tables
    deps.unicode_tables.addModuleImport(vt);

    // We need uucode for grapheme break support
    vt.addImport("uucode", deps.uucode_mod);

    // We need wuffs for Kitty graphics pixel operations (format
    // conversion and alpha blending). Unlike pure Zig dependencies
    // its C code is compiled whenever the module is in the build
    // graph regardless of analysis, so only wire it in when Kitty
    // graphics is actually enabled.
    if (vt_options.kittyGraphics(cfg.target.result)) {
        if (b.lazyDependency("wuffs", .{
            .target = cfg.target,
            .optimize = cfg.optimize,
        })) |dep| {
            vt.addImport("wuffs", dep.module("wuffs"));
        }
    }

    // If SIMD is enabled, add all our SIMD dependencies.
    if (cfg.simd) {
        try SharedDeps.addSimd(b, vt, simd_libs);
    }

    return vt;
}
