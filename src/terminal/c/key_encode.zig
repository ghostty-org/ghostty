const std = @import("std");
const Allocator = std.mem.Allocator;
const lib = @import("../lib.zig");
const CAllocator = lib.alloc.Allocator;
const key_encode = @import("../../input/key_encode.zig");
const key_event = @import("key_event.zig");
const KittyFlags = @import("../../terminal/kitty/key.zig").Flags;
const OptionAsAlt = @import("../../input/config.zig").OptionAsAlt;
const Result = @import("result.zig").Result;
const KeyEvent = @import("key_event.zig").Event;
const Terminal = @import("terminal.zig").Terminal;
const ZigTerminal = @import("../Terminal.zig");

const log = std.log.scoped(.key_encode);

/// Wrapper around key encoding options that tracks the allocator for C API usage.
const KeyEncoderWrapper = struct {
    opts: key_encode.Options,
    alloc: Allocator,
};

/// C: GhosttyKeyEncoder
pub const Encoder = ?*KeyEncoderWrapper;

pub fn new(
    alloc_: ?*const CAllocator,
    result_: ?*Encoder,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.input_encode)) {
        if (result_) |o| o.* = null;
        return .unsupported;
    }
    const result = result_ orelse return .invalid_value;
    const alloc = lib.alloc.default(alloc_);
    const ptr = alloc.create(KeyEncoderWrapper) catch
        return .out_of_memory;
    ptr.* = .{
        .opts = .{},
        .alloc = alloc,
    };
    result.* = ptr;
    return .success;
}

pub fn free(encoder_: Encoder) callconv(lib.calling_conv) void {
    if (comptime !lib.feature(.input_encode)) return;
    const wrapper = encoder_ orelse return;
    const alloc = wrapper.alloc;
    alloc.destroy(wrapper);
}

/// C: GhosttyKeyEncoderOption
pub const Option = enum(c_int) {
    invalid = 0,
    cursor_key_application = 1,
    keypad_key_application = 2,
    ignore_keypad_with_numlock = 3,
    alt_esc_prefix = 4,
    modify_other_keys_state_2 = 5,
    kitty_flags = 6,
    macos_option_as_alt = 7,
    /// DEC Backarrow Key Mode (DECBKM)
    /// See https://vt100.net/dec/ek-vt3xx-tp-002.pdf page 170
    /// If `false` (the default), `backspace` emits 0x7f
    /// If `true`, `backspace` emits 0x08
    backarrow_key_mode = 8,

    _,

    /// Input type expected for setting the option.
    pub fn InType(comptime self: Option) type {
        return switch (self) {
            .cursor_key_application,
            .keypad_key_application,
            .ignore_keypad_with_numlock,
            .alt_esc_prefix,
            .modify_other_keys_state_2,
            .backarrow_key_mode,
            => bool,
            .kitty_flags => u8,
            .macos_option_as_alt => OptionAsAlt,
            .invalid, _ => void,
        };
    }
};

pub fn set(
    encoder_: Encoder,
    option: Option,
    value: ?*const anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.input_encode)) return .unsupported;
    return switch (option) {
        .invalid => .invalid_value,
        _ => .unsupported,
        inline else => |comptime_option| {
            const encoder = encoder_ orelse return .invalid_value;
            const ptr = value orelse return resetTyped(encoder, comptime_option);
            return setTyped(encoder, comptime_option, @ptrCast(@alignCast(ptr)));
        },
    };
}

/// Reset an option to the default from `key_encode.Options`. This is what a
/// NULL value to `set` does.
fn resetTyped(encoder: *KeyEncoderWrapper, comptime option: Option) Result {
    const defaults: key_encode.Options = .{};
    const name = @tagName(option);
    @field(encoder.opts, name) = @field(defaults, name);
    return .success;
}

fn setTyped(
    encoder: *KeyEncoderWrapper,
    comptime option: Option,
    value: *const option.InType(),
) Result {
    const opts = &encoder.opts;
    switch (option) {
        .cursor_key_application => opts.cursor_key_application = value.*,
        .keypad_key_application => opts.keypad_key_application = value.*,
        .ignore_keypad_with_numlock => opts.ignore_keypad_with_numlock = value.*,
        .alt_esc_prefix => opts.alt_esc_prefix = value.*,
        .modify_other_keys_state_2 => opts.modify_other_keys_state_2 = value.*,
        .kitty_flags => opts.kitty_flags = flags: {
            const bits: u5 = @truncate(value.*);
            break :flags @bitCast(bits);
        },
        .macos_option_as_alt => opts.macos_option_as_alt =
            lib.enumFromPtr(OptionAsAlt, value) orelse return .invalid_value,
        .backarrow_key_mode => opts.backarrow_key_mode = value.*,
        .invalid, _ => comptime unreachable,
    }

    return .success;
}

pub fn set_from_terminal(
    encoder_: Encoder,
    terminal_: Terminal,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.input_encode)) return .unsupported;
    const wrapper = encoder_ orelse return .invalid_value;
    const t: *ZigTerminal = (terminal_ orelse return .invalid_value).terminal;
    wrapper.opts = .fromTerminal(t);
    return .success;
}

pub fn encode(
    encoder_: Encoder,
    event_: KeyEvent,
    out_: ?[*]u8,
    out_len: usize,
    out_written_: ?*usize,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.input_encode)) return .unsupported;
    const encoder = encoder_ orelse return .invalid_value;
    const event = event_ orelse return .invalid_value;
    const out_written = out_written_ orelse return .invalid_value;

    // Attempt to write to this buffer
    var writer: std.Io.Writer = .fixed(if (out_) |out| out[0..out_len] else &.{});
    key_encode.encode(
        &writer,
        event.event,
        encoder.opts,
    ) catch |err| switch (err) {
        error.WriteFailed => {
            // If we don't have space, use a discarding writer to count
            // how much space we would have needed.
            var discarding: std.Io.Writer.Discarding = .init(&.{});
            key_encode.encode(
                &discarding.writer,
                event.event,
                encoder.opts,
            ) catch unreachable;

            // Discarding always uses a u64. If we're on 32-bit systems
            // we cast down. We should make this safer in the future.
            out_written.* = @intCast(discarding.count);
            return .out_of_space;
        },
    };

    out_written.* = writer.end;
    return .success;
}

test "alloc" {
    const testing = std.testing;
    var e: Encoder = undefined;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &e,
    ));
    free(e);
}

test "set bool" {
    const testing = std.testing;
    var e: Encoder = undefined;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &e,
    ));
    defer free(e);

    // Test setting bool options
    const val_true: bool = true;
    try testing.expectEqual(Result.success, set(e, .cursor_key_application, &val_true));
    try testing.expect(e.?.opts.cursor_key_application);

    const val_false: bool = false;
    try testing.expectEqual(Result.success, set(e, .cursor_key_application, &val_false));
    try testing.expect(!e.?.opts.cursor_key_application);

    try testing.expectEqual(Result.success, set(e, .keypad_key_application, &val_true));
    try testing.expect(e.?.opts.keypad_key_application);
}

test "set kitty flags" {
    const testing = std.testing;
    var e: Encoder = undefined;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &e,
    ));
    defer free(e);

    // Test setting kitty flags
    const flags: KittyFlags = .{
        .disambiguate = true,
        .report_events = true,
    };
    const flags_int: u8 = @intCast(flags.int());
    try testing.expectEqual(Result.success, set(e, .kitty_flags, &flags_int));
    try testing.expect(e.?.opts.kitty_flags.disambiguate);
    try testing.expect(e.?.opts.kitty_flags.report_events);
    try testing.expect(!e.?.opts.kitty_flags.report_alternates);
}

test "set macos option as alt" {
    const testing = std.testing;
    var e: Encoder = undefined;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &e,
    ));
    defer free(e);

    // Test setting option as alt
    const opt_left: OptionAsAlt = .left;
    try testing.expectEqual(Result.success, set(e, .macos_option_as_alt, &opt_left));
    try testing.expectEqual(OptionAsAlt.left, e.?.opts.macos_option_as_alt);

    const opt_true: OptionAsAlt = .true;
    try testing.expectEqual(Result.success, set(e, .macos_option_as_alt, &opt_true));
    try testing.expectEqual(OptionAsAlt.true, e.?.opts.macos_option_as_alt);
}

test "set_from_terminal" {
    const testing = std.testing;
    const terminal_c = @import("terminal.zig");

    // Create encoder
    var e: Encoder = undefined;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &e,
    ));
    defer free(e);

    // Create terminal
    var t: Terminal = undefined;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    // Apply terminal state to encoder
    try testing.expectEqual(Result.success, set_from_terminal(e, t));

    // Options should reflect defaults from a fresh terminal
    try testing.expect(!e.?.opts.cursor_key_application);
    try testing.expect(e.?.opts.alt_esc_prefix);
    try testing.expectEqual(KittyFlags.disabled, e.?.opts.kitty_flags);
    try testing.expectEqual(OptionAsAlt.false, e.?.opts.macos_option_as_alt);
}

test "set_from_terminal null" {
    const testing = std.testing;

    try testing.expectEqual(Result.invalid_value, set_from_terminal(null, null));

    // Encoder null with valid terminal
    const terminal_c = @import("terminal.zig");
    var t: Terminal = undefined;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);
    try testing.expectEqual(Result.invalid_value, set_from_terminal(null, t));

    // Valid encoder with null terminal leaves the options unchanged
    var e: Encoder = undefined;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &e,
    ));
    defer free(e);
    const opt_true: OptionAsAlt = .true;
    try testing.expectEqual(Result.success, set(e, .macos_option_as_alt, &opt_true));
    try testing.expectEqual(Result.invalid_value, set_from_terminal(e, null));
    try testing.expectEqual(OptionAsAlt.true, e.?.opts.macos_option_as_alt);
}

test "encode: kitty ctrl release with ctrl mod set" {
    const testing = std.testing;

    // Create encoder
    var encoder: Encoder = undefined;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &encoder,
    ));
    defer free(encoder);

    // Set kitty flags with all features enabled
    {
        const flags: KittyFlags = .{
            .disambiguate = true,
            .report_events = true,
            .report_alternates = true,
            .report_all = true,
            .report_associated = true,
        };
        const flags_int: u8 = @intCast(flags.int());
        try testing.expectEqual(Result.success, set(encoder, .kitty_flags, &flags_int));
    }

    // Create key event
    var event: key_event.Event = undefined;
    try testing.expectEqual(Result.success, key_event.new(
        &lib.alloc.test_allocator,
        &event,
    ));
    defer key_event.free(event);

    // Set event properties: release action, ctrl key, ctrl modifier
    try testing.expectEqual(Result.success, key_event.set_action(event, .release));
    try testing.expectEqual(Result.success, key_event.set_key(event, .control_left));
    try testing.expectEqual(Result.success, key_event.set_mods(event, .{ .ctrl = true }));

    // Encode null should give us the length required
    var required: usize = 0;
    try testing.expectEqual(Result.out_of_space, encode(
        encoder,
        event,
        null,
        0,
        &required,
    ));

    // An undersized buffer reports the same required size
    var small: [4]u8 = undefined;
    var small_written: usize = 0;
    try testing.expectEqual(Result.out_of_space, encode(
        encoder,
        event,
        &small,
        small.len,
        &small_written,
    ));
    try testing.expectEqual(required, small_written);

    // Encode the key event
    var buf: [128]u8 = undefined;
    var written: usize = 0;
    try testing.expectEqual(Result.success, encode(
        encoder,
        event,
        &buf,
        buf.len,
        &written,
    ));
    try testing.expectEqual(required, written);

    // Expected: ESC[57442;5:3u (ctrl key code with mods and release event)
    const actual = buf[0..written];
    try testing.expectEqualStrings("\x1b[57442;5:3u", actual);
}
