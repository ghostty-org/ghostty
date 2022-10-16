const std = @import("std");
const Allocator = std.mem.Allocator;

/// A bitmask for all key modifiers. This is taken directly from the
/// GLFW representation, but we use this generically.
pub const Mods = packed struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    _padding: u2 = 0,
};

/// The set of keys that can map to keybindings. These have no fixed enum
/// values because we map platform-specific keys to this set. Note that
/// this only needs to accomodate what maps to a key. If a key is not bound
/// to anything and the key can be mapped to a printable character, then that
/// unicode character is sent directly to the pty.
pub const Key = enum {
    invalid,

    // a-z
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,

    // other
    grave_accent, // `

    // control
    up,
    down,
    right,
    left,
    home,
    end,
    page_up,
    page_down,

    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,

    // To support more keys (there are obviously more!) add them here
    // and ensure the mapping is up to date in the Window key handler.
};
