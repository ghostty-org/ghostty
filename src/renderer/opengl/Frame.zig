//! Wrapper for handling render passes.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const builtin = @import("builtin");
const gl = @import("opengl");

const Renderer = @import("../generic.zig").Renderer(OpenGL);
const OpenGL = @import("../OpenGL.zig");
const Target = @import("Target.zig");
const Pipeline = @import("Pipeline.zig");
const RenderPass = @import("RenderPass.zig");
const Buffer = @import("buffer.zig").Buffer;

const Health = @import("../../renderer.zig").Health;

const log = std.log.scoped(.opengl);

/// Options for beginning a frame.
pub const Options = struct {};

renderer: *Renderer,
target: *Target,

/// Begin encoding a frame.
pub fn begin(
    opts: Options,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Self {
    _ = opts;

    return .{
        .renderer = renderer,
        .target = target,
    };
}

/// Add a render pass to this frame with the provided attachments.
/// Returns a RenderPass which allows render steps to be added.
pub inline fn renderPass(
    self: *const Self,
    attachments: []const RenderPass.Options.Attachment,
) RenderPass {
    _ = self;
    return RenderPass.begin(.{ .attachments = attachments });
}

/// Complete this frame and present the target.
///
/// If `sync` is true, this will block until the frame is presented.
///
/// NOTE: For OpenGL, `sync` is ignored and we always block.
pub fn complete(self: *const Self, sync: bool) void {
    _ = sync;
    gl.finish();

    // If there are any GL errors, consider the frame unhealthy.
    const health: Health = if (gl.errors.getError()) .healthy else |_| .unhealthy;

    // If the frame is healthy, present it.
    if (health == .healthy) {
        self.renderer.api.present(self.target.*) catch |err| {
            log.err("Failed to present render target: err={}", .{err});
        };
    }

    // Report the health to the renderer.
    self.renderer.frameCompleted(health);
}
