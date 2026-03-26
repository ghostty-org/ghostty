const lib = @import("../lib.zig");
const CAllocator = lib.alloc.Allocator;

const buildpkg = @import("build_info.zig");
pub const allocator = @import("allocator.zig");
pub const cell = @import("cell.zig");
pub const clipboard = @import("clipboard.zig");
pub const color = @import("color.zig");
pub const focus = @import("focus.zig");
pub const formatter = @import("formatter.zig");
pub const modes = @import("modes.zig");
pub const osc = @import("osc.zig");
pub const render = @import("render.zig");
pub const key_event = @import("key_event.zig");
pub const key_encode = @import("key_encode.zig");
pub const mouse_event = @import("mouse_event.zig");
pub const mouse_encode = @import("mouse_encode.zig");
pub const row = @import("row.zig");
pub const sgr = @import("sgr.zig");
pub const size_report = @import("size_report.zig");
pub const style = @import("style.zig");
pub const terminal = @import("terminal.zig");

// The full C API, unexported.
pub const build_info = buildpkg.get;

pub const osc_new = osc.new;
pub const osc_free = osc.free;
pub const osc_reset = osc.reset;
pub const osc_next = osc.next;
pub const osc_end = osc.end;
pub const osc_command_type = osc.commandType;
pub const osc_command_data = osc.commandData;

pub const color_rgb_get = color.rgb_get;

pub const focus_encode = focus.encode;

pub const mode_report_encode = modes.report_encode;

pub const formatter_terminal_new = formatter.terminal_new;
pub const formatter_format_buf = formatter.format_buf;
pub const formatter_format_alloc = formatter.format_alloc;
pub const formatter_free = formatter.free;

pub const render_state_new = render.new;
pub const render_state_free = render.free;
pub const render_state_update = render.update;
pub const render_state_get = render.get;
pub const render_state_set = render.set;
pub const render_state_colors_get = render.colors_get;
pub const render_state_row_iterator_new = render.row_iterator_new;
pub const render_state_row_iterator_next = render.row_iterator_next;
pub const render_state_row_get = render.row_get;
pub const render_state_row_set = render.row_set;
pub const render_state_row_iterator_free = render.row_iterator_free;
pub const render_state_row_cells_new = render.row_cells_new;
pub const render_state_row_cells_next = render.row_cells_next;
pub const render_state_row_cells_select = render.row_cells_select;
pub const render_state_row_cells_get = render.row_cells_get;
pub const render_state_row_cells_free = render.row_cells_free;

pub const sgr_new = sgr.new;
pub const sgr_free = sgr.free;
pub const sgr_reset = sgr.reset;
pub const sgr_set_params = sgr.setParams;
pub const sgr_next = sgr.next;
pub const sgr_unknown_full = sgr.unknown_full;
pub const sgr_unknown_partial = sgr.unknown_partial;
pub const sgr_attribute_tag = sgr.attribute_tag;
pub const sgr_attribute_value = sgr.attribute_value;
pub const wasm_alloc_sgr_attribute = sgr.wasm_alloc_attribute;
pub const wasm_free_sgr_attribute = sgr.wasm_free_attribute;

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

pub const paste_is_safe = clipboard.paste_is_safe;
pub const clipboard_encode_paste = clipboard.encodePaste;

pub const alloc_alloc = allocator.alloc;
pub const alloc_free = allocator.free;

pub const clipboard_encode_osc52_read = clipboard.encodeOSC52Read;

pub const size_report_encode = size_report.encode;

pub const cell_get = cell.get;

pub const row_get = row.get;

pub const style_default = style.default_style;
pub const style_is_default = style.style_is_default;

pub const terminal_new = terminal.new;
pub const terminal_free = terminal.free;
pub const terminal_reset = terminal.reset;
pub const terminal_resize = terminal.resize;
pub const terminal_set = terminal.set;
pub const terminal_vt_write = terminal.vt_write;
pub const terminal_scroll_viewport = terminal.scroll_viewport;
pub const terminal_mode_get = terminal.mode_get;
pub const terminal_mode_set = terminal.mode_set;
pub const terminal_get = terminal.get;
pub const terminal_grid_ref = terminal.grid_ref;

const grid_ref = @import("grid_ref.zig");
pub const grid_ref_cell = grid_ref.grid_ref_cell;
pub const grid_ref_row = grid_ref.grid_ref_row;
pub const grid_ref_graphemes = grid_ref.grid_ref_graphemes;
pub const grid_ref_style = grid_ref.grid_ref_style;

test {
    _ = allocator;
    _ = buildpkg;
    _ = cell;
    _ = clipboard;
    _ = color;
    _ = grid_ref;
    _ = row;
    _ = focus;
    _ = formatter;
    _ = modes;
    _ = osc;
    _ = render;
    _ = key_event;
    _ = key_encode;
    _ = mouse_event;
    _ = mouse_encode;
    _ = sgr;
    _ = size_report;
    _ = style;
    _ = terminal;

    // We want to make sure we run the tests for the C allocator interface.
    _ = @import("../../lib/allocator.zig");
}
