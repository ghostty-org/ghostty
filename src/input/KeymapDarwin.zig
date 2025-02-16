// Keymap is responsible for translating keyboard inputs into localized chars.
///
/// For example, the physical key "S" on a US-layout keyboard might mean "O"
/// in Dvorak. On international keyboard layouts, it may require multiple
/// keystrokes to produce a single character that is otherwise a single
/// keystroke on a US-layout keyboard.
///
/// This information is critical to know for many reasons. For keybindings,
/// if a user configures "ctrl+o" to do something, it should work with the
/// physical "ctrl+S" key on a Dvorak keyboard and so on.
///
/// This is currently only implemented for macOS.
const Keymap = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const macos = @import("macos");
const codes = @import("keycodes.zig").entries;
const Key = @import("key.zig").Key;
const Mods = @import("key.zig").Mods;

/// The current input source that is selected for the keyboard. This can
/// and does change whenever the user selects a new keyboard layout. This
/// change doesn't happen automatically; the user of this struct has to
/// detect it and then call `reload` to update the keymap.
source: *TISInputSource,

/// The keyboard layout for the current input source.
///
/// This doesn't need to be freed because its owned by the InputSource.
unicode_layout: *const UCKeyboardLayout,

pub const Error = error{
    GetInputSourceFailed,
    TranslateFailed,
};

/// The state that has to be passed in with each call to translate.
/// The contents of this are meant to mostly be opaque and can change
/// for platform-specific reasons.
pub const State = struct {
    dead_key: u32 = 0,
};

/// The result of a translation. The result of a translation can be multiple
/// states. For example, if the user types a dead key, the result will be
/// "composing" since they're still in the process of composing a full
/// character.
pub const Translation = struct {
    /// The translation result. If this is a dead key state, then this will
    /// be pre-edit text that can be displayed but will ultimately be replaced.
    text: []const u8 = "",

    /// Whether the text is still composing, i.e. this is a dead key state.
    composing: bool = false,

    /// The mods that were consumed to produce this translation
    mods: Mods = .{},
};

pub fn init() !Keymap {
    var keymap: Keymap = .{ .source = undefined, .unicode_layout = undefined };
    try keymap.reinit();
    return keymap;
}

pub fn deinit(self: *const Keymap) void {
    macos.foundation.CFRelease(self.source);
}

/// Reload the keymap. This must be called if the user changes their
/// keyboard layout.
pub fn reload(self: *Keymap) !void {
    macos.foundation.CFRelease(self.source);
    try self.reinit();
}

/// Get the input source ID for the current keyboard layout. The input
/// source ID is a unique identifier for the keyboard layout which is uniquely
/// defined by Apple.
///
/// This is macOS-only. Other platforms don't have an equivalent of this
/// so this isn't expected to be generally implemented.
pub fn sourceId(self: *const Keymap, buf: []u8) Allocator.Error![]const u8 {
    // Get the raw CFStringRef
    const id_raw = TISGetInputSourceProperty(
        self.source,
        kTISPropertyInputSourceID,
    ) orelse return error.OutOfMemory;

    // Convert the CFStringRef to a C string into our buffer.
    const id: *CFString = @ptrCast(id_raw);
    return id.cstring(buf, .utf8) orelse error.OutOfMemory;
}

/// Reinit reinitializes the keymap. It assumes that all the memory associated
/// with the keymap is already freed.
fn reinit(self: *Keymap) !void {
    self.source = TISCopyCurrentKeyboardLayoutInputSource() orelse
        return Error.GetInputSourceFailed;

    self.unicode_layout = layout: {
        // This returns a CFDataRef
        const data_raw = TISGetInputSourceProperty(
            self.source,
            kTISPropertyUnicodeKeyLayoutData,
        ) orelse return Error.GetInputSourceFailed;
        const data: *CFData = @ptrCast(data_raw);

        // The CFDataRef contains a UCKeyboardLayout pointer
        break :layout @ptrCast(data.getPointer());
    };

    if (comptime builtin.mode == .Debug) id: {
        var buf: [256]u8 = undefined;
        const id = self.sourceId(&buf) catch break :id;
        std.log.debug("keyboard layout={s}", .{id});
    }
}

/// Translate a single key input into a utf8 sequence.
pub fn translate(
    self: *const Keymap,
    out: []u8,
    state: *State,
    code: u16,
    input_mods: Mods,
) !Translation {
    // On macOS we strip ctrl because UCKeyTranslate
    // converts to the masked values (i.e. ctrl+c becomes 3)
    // and we don't want that behavior in Ghostty ever. This makes
    // this file not a general-purpose keymap implementation.
    const mods: Mods = mods: {
        var v = input_mods;
        v.ctrl = false;
        break :mods v;
    };

    // Get the keycode for the space key, using comptime.
    const code_space: u16 = comptime space: for (codes) |entry| {
        if (std.mem.eql(u8, entry.code, "Space"))
            break :space entry.native;
    } else @compileError("space code not found");

    // Convert our mods from our format to the Carbon API format
    const modifier_state: u32 = (CarbonMods{
        .alt = if (mods.alt) true else false,
        .ctrl = if (mods.ctrl) true else false,
        .meta = if (mods.super) true else false,
        .shift = if (mods.shift) true else false,
        .caps_lock = if (mods.caps_lock) true else false,
    }).ucKeyTranslate();

    // We use 4 here because the Chromium source code uses 4 and Chrome
    // works pretty well. They have a todo to look into longer sequences
    // but given how mature that software is I think this is fine.
    //
    // From Chromium:
    // Per Apple docs, the buffer length can be up to 255 but is rarely more than 4.
    // https://developer.apple.com/documentation/coreservices/1390584-uckeytranslate
    var char: [4]u16 = undefined;
    var char_count: c_ulong = 0;
    if (UCKeyTranslate(
        self.unicode_layout,
        code,
        kUCKeyActionDown,
        modifier_state,
        LMGetKbdType(),
        kUCKeyTranslateNoDeadKeysBit,
        &state.dead_key,
        char.len,
        &char_count,
        &char,
    ) != 0) return Error.TranslateFailed;

    // If we got a dead key, then we translate again with "space"
    // in order to get the pre-edit text.
    const composing = if (state.dead_key != 0 and char_count == 0) composing: {
        // We need to copy our dead key state so that it isn't modified.
        var dead_key_ignore: u32 = state.dead_key;
        if (UCKeyTranslate(
            self.unicode_layout,
            code_space,
            kUCKeyActionDown,
            modifier_state,
            LMGetKbdType(),
            kUCKeyTranslateNoDeadKeysMask,
            &dead_key_ignore,
            char.len,
            &char_count,
            &char,
        ) != 0) return Error.TranslateFailed;
        break :composing true;
    } else false;

    // Convert the utf16 to utf8
    const len = try std.unicode.utf16leToUtf8(out, char[0..char_count]);
    return .{
        .text = out[0..len],
        .composing = composing,
        .mods = mods,
    };
}

/// Map to the modifiers format used by the UCKeyTranslate function.
/// We use a u32 here because our bit arithmetic is all u32 anyways.
const CarbonMods = packed struct(u32) {
    _padding_start: u8 = 0,
    meta: bool = false,
    shift: bool = false,
    caps_lock: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    _padding_end: u19 = 0,

    /// Translate NSEventModifierFlags into the format used by UCKeyTranslate.
    fn ucKeyTranslate(self: CarbonMods) u32 {
        const int: u32 = @bitCast(self);
        return (int >> 8) & 0xFF;
    }

    // We got this from dumping the values out of another program since
    // I can't find the header for this anywhere. I find various modifier
    // headers but they do not match this! 🥺
    test "expected values" {
        const testing = std.testing;
        try testing.expectEqual(@as(u32, 0x100), @as(u32, @bitCast(CarbonMods{ .meta = true })));
        try testing.expectEqual(@as(u32, 0x200), @as(u32, @bitCast(CarbonMods{ .shift = true })));
        try testing.expectEqual(@as(u32, 0x400), @as(u32, @bitCast(CarbonMods{ .caps_lock = true })));
        try testing.expectEqual(@as(u32, 0x800), @as(u32, @bitCast(CarbonMods{ .alt = true })));
        try testing.expectEqual(@as(u32, 0x1000), @as(u32, @bitCast(CarbonMods{ .ctrl = true })));
    }
};

// The documentation for all of these types and functions is in the macOS SDK:
// Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/Headers/TextInputSources.h
extern "c" fn TISCopyCurrentKeyboardLayoutInputSource() ?*TISInputSource;
extern "c" fn TISGetInputSourceProperty(*TISInputSource, *CFString) ?*anyopaque;
extern "c" fn LMGetKbdLast() u8;
extern "c" fn LMGetKbdType() u8;
extern "c" fn UCKeyTranslate(*const UCKeyboardLayout, u16, u16, u32, u32, u32, *u32, c_ulong, *c_ulong, [*]u16) i32;
extern const kTISPropertyLocalizedName: *CFString;
extern const kTISPropertyUnicodeKeyLayoutData: *CFString;
extern const kTISPropertyInputSourceID: *CFString;
const TISInputSource = opaque {};
const UCKeyboardLayout = opaque {};
const kUCKeyActionDown: u16 = 0;
const kUCKeyActionUp: u16 = 1;
const kUCKeyActionAutoKey: u16 = 2;
const kUCKeyActionDisplay: u16 = 3;
const kUCKeyTranslateNoDeadKeysBit: u32 = 0;
const kUCKeyTranslateNoDeadKeysMask: u32 = 1 << kUCKeyTranslateNoDeadKeysBit;

const CFData = macos.foundation.Data;
const CFString = macos.foundation.String;

test {
    var keymap = try init();
    defer keymap.deinit();

    // These tests are all commented because they depend on the user-selected
    // keyboard layout...
    //
    // // Single quote ' which is fine on US, but dead on US-International
    // var buf: [4]u8 = undefined;
    // var state: State = .{};
    // {
    //     const result = try keymap.translate(&buf, &state, 0x27, .{});
    //     std.log.warn("map: text={s} dead={}", .{ result.text, result.composing });
    // }
    //
    // // Then type "a" which should combine with the dead key to make á
    // {
    //     const result = try keymap.translate(&buf, &state, 0x00, .{});
    //     std.log.warn("map: text={s} dead={}", .{ result.text, result.composing });
    // }
    //
    // // Shift+1 = ! on US
    // {
    //     const result = try keymap.translate(&buf, &state, 0x12, .{ .shift = true });
    //     std.log.warn("map: text={s} dead={}", .{ result.text, result.composing });
    // }
    //
    // // Scratch space
    // {
    //     const result = try keymap.translate(&buf, &state, 0x00, .{ .ctrl = true });
    //     std.log.warn("map: text={s} dead={}", .{ result.text, result.composing });
    // }
}
