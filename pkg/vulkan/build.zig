const std = @import("std");

pub fn build(b: *std.Build) !void {
    // `addModule` registers "vulkan" on `b`'s module table; consumers
    // (`src/build/SharedDeps.zig`) reach it via
    // `b.lazyDependency("vulkan", ...).module("vulkan")`. No return
    // value or further wiring is needed here — Vulkan headers
    // (`vulkan-headers` package) sit on the default system include
    // path and libvulkan is link-system'd by the top-level build.
    // Same pattern as `pkg/opengl/build.zig`.
    _ = b.addModule("vulkan", .{
        .root_source_file = b.path("main.zig"),
    });
}
