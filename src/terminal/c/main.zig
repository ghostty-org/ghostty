pub const color = @import("color.zig");
pub const osc = @import("osc.zig");
pub const key_event = @import("key_event.zig");
pub const key_encode = @import("key_encode.zig");
pub const paste = @import("paste.zig");
pub const sgr = @import("sgr.zig");

// The full C API, unexported.
pub const osc_new = osc.new;
pub const osc_free = osc.free;
pub const osc_reset = osc.reset;
pub const osc_next = osc.next;
pub const osc_end = osc.end;
pub const osc_command_type = osc.commandType;
pub const osc_command_data = osc.commandData;

pub const color_rgb_get = color.rgb_get;

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
pub const key_encoder_encode = key_encode.encode;

pub const paste_is_safe = paste.is_safe;

test {
    _ = color;
    _ = osc;
    _ = key_event;
    _ = key_encode;
    _ = paste;
    _ = sgr;

    // We want to make sure we run the tests for the C allocator interface.
    _ = @import("../../lib/allocator.zig");
}
