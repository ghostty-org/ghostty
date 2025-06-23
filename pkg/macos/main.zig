const builtin = @import("builtin");

pub const carbon = @import("carbon.zig");
pub const foundation = @import("foundation.zig");
pub const animation = @import("animation.zig");
pub const dispatch = @import("dispatch.zig");
pub const graphics = @import("graphics.zig");
pub const os = @import("os.zig");
pub const text = @import("text.zig");
pub const video = @import("video.zig");
pub const iosurface = @import("iosurface.zig");

// All of our C imports consolidated into one place. We used to
// import them one by one in each package but Zig 0.14 has some
// kind of issue with that I wasn't able to minimize.
pub const c = @cImport({
    @cInclude("CoreFoundation/CoreFoundation.h");
    @cInclude("CoreGraphics/CoreGraphics.h");
    @cInclude("CoreText/CoreText.h");
    @cInclude("CoreVideo/CoreVideo.h");
    @cInclude("CoreVideo/CVPixelBuffer.h");
    @cInclude("QuartzCore/CALayer.h");
    @cInclude("IOSurface/IOSurfaceRef.h");
    @cInclude("dispatch/dispatch.h");
    @cInclude("os/log.h");

    if (builtin.os.tag == .macos) {
        @cInclude("Carbon/Carbon.h");
    }
});

test {
    @import("std").testing.refAllDecls(@This());
}
