//! The binding actions the macOS and iOS apps implement. See
//! `apprt/command.zig`.
//!
//! Actions still pending work in Swift go in `false`.

const std = @import("std");
const Action = @import("../../input/Binding.zig").Action;

/// Returns true if the Apple apps implement `action`.
pub fn supported(action: Action) bool {
    return switch (action) {
        // No case in the action dispatch in `Ghostty.App.swift`.
        .move_tab_to_new_window,
        .toggle_tab_overview,
        .show_gtk_inspector,
        .show_on_screen_keyboard,
        .toggle_window_decorations,
        .prompt_window_title,
        .set_window_title,
        => false,

        // Implemented, or handled by the core with no apprt involvement.
        .ignore,
        .unbind,
        .csi,
        .esc,
        .text,
        .cursor_key,
        .reset,
        .copy_to_clipboard,
        .paste_from_clipboard,
        .paste_from_selection,
        .copy_url_to_clipboard,
        .copy_title_to_clipboard,
        .increase_font_size,
        .decrease_font_size,
        .reset_font_size,
        .set_font_size,
        .search,
        .search_selection,
        .navigate_search,
        .start_search,
        .end_search,
        .clear_screen,
        .select_all,
        .scroll_to_top,
        .scroll_to_bottom,
        .scroll_to_selection,
        .scroll_to_row,
        .scroll_page_up,
        .scroll_page_down,
        .scroll_page_fractional,
        .scroll_page_lines,
        .adjust_selection,
        .jump_to_prompt,
        .write_scrollback_file,
        .write_screen_file,
        .write_selection_file,
        .new_window,
        .new_tab,
        .previous_tab,
        .next_tab,
        .last_tab,
        .goto_tab,
        .move_tab,
        .prompt_surface_title,
        .prompt_tab_title,
        .set_surface_title,
        .set_tab_title,
        .new_split,
        .goto_split,
        .goto_window,
        .toggle_split_zoom,
        .toggle_readonly,
        .resize_split,
        .equalize_splits,
        .reset_window_size,
        .inspector,
        .open_config,
        .reload_config,
        .close_surface,
        .close_tab,
        .close_window,
        .close_all_windows,
        .toggle_maximize,
        .toggle_fullscreen,
        .toggle_window_float_on_top,
        .toggle_secure_input,
        .toggle_mouse_reporting,
        .toggle_command_palette,
        .toggle_quick_terminal,
        .toggle_visibility,
        .toggle_background_opacity,
        .check_for_updates,
        .undo,
        .redo,
        .end_key_sequence,
        .activate_key_table,
        .activate_key_table_once,
        .deactivate_key_table,
        .deactivate_all_key_tables,
        .quit,
        .crash,
        => true,
    };
}

test "GTK-only actions are unsupported" {
    const testing = std.testing;
    try testing.expect(!supported(.show_gtk_inspector));
    try testing.expect(!supported(.show_on_screen_keyboard));
    try testing.expect(!supported(.toggle_tab_overview));
    try testing.expect(!supported(.toggle_window_decorations));
    try testing.expect(!supported(.move_tab_to_new_window));
}

test "macOS-only and core actions are supported" {
    const testing = std.testing;
    try testing.expect(supported(.toggle_secure_input));
    try testing.expect(supported(.check_for_updates));
    try testing.expect(supported(.undo));
    try testing.expect(supported(.{ .copy_to_clipboard = .mixed }));
}
