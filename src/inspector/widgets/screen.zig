const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const cimgui = @import("dcimgui");
const widgets = @import("../widgets.zig");
const units = @import("../units.zig");
const terminal = @import("../../terminal/main.zig");
const stylepkg = @import("../../terminal/style.zig");

/// Window names for the screen dockspace.
const window_info = "Info";
const window_cell = "Cell";
const window_pagelist = "PageList";

/// Screen information inspector widget.
pub const Info = struct {
    pagelist: widgets.pagelist.Inspector,
    cell_chooser: widgets.pagelist.CellChooser,

    pub const empty: Info = .{
        .pagelist = .empty,
        .cell_chooser = .empty,
    };

    /// Draw the screen info contents.
    pub fn draw(self: *Info, open: bool, data: struct {
        /// The screen that we're inspecting.
        screen: *terminal.Screen,

        /// Which screen key we're viewing.
        key: terminal.ScreenSet.Key,

        /// Which screen is active (primary or alternate).
        active_key: terminal.ScreenSet.Key,

        /// Whether xterm modify other keys mode 2 is enabled.
        modify_other_keys_2: bool,

        /// Color palette for cursor color resolution.
        color_palette: *const terminal.color.DynamicPalette,
    }) void {
        // Create the dockspace for this screen
        const dockspace_id = cimgui.c.ImGui_GetID("Screen Dockspace");
        _ = createDockSpace(dockspace_id);

        const screen = data.screen;

        // Info window
        info: {
            defer cimgui.c.ImGui_End();
            if (!cimgui.c.ImGui_Begin(
                window_info,
                null,
                cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
            )) break :info;

            if (cimgui.c.ImGui_CollapsingHeader(
                "Cursor",
                cimgui.c.ImGuiTreeNodeFlags_DefaultOpen,
            )) {
                cursorTable(&screen.cursor);
                cimgui.c.ImGui_Separator();
                cursorStyle(
                    &screen.cursor,
                    &data.color_palette.current,
                );
            }

            if (cimgui.c.ImGui_CollapsingHeader(
                "Keyboard",
                cimgui.c.ImGuiTreeNodeFlags_DefaultOpen,
            )) keyboardTable(
                screen,
                data.modify_other_keys_2,
            );

            if (cimgui.c.ImGui_CollapsingHeader(
                "Kitty Graphics",
                cimgui.c.ImGuiTreeNodeFlags_DefaultOpen,
            )) kittyGraphicsTable(&screen.kitty_images);

            if (cimgui.c.ImGui_CollapsingHeader(
                "Other Screen State",
                cimgui.c.ImGuiTreeNodeFlags_DefaultOpen,
            )) internalStateTable(screen);
        }

        // Cell window
        cell: {
            defer cimgui.c.ImGui_End();
            if (!cimgui.c.ImGui_Begin(
                window_cell,
                null,
                cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
            )) break :cell;
            self.cell_chooser.draw(&screen.pages);
        }

        // PageList window
        pagelist: {
            defer cimgui.c.ImGui_End();
            if (!cimgui.c.ImGui_Begin(
                window_pagelist,
                null,
                cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
            )) break :pagelist;
            self.pagelist.draw(&screen.pages);
        }

        // The remainder is the open state
        if (!open) return;

        // Show warning if viewing an inactive screen
        if (data.key != data.active_key) {
            cimgui.c.ImGui_TextColored(
                .{ .x = 1.0, .y = 0.8, .z = 0.0, .w = 1.0 },
                "⚠ Viewing inactive screen",
            );
            cimgui.c.ImGui_Separator();
        }
    }

    /// Create the dock space for the screen inspector. This creates
    /// a dedicated dock space for the screen inspector windows. But they
    /// can of course be undocked and moved around as desired.
    fn createDockSpace(dockspace_id: cimgui.c.ImGuiID) bool {
        // Check if we need to set up the dockspace
        const setup = cimgui.ImGui_DockBuilderGetNode(dockspace_id) == null;

        if (setup) {
            // Register our dockspace node
            assert(cimgui.ImGui_DockBuilderAddNodeEx(
                dockspace_id,
                cimgui.ImGuiDockNodeFlagsPrivate.DockSpace,
            ) == dockspace_id);

            // Dock windows into the space
            cimgui.ImGui_DockBuilderDockWindow(window_info, dockspace_id);
            cimgui.ImGui_DockBuilderDockWindow(window_cell, dockspace_id);
            cimgui.ImGui_DockBuilderDockWindow(window_pagelist, dockspace_id);
            cimgui.ImGui_DockBuilderFinish(dockspace_id);
        }

        // Create the dockspace
        assert(cimgui.c.ImGui_DockSpaceEx(
            dockspace_id,
            .{ .x = 0, .y = 0 },
            cimgui.c.ImGuiDockNodeFlags_None,
            null,
        ) == dockspace_id);
        return setup;
    }
};

/// Render cursor state with a table of cursor-specific fields.
pub fn cursorTable(
    cursor: *const terminal.Screen.Cursor,
) void {
    if (!cimgui.c.ImGui_BeginTable(
        "table_cursor",
        2,
        cimgui.c.ImGuiTableFlags_None,
    )) return;
    defer cimgui.c.ImGui_EndTable();

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Position (x, y)");
    cimgui.c.ImGui_SameLine();
    widgets.helpMarker("The current cursor position in the terminal grid (0-indexed).");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    cimgui.c.ImGui_Text("(%d, %d)", cursor.x, cursor.y);

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Hyperlink");
    cimgui.c.ImGui_SameLine();
    widgets.helpMarker("The active OSC8 hyperlink for newly printed characters.");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    if (cursor.hyperlink) |link| {
        cimgui.c.ImGui_Text("%.*s", link.uri.len, link.uri.ptr);
    } else {
        cimgui.c.ImGui_TextDisabled("(none)");
    }

    {
        cimgui.c.ImGui_TableNextRow();
        _ = cimgui.c.ImGui_TableSetColumnIndex(0);
        cimgui.c.ImGui_Text("Pending Wrap");
        cimgui.c.ImGui_SameLine();
        widgets.helpMarker("The 'last column flag' (LCF). If set, the next character will force a soft-wrap to the next line.");
        _ = cimgui.c.ImGui_TableSetColumnIndex(1);
        var value: bool = cursor.pending_wrap;
        _ = cimgui.c.ImGui_Checkbox("##pending_wrap", &value);
    }

    {
        cimgui.c.ImGui_TableNextRow();
        _ = cimgui.c.ImGui_TableSetColumnIndex(0);
        cimgui.c.ImGui_Text("Protected");
        cimgui.c.ImGui_SameLine();
        widgets.helpMarker("If enabled, new characters will have the protected attribute set, preventing erasure by certain sequences.");
        _ = cimgui.c.ImGui_TableSetColumnIndex(1);
        var value: bool = cursor.protected;
        _ = cimgui.c.ImGui_Checkbox("##protected", &value);
    }
}

/// Render cursor style information using the shared style table.
pub fn cursorStyle(cursor: *const terminal.Screen.Cursor, palette: ?*const terminal.color.Palette) void {
    widgets.style.table(cursor.style, palette);
}

/// Render keyboard information with a table.
fn keyboardTable(
    screen: *const terminal.Screen,
    modify_other_keys_2: bool,
) void {
    if (!cimgui.c.ImGui_BeginTable(
        "table_keyboard",
        2,
        cimgui.c.ImGuiTableFlags_None,
    )) return;
    defer cimgui.c.ImGui_EndTable();

    const kitty_flags = screen.kitty_keyboard.current();

    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Mode");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            const mode = if (kitty_flags.int() != 0) "kitty" else "legacy";
            cimgui.c.ImGui_Text("%s", mode.ptr);
        }
    }

    if (kitty_flags.int() != 0) {
        const Flags = @TypeOf(kitty_flags);
        inline for (@typeInfo(Flags).@"struct".fields) |field| {
            {
                const value = @field(kitty_flags, field.name);

                cimgui.c.ImGui_TableNextRow();
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                    const field_name = std.fmt.comptimePrint("{s}", .{field.name});
                    cimgui.c.ImGui_Text("%s", field_name.ptr);
                }
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                    cimgui.c.ImGui_Text(
                        "%s",
                        if (value) "true".ptr else "false".ptr,
                    );
                }
            }
        }
    } else {
        {
            cimgui.c.ImGui_TableNextRow();
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                cimgui.c.ImGui_Text("Xterm modify keys");
            }
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                cimgui.c.ImGui_Text(
                    "%s",
                    if (modify_other_keys_2) "true".ptr else "false".ptr,
                );
            }
        }
    } // keyboard mode info
}

/// Render kitty graphics information table.
pub fn kittyGraphicsTable(
    kitty_images: *const terminal.kitty.graphics.ImageStorage,
) void {
    if (!kitty_images.enabled()) {
        cimgui.c.ImGui_TextDisabled("(Kitty graphics are disabled)");
        return;
    }

    if (!cimgui.c.ImGui_BeginTable(
        "##kitty_graphics",
        2,
        cimgui.c.ImGuiTableFlags_None,
    )) return;
    defer cimgui.c.ImGui_EndTable();

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Memory Usage");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    cimgui.c.ImGui_Text("%d bytes (%d KiB)", kitty_images.total_bytes, units.toKibiBytes(kitty_images.total_bytes));

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Memory Limit");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    cimgui.c.ImGui_Text("%d bytes (%d KiB)", kitty_images.total_limit, units.toKibiBytes(kitty_images.total_limit));

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Image Count");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    cimgui.c.ImGui_Text("%d", kitty_images.images.count());

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Placement Count");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    cimgui.c.ImGui_Text("%d", kitty_images.placements.count());

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Image Loading");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    cimgui.c.ImGui_Text("%s", if (kitty_images.loading != null) "true".ptr else "false".ptr);
}

/// Render internal terminal state table.
pub fn internalStateTable(
    screen: *const terminal.Screen,
) void {
    const pages = &screen.pages;

    if (!cimgui.c.ImGui_BeginTable(
        "##terminal_state",
        2,
        cimgui.c.ImGuiTableFlags_None,
    )) return;
    defer cimgui.c.ImGui_EndTable();

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Memory Usage");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    cimgui.c.ImGui_Text("%d bytes (%d KiB)", pages.page_size, units.toKibiBytes(pages.page_size));

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Memory Limit");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    cimgui.c.ImGui_Text("%d bytes (%d KiB)", pages.maxSize(), units.toKibiBytes(pages.maxSize()));

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Viewport Location");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    cimgui.c.ImGui_Text("%s", @tagName(pages.viewport).ptr);

    {
        cimgui.c.ImGui_TableNextRow();
        _ = cimgui.c.ImGui_TableSetColumnIndex(0);
        cimgui.c.ImGui_Text("Semantic Content");
        cimgui.c.ImGui_SameLine();
        widgets.helpMarker("Whether semantic prompt markers (OSC 133) have been seen.");
        _ = cimgui.c.ImGui_TableSetColumnIndex(1);
        var value: bool = screen.flags.semantic_content;
        _ = cimgui.c.ImGui_Checkbox("##semantic_content", &value);
    }
}
