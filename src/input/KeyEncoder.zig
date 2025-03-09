/// KeyEncoder is responsible for processing keyboard input and generating
/// the proper VT sequence for any events.
///
/// A new KeyEncoder should be created for each individual key press.
/// These encoders are not meant to be reused.
const KeyEncoder = @This();

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const key = @import("key.zig");
const config = @import("../config.zig");
const function_keys = @import("function_keys.zig");
const terminal = @import("../terminal/main.zig");
const KittyEntry = @import("kitty.zig").Entry;
const kitty_entries = @import("kitty.zig").entries;
const KittyFlags = terminal.kitty.KeyFlags;

const log = std.log.scoped(.key_encoder);

event: key.KeyEvent,

/// The state of various modes of a terminal that impact encoding.
macos_option_as_alt: config.OptionAsAlt = .false,
alt_esc_prefix: bool = false,
cursor_key_application: bool = false,
keypad_key_application: bool = false,
ignore_keypad_with_numlock: bool = false,
modify_other_keys_state_2: bool = false,
kitty_flags: KittyFlags = .{},

/// Perform the proper encoding depending on the terminal state.
pub fn encode(
    self: *const KeyEncoder,
    buf: []u8,
) ![]const u8 {
    // log.warn("KEYENCODER self={}", .{self.j});
    if (self.kitty_flags.int() != 0) return try self.kitty(buf);
    return try self.legacy(buf);
}

/// Perform Kitty keyboard protocol encoding of the key event.
fn kitty(
    self: *const KeyEncoder,
    buf: []u8,
) ![]const u8 {
    // This should never happen but we'll check anyway.
    if (self.kitty_flags.int() == 0) return try self.legacy(buf);

    // We only processed "press" events unless report events is active
    if (self.event.action == .release) {
        if (!self.kitty_flags.report_events) {
            return "";
        }

        // Enter, backspace, and tab do not report release events unless "report
        // all" is set
        if (!self.kitty_flags.report_all) {
            switch (self.event.key) {
                .enter, .backspace, .tab => return "",
                else => {},
            }
        }
    }

    const all_mods = self.event.mods;
    const effective_mods = self.event.effectiveMods();
    const binding_mods = effective_mods.binding();

    // Find the entry for this key in the kitty table.
    const entry_: ?KittyEntry = entry: {
        // Functional or predefined keys
        for (kitty_entries) |entry| {
            if (entry.key == self.event.key) break :entry entry;
        }

        // Otherwise, we use our unicode codepoint from UTF8. We
        // always use the unshifted value.
        if (self.event.unshifted_codepoint > 0) {
            break :entry .{
                .key = self.event.key,
                .code = self.event.unshifted_codepoint,
                .final = 'u',
                .modifier = false,
            };
        }

        break :entry null;
    };

    preprocessing: {
        // When composing, the only keys sent are plain modifiers.
        if (self.event.composing) {
            if (entry_) |entry| {
                if (entry.modifier) break :preprocessing;
            }

            return "";
        }

        // IME confirmation still sends an enter key so if we have enter
        // and UTF8 text we just send it directly since we assume that is
        // whats happening.
        if (self.event.utf8.len > 0) {
            switch (self.event.key) {
                .enter => return try copyToBuf(buf, self.event.utf8),
                .backspace => return "",
                else => {},
            }
        }

        // If we're reporting all then we always send CSI sequences.
        if (!self.kitty_flags.report_all) {
            // Quote:
            // The only exceptions are the Enter, Tab and Backspace keys which
            // still generate the same bytes as in legacy mode this is to allow the
            // user to type and execute commands in the shell such as reset after a
            // program that sets this mode crashes without clearing it.
            //
            // Quote ("report all" mode):
            // Note that all keys are reported as escape codes, including Enter,
            // Tab, Backspace etc.
            if (effective_mods.empty()) {
                switch (self.event.key) {
                    .enter => return try copyToBuf(buf, "\r"),
                    .tab => return try copyToBuf(buf, "\t"),
                    .backspace => return try copyToBuf(buf, "\x7F"),
                    else => {},
                }
            }

            // Send plain-text non-modified text directly to the terminal.
            // We don't send release events because those are specially encoded.
            if (self.event.utf8.len > 0 and
                binding_mods.empty() and
                self.event.action != .release)
            plain_text: {
                // We only do this for printable characters. We should
                // inspect the real unicode codepoint properties here but
                // the real world issue is usually control characters.
                const view = try std.unicode.Utf8View.init(self.event.utf8);
                var it = view.iterator();
                while (it.nextCodepoint()) |cp| if (isControl(cp)) break :plain_text;

                return try copyToBuf(buf, self.event.utf8);
            }
        }
    }

    const entry = entry_ orelse return "";

    // If this is just a modifier we require "report all" to send the sequence.
    if (entry.modifier and !self.kitty_flags.report_all) return "";

    const seq: KittySequence = seq: {
        var seq: KittySequence = .{
            .key = entry.code,
            .final = entry.final,
            .mods = KittyMods.fromInput(
                self.event.action,
                self.event.key,
                all_mods,
            ),
        };

        if (self.kitty_flags.report_events) {
            seq.event = switch (self.event.action) {
                .press => .press,
                .release => .release,
                .repeat => .repeat,
            };
        }

        if (self.kitty_flags.report_alternates) alternates: {
            // Break early if this is a control key
            if (isControl(seq.key)) break :alternates;

            const view = try std.unicode.Utf8View.init(self.event.utf8);
            var it = view.iterator();

            // If we have a codepoint in our UTF-8 sequence, then we can
            // report the shifted version.
            if (it.nextCodepoint()) |cp1| {
                // Set the first alternate (shifted version)
                if (cp1 != seq.key and seq.mods.shift) seq.alternates[0] = cp1;

                // We want to know if there are additional codepoints because
                // our logic below depends on the utf8 being a single codepoint.
                const has_cp2 = it.nextCodepoint() != null;

                // Set the base layout key. We only report this if this codepoint
                // differs from our pressed key.
                if (self.event.key.codepoint()) |base| {
                    if (base != seq.key and
                        (cp1 != base and !has_cp2))
                    {
                        seq.alternates[1] = base;
                    }
                }
            } else {
                // No UTF-8 so we can't report a shifted key but we can still
                // report a base layout key.
                if (self.event.key.codepoint()) |base| {
                    if (base != seq.key) seq.alternates[1] = base;
                }
            }
        }

        if (self.kitty_flags.report_associated and seq.event != .release) associated: {
            // Determine if the Alt modifier should be treated as an actual
            // modifier (in which case it prevents associated text) or as
            // the macOS Option key, which does not prevent associated text.
            const alt_prevents_text = if (comptime builtin.os.tag == .macos)
                switch (self.macos_option_as_alt) {
                    .left => all_mods.sides.alt == .left,
                    .right => all_mods.sides.alt == .right,
                    .true => true,
                    .false => false,
                }
            else
                true;

            if (seq.mods.preventsText(alt_prevents_text)) break :associated;

            seq.text = self.event.utf8;
        }

        break :seq seq;
    };

    return try seq.encode(buf);
}

/// Perform legacy encoding of the key event. "Legacy" in this case
/// is referring to the behavior of traditional terminals, plus
/// xterm's `modifyOtherKeys`, plus Paul Evans's "fixterms" spec.
/// These together combine the legacy protocol because they're all
/// meant to be extensions that do not change any existing behavior
/// and therefore safe to combine.
fn legacy(
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
        all_mods,
        self.cursor_key_application,
        self.keypad_key_application,
        self.ignore_keypad_with_numlock,
        self.modify_other_keys_state_2,
    )) |sequence| pc_style: {
        // If we have UTF-8 text, then we never emit PC style function
        // keys. Many function keys (escape, enter, backspace) have
        // a specific meaning when dead keys are active and so we don't
        // want to send that to the terminal. Examples:
        //
        //   - Japanese: escape clears the dead key state
        //   - Korean: escape commits the dead key state
        //   - Korean: backspace should delete a single preedit char
        //
        if (self.event.utf8.len > 0) {
            switch (self.event.key) {
                else => {},
                .backspace => return "",
                .enter, .escape => break :pc_style,
            }
        }

        return copyToBuf(buf, sequence);
    }

    // If we match a control sequence, we output that directly. For
    // ctrlSeq we have to use all mods because we want it to only
    // match ctrl+<char>.
    if (ctrlSeq(
        self.event.key,
        self.event.utf8,
        self.event.unshifted_codepoint,
        all_mods,
    )) |char| {
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

    // If we have no UTF8 text then the only possibility is the
    // alt-prefix handling of unshifted codepoints... so we process that.
    const utf8 = self.event.utf8;
    if (utf8.len == 0) {
        if (try self.legacyAltPrefix(binding_mods, all_mods)) |byte| {
            return try std.fmt.bufPrint(buf, "\x1B{c}", .{byte});
        }

        return "";
    }

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
    if (self.event.mods.ctrl) csiu: {
        // Important: we want to use the original mods here, not the
        // effective mods. The fixterms spec states the shifted chars
        // should be sent uppercase but Kitty changes that behavior
        // so we'll send all the mods.
        const csi_u_mods, const char = mods: {
            var mods = CsiUMods.fromInput(self.event.mods);

            // Get our codepoint. If we have more than one codepoint this
            // can't be valid CSIu.
            const view = std.unicode.Utf8View.init(self.event.utf8) catch break :csiu;
            var it = view.iterator();
            var char = it.nextCodepoint() orelse break :csiu;
            if (it.nextCodepoint() != null) break :csiu;

            // If our character is A to Z and we have shift set, then
            // we lowercase it. This is a Kitty-specific behavior that
            // we choose to follow and diverge from the fixterms spec.
            // This makes it easier for programs to detect shifted letters
            // for keybindings and is not just theoretical but used by
            // real programs.
            if (char >= 'A' and char <= 'Z' and mods.shift) {
                // We want to rely on apprt to send us the correct
                // unshifted codepoint...
                char = @intCast(std.ascii.toLower(@intCast(char)));
            }

            // If our unshifted codepoint is identical to the shifted
            // then we consider shift. Otherwise, we do not because the
            // shift key was used to obtain the character. This is specified
            // by fixterms.
            if (self.event.unshifted_codepoint != char) {
                mods.shift = false;
            }

            break :mods .{ mods, char };
        };
        const result = try std.fmt.bufPrint(
            buf,
            "\x1B[{};{}u",
            .{ char, csi_u_mods.seqInt() },
        );
        // std.log.warn("CSI_U: {s}", .{result});
        return result;
    }

    // If we have alt-pressed and alt-esc-prefix is enabled, then
    // we need to prefix the utf8 sequence with an esc.
    if (try self.legacyAltPrefix(binding_mods, all_mods)) |byte| {
        return try std.fmt.bufPrint(buf, "\x1B{c}", .{byte});
    }

    // If we are on macOS, command+keys do not encode text. It isn't
    // typical for command+keys on macOS to ever encode text. They
    // don't in native text inputs (i.e. TextEdit) and they also don't
    // in other native terminals (Terminal.app officially but also
    // iTerm2).
    //
    // For Linux, we continue to encode text because it is typical.
    // For example on Gnome Console Super+b will encode a "b" character
    // with legacy encoding.
    if ((comptime builtin.os.tag == .macos) and all_mods.super) {
        return "";
    }

    return try copyToBuf(buf, utf8);
}

fn legacyAltPrefix(
    self: *const KeyEncoder,
    binding_mods: key.Mods,
    mods: key.Mods,
) !?u8 {
    // This only takes effect with alt pressed
    if (!binding_mods.alt or !self.alt_esc_prefix) return null;

    // On macOS, we only handle option like alt in certain
    // circumstances. Otherwise, macOS does a unicode translation
    // and we allow that to happen.
    if (comptime builtin.os.tag == .macos) {
        switch (self.macos_option_as_alt) {
            .false => return null,
            .left => if (mods.sides.alt == .right) return null,
            .right => if (mods.sides.alt == .left) return null,
            .true => {},
        }
    }

    // Otherwise, we require utf8 to already have the byte represented.
    const utf8 = self.event.utf8;
    if (utf8.len == 1) {
        if (std.math.cast(u8, utf8[0])) |byte| {
            return byte;
        }
    }

    // If UTF8 isn't set, we will allow unshifted codepoints through.
    if (self.event.unshifted_codepoint > 0) {
        if (std.math.cast(
            u8,
            self.event.unshifted_codepoint,
        )) |byte| {
            return byte;
        }
    }

    // Else, we can't figure out the byte to alt-prefix so we
    // exit this handling.
    return null;
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
    keypad_key_application_req: bool,
    ignore_keypad_with_numlock: bool,
    modify_other_keys: bool, // True if state 2
) ?[]const u8 {
    // We only want binding-sensitive mods because lock keys
    // and directional modifiers (left/right) don't matter for
    // pc-style function keys.
    const mods_int = mods.binding().int();

    // Keypad application keymode isn't super straightforward.
    // On xterm, in VT220 mode, numlock alone is enough to trigger
    // application mode. But in more modern modes, numlock is
    // ignored by default via mode 1035 (default true). If mode
    // 1035 is on, we always are in numerical keypad mode. If
    // mode 1035 is off, we are in application mode if the
    // proper numlock state is pressed. The numlock state is implicitly
    // determined based on the keycode sent (i.e. 1 with numlock
    // on will be kp_end).
    const keypad_key_application = keypad: {
        // If we're ignoring keypad then this is always false.
        // In other words, we're always in numerical keypad mode.
        if (ignore_keypad_with_numlock) break :keypad false;

        // If we're not ignoring then we enable the desired state.
        break :keypad keypad_key_application_req;
    };

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
fn ctrlSeq(
    logical_key: key.Key,
    utf8: []const u8,
    unshifted_codepoint: u21,
    mods: key.Mods,
) ?u8 {
    const ctrl_only = comptime (key.Mods{ .ctrl = true }).int();

    // If ctrl is not pressed then we never do anything.
    if (!mods.ctrl) return null;

    const char, const unset_mods = unset_mods: {
        var unset_mods = mods;

        // Remove alt from our modifiers because it does not impact whether
        // we are generating a ctrl sequence and we handle the ESC-prefix
        // logic separately.
        unset_mods.alt = false;

        var char: u8 = char: {
            // If we have exactly one UTF8 byte, we assume that is the
            // character we want to convert to a C0 byte.
            if (utf8.len == 1) break :char utf8[0];

            // If we have a logical key that maps to a single byte
            // printable character, we use that. History to explain this:
            // this was added to support cyrillic keyboard layouts such
            // as Russian and Mongolian. These layouts have a `c` key that
            // maps to U+0441 (cyrillic small letter "c") but every
            // terminal I've tested encodes this as ctrl+c.
            if (logical_key.codepoint()) |cp| {
                if (std.math.cast(u8, cp)) |byte| {
                    // For this specific case, we only map to the key if
                    // we have exactly ctrl pressed. This is because shift
                    // would modify the key and we don't know how to do that
                    // properly here (don't have the layout). And we want
                    // to encode shift as CSIu.
                    if (unset_mods.int() != ctrl_only) return null;
                    break :char byte;
                }
            }

            // Otherwise we don't have a character to convert that
            // we can reliably map to a C0 byte.
            return null;
        };

        // Remove shift if we have something outside of the US letter
        // range. This is so that characters such as `ctrl+shift+-`
        // generate the correct ctrl-seq (used by emacs).
        if (unset_mods.shift and (char < 'A' or char > 'Z')) shift: {
            // Special case for fixterms awkward case as specified.
            if (char == '@') break :shift;
            unset_mods.shift = false;
        }

        // If the character is uppercase, we convert it to lowercase. We
        // rely on the unshifted codepoint to do this. This handles
        // the scenario where we have caps lock pressed. Note that
        // shifted characters are handled above, if we are just pressing
        // shift then the ctrl-only check will fail later and we won't
        // ctrl-seq encode.
        if (char >= 'A' and char <= 'Z' and unshifted_codepoint > 0) {
            if (std.math.cast(u8, unshifted_codepoint)) |byte| {
                char = byte;
            }
        }

        // An additional note on caps lock and shift interaction.
        // If we have caps lock set and an ASCII letter is pressed,
        // we lowercase it (above). If we have only control pressed,
        // we process it as a ctrl seq. For example ctrl+M with caps
        // lock but no shift will encode as 0x0D.
        //
        // But, if you press ctrl+shift+m, this will not encode as a
        // ctrl-seq and falls through to CSIu encoding. This lets programs
        // detect the difference between ctrl+M and ctrl+shift+M. This
        // diverges from the fixterms "spec" and most terminals. This
        // only matches Kitty in behavior. But I believe this is a
        // justified divergence because it's a useful distinction.

        break :unset_mods .{ char, unset_mods.binding() };
    };

    // After unsetting, we only continue if we have ONLY control set.
    if (unset_mods.int() != ctrl_only) return null;

    // From Kitty's key encoding logic. I tried to discern the exact
    // behavior across different terminals but it's not clear, so I'm
    // just going to repeat what Kitty does.
    return switch (char) {
        ' ' => 0,
        '/' => 31,
        '0' => 48,
        '1' => 49,
        '2' => 0,
        '3' => 27,
        '4' => 28,
        '5' => 29,
        '6' => 30,
        '7' => 31,
        '8' => 127,
        '9' => 57,
        '?' => 127,
        '@' => 0,
        '\\' => 28,
        ']' => 29,
        '^' => 30,
        '_' => 31,
        'a' => 1,
        'b' => 2,
        'c' => 3,
        'd' => 4,
        'e' => 5,
        'f' => 6,
        'g' => 7,
        'h' => 8,
        'j' => 10,
        'k' => 11,
        'l' => 12,
        'n' => 14,
        'o' => 15,
        'p' => 16,
        'q' => 17,
        'r' => 18,
        's' => 19,
        't' => 20,
        'u' => 21,
        'v' => 22,
        'w' => 23,
        'x' => 24,
        'y' => 25,
        'z' => 26,
        '~' => 30,

        // These are purposely NOT handled here because of the fixterms
        // specification: https://www.leonerd.org.uk/hacks/fixterms/
        // These are processed as CSI u.
        // 'i' => 0x09,
        // 'm' => 0x0D,
        // '[' => 0x1B,

        else => null,
    };
}

/// Returns true if this is an ASCII control character, matches libc implementation.
fn isControl(cp: u21) bool {
    return cp < 0x20 or cp == 0x7F;
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

    test "modifier sequence values" {
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
};

/// This is the bitfields for Kitty modifiers.
const KittyMods = packed struct(u8) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,
    hyper: bool = false,
    meta: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,

    /// Convert an input mods value into the CSI u mods value.
    pub fn fromInput(
        action: key.Action,
        k: key.Key,
        mods: key.Mods,
    ) KittyMods {
        _ = action;
        _ = k;
        return .{
            .shift = mods.shift,
            .alt = mods.alt,
            .ctrl = mods.ctrl,
            .super = mods.super,
            .caps_lock = mods.caps_lock,
            .num_lock = mods.num_lock,
        };
    }

    /// Returns true if the modifiers prevent printable text.
    ///
    /// The alt_prevents_text parameter determines whether or not the Alt
    /// modifier prevents printable text. On Linux, this is always true. On
    /// macOS, this is only true if macos-option-as-alt is set.
    pub fn preventsText(self: KittyMods, alt_prevents_text: bool) bool {
        return (self.alt and alt_prevents_text) or
            self.ctrl or
            self.super or
            self.hyper or
            self.meta;
    }

    /// Returns the raw int value of this packed struct.
    pub fn int(self: KittyMods) u8 {
        return @bitCast(self);
    }

    /// Returns the integer value sent as part of the Kitty sequence.
    /// This adds 1 to the bitmask value as described in the spec.
    pub fn seqInt(self: KittyMods) u9 {
        const raw: u9 = @intCast(self.int());
        return raw + 1;
    }

    test "modifier sequence values" {
        // This is all sort of trivially seen by looking at the code but
        // we want to make sure we never regress this.
        var mods: KittyMods = .{};
        try testing.expectEqual(@as(u9, 1), mods.seqInt());

        mods = .{ .shift = true };
        try testing.expectEqual(@as(u9, 2), mods.seqInt());

        mods = .{ .alt = true };
        try testing.expectEqual(@as(u9, 3), mods.seqInt());

        mods = .{ .ctrl = true };
        try testing.expectEqual(@as(u9, 5), mods.seqInt());

        mods = .{ .alt = true, .shift = true };
        try testing.expectEqual(@as(u9, 4), mods.seqInt());

        mods = .{ .ctrl = true, .shift = true };
        try testing.expectEqual(@as(u9, 6), mods.seqInt());

        mods = .{ .alt = true, .ctrl = true };
        try testing.expectEqual(@as(u9, 7), mods.seqInt());

        mods = .{ .alt = true, .ctrl = true, .shift = true };
        try testing.expectEqual(@as(u9, 8), mods.seqInt());
    }
};

/// Represents a kitty key sequence and has helpers for encoding it.
/// The sequence from the Kitty specification:
///
/// CSI unicode-key-code:alternate-key-codes ; modifiers:event-type ; text-as-codepoints u
const KittySequence = struct {
    key: u21,
    final: u8,
    mods: KittyMods = .{},
    event: Event = .none,
    alternates: [2]?u21 = .{ null, null },
    text: []const u8 = "",

    /// Values for the event code (see "event-type" in above comment).
    /// Note that Kitty omits the ":1" for the press event but other
    /// terminals include it. We'll include it.
    const Event = enum(u2) {
        none = 0,
        press = 1,
        repeat = 2,
        release = 3,
    };

    pub fn encode(self: KittySequence, buf: []u8) ![]const u8 {
        if (self.final == 'u' or self.final == '~') return try self.encodeFull(buf);
        return try self.encodeSpecial(buf);
    }

    fn encodeFull(self: KittySequence, buf: []u8) ![]const u8 {
        // Boilerplate to basically create a string builder that writes
        // over our buffer (but no more).
        var fba = std.heap.FixedBufferAllocator.init(buf);
        const alloc = fba.allocator();
        var builder = try std.ArrayListUnmanaged(u8).initCapacity(alloc, buf.len);
        const writer = builder.writer(alloc);

        // Key section
        try writer.print("\x1B[{d}", .{self.key});
        // Write our alternates
        if (self.alternates[0]) |shifted| try writer.print(":{d}", .{shifted});
        if (self.alternates[1]) |base| {
            if (self.alternates[0] == null) {
                try writer.print("::{d}", .{base});
            } else {
                try writer.print(":{d}", .{base});
            }
        }

        // Mods and events section
        const mods = self.mods.seqInt();
        var emit_prior = false;
        if (self.event != .none and self.event != .press) {
            try writer.print(
                ";{d}:{d}",
                .{ mods, @intFromEnum(self.event) },
            );
            emit_prior = true;
        } else if (mods > 1) {
            try writer.print(";{d}", .{mods});
            emit_prior = true;
        }

        // Text section
        if (self.text.len > 0) {
            const view = try std.unicode.Utf8View.init(self.text);
            var it = view.iterator();
            var count: usize = 0;
            while (it.nextCodepoint()) |cp| {
                // If the codepoint is non-printable ASCII character, skip.
                if (isControl(cp)) continue;

                // We need to add our ";". We need to add two if we didn't emit
                // the modifier section. We only do this initially.
                if (count == 0) {
                    if (!emit_prior) try writer.writeByte(';');
                    try writer.writeByte(';');
                } else {
                    try writer.writeByte(':');
                }

                try writer.print("{d}", .{cp});
                count += 1;
            }
        }

        try writer.print("{c}", .{self.final});
        return builder.items;
    }

    fn encodeSpecial(self: KittySequence, buf: []u8) ![]const u8 {
        const mods = self.mods.seqInt();
        if (self.event != .none) {
            return try std.fmt.bufPrint(buf, "\x1B[1;{d}:{d}{c}", .{
                mods,
                @intFromEnum(self.event),
                self.final,
            });
        }

        if (mods > 1) {
            return try std.fmt.bufPrint(buf, "\x1B[1;{d}{c}", .{
                mods,
                self.final,
            });
        }

        return try std.fmt.bufPrint(buf, "\x1B[{c}", .{self.final});
    }
};

test "KittySequence: backspace" {
    var buf: [128]u8 = undefined;

    // Plain
    {
        var seq: KittySequence = .{ .key = 127, .final = 'u' };
        const actual = try seq.encode(&buf);
        try testing.expectEqualStrings("\x1B[127u", actual);
    }

    // Release event
    {
        var seq: KittySequence = .{ .key = 127, .final = 'u', .event = .release };
        const actual = try seq.encode(&buf);
        try testing.expectEqualStrings("\x1B[127;1:3u", actual);
    }

    // Shift
    {
        var seq: KittySequence = .{
            .key = 127,
            .final = 'u',
            .mods = .{ .shift = true },
        };
        const actual = try seq.encode(&buf);
        try testing.expectEqualStrings("\x1B[127;2u", actual);
    }
}

test "KittySequence: text" {
    var buf: [128]u8 = undefined;

    // Plain
    {
        var seq: KittySequence = .{
            .key = 127,
            .final = 'u',
            .text = "A",
        };
        const actual = try seq.encode(&buf);
        try testing.expectEqualStrings("\x1B[127;;65u", actual);
    }

    // Release
    {
        var seq: KittySequence = .{
            .key = 127,
            .final = 'u',
            .event = .release,
            .text = "A",
        };
        const actual = try seq.encode(&buf);
        try testing.expectEqualStrings("\x1B[127;1:3;65u", actual);
    }

    // Shift
    {
        var seq: KittySequence = .{
            .key = 127,
            .final = 'u',
            .mods = .{ .shift = true },
            .text = "A",
        };
        const actual = try seq.encode(&buf);
        try testing.expectEqualStrings("\x1B[127;2;65u", actual);
    }
}

test "KittySequence: text with control characters" {
    var buf: [128]u8 = undefined;

    // By itself
    {
        var seq: KittySequence = .{
            .key = 127,
            .final = 'u',
            .text = "\n",
        };
        const actual = try seq.encode(&buf);
        try testing.expectEqualStrings("\x1b[127u", actual);
    }

    // With other printables
    {
        var seq: KittySequence = .{
            .key = 127,
            .final = 'u',
            .text = "A\n",
        };
        const actual = try seq.encode(&buf);
        try testing.expectEqualStrings("\x1b[127;;65u", actual);
    }
}

test "KittySequence: special no mods" {
    var buf: [128]u8 = undefined;
    var seq: KittySequence = .{ .key = 1, .final = 'A' };
    const actual = try seq.encode(&buf);
    try testing.expectEqualStrings("\x1B[A", actual);
}

test "KittySequence: special mods only" {
    var buf: [128]u8 = undefined;
    var seq: KittySequence = .{ .key = 1, .final = 'A', .mods = .{ .shift = true } };
    const actual = try seq.encode(&buf);
    try testing.expectEqualStrings("\x1B[1;2A", actual);
}

test "KittySequence: special mods and event" {
    var buf: [128]u8 = undefined;
    var seq: KittySequence = .{
        .key = 1,
        .final = 'A',
        .event = .release,
        .mods = .{ .shift = true },
    };
    const actual = try seq.encode(&buf);
    try testing.expectEqualStrings("\x1B[1;2:3A", actual);
}

test "kitty: plain text" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .a,
            .mods = .{},
            .utf8 = "abcd",
        },

        .kitty_flags = .{ .disambiguate = true },
    };

    const actual = try enc.kitty(&buf);
    try testing.expectEqualStrings("abcd", actual);
}

test "kitty: repeat with just disambiguate" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .a,
            .action = .repeat,
            .mods = .{},
            .utf8 = "a",
        },

        .kitty_flags = .{ .disambiguate = true },
    };

    const actual = try enc.kitty(&buf);
    try testing.expectEqualStrings("a", actual);
}

test "kitty: enter, backspace, tab" {
    var buf: [128]u8 = undefined;
    {
        var enc: KeyEncoder = .{
            .event = .{ .key = .enter, .mods = .{}, .utf8 = "" },
            .kitty_flags = .{ .disambiguate = true },
        };
        const actual = try enc.kitty(&buf);
        try testing.expectEqualStrings("\r", actual);
    }
    {
        var enc: KeyEncoder = .{
            .event = .{ .key = .backspace, .mods = .{}, .utf8 = "" },
            .kitty_flags = .{ .disambiguate = true },
        };
        const actual = try enc.kitty(&buf);
        try testing.expectEqualStrings("\x7f", actual);
    }
    {
        var enc: KeyEncoder = .{
            .event = .{ .key = .tab, .mods = .{}, .utf8 = "" },
            .kitty_flags = .{ .disambiguate = true },
        };
        const actual = try enc.kitty(&buf);
        try testing.expectEqualStrings("\t", actual);
    }

    // No release events if "report_all" is not set
    {
        var enc: KeyEncoder = .{
            .event = .{ .action = .release, .key = .enter, .mods = .{}, .utf8 = "" },
            .kitty_flags = .{ .disambiguate = true, .report_events = true },
        };
        const actual = try enc.kitty(&buf);
        try testing.expectEqualStrings("", actual);
    }
    {
        var enc: KeyEncoder = .{
            .event = .{ .action = .release, .key = .backspace, .mods = .{}, .utf8 = "" },
            .kitty_flags = .{ .disambiguate = true, .report_events = true },
        };
        const actual = try enc.kitty(&buf);
        try testing.expectEqualStrings("", actual);
    }
    {
        var enc: KeyEncoder = .{
            .event = .{ .action = .release, .key = .tab, .mods = .{}, .utf8 = "" },
            .kitty_flags = .{ .disambiguate = true, .report_events = true },
        };
        const actual = try enc.kitty(&buf);
        try testing.expectEqualStrings("", actual);
    }

    // Release events if "report_all" is set
    {
        var enc: KeyEncoder = .{
            .event = .{ .action = .release, .key = .enter, .mods = .{}, .utf8 = "" },
            .kitty_flags = .{
                .disambiguate = true,
                .report_events = true,
                .report_all = true,
            },
        };
        const actual = try enc.kitty(&buf);
        try testing.expectEqualStrings("\x1b[13;1:3u", actual);
    }
    {
        var enc: KeyEncoder = .{
            .event = .{ .action = .release, .key = .backspace, .mods = .{}, .utf8 = "" },
            .kitty_flags = .{
                .disambiguate = true,
                .report_events = true,
                .report_all = true,
            },
        };
        const actual = try enc.kitty(&buf);
        try testing.expectEqualStrings("\x1b[127;1:3u", actual);
    }
    {
        var enc: KeyEncoder = .{
            .event = .{ .action = .release, .key = .tab, .mods = .{}, .utf8 = "" },
            .kitty_flags = .{
                .disambiguate = true,
                .report_events = true,
                .report_all = true,
            },
        };
        const actual = try enc.kitty(&buf);
        try testing.expectEqualStrings("\x1b[9;1:3u", actual);
    }
}

test "kitty: enter with all flags" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{ .key = .enter, .mods = .{}, .utf8 = "" },
        .kitty_flags = .{
            .disambiguate = true,
            .report_events = true,
            .report_alternates = true,
            .report_all = true,
            .report_associated = true,
        },
    };
    const actual = try enc.kitty(&buf);
    try testing.expectEqualStrings("[13u", actual[1..]);
}

test "kitty: ctrl with all flags" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{ .key = .left_control, .mods = .{ .ctrl = true }, .utf8 = "" },
        .kitty_flags = .{
            .disambiguate = true,
            .report_events = true,
            .report_alternates = true,
            .report_all = true,
            .report_associated = true,
        },
    };
    const actual = try enc.kitty(&buf);
    try testing.expectEqualStrings("[57442;5u", actual[1..]);
}

test "kitty: ctrl release with ctrl mod set" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .action = .release,
            .key = .left_control,
            .mods = .{ .ctrl = true },
            .utf8 = "",
        },
        .kitty_flags = .{
            .disambiguate = true,
            .report_events = true,
            .report_alternates = true,
            .report_all = true,
            .report_associated = true,
        },
    };
    const actual = try enc.kitty(&buf);
    try testing.expectEqualStrings("[57442;5:3u", actual[1..]);
}

test "kitty: delete" {
    var buf: [128]u8 = undefined;
    {
        var enc: KeyEncoder = .{
            .event = .{ .key = .delete, .mods = .{}, .utf8 = "\x7F" },
            .kitty_flags = .{ .disambiguate = true },
        };
        const actual = try enc.kitty(&buf);
        try testing.expectEqualStrings("\x1b[3~", actual);
    }
}

test "kitty: composing with no modifier" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .a,
            .mods = .{ .shift = true },
            .composing = true,
        },
        .kitty_flags = .{ .disambiguate = true },
    };

    const actual = try enc.kitty(&buf);
    try testing.expectEqualStrings("", actual);
}

test "kitty: composing with modifier" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .left_shift,
            .mods = .{ .shift = true },
            .composing = true,
        },
        .kitty_flags = .{ .disambiguate = true, .report_all = true },
    };

    const actual = try enc.kitty(&buf);
    try testing.expectEqualStrings("\x1b[57441;2u", actual);
}

test "kitty: shift+a on US keyboard" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .a,
            .mods = .{ .shift = true },
            .utf8 = "A",
            .unshifted_codepoint = 97, // lowercase A
        },
        .kitty_flags = .{
            .disambiguate = true,
            .report_alternates = true,
        },
    };

    const actual = try enc.kitty(&buf);
    try testing.expectEqualStrings("\x1b[97:65;2u", actual);
}

test "kitty: matching unshifted codepoint" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .a,
            .mods = .{ .shift = true },
            .utf8 = "A",
            .unshifted_codepoint = 65,
        },
        .kitty_flags = .{
            .disambiguate = true,
            .report_alternates = true,
        },
    };

    // WARNING: This is not a valid encoding. This is a hypothetical encoding
    // just to test that our logic is correct around matching unshifted
    // codepoints. We get an alternate here because the unshifted_codepoint does
    // not match the base key
    const actual = try enc.kitty(&buf);
    try testing.expectEqualStrings("\x1b[65::97;2u", actual);
}

test "kitty: report alternates with caps" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .j,
            .mods = .{ .caps_lock = true },
            .utf8 = "J",
            .unshifted_codepoint = 106,
        },
        .kitty_flags = .{
            .disambiguate = true,
            .report_all = true,
            .report_alternates = true,
            .report_associated = true,
        },
    };

    const actual = try enc.kitty(&buf);
    try testing.expectEqualStrings("\x1b[106;65;74u", actual);
}

test "kitty: report alternates colon (shift+';')" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .semicolon,
            .mods = .{ .shift = true },
            .utf8 = ":",
            .unshifted_codepoint = ';',
        },
        .kitty_flags = .{
            .disambiguate = true,
            .report_all = true,
            .report_alternates = true,
            .report_associated = true,
        },
    };

    const actual = try enc.kitty(&buf);
    try testing.expectEqualStrings("\x1b[59:58;2;58u", actual);
}

test "kitty: report alternates with ru layout" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .semicolon,
            .mods = .{},
            .utf8 = "ч",
            .unshifted_codepoint = 1095,
        },
        .kitty_flags = .{
            .disambiguate = true,
            .report_all = true,
            .report_alternates = true,
            .report_associated = true,
        },
    };

    const actual = try enc.kitty(&buf);
    try testing.expectEqualStrings("\x1b[1095::59;;1095u", actual);
}

test "kitty: report alternates with ru layout shifted" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .semicolon,
            .mods = .{ .shift = true },
            .utf8 = "Ч",
            .unshifted_codepoint = 1095,
        },
        .kitty_flags = .{
            .disambiguate = true,
            .report_all = true,
            .report_alternates = true,
            .report_associated = true,
        },
    };

    const actual = try enc.kitty(&buf);
    try testing.expectEqualStrings("\x1b[1095:1063:59;2;1063u", actual);
}

test "kitty: report alternates with ru layout caps lock" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .semicolon,
            .mods = .{ .caps_lock = true },
            .utf8 = "Ч",
            .unshifted_codepoint = 1095,
        },
        .kitty_flags = .{
            .disambiguate = true,
            .report_all = true,
            .report_alternates = true,
            .report_associated = true,
        },
    };

    const actual = try enc.kitty(&buf);
    try testing.expectEqualStrings("\x1b[1095::59;65;1063u", actual);
}

test "kitty: report alternates with hu layout release" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .action = .release,
            .key = .left_bracket,
            .mods = .{ .ctrl = true },
            .utf8 = "",
            .unshifted_codepoint = 337,
        },
        .kitty_flags = .{
            .disambiguate = true,
            .report_all = true,
            .report_alternates = true,
            .report_associated = true,
            .report_events = true,
        },
    };

    const actual = try enc.kitty(&buf);
    try testing.expectEqualStrings("[337::91;5:3u", actual[1..]);
}

// macOS generates utf8 text for arrow keys.
test "kitty: up arrow with utf8" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .up,
            .mods = .{},
            .utf8 = &.{30},
        },

        .kitty_flags = .{ .disambiguate = true },
    };

    const actual = try enc.kitty(&buf);
    try testing.expectEqualStrings("\x1b[A", actual);
}

test "kitty: shift+tab" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .tab,
            .mods = .{ .shift = true },
            .utf8 = "", // tab
        },

        .kitty_flags = .{ .disambiguate = true, .report_alternates = true },
    };

    const actual = try enc.kitty(&buf);
    try testing.expectEqualStrings("\x1b[9;2u", actual);
}

test "kitty: left shift" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .left_shift,
            .mods = .{},
            .utf8 = "",
        },

        .kitty_flags = .{ .disambiguate = true, .report_alternates = true },
    };

    const actual = try enc.kitty(&buf);
    try testing.expectEqualStrings("", actual);
}

test "kitty: left shift with report all" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .left_shift,
            .mods = .{},
            .utf8 = "",
        },

        .kitty_flags = .{ .disambiguate = true, .report_all = true },
    };

    const actual = try enc.kitty(&buf);
    try testing.expectEqualStrings("\x1b[57441u", actual);
}

test "kitty: report associated with alt text on macOS with option" {
    if (comptime !builtin.target.isDarwin()) return error.SkipZigTest;

    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .w,
            .mods = .{ .alt = true },
            .utf8 = "∑",
            .unshifted_codepoint = 119,
        },
        .kitty_flags = .{
            .disambiguate = true,
            .report_all = true,
            .report_alternates = true,
            .report_associated = true,
        },
        .macos_option_as_alt = .false,
    };

    const actual = try enc.kitty(&buf);
    try testing.expectEqualStrings("\x1b[119;3;8721u", actual);
}

test "kitty: report associated with alt text on macOS with alt" {
    if (comptime !builtin.target.isDarwin()) return error.SkipZigTest;

    {
        // With Alt modifier
        var buf: [128]u8 = undefined;
        var enc: KeyEncoder = .{
            .event = .{
                .key = .w,
                .mods = .{ .alt = true },
                .utf8 = "∑",
                .unshifted_codepoint = 119,
            },
            .kitty_flags = .{
                .disambiguate = true,
                .report_all = true,
                .report_alternates = true,
                .report_associated = true,
            },
            .macos_option_as_alt = .true,
        };

        const actual = try enc.kitty(&buf);
        try testing.expectEqualStrings("\x1b[119;3u", actual);
    }

    {
        // Without Alt modifier
        var buf: [128]u8 = undefined;
        var enc: KeyEncoder = .{
            .event = .{
                .key = .w,
                .mods = .{},
                .utf8 = "∑",
                .unshifted_codepoint = 119,
            },
            .kitty_flags = .{
                .disambiguate = true,
                .report_all = true,
                .report_alternates = true,
                .report_associated = true,
            },
            .macos_option_as_alt = .true,
        };

        const actual = try enc.kitty(&buf);
        try testing.expectEqualStrings("\x1b[119;;8721u", actual);
    }
}

test "kitty: report associated with modifiers" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .j,
            .mods = .{ .ctrl = true },
            .utf8 = "j",
            .unshifted_codepoint = 106,
        },
        .kitty_flags = .{
            .disambiguate = true,
            .report_all = true,
            .report_alternates = true,
            .report_associated = true,
        },
    };

    const actual = try enc.kitty(&buf);
    try testing.expectEqualStrings("\x1b[106;5u", actual);
}

test "kitty: report associated" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .j,
            .mods = .{ .shift = true },
            .utf8 = "J",
            .unshifted_codepoint = 106,
        },
        .kitty_flags = .{
            .disambiguate = true,
            .report_all = true,
            .report_alternates = true,
            .report_associated = true,
        },
    };

    const actual = try enc.kitty(&buf);
    try testing.expectEqualStrings("\x1b[106:74;2;74u", actual);
}

test "kitty: report associated on release" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .action = .release,
            .key = .j,
            .mods = .{ .shift = true },
            .utf8 = "J",
            .unshifted_codepoint = 106,
        },
        .kitty_flags = .{
            .disambiguate = true,
            .report_all = true,
            .report_alternates = true,
            .report_associated = true,
            .report_events = true,
        },
    };

    const actual = try enc.kitty(&buf);
    try testing.expectEqualStrings("[106:74;2:3u", actual[1..]);
}

test "kitty: alternates omit control characters" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .delete,
            .mods = .{},
            .utf8 = &.{0x7F},
        },
        .kitty_flags = .{
            .disambiguate = true,
            .report_alternates = true,
            .report_all = true,
        },
    };

    const actual = try enc.kitty(&buf);
    try testing.expectEqualStrings("\x1b[3~", actual);
}

test "kitty: enter with utf8 (dead key state)" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .enter,
            .utf8 = "A",
            .unshifted_codepoint = 0x0D,
        },
        .kitty_flags = .{
            .disambiguate = true,
            .report_alternates = true,
            .report_all = true,
        },
    };

    const actual = try enc.kitty(&buf);
    try testing.expectEqualStrings("A", actual);
}

test "kitty: keypad number" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{ .key = .kp_1, .mods = .{}, .utf8 = "1" },
        .kitty_flags = .{
            .disambiguate = true,
            .report_events = true,
            .report_alternates = true,
            .report_all = true,
            .report_associated = true,
        },
    };
    const actual = try enc.kitty(&buf);
    try testing.expectEqualStrings("[57400;;49u", actual[1..]);
}

test "legacy: backspace with utf8 (dead key state)" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .backspace,
            .utf8 = "A",
            .unshifted_codepoint = 0x0D,
        },
    };

    const actual = try enc.legacy(&buf);
    try testing.expectEqualStrings("", actual);
}

test "legacy: enter with utf8 (dead key state)" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .enter,
            .utf8 = "A",
            .unshifted_codepoint = 0x0D,
        },
    };

    const actual = try enc.legacy(&buf);
    try testing.expectEqualStrings("A", actual);
}

test "legacy: esc with utf8 (dead key state)" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .escape,
            .utf8 = "A",
            .unshifted_codepoint = 0x0D,
        },
    };

    const actual = try enc.legacy(&buf);
    try testing.expectEqualStrings("A", actual);
}

test "legacy: ctrl+shift+minus (underscore on US)" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .minus,
            .mods = .{ .ctrl = true, .shift = true },
            .utf8 = "_",
        },
    };

    const actual = try enc.legacy(&buf);
    try testing.expectEqualStrings("\x1F", actual);
}

test "legacy: ctrl+alt+c" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .c,
            .mods = .{ .ctrl = true, .alt = true },
            .utf8 = "c",
        },
    };

    const actual = try enc.legacy(&buf);
    try testing.expectEqualStrings("\x1b\x03", actual);
}

test "legacy: alt+c" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .c,
            .utf8 = "c",
            .mods = .{ .alt = true },
        },
        .alt_esc_prefix = true,
        .macos_option_as_alt = .true,
    };

    const actual = try enc.legacy(&buf);
    try testing.expectEqualStrings("\x1Bc", actual);
}

test "legacy: alt+e only unshifted" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .e,
            .unshifted_codepoint = 'e',
            .mods = .{ .alt = true },
        },
        .alt_esc_prefix = true,
        .macos_option_as_alt = .true,
    };

    const actual = try enc.legacy(&buf);
    try testing.expectEqualStrings("\x1Be", actual);
}

test "legacy: alt+x macos" {
    if (comptime !builtin.target.isDarwin()) return error.SkipZigTest;

    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .c,
            .utf8 = "≈",
            .unshifted_codepoint = 'c',
            .mods = .{ .alt = true },
        },
        .alt_esc_prefix = true,
        .macos_option_as_alt = .true,
    };

    const actual = try enc.legacy(&buf);
    try testing.expectEqualStrings("\x1Bc", actual);
}

test "legacy: shift+alt+. macos" {
    if (comptime !builtin.target.isDarwin()) return error.SkipZigTest;

    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .period,
            .utf8 = ">",
            .unshifted_codepoint = '.',
            .mods = .{ .alt = true, .shift = true },
        },
        .alt_esc_prefix = true,
        .macos_option_as_alt = .true,
    };

    const actual = try enc.legacy(&buf);
    try testing.expectEqualStrings("\x1B>", actual);
}

test "legacy: alt+ф" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .f,
            .utf8 = "ф",
            .mods = .{ .alt = true },
        },
        .alt_esc_prefix = true,
    };

    const actual = try enc.legacy(&buf);
    try testing.expectEqualStrings("ф", actual);
}

test "legacy: ctrl+c" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .c,
            .mods = .{ .ctrl = true },
            .utf8 = "c",
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
            .utf8 = " ",
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
        var enc: KeyEncoder = .{ .event = .{
            .key = .two,
            .mods = .{ .ctrl = true, .shift = true },
            .utf8 = "@",
            .unshifted_codepoint = '2',
        } };
        const actual = try enc.legacy(&buf);
        try testing.expectEqualStrings("\x1b[64;5u", actual);
    }
}

// These tests apply Kitty's behavior to CSIu where ctrl+shift+letter
// is sent as the unshifted letter with the shift modifier present.
test "legacy: ctrl+shift+letter ascii" {
    var buf: [128]u8 = undefined;
    {
        var enc: KeyEncoder = .{ .event = .{
            .key = .m,
            .mods = .{ .ctrl = true, .shift = true },
            .utf8 = "M",
            .unshifted_codepoint = 'm',
        } };
        const actual = try enc.legacy(&buf);
        try testing.expectEqualStrings("\x1b[109;6u", actual);
    }
}

test "legacy: shift+function key should use all mods" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .up,
            .mods = .{ .shift = true },
            .consumed_mods = .{ .shift = true },
        },
    };

    const actual = try enc.legacy(&buf);
    try testing.expectEqualStrings("\x1b[1;2A", actual);
}

test "legacy: keypad enter" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .kp_enter,
            .mods = .{},
            .consumed_mods = .{},
        },
    };

    const actual = try enc.legacy(&buf);
    try testing.expectEqualStrings("\r", actual);
}

test "legacy: keypad 1" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .kp_1,
            .mods = .{},
            .consumed_mods = .{},
            .utf8 = "1",
        },
    };

    const actual = try enc.legacy(&buf);
    try testing.expectEqualStrings("1", actual);
}

test "legacy: keypad 1 with application keypad" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .kp_1,
            .mods = .{},
            .consumed_mods = .{},
            .utf8 = "1",
        },
        .keypad_key_application = true,
    };

    const actual = try enc.legacy(&buf);
    try testing.expectEqualStrings("\x1bOq", actual);
}

test "legacy: keypad 1 with application keypad and numlock" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .kp_1,
            .mods = .{ .num_lock = true },
            .consumed_mods = .{},
            .utf8 = "1",
        },
        .keypad_key_application = true,
    };

    const actual = try enc.legacy(&buf);
    try testing.expectEqualStrings("\x1bOq", actual);
}

test "legacy: keypad 1 with application keypad and numlock ignore" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .kp_1,
            .mods = .{ .num_lock = false },
            .consumed_mods = .{},
            .utf8 = "1",
        },
        .keypad_key_application = true,
        .ignore_keypad_with_numlock = true,
    };

    const actual = try enc.legacy(&buf);
    try testing.expectEqualStrings("1", actual);
}

test "legacy: f1" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .f1,
            .mods = .{ .ctrl = true },
            .consumed_mods = .{},
        },
    };

    // F1
    {
        enc.event.key = .f1;
        const actual = try enc.legacy(&buf);
        try testing.expectEqualStrings("\x1b[1;5P", actual);
    }

    // F2
    {
        enc.event.key = .f2;
        const actual = try enc.legacy(&buf);
        try testing.expectEqualStrings("\x1b[1;5Q", actual);
    }

    // F3
    {
        enc.event.key = .f3;
        const actual = try enc.legacy(&buf);
        try testing.expectEqualStrings("\x1b[13;5~", actual);
    }

    // F4
    {
        enc.event.key = .f4;
        const actual = try enc.legacy(&buf);
        try testing.expectEqualStrings("\x1b[1;5S", actual);
    }

    // F5 uses new encoding
    {
        enc.event.key = .f5;
        const actual = try enc.legacy(&buf);
        try testing.expectEqualStrings("\x1b[15;5~", actual);
    }
}

test "legacy: left_shift+tab" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .tab,
            .mods = .{
                .shift = true,
                .sides = .{ .shift = .left },
            },
        },
    };

    const actual = try enc.legacy(&buf);
    try testing.expectEqualStrings("\x1b[Z", actual);
}

test "legacy: right_shift+tab" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .tab,
            .mods = .{
                .shift = true,
                .sides = .{ .shift = .right },
            },
        },
    };

    const actual = try enc.legacy(&buf);
    try testing.expectEqualStrings("\x1b[Z", actual);
}

test "legacy: hu layout ctrl+ő sends proper codepoint" {
    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .left_bracket,
            .physical_key = .left_bracket,
            .mods = .{ .ctrl = true },
            .utf8 = "ő",
            .unshifted_codepoint = 337,
        },
    };

    const actual = try enc.legacy(&buf);
    try testing.expectEqualStrings("[337;5u", actual[1..]);
}

test "legacy: super-only on macOS with text" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;

    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .b,
            .utf8 = "b",
            .mods = .{ .super = true },
        },
    };

    const actual = try enc.legacy(&buf);
    try testing.expectEqualStrings("", actual);
}

test "legacy: super and other mods on macOS with text" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;

    var buf: [128]u8 = undefined;
    var enc: KeyEncoder = .{
        .event = .{
            .key = .b,
            .utf8 = "B",
            .mods = .{ .super = true, .shift = true },
        },
    };

    const actual = try enc.legacy(&buf);
    try testing.expectEqualStrings("", actual);
}

test "ctrlseq: normal ctrl c" {
    const seq = ctrlSeq(.invalid, "c", 'c', .{ .ctrl = true });
    try testing.expectEqual(@as(u8, 0x03), seq.?);
}

test "ctrlseq: normal ctrl c, right control" {
    const seq = ctrlSeq(.invalid, "c", 'c', .{ .ctrl = true, .sides = .{ .ctrl = .right } });
    try testing.expectEqual(@as(u8, 0x03), seq.?);
}

test "ctrlseq: alt should be allowed" {
    const seq = ctrlSeq(.invalid, "c", 'c', .{ .alt = true, .ctrl = true });
    try testing.expectEqual(@as(u8, 0x03), seq.?);
}

test "ctrlseq: no ctrl does nothing" {
    try testing.expect(ctrlSeq(.invalid, "c", 'c', .{}) == null);
}

test "ctrlseq: shifted non-character" {
    const seq = ctrlSeq(.invalid, "_", '-', .{ .ctrl = true, .shift = true });
    try testing.expectEqual(@as(u8, 0x1F), seq.?);
}

test "ctrlseq: caps ascii letter" {
    const seq = ctrlSeq(.invalid, "C", 'c', .{ .ctrl = true, .caps_lock = true });
    try testing.expectEqual(@as(u8, 0x03), seq.?);
}

test "ctrlseq: shift does not generate ctrl seq" {
    try testing.expect(ctrlSeq(.invalid, "C", 'c', .{ .shift = true }) == null);
    try testing.expect(ctrlSeq(.invalid, "C", 'c', .{ .shift = true, .ctrl = true }) == null);
}

test "ctrlseq: russian ctrl c" {
    const seq = ctrlSeq(.c, "с", 0x0441, .{ .ctrl = true });
    try testing.expectEqual(@as(u8, 0x03), seq.?);
}

test "ctrlseq: russian shifted ctrl c" {
    const seq = ctrlSeq(.c, "с", 0x0441, .{ .ctrl = true, .shift = true });
    try testing.expect(seq == null);
}

test "ctrlseq: russian alt ctrl c" {
    const seq = ctrlSeq(.c, "с", 0x0441, .{ .ctrl = true, .alt = true });
    try testing.expectEqual(@as(u8, 0x03), seq.?);
}
