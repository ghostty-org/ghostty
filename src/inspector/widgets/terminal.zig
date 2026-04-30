const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const cimgui = @import("dcimgui");
const widgets = @import("../widgets.zig");
const terminal = @import("../../terminal/main.zig");
const modes = terminal.modes;
const Terminal = terminal.Terminal;

/// Terminal information inspector widget.
pub const Info = struct {
    /// True if we're showing the 256-color palette window.
    show_palette: bool,

    /// The various detachable headers.
    misc_header: widgets.DetachableHeader,
    layout_header: widgets.DetachableHeader,
    mouse_header: widgets.DetachableHeader,
    color_header: widgets.DetachableHeader,
    modes_header: widgets.DetachableHeader,

    /// Screen detail windows for each screen key.
    screens: ScreenMap,

    pub const empty: Info = .{
        .show_palette = false,
        .misc_header = .{},
        .layout_header = .{},
        .mouse_header = .{},
        .color_header = .{},
        .modes_header = .{},
        .screens = .{},
    };

    /// Draw the terminal info window.
    pub fn draw(
        self: *Info,
        open: bool,
        t: *Terminal,
    ) void {
        // Draw our open state if we're open.
        if (open) self.drawOpen(t);

        // Draw our detached state that draws regardless of if
        // we're open or not.
        if (self.misc_header.window("Terminal Misc")) |visible| {
            defer self.misc_header.windowEnd();
            if (visible) miscTable(t);
        }
        if (self.layout_header.window("Terminal Layout")) |visible| {
            defer self.layout_header.windowEnd();
            if (visible) layoutTable(t);
        }
        if (self.mouse_header.window("Terminal Mouse")) |visible| {
            defer self.mouse_header.windowEnd();
            if (visible) mouseTable(t);
        }
        if (self.color_header.window("Terminal Color")) |visible| {
            defer self.color_header.windowEnd();
            if (visible) colorTable(t, &self.show_palette);
        }
        if (self.modes_header.window("Terminal Modes")) |visible| {
            defer self.modes_header.windowEnd();
            if (visible) modesTable(t);
        }

        // Palette pop-out window
        if (self.show_palette) {
            defer cimgui.c.ImGui_End();
            if (cimgui.c.ImGui_Begin(
                "256-Color Palette",
                &self.show_palette,
                cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
            )) {
                palette("palette", &t.colors.palette.current);
            }
        }

        // Screen pop-out windows
        var it = self.screens.iterator();
        while (it.next()) |entry| {
            const screen = t.screens.get(entry.key) orelse {
                // Could happen if we opened up a window for a screen
                // and that screen was subsequently deinitialized. In
                // this case, hide the window.
                self.screens.remove(entry.key);
                continue;
            };

            var title_buf: [128]u8 = undefined;
            const title = std.fmt.bufPrintZ(
                &title_buf,
                "Screen: {t}",
                .{entry.key},
            ) catch "Screen";

            // Setup our next window so it has some size to it.
            const viewport = cimgui.c.ImGui_GetMainViewport();
            cimgui.c.ImGui_SetNextWindowSize(
                .{
                    .x = @min(400, viewport.*.Size.x),
                    .y = @min(300, viewport.*.Size.y),
                },
                cimgui.c.ImGuiCond_FirstUseEver,
            );

            var screen_open: bool = true;
            defer cimgui.c.ImGui_End();
            const screen_draw = cimgui.c.ImGui_Begin(
                title,
                &screen_open,
                cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
            );
            entry.value.draw(screen_draw, .{
                .screen = screen,
                .key = entry.key,
                .active_key = t.screens.active_key,
                .modify_other_keys_2 = t.flags.modify_other_keys_2,
                .color_palette = &t.colors.palette,
            });

            // If the window was closed, remove it from our map so future
            // renders don't draw it.
            if (!screen_open) self.screens.remove(entry.key);
        }
    }

    fn drawOpen(self: *Info, t: *Terminal) void {
        // Show our screens up top.
        screensTable(t, &self.screens);

        if (self.misc_header.header("Misc")) miscTable(t);
        if (self.layout_header.header("Layout")) layoutTable(t);
        if (self.mouse_header.header("Mouse")) mouseTable(t);
        if (self.color_header.header("Color")) colorTable(t, &self.show_palette);
        if (self.modes_header.header("Modes")) modesTable(t);
    }
};

pub const ScreenMap = std.EnumMap(
    terminal.ScreenSet.Key,
    widgets.screen.Info,
);

/// Render the table of possible screens with various actions.
fn screensTable(
    t: *Terminal,
    map: *ScreenMap,
) void {
    if (!cimgui.c.ImGui_BeginTable(
        "screens",
        3,
        cimgui.c.ImGuiTableFlags_Borders |
            cimgui.c.ImGuiTableFlags_RowBg |
            cimgui.c.ImGuiTableFlags_SizingFixedFit,
    )) return;
    defer cimgui.c.ImGui_EndTable();

    cimgui.c.ImGui_TableSetupColumn("Screen", cimgui.c.ImGuiTableColumnFlags_WidthFixed);
    cimgui.c.ImGui_TableSetupColumn("Status", cimgui.c.ImGuiTableColumnFlags_WidthFixed);
    cimgui.c.ImGui_TableSetupColumn("", cimgui.c.ImGuiTableColumnFlags_WidthFixed);

    // Custom header row to include help marker before "Screen"
    {
        cimgui.c.ImGui_TableNextRowEx(cimgui.c.ImGuiTableRowFlags_Headers, 0.0);
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_PushStyleVarImVec2(cimgui.c.ImGuiStyleVar_FramePadding, .{ .x = 0, .y = 0 });
            widgets.helpMarker(
                "A terminal can have multiple screens, only one of which is active at " ++
                    "a time. Each screen has its own grid, contents, and other state. " ++
                    "This section allows you to inspect the different screens managed by " ++
                    "the terminal.",
            );
            cimgui.c.ImGui_PopStyleVar();
            cimgui.c.ImGui_SameLineEx(0.0, cimgui.c.ImGui_GetStyle().*.ItemInnerSpacing.x);
            cimgui.c.ImGui_TableHeader("Screen");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            cimgui.c.ImGui_TableHeader("Status");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(2);
            cimgui.c.ImGui_TableHeader("");
        }
    }

    for (std.meta.tags(terminal.ScreenSet.Key)) |key| {
        const is_initialized = t.screens.get(key) != null;
        const is_active = t.screens.active_key == key;

        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("%s", @tagName(key).ptr);
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            if (is_active) {
                cimgui.c.ImGui_TextColored(
                    .{ .x = 0.4, .y = 1.0, .z = 0.4, .w = 1.0 },
                    "active",
                );
            } else if (is_initialized) {
                cimgui.c.ImGui_TextColored(
                    .{ .x = 0.6, .y = 0.6, .z = 0.6, .w = 1.0 },
                    "initialized",
                );
            } else {
                cimgui.c.ImGui_TextColored(
                    .{ .x = 0.4, .y = 0.4, .z = 0.4, .w = 1.0 },
                    "(not initialized)",
                );
            }
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(2);
            cimgui.c.ImGui_PushIDInt(@intFromEnum(key));
            defer cimgui.c.ImGui_PopID();
            cimgui.c.ImGui_BeginDisabled(!is_initialized);
            defer cimgui.c.ImGui_EndDisabled();
            if (cimgui.c.ImGui_Button("View")) {
                if (!map.contains(key)) {
                    map.put(key, .empty);
                }
            }
        }
    }
}

/// Table of miscellaneous terminal information.
fn miscTable(t: *Terminal) void {
    _ = cimgui.c.ImGui_BeginTable(
        "table_misc",
        2,
        cimgui.c.ImGuiTableFlags_None,
    );
    defer cimgui.c.ImGui_EndTable();

    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Working Directory");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("The current working directory reported by the shell.");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            if (t.pwd.items.len > 0) {
                cimgui.c.ImGui_Text(
                    "%.*s",
                    t.pwd.items.len,
                    t.pwd.items.ptr,
                );
            } else {
                cimgui.c.ImGui_TextDisabled("(none)");
            }
        }
    }

    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Focused");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("Whether the terminal itself is currently focused.");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            var value: bool = t.flags.focused;
            _ = cimgui.c.ImGui_Checkbox("##focused", &value);
        }
    }

    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Previous Char");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("The previously printed character, used only for the REP sequence.");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            if (t.previous_char) |c| {
                cimgui.c.ImGui_Text("U+%04X", @as(u32, c));
            } else {
                cimgui.c.ImGui_TextDisabled("(none)");
            }
        }
    }
}

/// Table of terminal layout information.
fn layoutTable(t: *Terminal) void {
    _ = cimgui.c.ImGui_BeginTable(
        "table_layout",
        2,
        cimgui.c.ImGuiTableFlags_None,
    );
    defer cimgui.c.ImGui_EndTable();

    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Grid");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("The size of the terminal grid in columns and rows.");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            cimgui.c.ImGui_Text(
                "%dc x %dr",
                t.cols,
                t.rows,
            );
        }
    }

    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Pixels");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("The size of the terminal grid in pixels.");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            cimgui.c.ImGui_Text(
                "%dw x %dh",
                t.width_px,
                t.height_px,
            );
        }
    }

    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Scroll Region");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("The scrolling region boundaries (top, bottom, left, right).");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            cimgui.c.ImGui_PushItemWidth(cimgui.c.ImGui_CalcTextSize("00000").x);
            defer cimgui.c.ImGui_PopItemWidth();

            var override = t.scrolling_region;
            var changed = false;

            cimgui.c.ImGui_AlignTextToFramePadding();
            cimgui.c.ImGui_Text("T:");
            cimgui.c.ImGui_SameLine();
            if (cimgui.c.ImGui_InputScalar(
                "##scroll_top",
                cimgui.c.ImGuiDataType_U16,
                &override.top,
            )) {
                override.top = @min(override.top, t.rows -| 1);
                changed = true;
            }

            cimgui.c.ImGui_SameLine();
            cimgui.c.ImGui_Text("B:");
            cimgui.c.ImGui_SameLine();
            if (cimgui.c.ImGui_InputScalar(
                "##scroll_bottom",
                cimgui.c.ImGuiDataType_U16,
                &override.bottom,
            )) {
                override.bottom = @min(override.bottom, t.rows -| 1);
                changed = true;
            }

            cimgui.c.ImGui_SameLine();
            cimgui.c.ImGui_Text("L:");
            cimgui.c.ImGui_SameLine();
            if (cimgui.c.ImGui_InputScalar(
                "##scroll_left",
                cimgui.c.ImGuiDataType_U16,
                &override.left,
            )) {
                override.left = @min(override.left, t.cols -| 1);
                changed = true;
            }

            cimgui.c.ImGui_SameLine();
            cimgui.c.ImGui_Text("R:");
            cimgui.c.ImGui_SameLine();
            if (cimgui.c.ImGui_InputScalar(
                "##scroll_right",
                cimgui.c.ImGuiDataType_U16,
                &override.right,
            )) {
                override.right = @min(override.right, t.cols -| 1);
                changed = true;
            }

            if (changed and
                override.top < override.bottom and
                override.left < override.right)
            {
                t.scrolling_region = override;
            }
        }
    }
}

/// Table of mouse-related terminal information.
fn mouseTable(t: *Terminal) void {
    _ = cimgui.c.ImGui_BeginTable(
        "table_mouse",
        2,
        cimgui.c.ImGuiTableFlags_None,
    );
    defer cimgui.c.ImGui_EndTable();

    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Event Mode");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("The mouse event reporting mode set by the application.");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            cimgui.c.ImGui_Text("%s", @tagName(t.flags.mouse_event).ptr);
        }
    }

    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Format");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("The mouse event encoding format.");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            cimgui.c.ImGui_Text("%s", @tagName(t.flags.mouse_format).ptr);
        }
    }

    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Shape");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("The current mouse cursor shape set by the application.");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            cimgui.c.ImGui_Text("%s", @tagName(t.mouse_shape).ptr);
        }
    }

    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Shift Capture");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("XTSHIFTESCAPE state for capturing shift in mouse protocol.");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            if (t.flags.mouse_shift_capture == .null) {
                cimgui.c.ImGui_TextDisabled("(unset)");
            } else {
                cimgui.c.ImGui_Text("%s", @tagName(t.flags.mouse_shift_capture).ptr);
            }
        }
    }
}

/// Table of color-related terminal information.
fn colorTable(
    t: *Terminal,
    show_palette: *bool,
) void {
    cimgui.c.ImGui_TextWrapped(
        "Color state for the terminal. Note these colors only apply " ++
            "to the palette and unstyled colors. Many modern terminal " ++
            "applications use direct RGB colors which are not reflected here.",
    );
    cimgui.c.ImGui_Separator();

    _ = cimgui.c.ImGui_BeginTable(
        "table_color",
        2,
        cimgui.c.ImGuiTableFlags_None,
    );
    defer cimgui.c.ImGui_EndTable();

    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Background");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("Unstyled cell background color.");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            _ = dynamicRGB(
                "bg_color",
                &t.colors.background,
            );
        }
    }

    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Foreground");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("Unstyled cell foreground color.");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            _ = dynamicRGB(
                "fg_color",
                &t.colors.foreground,
            );
        }
    }

    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Cursor");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("Cursor coloring set by escape sequences.");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            _ = dynamicRGB(
                "cursor_color",
                &t.colors.cursor,
            );
        }
    }

    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Palette");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("The 256-color palette.");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            if (cimgui.c.ImGui_Button("View")) {
                show_palette.* = true;
            }
        }
    }
}

/// Table of terminal modes.
fn modesTable(t: *Terminal) void {
    _ = cimgui.c.ImGui_BeginTable(
        "table_modes",
        3,
        cimgui.c.ImGuiTableFlags_SizingFixedFit |
            cimgui.c.ImGuiTableFlags_RowBg,
    );
    defer cimgui.c.ImGui_EndTable();

    {
        cimgui.c.ImGui_TableSetupColumn("", cimgui.c.ImGuiTableColumnFlags_NoResize);
        cimgui.c.ImGui_TableSetupColumn("Number", cimgui.c.ImGuiTableColumnFlags_PreferSortAscending);
        cimgui.c.ImGui_TableSetupColumn("Name", cimgui.c.ImGuiTableColumnFlags_WidthStretch);
        cimgui.c.ImGui_TableHeadersRow();
    }

    inline for (@typeInfo(terminal.Mode).@"enum".fields) |field| {
        @setEvalBranchQuota(6000);
        const tag: modes.ModeTag = @bitCast(@as(modes.ModeTag.Backing, field.value));

        cimgui.c.ImGui_TableNextRow();
        cimgui.c.ImGui_PushIDInt(@intCast(field.value));
        defer cimgui.c.ImGui_PopID();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            var value: bool = t.modes.get(@field(terminal.Mode, field.name));
            _ = cimgui.c.ImGui_Checkbox("##checkbox", &value);
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            cimgui.c.ImGui_Text(
                "%s%d",
                if (tag.ansi) "" else "?",
                @as(u32, @intCast(tag.value)),
            );
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(2);
            const name = std.fmt.comptimePrint("{s}", .{field.name});
            cimgui.c.ImGui_Text("%s", name.ptr);
        }
    }
}

/// Render a DynamicRGB color.
fn dynamicRGB(
    label: [:0]const u8,
    rgb: *terminal.color.DynamicRGB,
) bool {
    _ = cimgui.c.ImGui_BeginTable(
        label,
        if (rgb.override != null) 2 else 1,
        cimgui.c.ImGuiTableFlags_SizingFixedFit,
    );
    defer cimgui.c.ImGui_EndTable();

    if (rgb.override != null) cimgui.c.ImGui_TableSetupColumn(
        "##label",
        cimgui.c.ImGuiTableColumnFlags_WidthFixed,
    );
    cimgui.c.ImGui_TableSetupColumn(
        "##value",
        cimgui.c.ImGuiTableColumnFlags_WidthStretch,
    );

    if (rgb.override) |c| {
        cimgui.c.ImGui_TableNextRow();
        _ = cimgui.c.ImGui_TableSetColumnIndex(0);
        cimgui.c.ImGui_Text("override:");
        cimgui.c.ImGui_SameLine();
        widgets.helpMarker("Overridden color set by escape sequences.");

        _ = cimgui.c.ImGui_TableSetColumnIndex(1);
        var col = [3]f32{
            @as(f32, @floatFromInt(c.r)) / 255.0,
            @as(f32, @floatFromInt(c.g)) / 255.0,
            @as(f32, @floatFromInt(c.b)) / 255.0,
        };
        _ = cimgui.c.ImGui_ColorEdit3(
            "##override",
            &col,
            cimgui.c.ImGuiColorEditFlags_None,
        );
    }

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    if (rgb.default) |c| {
        if (rgb.override != null) {
            cimgui.c.ImGui_Text("default:");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("Default color from configuration.");

            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
        }

        var col = [3]f32{
            @as(f32, @floatFromInt(c.r)) / 255.0,
            @as(f32, @floatFromInt(c.g)) / 255.0,
            @as(f32, @floatFromInt(c.b)) / 255.0,
        };
        _ = cimgui.c.ImGui_ColorEdit3(
            "##default",
            &col,
            cimgui.c.ImGuiColorEditFlags_None,
        );
    } else {
        cimgui.c.ImGui_TextDisabled("(unset)");
    }

    return false;
}

/// Render a color palette as a 16x16 grid of color buttons.
fn palette(
    label: [:0]const u8,
    pal: *const terminal.color.Palette,
) void {
    cimgui.c.ImGui_PushID(label);
    defer cimgui.c.ImGui_PopID();

    for (0..16) |row| {
        for (0..16) |col| {
            const idx = row * 16 + col;
            const rgb = pal[idx];
            var col_arr = [3]f32{
                @as(f32, @floatFromInt(rgb.r)) / 255.0,
                @as(f32, @floatFromInt(rgb.g)) / 255.0,
                @as(f32, @floatFromInt(rgb.b)) / 255.0,
            };

            if (col > 0) cimgui.c.ImGui_SameLine();

            cimgui.c.ImGui_PushIDInt(@intCast(idx));
            _ = cimgui.c.ImGui_ColorEdit3(
                "##color",
                &col_arr,
                cimgui.c.ImGuiColorEditFlags_NoInputs,
            );
            if (cimgui.c.ImGui_IsItemHovered(cimgui.c.ImGuiHoveredFlags_DelayShort)) {
                cimgui.c.ImGui_SetTooltip(
                    "%d: #%02X%02X%02X",
                    idx,
                    rgb.r,
                    rgb.g,
                    rgb.b,
                );
            }
            cimgui.c.ImGui_PopID();
        }
    }
}
