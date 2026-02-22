const std = @import("std");

pub const change_window_icon = @import("parsers/change_window_icon.zig");
pub const change_window_title = @import("parsers/change_window_title.zig");
pub const clipboard_operation = @import("parsers/clipboard_operation.zig");
pub const color = @import("parsers/color.zig");
pub const hyperlink = @import("parsers/hyperlink.zig");
pub const iterm2 = @import("parsers/iterm2.zig");
pub const kitty_clipboard_protocol = @import("parsers/kitty_clipboard_protocol.zig");
pub const kitty_color = @import("parsers/kitty_color.zig");
pub const kitty_desktop_notification = @import("parsers/kitty_desktop_notification.zig");
pub const kitty_text_sizing = @import("parsers/kitty_text_sizing.zig");
pub const mouse_shape = @import("parsers/mouse_shape.zig");
pub const osc9 = @import("parsers/osc9.zig");
pub const report_pwd = @import("parsers/report_pwd.zig");
pub const rxvt_extension = @import("parsers/rxvt_extension.zig");
pub const semantic_prompt = @import("parsers/semantic_prompt.zig");

test {
    std.testing.refAllDecls(@This());
}
