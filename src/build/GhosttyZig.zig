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

pub fn init(
    b: *std.Build,
    cfg: *const Config,
    deps: *const SharedDeps,
) !GhosttyZig {
    // Terminal module build options
    var vt_options = cfg.terminalOptions();
    vt_options.artifact = .lib;
    // We presently don't allow Oniguruma in our Zig module at all.
    // We should expose this as a build option in the future so we can
    // conditionally do this.
    vt_options.oniguruma = false;

    return .{
        .vt = try initVt(
            "ghostty-vt",
            b,
            cfg,
            deps,
            vt_options,
        ),

        .vt_c = try initVt(
            "ghostty-vt-c",
            b,
            cfg,
            deps,
            options: {
                var dup = vt_options;
                dup.c_abi = true;
                break :options dup;
            },
        ),
    };
}

fn initVt(
    name: []const u8,
    b: *std.Build,
    cfg: *const Config,
    deps: *const SharedDeps,
    vt_options: TerminalBuildOptions,
) !*std.Build.Module {
    // General build options
    const general_options = b.addOptions();
    try cfg.addOptions(general_options);

    const vt = b.addModule(name, .{
        .root_source_file = b.path("src/lib_vt.zig"),
        .target = cfg.target,
        .optimize = cfg.optimize,

        // SIMD require libc/libcpp (both) but otherwise we don't care.
        .link_libc = if (cfg.simd) true else null,
        .link_libcpp = if (cfg.simd) true else null,
    });
    vt.addOptions("build_options", general_options);
    vt_options.add(b, vt);

    // We always need unicode tables
    deps.unicode_tables.addModuleImport(vt);

    // If SIMD is enabled, add all our SIMD dependencies.
    if (cfg.simd) {
        try SharedDeps.addSimd(b, vt, null);
    }

    return vt;
}
