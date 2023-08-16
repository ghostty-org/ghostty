/// KeyEncoder is responsible for processing keyboard input and generating
/// the proper VT sequence for any events.
///
/// A new KeyEncoder should be created for each individual key press.
/// These encoders are not meant to be reused.
const KeyEncoder = @This();

const std = @import("std");
const testing = std.testing;

const key = @import("key.zig");
const function_keys = @import("function_keys.zig");

event: key.KeyEvent,

/// The state of various modes of a terminal that impact encoding.
alt_esc_prefix: bool = false,
cursor_key_application: bool = false,
keypad_key_application: bool = false,
modify_other_keys_state_2: bool = false,

/// Perform legacy encoding of the key event. "Legacy" in this case
/// is referring to the behavior of traditional terminals, plus
/// xterm's `modifyOtherKeys`, plus Paul Evans's "fixterms" spec.
/// These together combine the legacy protocol because they're all
/// meant to be extensions that do not change any existing behavior
/// and therefore safe to combine.
pub fn legacy(
    self: *const KeyEncoder,
    buf: []u8,
) ![]const u8 {
    const all_mods = self.event.mods;
    const effective_mods = self.event.effectiveMods();
    const binding_mods = effective_mods.binding();

    // Legacy encoding only does press/repeat
    if (self.event.action != .press and
        self.event.action != .repeat) return "";

    // If we're in a dead key state then we never emit a sequence.
    if (self.event.composing) return "";

    // If we match a PC style function key then that is our result.
    if (pcStyleFunctionKey(
        self.event.key,
        binding_mods,
        self.cursor_key_application,
        self.keypad_key_application,
        self.modify_other_keys_state_2,
    )) |sequence| return copyToBuf(buf, sequence);

    // If we match a control sequence, we output that directly. For
    // ctrlSeq we have to use all mods because we want it to only
    // match ctrl+<char>.
    if (ctrlSeq(self.event.key, all_mods)) |char| {
        // C0 sequences support alt-as-esc prefixing.
        if (binding_mods.alt) {
            if (buf.len < 2) return error.OutOfMemory;
            buf[0] = 0x1B;
            buf[1] = char;
            return buf[0..2];
        }

        if (buf.len < 1) return error.OutOfMemory;
        buf[0] = char;
        return buf[0..1];
    }

    // If we have no UTF8 text then at this point there is nothing to do.
    const utf8 = self.event.utf8;
    if (utf8.len == 0) return "";

    // In modify other keys state 2, we send the CSI 27 sequence
    // for any char with a modifier. Ctrl sequences like Ctrl+a
    // are already handled above.
    if (self.modify_other_keys_state_2) modify_other: {
        const view = try std.unicode.Utf8View.init(utf8);
        var it = view.iterator();
        const codepoint = it.nextCodepoint() orelse break :modify_other;

        // We only do this if we have a single codepoint. There shouldn't
        // ever be a multi-codepoint sequence that triggers this.
        if (it.nextCodepoint() != null) break :modify_other;

        // This copies xterm's `ModifyOtherKeys` function that returns
        // whether modify other keys should be encoded for the given
        // input.
        const should_modify = should_modify: {
            // xterm IsControlInput
            if (codepoint >= 0x40 and codepoint <= 0x7F)
                break :should_modify true;

            // If we have anything other than shift pressed, encode.
            var mods_no_shift = binding_mods;
            mods_no_shift.shift = false;
            if (!mods_no_shift.empty()) break :should_modify true;

            // We only have shift pressed. We only allow space.
            if (codepoint == ' ') break :should_modify true;

            // This logic isn't complete but I don't fully understand
            // the rest so I'm going to wait until we can have a
            // reasonable test scenario.
            break :should_modify false;
        };

        if (should_modify) {
            for (function_keys.modifiers, 2..) |modset, code| {
                if (!binding_mods.equal(modset)) continue;
                return try std.fmt.bufPrint(
                    buf,
                    "\x1B[27;{};{}~",
                    .{ code, codepoint },
                );
            }
        }
    }

    // Let's see if we should apply fixterms to this codepoint.
    // At this stage of key processing, we only need to apply fixterms
    // to unicode codepoints if we have ctrl set.
    if (self.event.mods.ctrl) {
        // Important: we want to use the original mods here, not the
        // effective mods. The fixterms spec states the shifted chars
        // should be sent uppercase but Kitty changes that behavior
        // so we'll send all the mods.
        const csi_u_mods = CsiUMods.fromInput(self.event.mods);
        const result = try std.fmt.bufPrint(
            buf,
            "\x1B[{};{}u",
            .{ utf8[0], csi_u_mods.seqInt() },
        );
        // std.log.warn("CSI_U: {s}", .{result});
        return result;
    }

    // If we have alt-pressed and alt-esc-prefix is enabled, then
    // we need to prefix the utf8 sequence with an esc.
    if (binding_mods.alt and self.alt_esc_prefix) {
        // TODO: port this, I think we can just use effective mods
        // without any OS special case
        //
        // On macOS, we have to opt-in to using alt because option
        // by default is a unicode character sequence.
        // if (comptime builtin.target.isDarwin()) {
        //     switch (self.config.macos_option_as_alt) {
        //         .false => break :alt,
        //         .true => {},
        //         .left => if (mods.sides.alt != .left) break :alt,
        //         .right => if (mods.sides.alt != .right) break :alt,
        //     }
        // }

        return try std.fmt.bufPrint(buf, "\x1B{s}", .{utf8});
    }

    return try copyToBuf(buf, utf8);
}

/// A helper to memcpy a src value to a buffer and return the result.
fn copyToBuf(buf: []u8, src: []const u8) ![]const u8 {
    if (src.len > buf.len) return error.OutOfMemory;
    const result = buf[0..src.len];
    @memcpy(result, src);
    return result;
}

/// Determines whether the key should be encoded in the xterm
/// "PC-style Function Key" syntax (roughly). This is a hardcoded
/// table of keys and modifiers that result in a specific sequence.
fn pcStyleFunctionKey(
    keyval: key.Key,
    mods: key.Mods,
    cursor_key_application: bool,
    keypad_key_application: bool,
    modify_other_keys: bool, // True if state 2
) ?[]const u8 {
    const mods_int = mods.int();
    for (function_keys.keys.get(keyval)) |entry| {
        switch (entry.cursor) {
            .any => {},
            .normal => if (cursor_key_application) continue,
            .application => if (!cursor_key_application) continue,
        }

        switch (entry.keypad) {
            .any => {},
            .normal => if (keypad_key_application) continue,
            .application => if (!keypad_key_application) continue,
        }

        switch (entry.modify_other_keys) {
            .any => {},
            .set => if (modify_other_keys) continue,
            .set_other => if (!modify_other_keys) continue,
        }

        const entry_mods_int = entry.mods.int();
        if (entry_mods_int == 0) {
            if (mods_int != 0 and !entry.mods_empty_is_any) continue;
            // mods are either empty, or empty means any so we allow it.
        } else if (entry_mods_int != mods_int) {
            // any set mods require an exact match
            continue;
        }

        return entry.sequence;
    }

    return null;
}

/// Returns the C0 byte for the key event if it should be used.
/// This converts a key event into the expected terminal behavior
/// such as Ctrl+C turning into 0x03, amongst many other translations.
///
/// This will return null if the key event should not be converted
/// into a C0 byte. There are many cases for this and you should read
/// the source code to understand them.
fn ctrlSeq(keyval: key.Key, mods: key.Mods) ?u8 {
    // Remove alt from our modifiers because it does not impact whether
    // we are generating a ctrl sequence.
    const unalt_mods = unalt_mods: {
        var unalt_mods = mods;
        unalt_mods.alt = false;
        break :unalt_mods unalt_mods.binding();
    };

    // If we have any other modifier key set, then we do not generate
    // a C0 sequence.
    const ctrl_only = comptime (key.Mods{ .ctrl = true }).int();
    if (unalt_mods.int() != ctrl_only) return null;

    // The normal approach to get this value is to make the ascii byte
    // with 0x1F. However, not all apprt key translation will properly
    // generate the correct value so we just hardcode this based on
    // logical key.
    return switch (keyval) {
        .space => 0,
        .slash => 0x1F,
        .zero => 0x30,
        .one => 0x31,
        .two => 0x00,
        .three => 0x1B,
        .four => 0x1C,
        .five => 0x1D,
        .six => 0x1E,
        .seven => 0x1F,
        .eight => 0x7F,
        .nine => 0x39,
        .backslash => 0x1C,
        .right_bracket => 0x1D,
        .a => 0x01,
        .b => 0x02,
        .c => 0x03,
        .d => 0x04,
        .e => 0x05,
        .f => 0x06,
        .g => 0x07,
        .h => 0x08,
        .j => 0x0A,
        .k => 0x0B,
        .l => 0x0C,
        .n => 0x0E,
        .o => 0x0F,
        .p => 0x10,
        .q => 0x11,
        .r => 0x12,
        .s => 0x13,
        .t => 0x14,
        .u => 0x15,
        .v => 0x16,
        .w => 0x17,
        .x => 0x18,
        .y => 0x19,
        .z => 0x1A,

        // These are purposely NOT handled here because of the fixterms
        // specification: https://www.leonerd.org.uk/hacks/fixterms/
        // These are processed as CSI u.
        // .i => 0x09,
        // .m => 0x0D,
        // .left_bracket => 0x1B,

        else => null,
    };
}

/// This is the bitmask for fixterm CSI u modifiers.
const CsiUMods = packed struct(u3) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,

    /// Convert an input mods value into the CSI u mods value.
    pub fn fromInput(mods: key.Mods) CsiUMods {
        return .{
            .shift = mods.shift,
            .alt = mods.alt,
            .ctrl = mods.ctrl,
        };
    }

    /// Returns the raw int value of this packed struct.
    pub fn int(self: CsiUMods) u3 {
        return @bitCast(self);
    }

    /// Returns the integer value sent as part of the CSI u sequence.
    /// This adds 1 to the bitmask value as described in the spec.
    pub fn seqInt(self: CsiUMods) u4 {
        const raw: u4 = @intCast(self.int());
        return raw + 1;
    }
};

test "modifer sequence values" {
    // This is all sort of trivially seen by looking at the code but
    // we want to make sure we never regress this.
    var mods: CsiUMods = .{};
    try testing.expectEqual(@as(u4, 1), mods.seqInt());

    mods = .{ .shift = true };
    try testing.expectEqual(@as(u4, 2), mods.seqInt());

    mods = .{ .alt = true };
    try testing.expectEqual(@as(u4, 3), mods.seqInt());

    mods = .{ .ctrl = true };
    try testing.expectEqual(@as(u4, 5), mods.seqInt());

    mods = .{ .alt = true, .shift = true };
    try testing.expectEqual(@as(u4, 4), mods.seqInt());

    mods = .{ .ctrl = true, .shift = true };
    try testing.expectEqual(@as(u4, 6), mods.seqInt());

    mods = .{ .alt = true, .ctrl = true };
    try testing.expectEqual(@as(u4, 7), mods.seqInt());

    mods = .{ .alt = true, .ctrl = true, .shift = true };
    try testing.expectEqual(@as(u4, 8), mods.seqInt());
}

test "legacy: ctrl+alt+c" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .c,
            .mods = .{ .ctrl = true, .alt = true },
        },
    };

    const actual = try enc.legacy(&buf);
    try testing.expectEqualStrings("\x1b\x03", actual);
}

test "legacy: ctrl+c" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .c,
            .mods = .{ .ctrl = true },
        },
    };

    const actual = try enc.legacy(&buf);
    try testing.expectEqualStrings("\x03", actual);
}

test "legacy: ctrl+space" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .space,
            .mods = .{ .ctrl = true },
        },
    };

    const actual = try enc.legacy(&buf);
    try testing.expectEqualStrings("\x00", actual);
}

test "legacy: ctrl+shift+backspace" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .backspace,
            .mods = .{ .ctrl = true, .shift = true },
        },
    };

    const actual = try enc.legacy(&buf);
    try testing.expectEqualStrings("\x08", actual);
}

test "legacy: ctrl+shift+char with modify other state 2" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .h,
            .mods = .{ .ctrl = true, .shift = true },
            .utf8 = "H",
        },
        .modify_other_keys_state_2 = true,
    };

    const actual = try enc.legacy(&buf);
    try testing.expectEqualStrings("\x1b[27;6;72~", actual);
}

test "legacy: fixterm awkward letters" {
    var buf: [128]u8 = undefined;
    {
        var enc: KeyEncoder = .{ .event = .{
            .key = .i,
            .mods = .{ .ctrl = true },
            .utf8 = "i",
        } };
        const actual = try enc.legacy(&buf);
        try testing.expectEqualStrings("\x1b[105;5u", actual);
    }
    {
        var enc: KeyEncoder = .{ .event = .{
            .key = .m,
            .mods = .{ .ctrl = true },
            .utf8 = "m",
        } };
        const actual = try enc.legacy(&buf);
        try testing.expectEqualStrings("\x1b[109;5u", actual);
    }
    {
        var enc: KeyEncoder = .{ .event = .{
            .key = .left_bracket,
            .mods = .{ .ctrl = true },
            .utf8 = "[",
        } };
        const actual = try enc.legacy(&buf);
        try testing.expectEqualStrings("\x1b[91;5u", actual);
    }
    {
        // This doesn't exactly match the fixterm spec but matches the
        // behavior of Kitty.
        var enc: KeyEncoder = .{ .event = .{
            .key = .two,
            .mods = .{ .ctrl = true, .shift = true },
            .utf8 = "@",
        } };
        const actual = try enc.legacy(&buf);
        try testing.expectEqualStrings("\x1b[64;6u", actual);
    }
}

test "ctrlseq: normal ctrl c" {
    const seq = ctrlSeq(.c, .{ .ctrl = true });
    try testing.expectEqual(@as(u8, 0x03), seq.?);
}

test "ctrlseq: alt should be allowed" {
    const seq = ctrlSeq(.c, .{ .alt = true, .ctrl = true });
    try testing.expectEqual(@as(u8, 0x03), seq.?);
}

test "ctrlseq: no ctrl does nothing" {
    try testing.expect(ctrlSeq(.c, .{}) == null);
}

test "ctrlseq: shift does not generate ctrl seq" {
    try testing.expect(ctrlSeq(.c, .{ .shift = true }) == null);
    try testing.expect(ctrlSeq(.c, .{ .shift = true, .ctrl = true }) == null);
}
