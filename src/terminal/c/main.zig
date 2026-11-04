const std = @import("std");
const build_options = @import("terminal_options");
const lib = @import("../lib.zig");
const CAllocator = lib.alloc.Allocator;
const Result = @import("result.zig").Result;

const buildpkg = @import("build_info.zig");
pub const allocator = @import("allocator.zig");
pub const cell = @import("cell.zig");
pub const color = @import("color.zig");
pub const color_scheme = @import("color_scheme.zig");
pub const focus = @import("focus.zig");
pub const formatter = @import("formatter.zig");
pub const grid_ref = @import("grid_ref.zig");
pub const grid_ref_tracked = @import("grid_ref_tracked.zig");
pub const io = @import("io.zig");
pub const kitty_graphics = @import("kitty_graphics.zig");
pub const kitty_graphics_get = kitty_graphics.get;
pub const kitty_graphics_animation_tick = kitty_graphics.animation_tick;
pub const kitty_graphics_image = kitty_graphics.image_get_handle;
pub const kitty_graphics_image_get = kitty_graphics.image_get;
pub const kitty_graphics_image_get_multi = kitty_graphics.image_get_multi;
pub const kitty_graphics_placement_iterator_new = kitty_graphics.placement_iterator_new;
pub const kitty_graphics_placement_iterator_free = kitty_graphics.placement_iterator_free;
pub const kitty_graphics_placement_iterator_set = kitty_graphics.placement_iterator_set;
pub const kitty_graphics_placement_next = kitty_graphics.placement_iterator_next;
pub const kitty_graphics_placement_get = kitty_graphics.placement_get;
pub const kitty_graphics_placement_get_multi = kitty_graphics.placement_get_multi;
pub const kitty_graphics_placement_rect = kitty_graphics.placement_rect;
pub const kitty_graphics_placement_pixel_size = kitty_graphics.placement_pixel_size;
pub const kitty_graphics_placement_grid_size = kitty_graphics.placement_grid_size;
pub const kitty_graphics_placement_viewport_pos = kitty_graphics.placement_viewport_pos;
pub const kitty_graphics_placement_source_rect = kitty_graphics.placement_source_rect;
pub const kitty_graphics_placement_render_info = kitty_graphics.placement_render_info;
pub const types = @import("types.zig");
pub const modes = @import("modes.zig");
pub const osc = @import("osc.zig");
pub const render = @import("render.zig");
pub const selection = @import("selection.zig");
pub const selection_gesture = @import("selection_gesture.zig");
pub const key_event = @import("key_event.zig");
pub const key_encode = @import("key_encode.zig");
pub const mouse_event = @import("mouse_event.zig");
pub const mouse_encode = @import("mouse_encode.zig");
pub const paste = @import("paste.zig");
pub const row = @import("row.zig");
pub const search = @import("search.zig");
pub const sgr = @import("sgr.zig");
pub const size_report = @import("size_report.zig");
pub const snapshot = @import("snapshot.zig");
pub const style = @import("style.zig");
pub const sys = @import("sys.zig");
pub const terminal = @import("terminal.zig");
pub const unicode = @import("unicode.zig");

// The full C API, unexported.
pub const build_info = buildpkg.get;
pub const version = buildpkg.version;

pub const osc_new = osc.new;
pub const osc_free = osc.free;
pub const osc_reset = osc.reset;
pub const osc_next = osc.next;
pub const osc_end = osc.end;
pub const osc_set = osc.set;
pub const osc_command_type = osc.commandType;
pub const osc_command_data = osc.commandData;

pub const color_rgb_get = color.rgb_get;
pub const color_contrast = color.contrast;
pub const color_luminance = color.luminance;
pub const color_parse = color.parse;
pub const color_parse_palette_entry = color.parse_palette_entry;
pub const color_parse_x11 = color.parse_x11;
pub const color_palette_default = color.palette_default;
pub const color_palette_generate = color.palette_generate;
pub const color_perceived_luminance = color.perceived_luminance;
pub const color_x11_name_count = color.x11_name_count;
pub const color_x11_names = color.x11_names;

pub const color_scheme_report_encode = color_scheme.report_encode;

pub const focus_encode = focus.encode;

pub const mode_report_encode = modes.report_encode;

pub const formatter_terminal_new = formatter.terminal_new;
pub const formatter_set = formatter.set;
pub const formatter_get = formatter.get;
pub const formatter_format = formatter.format;
pub const formatter_format_buf = formatter.format_buf;
pub const formatter_format_alloc = formatter.format_alloc;
pub const formatter_free = formatter.free;

pub const render_state_new = render.new;
pub const render_state_free = render.free;
pub const render_state_update = render.update;
pub const render_state_begin_update = render.begin_update;
pub const render_state_end_update = render.end_update;
pub const render_state_clean = render.clean;
pub const render_state_get = render.get;
pub const render_state_get_multi = render.get_multi;
pub const render_state_set = render.set;
pub const render_state_row_iterator_new = render.row_iterator_new;
pub const render_state_row_iterator_next = render.row_iterator_next;
pub const render_state_row_iterator_next_dirty = render.row_iterator_next_dirty;
pub const render_state_row_get = render.row_get;
pub const render_state_row_get_multi = render.row_get_multi;
pub const render_state_row_set = render.row_set;
pub const render_state_row_iterator_free = render.row_iterator_free;
pub const render_state_row_cells_new = render.row_cells_new;
pub const render_state_row_cells_next = render.row_cells_next;
pub const render_state_row_cells_select = render.row_cells_select;
pub const render_state_row_cells_get = render.row_cells_get;
pub const render_state_row_cells_get_multi = render.row_cells_get_multi;
pub const render_state_row_cells_free = render.row_cells_free;
pub const render_state_image_iterator_new = render.image_iterator_new;
pub const render_state_image_iterator_next = render.image_iterator_next;
pub const render_state_image_iterator_free = render.image_iterator_free;
pub const render_state_image_get = render.image_get;
pub const render_state_image_get_multi = render.image_get_multi;

pub const sgr_new = sgr.new;
pub const sgr_free = sgr.free;
pub const sgr_reset = sgr.reset;
pub const sgr_set_params = sgr.setParams;
pub const sgr_next = sgr.next;
pub const sgr_unknown_full = sgr.unknown_full;
pub const sgr_unknown_partial = sgr.unknown_partial;
pub const sgr_attribute_tag = sgr.attribute_tag;
pub const sgr_attribute_value = sgr.attribute_value;

pub const key_event_new = key_event.new;
pub const key_event_free = key_event.free;
pub const key_event_set_action = key_event.set_action;
pub const key_event_get_action = key_event.get_action;
pub const key_event_set_key = key_event.set_key;
pub const key_event_get_key = key_event.get_key;
pub const key_event_set_mods = key_event.set_mods;
pub const key_event_get_mods = key_event.get_mods;
pub const key_event_set_consumed_mods = key_event.set_consumed_mods;
pub const key_event_get_consumed_mods = key_event.get_consumed_mods;
pub const key_event_set_composing = key_event.set_composing;
pub const key_event_get_composing = key_event.get_composing;
pub const key_event_set_utf8 = key_event.set_utf8;
pub const key_event_get_utf8 = key_event.get_utf8;
pub const key_event_set_unshifted_codepoint = key_event.set_unshifted_codepoint;
pub const key_event_get_unshifted_codepoint = key_event.get_unshifted_codepoint;

pub const key_encoder_new = key_encode.new;
pub const key_encoder_free = key_encode.free;
pub const key_encoder_setopt = key_encode.setopt;
pub const key_encoder_setopt_from_terminal = key_encode.setopt_from_terminal;
pub const key_encoder_encode = key_encode.encode;

pub const mouse_event_new = mouse_event.new;
pub const mouse_event_free = mouse_event.free;
pub const mouse_event_set_action = mouse_event.set_action;
pub const mouse_event_get_action = mouse_event.get_action;
pub const mouse_event_set_button = mouse_event.set_button;
pub const mouse_event_clear_button = mouse_event.clear_button;
pub const mouse_event_get_button = mouse_event.get_button;
pub const mouse_event_set_mods = mouse_event.set_mods;
pub const mouse_event_get_mods = mouse_event.get_mods;
pub const mouse_event_set_position = mouse_event.set_position;
pub const mouse_event_get_position = mouse_event.get_position;

pub const mouse_encoder_new = mouse_encode.new;
pub const mouse_encoder_free = mouse_encode.free;
pub const mouse_encoder_setopt = mouse_encode.setopt;
pub const mouse_encoder_setopt_from_terminal = mouse_encode.setopt_from_terminal;
pub const mouse_encoder_reset = mouse_encode.reset;
pub const mouse_encoder_encode = mouse_encode.encode;

pub const paste_is_safe = paste.is_safe;
pub const paste_encode = paste.encode;
pub const terminal_paste = paste.terminal_paste;

pub const alloc_alloc = allocator.alloc;
pub const alloc_free = allocator.free;

pub const size_report_encode = size_report.encode;

pub const cell_get = cell.get;
pub const cell_get_multi = cell.get_multi;

pub const row_get = row.get;
pub const row_get_multi = row.get_multi;

pub const style_default = style.default_style;
pub const style_is_default = style.style_is_default;

pub const sys_log_stderr = sys.logStderr;
pub const sys_set = sys.set;

pub const terminal_new = terminal.new;
pub const terminal_free = terminal.free;
pub const terminal_reset = terminal.reset;
pub const terminal_resize = terminal.resize;
pub const terminal_set = terminal.set;
pub const terminal_vt_write = terminal.vt_write;
pub const terminal_vt_write_until = terminal.vt_write_until;
pub const terminal_scroll_viewport = terminal.scroll_viewport;
pub const terminal_compression_activity = terminal.compression_activity;
pub const terminal_compress = terminal.compress;
pub const terminal_get = terminal.get;
pub const terminal_get_multi = terminal.get_multi;
pub const terminal_continuation_write = terminal.continuation_write;
pub const terminal_continuation_buf = terminal.continuation_buf;
pub const terminal_continuation_alloc = terminal.continuation_alloc;
pub const terminal_select_word = selection.word;
pub const terminal_select_word_between = selection.word_between;
pub const terminal_select_line = selection.line;
pub const terminal_select_all = selection.all;
pub const terminal_select_output = selection.output;
pub const terminal_selection_format_buf = selection.format_buf;
pub const terminal_selection_format_alloc = selection.format_alloc;
pub const terminal_selection_adjust = selection.adjust;
pub const terminal_selection_order = selection.order;
pub const terminal_selection_ordered = selection.ordered;
pub const terminal_selection_contains = selection.contains;
pub const terminal_selection_equal = selection.equal;
pub const selection_gesture_new = selection_gesture.new;
pub const selection_gesture_free = selection_gesture.free;
pub const selection_gesture_reset = selection_gesture.reset;
pub const selection_gesture_event = selection_gesture.handle_event;
pub const selection_gesture_get = selection_gesture.get;
pub const selection_gesture_get_multi = selection_gesture.get_multi;
pub const selection_gesture_event_new = selection_gesture.event_new;
pub const selection_gesture_event_free = selection_gesture.event_free;
pub const selection_gesture_event_set = selection_gesture.event_set;
pub const search_new = search.new;
pub const search_free = search.free;
pub const search_tick = search.tick;
pub const search_feed = search.feed;
pub const search_run = search.run;
pub const search_set = search.set;
pub const search_get = search.get;
pub const search_get_multi = search.get_multi;
pub const terminal_grid_ref = terminal.grid_ref;
pub const terminal_grid_ref_track = terminal.grid_ref_track;
pub const terminal_point_from_grid_ref = terminal.point_from_grid_ref;

pub const snapshot_encode = snapshot.encode;
pub const snapshot_encode_buf = snapshot.encode_buf;
pub const snapshot_encode_alloc = snapshot.encode_alloc;
pub const snapshot_decoder_new = snapshot.decoder_new;
pub const snapshot_decoder_new_buf = snapshot.decoder_new_buf;
pub const snapshot_decoder_free = snapshot.decoder_free;
pub const snapshot_decoder_set = snapshot.decoder_set;
pub const snapshot_decoder_get = snapshot.decoder_get;
pub const snapshot_decoder_get_multi = snapshot.decoder_get_multi;
pub const snapshot_decoder_ready = snapshot.decoder_ready;
pub const snapshot_decoder_next = snapshot.decoder_next;
pub const snapshot_decoder_decode = snapshot.decoder_decode;

pub const type_json = types.get_json;
pub const sized_init = types.sized_init;

pub const unicode_codepoint_width = unicode.codepoint_width;
pub const unicode_grapheme_width = unicode.grapheme_width;

pub const grid_ref_cell = grid_ref.grid_ref_cell;
pub const grid_ref_row = grid_ref.grid_ref_row;
pub const grid_ref_graphemes = grid_ref.grid_ref_graphemes;
pub const grid_ref_hyperlink_uri = grid_ref.grid_ref_hyperlink_uri;
pub const grid_ref_style = grid_ref.grid_ref_style;
pub const tracked_grid_ref_free = grid_ref_tracked.tracked_grid_ref_free;
pub const tracked_grid_ref_has_value = grid_ref_tracked.tracked_grid_ref_has_value;
pub const tracked_grid_ref_point = grid_ref_tracked.tracked_grid_ref_point;
pub const tracked_grid_ref_set = grid_ref_tracked.tracked_grid_ref_set;
pub const tracked_grid_ref_snapshot = grid_ref_tracked.tracked_grid_ref_snapshot;

test {
    _ = allocator;
    _ = buildpkg;
    _ = cell;
    _ = color;
    _ = color_scheme;
    _ = grid_ref;
    _ = grid_ref_tracked;
    _ = io;
    _ = kitty_graphics;
    _ = row;
    _ = focus;
    _ = formatter;
    _ = modes;
    _ = osc;
    _ = render;
    _ = selection;
    _ = selection_gesture;
    _ = key_event;
    _ = key_encode;
    _ = mouse_event;
    _ = mouse_encode;
    _ = paste;
    _ = search;
    _ = sgr;
    _ = size_report;
    _ = snapshot;
    _ = style;
    _ = sys;
    _ = terminal;
    _ = types;
    _ = @import("abi_test.zig");
    _ = unicode;

    // We want to make sure we run the tests for the C allocator interface.
    _ = @import("../../lib/allocator.zig");
}

test "unknown keys return unsupported in every family" {
    const testing = std.testing;

    // One below the _MAX_VALUE sentinel (INT_MAX). No real key will ever
    // use it. Most handles are null because the key is checked before the
    // handle.
    const unknown = std.math.maxInt(c_int) - 1;
    var out: [256]u8 align(16) = undefined;
    var values: [1]?*anyopaque = .{&out};
    var written: usize = 99;

    // Kitty graphics getters report no_value when the feature is compiled
    // out, before looking at the key.
    const kitty: Result = if (build_options.kitty_graphics) .unsupported else .no_value;

    // The render getters check the handle and row/cell position before the
    // key, so they need real handles.
    const alloc = &lib.alloc.test_allocator;
    var term: terminal.Terminal = null;
    try testing.expectEqual(Result.success, terminal.new(alloc, &term, 10, 3));
    defer terminal.free(term);
    var state: render.RenderState = null;
    try testing.expectEqual(Result.success, render.new(alloc, &state));
    defer render.free(state);
    try testing.expectEqual(Result.success, render.update(state, term));
    var rows: render.RowIterator = null;
    try testing.expectEqual(Result.success, render.row_iterator_new(alloc, &rows));
    defer render.row_iterator_free(rows);
    var cells: render.RowCells = null;
    try testing.expectEqual(Result.success, render.row_cells_new(alloc, &cells));
    defer render.row_cells_free(cells);
    try testing.expectEqual(Result.success, render.get(state, .row_iterator, @ptrCast(&rows)));
    try testing.expect(render.row_iterator_next(rows));
    try testing.expectEqual(Result.success, render.row_get(rows, .cells, @ptrCast(&cells)));
    try testing.expectEqual(Result.success, render.row_cells_select(cells, 0));

    const cases = .{
        .{ "build_info", Result.unsupported, buildpkg.get(@fromBackingInt(@intCast(unknown)), &out) },
        .{ "cell_get", Result.unsupported, cell.get(0, @fromBackingInt(@intCast(unknown)), &out) },
        .{ "cell_get_multi", Result.unsupported, cell.get_multi(0, 1, &.{@fromBackingInt(@intCast(unknown))}, &values, &written) },
        .{ "row_get", Result.unsupported, row.get(0, @fromBackingInt(@intCast(unknown)), &out) },
        .{ "row_get_multi", Result.unsupported, row.get_multi(0, 1, &.{@fromBackingInt(@intCast(unknown))}, &values, &written) },
        .{ "kitty_graphics_get", kitty, kitty_graphics.get(undefined, @fromBackingInt(@intCast(unknown)), &out) },
        .{ "kitty_graphics_image_get", kitty, kitty_graphics.image_get(null, @fromBackingInt(@intCast(unknown)), &out) },
        .{ "kitty_graphics_image_get_multi", kitty, kitty_graphics.image_get_multi(null, 1, &.{@fromBackingInt(@intCast(unknown))}, &values, &written) },
        .{ "kitty_graphics_placement_iterator_set", kitty, kitty_graphics.placement_iterator_set(null, @fromBackingInt(@intCast(unknown)), &out) },
        .{ "kitty_graphics_placement_get", kitty, kitty_graphics.placement_get(null, @fromBackingInt(@intCast(unknown)), &out) },
        .{ "kitty_graphics_placement_get_multi", kitty, kitty_graphics.placement_get_multi(null, 1, &.{@fromBackingInt(@intCast(unknown))}, &values, &written) },
        .{ "key_encoder_setopt", Result.unsupported, key_encode.setopt(null, @fromBackingInt(@intCast(unknown)), &out) },
        .{ "mouse_encoder_setopt", Result.unsupported, mouse_encode.setopt(null, @fromBackingInt(@intCast(unknown)), &out) },
        .{ "osc_set", Result.unsupported, osc.set(null, @fromBackingInt(@intCast(unknown)), &out) },
        .{ "render_state_get", Result.unsupported, render.get(state, @fromBackingInt(@intCast(unknown)), &out) },
        .{ "render_state_get_multi", Result.unsupported, render.get_multi(state, 1, &.{@fromBackingInt(@intCast(unknown))}, &values, &written) },
        .{ "render_state_set", Result.unsupported, render.set(null, @fromBackingInt(@intCast(unknown)), &out) },
        .{ "render_state_row_get", Result.unsupported, render.row_get(rows, @fromBackingInt(@intCast(unknown)), &out) },
        .{ "render_state_row_get_multi", Result.unsupported, render.row_get_multi(rows, 1, &.{@fromBackingInt(@intCast(unknown))}, &values, &written) },
        .{ "render_state_row_set", Result.unsupported, render.row_set(null, @fromBackingInt(@intCast(unknown)), &out) },
        .{ "render_state_row_cells_get", Result.unsupported, render.row_cells_get(cells, @fromBackingInt(@intCast(unknown)), &out) },
        .{ "render_state_row_cells_get_multi", Result.unsupported, render.row_cells_get_multi(cells, 1, &.{@fromBackingInt(@intCast(unknown))}, &values, &written) },
        .{ "render_state_image_get", Result.unsupported, render.image_get(null, @fromBackingInt(@intCast(unknown)), &out) },
        .{ "render_state_image_get_multi", Result.unsupported, render.image_get_multi(null, 1, &.{@fromBackingInt(@intCast(unknown))}, &values, &written) },
        .{ "search_set", Result.unsupported, search.set(null, @fromBackingInt(@intCast(unknown)), &out) },
        .{ "search_get", Result.unsupported, search.get(null, @fromBackingInt(@intCast(unknown)), &out) },
        .{ "search_get_multi", Result.unsupported, search.get_multi(null, 1, &.{@fromBackingInt(@intCast(unknown))}, &values, &written) },
        .{ "selection_gesture_event_set", Result.unsupported, selection_gesture.event_set(null, @fromBackingInt(@intCast(unknown)), &out) },
        .{ "selection_gesture_get", Result.unsupported, selection_gesture.get(null, null, @fromBackingInt(@intCast(unknown)), &out) },
        .{ "selection_gesture_get_multi", Result.unsupported, selection_gesture.get_multi(null, null, 1, &.{@fromBackingInt(@intCast(unknown))}, &values, &written) },
        .{ "snapshot_decoder_get", Result.unsupported, snapshot.decoder_get(null, @fromBackingInt(@intCast(unknown)), &out) },
        .{ "snapshot_decoder_get_multi", Result.unsupported, snapshot.decoder_get_multi(null, 1, &.{@fromBackingInt(@intCast(unknown))}, &values, &written) },
        .{ "sys_set", Result.unsupported, sys.set(@fromBackingInt(@intCast(unknown)), &out) },
        .{ "terminal_set", Result.unsupported, terminal.set(null, @fromBackingInt(@intCast(unknown)), &out) },
        .{ "terminal_get", Result.unsupported, terminal.get(null, @fromBackingInt(@intCast(unknown)), &out) },
        .{ "terminal_get_multi", Result.unsupported, terminal.get_multi(null, 1, &.{@fromBackingInt(@intCast(unknown))}, &values, &written) },
    };

    var failed = false;
    inline for (cases) |case| {
        if (case[1] != case[2]) {
            std.log.err("family={s} got={t}", .{ case[0], case[2] });
            failed = true;
        }
    }
    try testing.expect(!failed);

    // An unknown first key in a _get_multi call writes nothing.
    try testing.expectEqual(@as(usize, 0), written);

    // osc_command_data reports failure as false rather than a Result.
    try testing.expect(!osc.commandData(null, @fromBackingInt(@intCast(unknown)), &out));
}

test "out-of-range enum values passed as data return invalid_value" {
    const testing = std.testing;
    const bad = std.math.maxInt(c_int) - 1;
    const alloc = &lib.alloc.test_allocator;

    var key_ev: key_event.Event = undefined;
    try testing.expectEqual(Result.success, key_event.new(alloc, &key_ev));
    defer key_event.free(key_ev);
    var mouse_ev: mouse_event.Event = undefined;
    try testing.expectEqual(Result.success, mouse_event.new(alloc, &mouse_ev));
    defer mouse_event.free(mouse_ev);
    var key_enc: key_encode.Encoder = undefined;
    try testing.expectEqual(Result.success, key_encode.new(alloc, &key_enc));
    defer key_encode.free(key_enc);
    var mouse_enc: mouse_encode.Encoder = undefined;
    try testing.expectEqual(Result.success, mouse_encode.new(alloc, &mouse_enc));
    defer mouse_encode.free(mouse_enc);

    var gesture_ev: selection_gesture.Event = null;
    var buf: [64]u8 = undefined;
    var written: usize = 0;
    const bad_int: c_int = bad;

    const cases = .{
        .{ "key_event_set_action", key_event.set_action(key_ev, @fromBackingInt(@intCast(bad))) },
        .{ "key_event_set_key", key_event.set_key(key_ev, @fromBackingInt(@intCast(bad))) },
        .{ "mouse_event_set_action", mouse_event.set_action(mouse_ev, @fromBackingInt(@intCast(bad))) },
        .{ "mouse_event_set_button", mouse_event.set_button(mouse_ev, @fromBackingInt(@intCast(bad))) },
        .{ "key_encoder_setopt option_as_alt", key_encode.setopt(key_enc, .macos_option_as_alt, &bad_int) },
        .{ "mouse_encoder_setopt event", mouse_encode.setopt(mouse_enc, .event, &bad_int) },
        .{ "mouse_encoder_setopt format", mouse_encode.setopt(mouse_enc, .format, &bad_int) },
        .{ "selection_gesture_event_new", selection_gesture.event_new(alloc, &gesture_ev, @fromBackingInt(@intCast(bad))) },
        .{ "size_report_encode", size_report.encode(@fromBackingInt(@intCast(bad)), &.{ .rows = 1, .columns = 1, .cell_width = 1, .cell_height = 1 }, &buf, buf.len, &written) },
        .{ "color_scheme_report_encode", color_scheme.report_encode(@fromBackingInt(@intCast(bad)), &buf, buf.len, &written) },
    };

    inline for (cases) |case| {
        testing.expectEqual(Result.invalid_value, case[1]) catch |err| {
            std.log.err("function={s}", .{case[0]});
            return err;
        };
    }

    // The rejected values left the previous state in place.
    try testing.expectEqual(key_event.get_action(key_ev), .press);

    // A color_scheme callback that writes an out-of-range value gets no
    // reply sent, the same as returning false.
    {
        const S = struct {
            var value: ?c_int = null;
            var replies: usize = 0;
            var reply: [32]u8 = undefined;
            var reply_len: usize = 0;

            fn writePty(_: terminal.Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
                replies += 1;
                @memcpy(reply[0..len], ptr[0..len]);
                reply_len = len;
            }

            fn colorScheme(_: terminal.Terminal, _: ?*anyopaque, out: *c_int) callconv(lib.calling_conv) bool {
                if (value) |v| out.* = v;
                return true;
            }
        };
        S.value = bad_int;
        S.replies = 0;

        var t: terminal.Terminal = null;
        try testing.expectEqual(Result.success, terminal.new(alloc, &t, 80, 24));
        defer terminal.free(t);
        try testing.expectEqual(Result.success, terminal.set(t, .write_pty, @ptrCast(&S.writePty)));
        try testing.expectEqual(Result.success, terminal.set(t, .color_scheme, @ptrCast(&S.colorScheme)));

        const query = "\x1B[?996n";
        terminal.vt_write(t, query, query.len);
        try testing.expectEqual(@as(usize, 0), S.replies);

        // A callback that returns true without writing reports light,
        // because the library zeroes the value first.
        S.value = null;
        terminal.vt_write(t, query, query.len);
        try testing.expectEqual(@as(usize, 1), S.replies);
        try testing.expectEqualStrings("\x1B[?997;2n", S.reply[0..S.reply_len]);
    }
}

test "null value resets encoder options to their defaults" {
    const testing = std.testing;
    const alloc = &lib.alloc.test_allocator;
    const yes = true;

    // Key encoder: one non-default value per option.
    {
        var enc: key_encode.Encoder = undefined;
        try testing.expectEqual(Result.success, key_encode.new(alloc, &enc));
        defer key_encode.free(enc);
        const defaults = enc.?.opts;

        const flags: u8 = 0b11111;
        const option_as_alt: c_int = 2; // GHOSTTY_OPTION_AS_ALT_LEFT
        const cases = .{
            .{ key_encode.Option.cursor_key_application, &yes },
            .{ key_encode.Option.keypad_key_application, &yes },
            .{ key_encode.Option.ignore_keypad_with_numlock, &yes },
            .{ key_encode.Option.alt_esc_prefix, &yes },
            .{ key_encode.Option.modify_other_keys_state_2, &yes },
            .{ key_encode.Option.kitty_flags, &flags },
            .{ key_encode.Option.macos_option_as_alt, &option_as_alt },
            .{ key_encode.Option.backarrow_key_mode, &yes },
        };
        comptime std.debug.assert(cases.len ==
            @typeInfo(key_encode.Option).@"enum".field_names.len);

        inline for (cases) |case| {
            try testing.expectEqual(Result.success, key_encode.setopt(enc, case[0], case[1]));
            try testing.expect(!std.meta.eql(defaults, enc.?.opts));
            try testing.expectEqual(Result.success, key_encode.setopt(enc, case[0], null));
            testing.expect(std.meta.eql(defaults, enc.?.opts)) catch |err| {
                std.log.err("key option={t}", .{case[0]});
                return err;
            };
        }
    }

    // Mouse encoder: one non-default value per option.
    {
        var enc: mouse_encode.Encoder = undefined;
        try testing.expectEqual(Result.success, mouse_encode.new(alloc, &enc));
        defer mouse_encode.free(enc);
        const defaults = enc.?.opts;
        const default_track_last_cell = enc.?.track_last_cell;

        const tracking: c_int = 4; // GHOSTTY_MOUSE_TRACKING_ANY
        const format: c_int = 2; // GHOSTTY_MOUSE_FORMAT_SGR
        const size: mouse_encode.Size = .{
            .screen_width = 800,
            .screen_height = 600,
            .cell_width = 10,
            .cell_height = 20,
            .padding_top = 1,
            .padding_bottom = 1,
            .padding_right = 1,
            .padding_left = 1,
        };
        const cases = .{
            .{ mouse_encode.Option.event, &tracking },
            .{ mouse_encode.Option.format, &format },
            .{ mouse_encode.Option.size, &size },
            .{ mouse_encode.Option.any_button_pressed, &yes },
            .{ mouse_encode.Option.track_last_cell, &yes },
        };
        comptime std.debug.assert(cases.len ==
            @typeInfo(mouse_encode.Option).@"enum".field_names.len);

        inline for (cases) |case| {
            try testing.expectEqual(Result.success, mouse_encode.setopt(enc, case[0], case[1]));
            try testing.expect(!std.meta.eql(defaults, enc.?.opts) or
                enc.?.track_last_cell != default_track_last_cell);
            try testing.expectEqual(Result.success, mouse_encode.setopt(enc, case[0], null));
            testing.expect(std.meta.eql(defaults, enc.?.opts) and
                enc.?.track_last_cell == default_track_last_cell) catch |err| {
                std.log.err("mouse option={t}", .{case[0]});
                return err;
            };
        }
    }
}
