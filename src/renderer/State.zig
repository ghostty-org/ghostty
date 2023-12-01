//! This is the render state that is given to a renderer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Inspector = @import("../inspector/main.zig").Inspector;
const terminal = @import("../terminal/main.zig");
const renderer = @import("../renderer.zig");

/// The mutex that must be held while reading any of the data in the
/// members of this state. Note that the state itself is NOT protected
/// by the mutex and is NOT thread-safe, only the members values of the
/// state (i.e. the terminal, devmode, etc. values).
mutex: *std.Thread.Mutex,

/// The terminal data.
terminal: *terminal.Terminal,

/// The terminal inspector, if any. This will be null while the inspector
/// is not active and will be set when it is active.
inspector: ?*Inspector = null,

/// Dead key state. This will render the current dead key preedit text
/// over the cursor. This currently only ever renders a single codepoint.
/// Preedit can in theory be multiple codepoints long but that is left as
/// a future exercise.
preedit: ?Preedit = null,

/// Mouse state. This only contains state relevant to what renderers
/// need about the mouse.
mouse: Mouse = .{},

pub const Mouse = struct {
    /// The point on the viewport where the mouse currently is. We use
    /// viewport points to avoid the complexity of mapping the mouse to
    /// the renderer state.
    point: ?terminal.point.Viewport = null,
};

/// The pre-edit state. See Surface.preeditCallback for more information.
pub const Preedit = struct {
    /// The codepoints to render as preedit text. We allow up to 16 codepoints
    /// as a sort of arbitrary limit. If we experience a realisitic use case
    /// where we need more please open an issue.
    codepoints: [16]Codepoint = undefined,
    len: u8 = 0,

    /// A single codepoint to render as preedit text.
    pub const Codepoint = struct {
        codepoint: u21,
        wide: bool = false,
    };

    /// The width in cells of all codepoints in the preedit.
    pub fn width(self: *const Preedit) usize {
        var result: usize = 0;
        for (self.codepoints[0..self.len]) |cp| {
            result += if (cp.wide) 2 else 1;
        }

        return result;
    }

    pub fn range(self: *const Preedit, start: usize, max: usize) [2]usize {
        // If our preedit goes off the end of the screen, we adjust it so
        // that it shifts left.
        const end = start + self.width();
        const offset = if (end > max) end - max else 0;
        return .{ start -| offset, end -| offset };
    }
};
