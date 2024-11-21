const Ghostty = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");

/// The primary Ghostty executable.
exe: *std.Build.Step.Compile,

/// The install step for the executable.
install_step: *std.Build.Step.InstallArtifact,

pub fn init(b: *std.Build, cfg: *const Config, deps: *const SharedDeps) !Ghostty {
    // Build our Wasm target.
    const wasm_crosstarget: std.Target.Query = .{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_model = .{ .explicit = &std.Target.wasm.cpu.mvp },
        .cpu_features_add = std.Target.wasm.featureSet(&.{
            // We use this to explicitly request shared memory.
            .atomics,

            // Not explicitly used but compiler could use them if they want.
            .bulk_memory,
            .reference_types,
            .sign_ext,
        }),
    };

    // Whether we're using wasm shared memory. Some behaviors change.
    // For now we require this but I wanted to make the code handle both
    // up front.
    const wasm_shared: bool = true;

    const wasm = b.addExecutable(.{
        .name = "ghostty-wasm",
        .root_source_file = b.path("src/main_wasm.zig"),
        .target = b.resolveTargetQuery(wasm_crosstarget),
        .optimize = cfg.optimize,
    });

    // So that we can use web workers with our wasm binary
    wasm.import_memory = true;
    wasm.initial_memory = 65536 * 512;
    wasm.entry = .disabled;
    // wasm.wasi_exec_model = .reactor;
    wasm.rdynamic = true;
    wasm.max_memory = 65536 * 65536; // Maximum number of pages in wasm32
    wasm.shared_memory = wasm_shared;

    // Stack protector adds extern requirements that we don't satisfy.
    wasm.root_module.stack_protector = false;

    // Add the shared dependencies
    _ = try deps.addWasm(wasm);

    // Install
    const wasm_install = b.addInstallArtifact(wasm, .{});
    const install = b.addInstallFile(wasm.getEmittedBin(), "../example/ghostty-wasm.wasm");
    wasm_install.step.dependOn(&install.step);

    const step = b.step("wasm", "Build the wasm library");
    step.dependOn(&install.step);

    const test_step = b.step("test-wasm", "Run all tests for wasm");
    const main_test = b.addTest(.{
        .name = "wasm-test",
        .root_source_file = b.path("src/main_wasm.zig"),
        .target = b.resolveTargetQuery(wasm_crosstarget),
    });

    _ = try deps.addWasm(main_test);
    test_step.dependOn(&main_test.step);

    return .{
        .exe = wasm,
        .install_step = wasm_install,
    };
}
