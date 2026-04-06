//! Wrapper for handling render passes.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");
const apprt = @import("../../apprt.zig");

const Renderer = @import("../generic.zig").Renderer(OpenGL);
const OpenGL = @import("../OpenGL.zig");
const Target = @import("Target.zig");
const RenderPass = @import("RenderPass.zig");

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
    const health: Health = health: {
        if (apprt.runtime == apprt.win32) {
            log.warn("opengl frame complete: win32 preview skipping gl.finish", .{});
            break :health .healthy;
        }

        log.info("opengl frame complete: gl.finish begin", .{});
        gl.finish();
        log.info("opengl frame complete: gl.finish end", .{});

        // If there are any GL errors, consider the frame unhealthy.
        break :health if (gl.errors.getError()) .healthy else |_| .unhealthy;
    };
    log.info("opengl frame complete: health={}", .{health});

    // If the frame is healthy, present it.
    if (health == .healthy) {
        log.info("opengl frame complete: present begin", .{});
        self.renderer.api.present(self.target.*) catch |err| {
            log.err("Failed to present render target: err={}", .{err});
        };
        log.info("opengl frame complete: present end", .{});
    }

    // Report the health to the renderer.
    log.info("opengl frame complete: frameCompleted", .{});
    self.renderer.frameCompleted(health);
}
