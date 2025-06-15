const std = @import("std");
const apple_sdk = @import("apple_sdk");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("glfw", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = try buildLib(b, module, .{
        .target = target,
        .optimize = optimize,
    });

    const test_exe: ?*std.Build.Step.Compile = if (target.query.isNative()) exe: {
        const exe = b.addTest(.{
            .name = "test",
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        });
        if (target.result.os.tag.isDarwin()) {
            try apple_sdk.addPaths(b, exe);
        }

        const tests_run = b.addRunArtifact(exe);
        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&tests_run.step);

        // Uncomment this if we're debugging tests
        b.installArtifact(exe);

        break :exe exe;
    } else null;

    if (b.systemIntegrationOption("glfw3", .{})) {
        module.linkSystemLibrary("glfw3", dynamic_link_opts);
        if (test_exe) |exe| exe.linkSystemLibrary2("glfw3", dynamic_link_opts);
    } else {
        module.linkLibrary(lib);
        b.installArtifact(lib);
        if (test_exe) |exe| exe.linkLibrary(lib);
    }
}

fn buildLib(
    b: *std.Build,
    module: *std.Build.Module,
    options: anytype,
) !*std.Build.Step.Compile {
    const target = options.target;
    const optimize = options.optimize;

    const use_x11 = b.option(
        bool,
        "x11",
        "Build with X11. Only useful on Linux",
    ) orelse true;
    const use_wl = b.option(
        bool,
        "wayland",
        "Build with Wayland. Only useful on Linux",
    ) orelse true;

    const use_opengl = b.option(
        bool,
        "opengl",
        "Build with OpenGL; deprecated on MacOS",
    ) orelse false;
    const use_gles = b.option(
        bool,
        "gles",
        "Build with GLES; not supported on MacOS",
    ) orelse false;
    const use_metal = b.option(
        bool,
        "metal",
        "Build with Metal; only supported on MacOS",
    ) orelse true;

    const lib = b.addStaticLibrary(.{
        .name = "glfw",
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibC();

    const upstream = b.lazyDependency("glfw", .{}) orelse return lib;
    lib.addIncludePath(upstream.path("include"));
    module.addIncludePath(upstream.path("include"));
    lib.installHeadersDirectory(upstream.path("include/GLFW"), "GLFW", .{});

    switch (target.result.os.tag) {
        .windows => {
            lib.linkSystemLibrary("gdi32");
            lib.linkSystemLibrary("user32");
            lib.linkSystemLibrary("shell32");

            if (use_opengl) {
                lib.linkSystemLibrary("opengl32");
            }

            if (use_gles) {
                lib.linkSystemLibrary("GLESv3");
            }

            const flags = [_][]const u8{"-D_GLFW_WIN32"};
            lib.addCSourceFiles(.{
                .root = upstream.path(""),
                .files = &base_sources,
                .flags = &flags,
            });
            lib.addCSourceFiles(.{
                .root = upstream.path(""),
                .files = &windows_sources,
                .flags = &flags,
            });
        },

        .macos => {
            try apple_sdk.addPaths(b, lib);

            // Transitive dependencies, explicit linkage of these works around
            // ziglang/zig#17130
            lib.linkFramework("CFNetwork");
            lib.linkFramework("ApplicationServices");
            lib.linkFramework("ColorSync");
            lib.linkFramework("CoreText");
            lib.linkFramework("ImageIO");

            // Direct dependencies
            lib.linkSystemLibrary("objc");
            lib.linkFramework("IOKit");
            lib.linkFramework("CoreFoundation");
            lib.linkFramework("AppKit");
            lib.linkFramework("CoreServices");
            lib.linkFramework("CoreGraphics");
            lib.linkFramework("Foundation");

            if (use_metal) {
                lib.linkFramework("Metal");
            }

            if (use_opengl) {
                lib.linkFramework("OpenGL");
            }

            const flags = [_][]const u8{"-D_GLFW_COCOA"};
            lib.addCSourceFiles(.{
                .root = upstream.path(""),
                .files = &base_sources,
                .flags = &flags,
            });
            lib.addCSourceFiles(.{
                .root = upstream.path(""),
                .files = &macos_sources,
                .flags = &flags,
            });
        },

        // everything that isn't windows or mac is linux :P
        else => {
            var sources = std.BoundedArray([]const u8, 64).init(0) catch unreachable;
            var flags = std.BoundedArray([]const u8, 16).init(0) catch unreachable;

            sources.appendSlice(&base_sources) catch unreachable;
            sources.appendSlice(&linux_sources) catch unreachable;

            if (use_x11) {
                lib.linkSystemLibrary2("X11", dynamic_link_opts);
                lib.linkSystemLibrary2("xkbcommon", dynamic_link_opts);
                sources.appendSlice(&linux_x11_sources) catch unreachable;
                flags.append("-D_GLFW_X11") catch unreachable;
            }

            if (use_wl) {
                lib.linkSystemLibrary2("wayland-client", dynamic_link_opts);

                lib.root_module.addCMacro("WL_MARSHAL_FLAG_DESTROY", "1");
                lib.addIncludePath(b.path("wayland-headers"));

                sources.appendSlice(&linux_wl_sources) catch unreachable;
                flags.append("-D_GLFW_WAYLAND") catch unreachable;
                flags.append("-Wno-implicit-function-declaration") catch unreachable;
            }

            lib.addCSourceFiles(.{
                .root = upstream.path(""),
                .files = sources.slice(),
                .flags = flags.slice(),
            });
        },
    }

    return lib;
}

// For dynamic linking, we prefer dynamic linking and to search by
// mode first. Mode first will search all paths for a dynamic library
// before falling back to static.
const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
    .preferred_link_mode = .dynamic,
    .search_strategy = .mode_first,
};

const base_sources = [_][]const u8{
    "src/context.c",
    "src/egl_context.c",
    "src/init.c",
    "src/input.c",
    "src/monitor.c",
    "src/null_init.c",
    "src/null_joystick.c",
    "src/null_monitor.c",
    "src/null_window.c",
    "src/osmesa_context.c",
    "src/platform.c",
    "src/vulkan.c",
    "src/window.c",
};

const linux_sources = [_][]const u8{
    "src/linux_joystick.c",
    "src/posix_module.c",
    "src/posix_poll.c",
    "src/posix_thread.c",
    "src/posix_time.c",
    "src/xkb_unicode.c",
};

const linux_wl_sources = [_][]const u8{
    "src/wl_init.c",
    "src/wl_monitor.c",
    "src/wl_window.c",
};

const linux_x11_sources = [_][]const u8{
    "src/glx_context.c",
    "src/x11_init.c",
    "src/x11_monitor.c",
    "src/x11_window.c",
};

const windows_sources = [_][]const u8{
    "src/wgl_context.c",
    "src/win32_init.c",
    "src/win32_joystick.c",
    "src/win32_module.c",
    "src/win32_monitor.c",
    "src/win32_thread.c",
    "src/win32_time.c",
    "src/win32_window.c",
};

const macos_sources = [_][]const u8{
    // C sources
    "src/cocoa_time.c",
    "src/posix_module.c",
    "src/posix_thread.c",

    // ObjC sources
    "src/cocoa_init.m",
    "src/cocoa_joystick.m",
    "src/cocoa_monitor.m",
    "src/cocoa_window.m",
    "src/nsgl_context.m",
};
