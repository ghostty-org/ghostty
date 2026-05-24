const std = @import("std");

pub fn build(b: *std.Build) !void {
    const module = b.addModule("vulkan", .{
        .root_source_file = b.path("main.zig"),
    });

    // The Vulkan headers (`vulkan-headers` package on every standard
    // Linux distro) live on the default system include path. Consumers
    // link libvulkan from the top-level build (see
    // `src/build/SharedDeps.zig`) — this package only owns the binding
    // surface, mirroring `pkg/opengl/`.
    _ = module;
}
