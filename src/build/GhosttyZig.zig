//! GhosttyZig generates the Zig modules that Ghostty exports
//! for downstream usage.
const GhosttyZig = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");
const TerminalBuildOptions = @import("../terminal/build_options.zig").Options;

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

    // Use unique module names to avoid collisions with the original target.
    const arch_name = @tagName(target.result.cpu.arch);
    return initInner(
        b,
        retargeted_config,
        retargeted_deps,
        b.fmt("ghostty-vt-{s}", .{arch_name}),
        b.fmt("ghostty-vt-c-{s}", .{arch_name}),
    );
}

fn initInner(
    b: *std.Build,
    cfg: *const Config,
    deps: *const SharedDeps,
    vt_name: []const u8,
    vt_c_name: []const u8,
) !GhosttyZig {
    // Terminal module build options
    var vt_options = cfg.terminalOptions(.lib);
    vt_options.artifact = .lib;
    // We presently don't allow Oniguruma in our Zig module at all.
    // We should expose this as a build option in the future so we can
    // conditionally do this.
    vt_options.oniguruma = false;

    var simd_libs: SharedDeps.LazyPathList = .empty;

    return .{
        .vt = try initVt(
            vt_name,
            b,
            cfg,
            deps,
            vt_options,
            null,
        ),

        .vt_c = try initVt(
            vt_c_name,
            b,
            cfg,
            deps,
            options: {
                var dup = vt_options;
                dup.c_abi = true;
                break :options dup;
            },
            &simd_libs,
        ),

        .version = cfg.lib_version,

        .simd_libs = simd_libs,
    };
}

fn initVt(
    name: []const u8,
    b: *std.Build,
    cfg: *const Config,
    deps: *const SharedDeps,
    vt_options: TerminalBuildOptions,
    simd_libs: ?*SharedDeps.LazyPathList,
) !*std.Build.Module {
    // General build options
    const general_options = b.addOptions();
    try cfg.addOptions(general_options);
    const system_simdutf = cfg.simd and b.systemIntegrationOption("simdutf", .{});

    const vt = b.addModule(name, .{
        .root_source_file = b.path("src/lib_vt.zig"),
        .target = cfg.target,
        .optimize = cfg.optimize,

        // Vendored C++ dependencies are built with no-libcxx and
        // no-libc modes so we don't need libc or libcpp. System-provided
        // simdutf requires both libc and libcpp at runtime.
        //
        // MSVC is an exception: its C and C++ runtimes are tightly
        // coupled, and the vendored C++ objects (simdutf, highway)
        // unconditionally reference MSVC runtime symbols such as
        // __security_cookie, __CxxFrameHandler3, and _purecall.
        .link_libc = if (system_simdutf or cfg.target.result.abi == .msvc) true else false,
        .link_libcpp = libcpp: {
            // MSVC is tightly coupled with the C++ standard library, so we
            // need to link it even if we don't use it directly.
            if (cfg.target.result.abi == .msvc) break :libcpp null;

            // System provided simdutf always requires libcpp because
            // we can't specify the macro required during build to disable
            // it.
            if (system_simdutf) break :libcpp true;

            break :libcpp false;
        },
    });
    vt.addOptions("build_options", general_options);
    vt_options.add(b, vt);

    // We always need unicode tables
    deps.unicode_tables.addModuleImport(vt);

    // We need uucode for grapheme break support
    deps.addUucode(b, vt, cfg.target, cfg.optimize);

    // If SIMD is enabled, add all our SIMD dependencies.
    if (cfg.simd) try SharedDeps.addSimd(
        b,
        vt,
        simd_libs,
        .no_libc,
    );

    return vt;
}
