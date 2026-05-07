const std = @import("std");

pub const Targets = packed struct {
    x11: bool = false,
    wayland: bool = false,
};

/// Returns the targets that GTK4 was compiled with.
pub fn targets(b: *std.Build) Targets {
    // Run pkg-config. We allow it to fail so that zig build --help
    // works without all dependencies. The build will fail later when
    // GTK isn't found anyways.
    var code: u8 = undefined;
    const output = b.runAllowFail(
        &.{ "pkg-config", "--variable=targets", "gtk4" },
        &code,
        .ignore,
    ) catch return .{};

    const x11 = std.mem.indexOf(u8, output, "x11") != null;
    const wayland = std.mem.indexOf(u8, output, "wayland") != null;

    return .{
        .x11 = x11,
        .wayland = wayland,
    };
}

/// Returns the GTK build version.
pub fn gtkVersion(b: *std.Build) std.SemanticVersion {
    const version_string = std.mem.trimEnd(
        u8,
        b.run(&.{ "pkg-config", "--modversion", "gtk4" }),
        "\n",
    );
    return std.SemanticVersion.parse(version_string) catch unreachable;
}

/// Returns the Adwaita build version.
pub fn adwVersion(b: *std.Build) std.SemanticVersion {
    // Note that we need to use sh here instead of just plain pkg-config
    // because libadwaita-1 does not have a semver-conforming version. We could
    // use pure Zig, but cut works just as well and it's in coreutils.
    const version_string = std.mem.trimEnd(
        u8,
        b.run(&.{ "sh", "-c", "pkg-config --modversion libadwaita-1 | cut -f-3 -d." }),
        "\n",
    );
    return std.SemanticVersion.parse(version_string) catch unreachable;
}
