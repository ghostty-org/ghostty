const std = @import("std");
const windows_shell = @import("../config/windows_shell.zig");

/// Pack r/g/b bytes into a Win32 COLORREF (0x00BBGGRR).
pub fn rgb(r: u8, g: u8, b: u8) u32 {
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16);
}

// ── Overlay mode ────────────────────────────────────────────────────────

pub const HostOverlayMode = enum {
    none,
    command_palette,
    profile,
    search,
    surface_title,
    tab_title,
    tab_overview,
};

// ── Structs ─────────────────────────────────────────────────────────────

pub const ButtonColors = struct {
    bg: u32,
    border: u32,
    fg: u32,
};

pub const ThemeColors = struct {
    // Chrome surfaces
    chrome_bg: u32,
    chrome_border: u32,
    overlay_bg: u32,
    overlay_border: u32,
    edit_bg: u32,
    edit_frame_bg: u32,
    status_bg: u32,
    inspector_bg: u32,

    // Text
    text_primary: u32,
    text_secondary: u32,
    text_disabled: u32,
    edit_fg: u32,
    overlay_label_fg: u32,
    info_fg: u32,
    error_fg: u32,

    // Accent
    accent: u32,
    accent_hover: u32,
    chrome_accent_idle: u32,
    edit_border_unfocused: u32,

    // Buttons - idle
    button_bg: u32,
    button_border: u32,
    button_fg: u32,

    // Buttons - overlay variant
    button_overlay_bg: u32,
    button_overlay_border: u32,
    button_overlay_fg: u32,
    button_chrome_fg: u32,

    // Buttons - active
    button_active_bg: u32,
    button_active_border: u32,
    button_active_fg: u32,

    // Buttons - accept
    button_accept_bg: u32,
    button_accept_border: u32,
    button_accept_fg: u32,

    // Buttons - disabled
    button_disabled_bg: u32,
    button_disabled_border: u32,
    button_disabled_fg: u32,

    // Focus rings
    button_focus_ring: u32,
    button_overlay_focus_ring: u32,
    button_active_focus_ring: u32,
    button_accept_focus_ring: u32,

    // Pane dividers
    pane_divider: u32,
    pane_divider_focused: u32,

    // Whether this is a dark theme (for DWM)
    is_dark: bool,
};

pub const ProfileChromeAccent = struct {
    idle_bg: u32,
    idle_border: u32,
    hover_bg: u32,
    hover_border: u32,
    pressed_bg: u32,
    active_bg: u32,
    active_border: u32,
    focus: u32,
};

// ── Theme palettes ──────────────────────────────────────────────────────

pub fn darkTheme() ThemeColors {
    return .{
        .chrome_bg = rgb(32, 32, 32),
        .chrome_border = rgb(48, 48, 48),
        .overlay_bg = rgb(26, 26, 28),
        .overlay_border = rgb(48, 48, 48),
        .edit_bg = rgb(20, 20, 22),
        .edit_frame_bg = rgb(18, 18, 20),
        .status_bg = rgb(26, 26, 28),
        .inspector_bg = rgb(22, 22, 24),

        .text_primary = rgb(220, 220, 224),
        .text_secondary = rgb(158, 158, 164),
        .text_disabled = rgb(110, 110, 116),
        .edit_fg = rgb(234, 234, 238),
        .overlay_label_fg = rgb(210, 228, 255),
        .info_fg = rgb(142, 197, 255),
        .error_fg = rgb(255, 132, 132),

        .accent = rgb(116, 156, 224),
        .accent_hover = rgb(132, 172, 238),
        .chrome_accent_idle = rgb(62, 62, 62),
        .edit_border_unfocused = rgb(72, 72, 72),

        .button_bg = rgb(38, 38, 38),
        .button_border = rgb(58, 58, 58),
        .button_fg = rgb(200, 200, 200),

        .button_overlay_bg = rgb(36, 36, 38),
        .button_overlay_border = rgb(68, 68, 72),
        .button_overlay_fg = rgb(224, 224, 228),
        .button_chrome_fg = rgb(190, 190, 194),

        .button_active_bg = rgb(50, 60, 82),
        .button_active_border = rgb(116, 156, 224),
        .button_active_fg = rgb(244, 247, 252),

        .button_accept_bg = rgb(52, 92, 166),
        .button_accept_border = rgb(126, 169, 247),
        .button_accept_fg = rgb(248, 250, 255),

        .button_disabled_bg = rgb(28, 28, 30),
        .button_disabled_border = rgb(48, 48, 50),
        .button_disabled_fg = rgb(110, 110, 114),

        .button_focus_ring = rgb(140, 166, 208),
        .button_overlay_focus_ring = rgb(160, 190, 238),
        .button_active_focus_ring = rgb(172, 206, 255),
        .button_accept_focus_ring = rgb(184, 212, 255),

        .pane_divider = rgb(58, 58, 58),
        .pane_divider_focused = rgb(116, 156, 224),

        .is_dark = true,
    };
}

pub fn lightTheme() ThemeColors {
    return .{
        .chrome_bg = rgb(243, 243, 243),
        .chrome_border = rgb(209, 209, 209),
        .overlay_bg = rgb(249, 249, 249),
        .overlay_border = rgb(220, 220, 220),
        .edit_bg = rgb(255, 255, 255),
        .edit_frame_bg = rgb(245, 245, 245),
        .status_bg = rgb(238, 238, 238),
        .inspector_bg = rgb(235, 235, 235),

        .text_primary = rgb(27, 27, 27),
        .text_secondary = rgb(96, 96, 96),
        .text_disabled = rgb(160, 160, 160),
        .edit_fg = rgb(27, 27, 27),
        .overlay_label_fg = rgb(0, 60, 116),
        .info_fg = rgb(0, 95, 184),
        .error_fg = rgb(196, 43, 28),

        .accent = rgb(0, 120, 212),
        .accent_hover = rgb(0, 99, 177),
        .chrome_accent_idle = rgb(180, 180, 180),
        .edit_border_unfocused = rgb(160, 160, 160),

        .button_bg = rgb(251, 251, 251),
        .button_border = rgb(209, 209, 209),
        .button_fg = rgb(27, 27, 27),

        .button_overlay_bg = rgb(245, 245, 245),
        .button_overlay_border = rgb(180, 180, 180),
        .button_overlay_fg = rgb(27, 27, 27),
        .button_chrome_fg = rgb(96, 96, 96),

        .button_active_bg = rgb(204, 228, 247),
        .button_active_border = rgb(0, 120, 212),
        .button_active_fg = rgb(0, 60, 116),

        .button_accept_bg = rgb(0, 120, 212),
        .button_accept_border = rgb(0, 99, 177),
        .button_accept_fg = rgb(255, 255, 255),

        .button_disabled_bg = rgb(243, 243, 243),
        .button_disabled_border = rgb(209, 209, 209),
        .button_disabled_fg = rgb(160, 160, 160),

        .button_focus_ring = rgb(0, 120, 212),
        .button_overlay_focus_ring = rgb(0, 120, 212),
        .button_active_focus_ring = rgb(0, 90, 158),
        .button_accept_focus_ring = rgb(0, 90, 158),

        .pane_divider = rgb(209, 209, 209),
        .pane_divider_focused = rgb(0, 120, 212),

        .is_dark = false,
    };
}

// ── Color helpers ───────────────────────────────────────────────────────

pub fn adjustColor(base: u32, dr: i16, dg: i16, db: i16) u32 {
    const r: u8 = @intCast(@as(u16, @intCast(std.math.clamp(@as(i16, @intCast(base & 0xFF)) + dr, 0, 255))));
    const g: u8 = @intCast(@as(u16, @intCast(std.math.clamp(@as(i16, @intCast((base >> 8) & 0xFF)) + dg, 0, 255))));
    const b: u8 = @intCast(@as(u16, @intCast(std.math.clamp(@as(i16, @intCast((base >> 16) & 0xFF)) + db, 0, 255))));
    return rgb(r, g, b);
}

// ── Button color derivation ─────────────────────────────────────────────

pub fn buttonColorsFromTheme(
    theme: *const ThemeColors,
    active: bool,
    overlay: bool,
    hovered: bool,
    pressed: bool,
    disabled: bool,
    accept: bool,
) ButtonColors {
    var colors: ButtonColors = .{
        .bg = if (overlay) theme.button_overlay_bg else theme.button_bg,
        .border = if (overlay) theme.button_overlay_border else theme.button_border,
        .fg = theme.button_fg,
    };

    if (active) {
        colors = .{
            .bg = theme.button_active_bg,
            .border = theme.button_active_border,
            .fg = theme.button_active_fg,
        };
    }
    if (accept) {
        colors = .{
            .bg = theme.button_accept_bg,
            .border = theme.button_accept_border,
            .fg = theme.button_accept_fg,
        };
    }
    if (hovered and !pressed and !disabled) {
        // Stronger hover deltas for responsive premium feel
        colors.bg = if (accept)
            adjustColor(theme.button_accept_bg, 14, 16, 22)
        else if (active)
            adjustColor(theme.button_active_bg, 16, 18, 22)
        else if (overlay)
            adjustColor(theme.button_overlay_bg, 14, 14, 16)
        else
            adjustColor(theme.button_bg, 16, 16, 18);
        colors.border = if (accept)
            adjustColor(theme.button_accept_border, 24, 20, 10)
        else if (active)
            theme.accent_hover
        else if (overlay)
            adjustColor(theme.button_overlay_border, 20, 20, 24)
        else
            adjustColor(theme.button_border, 28, 28, 30);
    }
    if (pressed) {
        colors.bg = if (overlay) adjustColor(theme.overlay_bg, -4, -4, -4) else adjustColor(theme.chrome_bg, -8, -8, -8);
        if (active) colors.bg = adjustColor(theme.button_active_bg, -18, -20, -20);
        if (accept) colors.bg = adjustColor(theme.button_accept_bg, -14, -20, -32);
    }
    if (disabled) {
        colors = .{
            .bg = theme.button_disabled_bg,
            .border = theme.button_disabled_border,
            .fg = theme.button_disabled_fg,
        };
    }

    return colors;
}

// Legacy buttonColors() and buttonFocusRingColor() removed.
// Use buttonColorsFromTheme() and ThemeColors focus ring fields instead.

// ── Overlay accent ──────────────────────────────────────────────────────

pub fn overlayAccentColor(mode: HostOverlayMode, is_dark: bool) u32 {
    if (!is_dark) {
        return switch (mode) {
            .command_palette => rgb(0, 90, 158),
            .profile => rgb(136, 60, 160),
            .search => rgb(16, 124, 80),
            .surface_title, .tab_title => rgb(156, 112, 24),
            .tab_overview => rgb(102, 76, 180),
            .none => rgb(140, 140, 140),
        };
    }
    return switch (mode) {
        .command_palette => rgb(116, 156, 224),
        .profile => rgb(192, 132, 214),
        .search => rgb(118, 196, 158),
        .surface_title, .tab_title => rgb(212, 170, 92),
        .tab_overview => rgb(168, 148, 228),
        .none => rgb(72, 82, 98),
    };
}

pub fn overlayEditBorderColor(mode: HostOverlayMode, focused: bool, is_dark: bool) u32 {
    if (focused) return overlayAccentColor(mode, is_dark);
    if (!is_dark) {
        return switch (mode) {
            .none => rgb(180, 180, 180),
            else => rgb(140, 140, 140),
        };
    }
    return switch (mode) {
        .none => rgb(72, 82, 98),
        else => rgb(86, 96, 112),
    };
}

// ── Profile chrome accents ──────────────────────────────────────────────

pub fn profileChromeAccent(kind: windows_shell.ProfileKind, is_dark: bool) ProfileChromeAccent {
    if (!is_dark) {
        return switch (kind) {
            .wsl_default, .wsl_distro => .{
                .idle_bg = rgb(228, 245, 233),
                .idle_border = rgb(46, 125, 70),
                .hover_bg = rgb(218, 238, 224),
                .hover_border = rgb(36, 110, 58),
                .pressed_bg = rgb(200, 228, 210),
                .active_bg = rgb(195, 232, 208),
                .active_border = rgb(28, 100, 48),
                .focus = rgb(22, 80, 40),
            },
            .pwsh => .{
                .idle_bg = rgb(224, 242, 248),
                .idle_border = rgb(24, 120, 150),
                .hover_bg = rgb(212, 236, 244),
                .hover_border = rgb(16, 108, 138),
                .pressed_bg = rgb(196, 226, 236),
                .active_bg = rgb(188, 228, 240),
                .active_border = rgb(12, 96, 126),
                .focus = rgb(8, 80, 108),
            },
            .powershell => .{
                .idle_bg = rgb(228, 232, 248),
                .idle_border = rgb(48, 68, 156),
                .hover_bg = rgb(218, 222, 242),
                .hover_border = rgb(38, 56, 140),
                .pressed_bg = rgb(200, 208, 232),
                .active_bg = rgb(196, 206, 236),
                .active_border = rgb(30, 48, 128),
                .focus = rgb(24, 40, 108),
            },
            .git_bash => .{
                .idle_bg = rgb(252, 244, 228),
                .idle_border = rgb(168, 120, 24),
                .hover_bg = rgb(248, 238, 216),
                .hover_border = rgb(152, 108, 16),
                .pressed_bg = rgb(240, 228, 200),
                .active_bg = rgb(244, 232, 196),
                .active_border = rgb(140, 96, 8),
                .focus = rgb(120, 80, 4),
            },
            .cmd => .{
                .idle_bg = rgb(240, 240, 240),
                .idle_border = rgb(128, 128, 128),
                .hover_bg = rgb(232, 232, 232),
                .hover_border = rgb(112, 112, 112),
                .pressed_bg = rgb(220, 220, 220),
                .active_bg = rgb(216, 216, 216),
                .active_border = rgb(96, 96, 96),
                .focus = rgb(64, 64, 64),
            },
        };
    }

    return switch (kind) {
        .wsl_default, .wsl_distro => .{
            .idle_bg = rgb(34, 46, 38),
            .idle_border = rgb(92, 176, 118),
            .hover_bg = rgb(40, 54, 44),
            .hover_border = rgb(116, 206, 144),
            .pressed_bg = rgb(28, 38, 31),
            .active_bg = rgb(46, 72, 54),
            .active_border = rgb(142, 224, 164),
            .focus = rgb(188, 244, 200),
        },
        .pwsh => .{
            .idle_bg = rgb(34, 45, 52),
            .idle_border = rgb(86, 176, 204),
            .hover_bg = rgb(40, 54, 62),
            .hover_border = rgb(110, 204, 234),
            .pressed_bg = rgb(28, 37, 43),
            .active_bg = rgb(44, 70, 82),
            .active_border = rgb(136, 216, 242),
            .focus = rgb(186, 232, 248),
        },
        .powershell => .{
            .idle_bg = rgb(34, 42, 58),
            .idle_border = rgb(98, 144, 220),
            .hover_bg = rgb(40, 50, 72),
            .hover_border = rgb(122, 170, 244),
            .pressed_bg = rgb(27, 34, 48),
            .active_bg = rgb(46, 64, 96),
            .active_border = rgb(148, 194, 255),
            .focus = rgb(192, 220, 255),
        },
        .git_bash => .{
            .idle_bg = rgb(48, 40, 31),
            .idle_border = rgb(212, 156, 92),
            .hover_bg = rgb(58, 48, 37),
            .hover_border = rgb(236, 182, 118),
            .pressed_bg = rgb(40, 33, 26),
            .active_bg = rgb(78, 62, 42),
            .active_border = rgb(248, 202, 134),
            .focus = rgb(255, 224, 178),
        },
        .cmd => .{
            .idle_bg = rgb(31, 41, 35),
            .idle_border = rgb(104, 186, 126),
            .hover_bg = rgb(38, 50, 42),
            .hover_border = rgb(128, 210, 150),
            .pressed_bg = rgb(25, 34, 29),
            .active_bg = rgb(42, 64, 50),
            .active_border = rgb(150, 228, 170),
            .focus = rgb(194, 244, 202),
        },
    };
}

pub fn applyProfileChromeAccent(
    base: ButtonColors,
    kind: windows_shell.ProfileKind,
    is_dark: bool,
    active: bool,
    hovered: bool,
    pressed: bool,
    disabled: bool,
) ButtonColors {
    if (disabled) return base;

    const accent = profileChromeAccent(kind, is_dark);
    var colors = base;
    colors.bg = if (active) accent.active_bg else accent.idle_bg;
    colors.border = if (active) accent.active_border else accent.idle_border;

    if (hovered and !pressed) {
        colors.bg = if (active) accent.active_bg else accent.hover_bg;
        colors.border = if (active) accent.active_border else accent.hover_border;
    }
    if (pressed) {
        colors.bg = accent.pressed_bg;
        colors.border = if (active) accent.active_border else accent.hover_border;
    }
    if (active) {
        colors.fg = if (is_dark) rgb(248, 250, 255) else rgb(16, 16, 24);
    }
    return colors;
}

pub fn profileKindFocusRingColor(kind: windows_shell.ProfileKind, is_dark: bool) u32 {
    return profileChromeAccent(kind, is_dark).focus;
}

pub fn profileChromeStripeColor(
    kind: windows_shell.ProfileKind,
    is_dark: bool,
    active: bool,
    hovered: bool,
    pressed: bool,
    disabled: bool,
) u32 {
    const accent = profileChromeAccent(kind, is_dark);
    if (disabled) return if (is_dark) rgb(86, 94, 108) else rgb(180, 180, 180);
    if (pressed) return accent.hover_border;
    if (hovered or active) return accent.active_border;
    return accent.idle_border;
}

pub fn profileKindLabelColor(kind: windows_shell.ProfileKind, is_dark: bool) u32 {
    return profileChromeAccent(kind, is_dark).focus;
}

pub fn profileKindHintColor(kind: windows_shell.ProfileKind, is_dark: bool) u32 {
    return profileChromeAccent(kind, is_dark).active_border;
}

pub fn quickSlotChipColors(kind: windows_shell.ProfileKind, is_dark: bool, hovered: bool) ButtonColors {
    const accent = profileChromeAccent(kind, is_dark);
    return .{
        .bg = if (hovered) accent.hover_bg else accent.idle_bg,
        .border = if (hovered) accent.hover_border else accent.idle_border,
        .fg = if (hovered) profileKindHintColor(kind, is_dark) else profileKindLabelColor(kind, is_dark),
    };
}

pub fn pinnedChipMarkerColor(kind: windows_shell.ProfileKind, is_dark: bool, hovered: bool) u32 {
    return if (hovered) profileKindLabelColor(kind, is_dark) else profileKindHintColor(kind, is_dark);
}
