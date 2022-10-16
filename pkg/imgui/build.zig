const std = @import("std");

/// Directories with our includes.
const root = thisDir() ++ "../../../vendor/cimgui/";
pub const include_paths = [_][]const u8{
    root,
    root ++ "imgui",
    root ++ "imgui/backends",
};

pub const pkg = std.build.Pkg{
    .name = "imgui",
    .source = .{ .path = thisDir() ++ "/main.zig" },
};

fn thisDir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}

pub const Options = struct {
    backends: ?[]const []const u8 = null,
};

pub fn link(
    b: *std.build.Builder,
    step: *std.build.LibExeObjStep,
    opt: Options,
) !*std.build.LibExeObjStep {
    const lib = try buildImgui(b, step, opt);
    step.linkLibrary(lib);
    inline for (include_paths) |path| step.addIncludePath(path);
    return lib;
}

pub fn buildImgui(
    b: *std.build.Builder,
    step: *std.build.LibExeObjStep,
    opt: Options,
) !*std.build.LibExeObjStep {
    const target = step.target;
    const lib = b.addStaticLibrary("imgui", null);
    lib.setTarget(step.target);
    lib.setBuildMode(step.build_mode);

    // Include
    inline for (include_paths) |path| lib.addIncludePath(path);

    // Link
    lib.linkLibC();

    // Compile
    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();
    try flags.appendSlice(&.{
        "-DIMGUI_DISABLE_OBSOLETE_FUNCTIONS=1",

        //"-fno-sanitize=undefined",
    });
    switch (target.getOsTag()) {
        .windows => try flags.appendSlice(&.{
            "-DIMGUI_IMPL_API=extern\t\"C\"\t__declspec(dllexport)",
        }),
        else => try flags.appendSlice(&.{
            "-DIMGUI_IMPL_API=extern\t\"C\"\t",
        }),
    }

    // C files
    lib.addCSourceFiles(srcs, flags.items);
    if (opt.backends) |backends| {
        for (backends) |backend| {
            var buf: [4096]u8 = undefined;
            const path = try std.fmt.bufPrint(
                &buf,
                "{s}imgui/backends/imgui_impl_{s}.cpp",
                .{ root, backend },
            );

            lib.addCSourceFile(path, flags.items);
        }
    }

    return lib;
}

const srcs = &.{
    root ++ "cimgui.cpp",
    root ++ "imgui/imgui.cpp",
    root ++ "imgui/imgui_demo.cpp",
    root ++ "imgui/imgui_draw.cpp",
    root ++ "imgui/imgui_tables.cpp",
    root ++ "imgui/imgui_widgets.cpp",
};
