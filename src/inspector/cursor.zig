const cimgui = @import("cimgui");
const terminal = @import("../terminal/main.zig");

/// Render cursor information with a table already open.
pub fn renderInTable(
    t: *const terminal.Terminal,
    cursor: *const terminal.Screen.Cursor,
) void {
    {
        cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
        {
            _ = cimgui.c.igTableSetColumnIndex(0);
            cimgui.c.igText("Position (x, y)");
        }
        {
            _ = cimgui.c.igTableSetColumnIndex(1);
            cimgui.c.igText("(%d, %d)", cursor.x, cursor.y);
        }
    }

    {
        cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
        {
            _ = cimgui.c.igTableSetColumnIndex(0);
            cimgui.c.igText("Style");
        }
        {
            _ = cimgui.c.igTableSetColumnIndex(1);
            cimgui.c.igText("%s", @tagName(cursor.cursor_style).ptr);
        }
    }

    if (cursor.pending_wrap) {
        cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
        {
            _ = cimgui.c.igTableSetColumnIndex(0);
            cimgui.c.igText("Pending Wrap");
        }
        {
            _ = cimgui.c.igTableSetColumnIndex(1);
            cimgui.c.igText("%s", if (cursor.pending_wrap) "true".ptr else "false".ptr);
        }
    }

    // If we have a color then we show the color
    cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
    _ = cimgui.c.igTableSetColumnIndex(0);
    cimgui.c.igText("Foreground Color");
    _ = cimgui.c.igTableSetColumnIndex(1);
    switch (cursor.style.fg_color) {
        .none => cimgui.c.igText("default"),
        .palette => |idx| {
            const rgb = t.colors.palette.current[idx];
            cimgui.c.igValue_Int("Palette", idx);
            var color: [3]f32 = .{
                @as(f32, @floatFromInt(rgb.r)) / 255,
                @as(f32, @floatFromInt(rgb.g)) / 255,
                @as(f32, @floatFromInt(rgb.b)) / 255,
            };
            _ = cimgui.c.igColorEdit3(
                "color_fg",
                &color,
                cimgui.c.ImGuiColorEditFlags_DisplayHex |
                    cimgui.c.ImGuiColorEditFlags_NoPicker |
                    cimgui.c.ImGuiColorEditFlags_NoLabel,
            );
        },

        .rgb => |rgb| {
            var color: [3]f32 = .{
                @as(f32, @floatFromInt(rgb.r)) / 255,
                @as(f32, @floatFromInt(rgb.g)) / 255,
                @as(f32, @floatFromInt(rgb.b)) / 255,
            };
            _ = cimgui.c.igColorEdit3(
                "color_fg",
                &color,
                cimgui.c.ImGuiColorEditFlags_DisplayHex |
                    cimgui.c.ImGuiColorEditFlags_NoPicker |
                    cimgui.c.ImGuiColorEditFlags_NoLabel,
            );
        },
    }

    cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
    _ = cimgui.c.igTableSetColumnIndex(0);
    cimgui.c.igText("Background Color");
    _ = cimgui.c.igTableSetColumnIndex(1);
    switch (cursor.style.bg_color) {
        .none => cimgui.c.igText("default"),
        .palette => |idx| {
            const rgb = t.colors.palette.current[idx];
            cimgui.c.igValue_Int("Palette", idx);
            var color: [3]f32 = .{
                @as(f32, @floatFromInt(rgb.r)) / 255,
                @as(f32, @floatFromInt(rgb.g)) / 255,
                @as(f32, @floatFromInt(rgb.b)) / 255,
            };
            _ = cimgui.c.igColorEdit3(
                "color_bg",
                &color,
                cimgui.c.ImGuiColorEditFlags_DisplayHex |
                    cimgui.c.ImGuiColorEditFlags_NoPicker |
                    cimgui.c.ImGuiColorEditFlags_NoLabel,
            );
        },

        .rgb => |rgb| {
            var color: [3]f32 = .{
                @as(f32, @floatFromInt(rgb.r)) / 255,
                @as(f32, @floatFromInt(rgb.g)) / 255,
                @as(f32, @floatFromInt(rgb.b)) / 255,
            };
            _ = cimgui.c.igColorEdit3(
                "color_bg",
                &color,
                cimgui.c.ImGuiColorEditFlags_DisplayHex |
                    cimgui.c.ImGuiColorEditFlags_NoPicker |
                    cimgui.c.ImGuiColorEditFlags_NoLabel,
            );
        },
    }

    // Boolean styles
    const styles = .{
        "bold",    "italic",    "faint",         "blink",
        "inverse", "invisible", "strikethrough",
    };
    inline for (styles) |style| style: {
        if (!@field(cursor.style.flags, style)) break :style;

        cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
        {
            _ = cimgui.c.igTableSetColumnIndex(0);
            cimgui.c.igText(style.ptr);
        }
        {
            _ = cimgui.c.igTableSetColumnIndex(1);
            cimgui.c.igText("true");
        }
    }
}
