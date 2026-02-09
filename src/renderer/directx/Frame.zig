//! Frame context for Direct3D 11 rendering.
const Self = @This();

const std = @import("std");

const Renderer = @import("../generic.zig").Renderer(DirectX);
const DirectX = @import("../DirectX.zig");
const Target = @import("Target.zig");
const RenderPass = @import("RenderPass.zig");

const Health = @import("../../renderer.zig").Health;

const log = std.log.scoped(.directx);

pub const Options = struct {};

renderer: *Renderer,
target: *Target,

pub fn begin(
    opts: Options,
    renderer: *Renderer,
    target: *Target,
) !Self {
    _ = opts;

    return .{
        .renderer = renderer,
        .target = target,
    };
}

pub inline fn renderPass(
    self: *const Self,
    attachments: []const RenderPass.Options.Attachment,
) RenderPass {
    return RenderPass.begin(self.renderer.api.context, .{ .attachments = attachments });
}

pub fn complete(self: *const Self, sync: bool) void {
    _ = sync;

    // Flush all pending GPU commands before presenting.
    // This is the D3D11 equivalent of OpenGL's gl.finish() which
    // ensures all rendering is complete before we copy to the swap chain.
    self.renderer.api.context.Flush();

    const health: Health = .healthy;

    if (health == .healthy) {
        self.renderer.api.present(self.target.*) catch |err| {
            log.err("Failed to present render target: err={}", .{err});
        };
    }

    self.renderer.frameCompleted(health);
}
