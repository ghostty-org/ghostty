//! The options that are used to configure a renderer.

const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const renderer = @import("../renderer.zig");
const Config = @import("../config.zig").Config;

/// The derived configuration for this renderer implementation.
config: renderer.Renderer.DerivedConfig,

/// The font grid that should be used along with the key for deref-ing.
font_grid: *font.SharedGrid,

/// The size of everything.
size: renderer.Size,

/// The mailbox for sending the surface messages. This is only valid
/// once the thread has started and should not be used outside of the thread.
surface_mailbox: apprt.surface.Mailbox,

/// The apprt surface.
rt_surface: *apprt.Surface,

/// The renderer thread.
thread: *renderer.Thread,
