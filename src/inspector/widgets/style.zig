const std = @import("std");
const cimgui = @import("dcimgui");
const terminal = @import("../../terminal/main.zig");
const widgets = @import("../widgets.zig");

/// Render a style as a table.
pub fn table(
    st: terminal.Style,
    palette: ?*const terminal.color.Palette,
) void {
    {
        _ = cimgui.c.ImGui_BeginTable(
            "style",
            2,
            cimgui.c.ImGuiTableFlags_None,
        );
        defer cimgui.c.ImGui_EndTable();
        {
            cimgui.c.ImGui_TableNextRow();
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Foreground");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("The foreground (text) color");
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            color("fg", st.fg_color, palette);
        }

        {
            cimgui.c.ImGui_TableNextRow();
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Background");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("The background (cell) color");
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            color("bg", st.bg_color, palette);
        }

        {
            cimgui.c.ImGui_TableNextRow();
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Underline");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("The underline color, if underlines are enabled.");
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            color("underline", st.underline_color, palette);
        }

        const style_flags = .{
            .{ "bold", "Text will be rendered with bold weight." },
            .{ "italic", "Text will be rendered in italic style." },
            .{ "faint", "Text will be rendered with reduced intensity." },
            .{ "blink", "Text will blink." },
            .{ "inverse", "Foreground and background colors are swapped." },
            .{ "invisible", "Text will be invisible (hidden)." },
            .{ "strikethrough", "Text will have a line through it." },
        };
        inline for (style_flags) |entry| entry: {
            const style = entry[0];
            const help = entry[1];
            if (!@field(st.flags, style)) break :entry;

            cimgui.c.ImGui_TableNextRow();
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                cimgui.c.ImGui_Text(style.ptr);
                cimgui.c.ImGui_SameLine();
                widgets.helpMarker(help);
            }
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                cimgui.c.ImGui_Text("true");
            }
        }
    }

    cimgui.c.ImGui_TextDisabled("(Any styles not shown are not currently set)");
}

/// Render a style color.
pub fn color(
    id: [:0]const u8,
    c: terminal.Style.Color,
    palette: ?*const terminal.color.Palette,
) void {
    cimgui.c.ImGui_PushID(id);
    defer cimgui.c.ImGui_PopID();

    switch (c) {
        .none => cimgui.c.ImGui_Text("default"),

        .palette => |idx| {
            cimgui.c.ImGui_Text("Palette %d", idx);
            if (palette) |p| {
                const rgb = p[idx];
                var data: [3]f32 = .{
                    @as(f32, @floatFromInt(rgb.r)) / 255,
                    @as(f32, @floatFromInt(rgb.g)) / 255,
                    @as(f32, @floatFromInt(rgb.b)) / 255,
                };
                _ = cimgui.c.ImGui_ColorEdit3(
                    "color_fg",
                    &data,
                    cimgui.c.ImGuiColorEditFlags_DisplayHex |
                        cimgui.c.ImGuiColorEditFlags_NoPicker |
                        cimgui.c.ImGuiColorEditFlags_NoLabel,
                );
            }
        },

        .rgb => |rgb| {
            var data: [3]f32 = .{
                @as(f32, @floatFromInt(rgb.r)) / 255,
                @as(f32, @floatFromInt(rgb.g)) / 255,
                @as(f32, @floatFromInt(rgb.b)) / 255,
            };
            _ = cimgui.c.ImGui_ColorEdit3(
                "color_fg",
                &data,
                cimgui.c.ImGuiColorEditFlags_DisplayHex |
                    cimgui.c.ImGuiColorEditFlags_NoPicker |
                    cimgui.c.ImGuiColorEditFlags_NoLabel,
            );
        },
    }
}
