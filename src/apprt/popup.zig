const std = @import("std");

/// The built-in profile name for the quick/dropdown terminal.
pub const quick_profile_name: [:0]const u8 = "quick";

/// Dimension: either absolute pixels or a percentage of screen.
/// Parsed from strings like "400" (pixels) or "80%" (percentage).
pub const Dimension = struct {
    value: u32,
    unit: Unit,

    pub const Unit = enum { pixels, percent };

    pub fn initPixels(v: u32) Dimension {
        return .{ .value = v, .unit = .pixels };
    }

    pub fn initPercent(v: u32) Dimension {
        return .{ .value = v, .unit = .percent };
    }

    /// Parse from a string like "400" or "80%".
    /// Conforms to the parseCLI convention used by the config framework.
    pub fn parseCLI(input: ?[]const u8) !Dimension {
        const s = input orelse return error.ValueRequired;
        if (s.len == 0) return error.InvalidValue;
        if (s[s.len - 1] == '%') {
            const num = std.fmt.parseInt(u32, s[0 .. s.len - 1], 10) catch
                return error.InvalidValue;
            if (num == 0 or num > 100) return error.InvalidValue;
            return initPercent(num);
        }
        const num = std.fmt.parseInt(u32, s, 10) catch
            return error.InvalidValue;
        return initPixels(num);
    }
};

pub const Position = enum {
    center,
    top,
    bottom,
    left,
    right,
};

pub const Anchor = enum {
    top_left,
    top_right,
    bottom_left,
    bottom_right,
    center,
};

/// Profile definition for a named popup terminal.
/// Field names are designed to work with the parseAutoStruct framework
/// (colon-delimited key:value pairs).
pub const PopupProfile = struct {
    position: Position = .center,
    anchor: ?Anchor = null,
    x: ?Dimension = null,
    y: ?Dimension = null,
    width: Dimension = Dimension.initPercent(80),
    height: Dimension = Dimension.initPercent(80),
    keybind: ?[]const u8 = null,
    command: ?[]const u8 = null,
    autohide: bool = true,
    persist: bool = true,
    cwd: ?[]const u8 = null,
    opacity: ?f64 = null,

    /// C-compatible representation of a PopupProfile.
    /// Sync with: ghostty_popup_profile_config_s in ghostty.h
    pub const C = extern struct {
        position: c_int,
        width_value: u32,
        width_is_percent: bool,
        height_value: u32,
        height_is_percent: bool,
        autohide: bool,
        persist: bool,
        /// Sentinel-terminated command string, or null if no command.
        /// This points into separately allocated memory (dupeZ'd),
        /// because the source `command` field is `?[]const u8` (no sentinel).
        command: ?[*:0]const u8,
        /// Sentinel-terminated CWD path, or null if not set.
        cwd: ?[*:0]const u8,
        /// Background opacity 0.0-1.0, or -1.0 if not set (extern structs can't have optionals).
        opacity: f64,
    };

    /// Convert to C-compatible representation.
    /// `command_z` is the pre-allocated sentinel-terminated copy of `command`,
    /// or null if no command was specified.
    /// `cwd_z` is the pre-allocated sentinel-terminated copy of `cwd`,
    /// or null if no cwd was specified.
    pub fn cval(self: PopupProfile, command_z: ?[*:0]const u8, cwd_z: ?[*:0]const u8) C {
        return .{
            .position = @intFromEnum(self.position),
            .width_value = self.width.value,
            .width_is_percent = self.width.unit == .percent,
            .height_value = self.height.value,
            .height_is_percent = self.height.unit == .percent,
            .autohide = self.autohide,
            .persist = self.persist,
            .command = command_z,
            .cwd = cwd_z,
            .opacity = if (self.opacity) |o| o else -1.0,
        };
    }
};

/// Validate a popup profile name.
/// Allowed characters: [a-zA-Z0-9_-], must be non-empty.
pub fn isValidName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => {},
            else => return false,
        }
    }
    return true;
}

test "Dimension: parse pixels" {
    const d = try Dimension.parseCLI("400");
    try std.testing.expectEqual(@as(u32, 400), d.value);
    try std.testing.expectEqual(Dimension.Unit.pixels, d.unit);
}

test "Dimension: parse percent" {
    const d = try Dimension.parseCLI("80%");
    try std.testing.expectEqual(@as(u32, 80), d.value);
    try std.testing.expectEqual(Dimension.Unit.percent, d.unit);
}

test "Dimension: reject zero percent" {
    try std.testing.expectError(error.InvalidValue, Dimension.parseCLI("0%"));
}

test "Dimension: reject over 100 percent" {
    try std.testing.expectError(error.InvalidValue, Dimension.parseCLI("101%"));
}

test "Dimension: reject empty" {
    try std.testing.expectError(error.InvalidValue, Dimension.parseCLI(""));
}

test "Dimension: reject null" {
    try std.testing.expectError(error.ValueRequired, Dimension.parseCLI(null));
}

test "isValidName: valid names" {
    try std.testing.expect(isValidName("quick"));
    try std.testing.expect(isValidName("my-popup"));
    try std.testing.expect(isValidName("calc_2"));
}

test "isValidName: invalid names" {
    try std.testing.expect(!isValidName(""));
    try std.testing.expect(!isValidName("bad name"));
    try std.testing.expect(!isValidName("bad:name"));
    try std.testing.expect(!isValidName("bad@name"));
}

test "PopupProfile: default cwd and opacity are null" {
    const p = PopupProfile{};
    try std.testing.expect(p.cwd == null);
    try std.testing.expect(p.opacity == null);
}

test "PopupProfile.C: opacity -1.0 means unset" {
    const p = PopupProfile{};
    const c = p.cval(null, null);
    try std.testing.expectEqual(@as(f64, -1.0), c.opacity);
    try std.testing.expect(c.cwd == null);
}

test "PopupProfile.C: opacity passes through" {
    const p = PopupProfile{ .opacity = 0.8 };
    const c = p.cval(null, null);
    try std.testing.expectEqual(@as(f64, 0.8), c.opacity);
}
