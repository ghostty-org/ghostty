const std = @import("std");
const cimgui = @import("dcimgui");
const terminal = @import("../../terminal/main.zig");
const stylepkg = @import("../../terminal/style.zig");
const widgets = @import("../widgets.zig");
const units = @import("../units.zig");

const PageList = terminal.PageList;

/// PageList inspector widget.
pub const Inspector = struct {
    pub const empty: Inspector = .{};

    pub fn draw(_: *const Inspector, pages: *PageList) void {
        cimgui.c.ImGui_TextWrapped(
            "PageList manages the backing pages that hold scrollback and the active " ++
                "terminal grid. Each page is a contiguous memory buffer with its " ++
                "own rows, cells, style set, grapheme map, and hyperlink storage.",
        );

        if (cimgui.c.ImGui_CollapsingHeader(
            "Overview",
            cimgui.c.ImGuiTreeNodeFlags_DefaultOpen,
        )) {
            summaryTable(pages);
        }

        if (cimgui.c.ImGui_CollapsingHeader(
            "Scrollbar & Regions",
            cimgui.c.ImGuiTreeNodeFlags_DefaultOpen,
        )) {
            cimgui.c.ImGui_SeparatorText("Scrollbar");
            scrollbarInfo(pages);
            cimgui.c.ImGui_SeparatorText("Regions");
            regionsTable(pages);
        }

        if (cimgui.c.ImGui_CollapsingHeader(
            "Tracked Pins",
            cimgui.c.ImGuiTreeNodeFlags_DefaultOpen,
        )) {
            trackedPinsTable(pages);
        }

        if (cimgui.c.ImGui_CollapsingHeader(
            "Pages",
            cimgui.c.ImGuiTreeNodeFlags_DefaultOpen,
        )) {
            widgets.helpMarker(
                "Pages are shown most-recent first. Each page holds a grid of rows/cells " ++
                    "plus metadata tables for styles, graphemes, strings, and hyperlinks.",
            );

            const active_pin = pages.getTopLeft(.active);
            const viewport_pin = pages.getTopLeft(.viewport);

            var row_offset = pages.total_rows;
            var index: usize = pages.totalPages();
            var node = pages.pages.last;
            while (node) |page_node| : (node = page_node.prev) {
                const page = &page_node.data;
                row_offset -= page.size.rows;
                index -= 1;

                // We use our location as the ID so that even if reallocations
                // happen we remain open if we're open already.
                cimgui.c.ImGui_PushIDInt(@intCast(index));
                defer cimgui.c.ImGui_PopID();

                // Open up the tree node.
                if (!widgets.page.treeNode(.{
                    .page = page,
                    .index = index,
                    .row_range = .{ row_offset, row_offset + page.size.rows - 1 },
                    .active = node == active_pin.node,
                    .viewport = node == viewport_pin.node,
                })) continue;
                defer cimgui.c.ImGui_TreePop();
                widgets.page.inspector(page);
            }
        }
    }
};

fn summaryTable(pages: *const PageList) void {
    if (!cimgui.c.ImGui_BeginTable(
        "pagelist_summary",
        3,
        cimgui.c.ImGuiTableFlags_BordersInnerV |
            cimgui.c.ImGuiTableFlags_RowBg |
            cimgui.c.ImGuiTableFlags_SizingFixedFit,
    )) return;
    defer cimgui.c.ImGui_EndTable();

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Active Grid");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    widgets.helpMarker("Active viewport size in columns x rows.");
    _ = cimgui.c.ImGui_TableSetColumnIndex(2);
    cimgui.c.ImGui_Text("%dc x %dr", pages.cols, pages.rows);

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Pages");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    widgets.helpMarker("Total number of pages in the linked list.");
    _ = cimgui.c.ImGui_TableSetColumnIndex(2);
    cimgui.c.ImGui_Text("%d", pages.totalPages());

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Total Rows");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    widgets.helpMarker("Total rows represented by scrollback + active area.");
    _ = cimgui.c.ImGui_TableSetColumnIndex(2);
    cimgui.c.ImGui_Text("%d", pages.total_rows);

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Page Bytes");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    widgets.helpMarker("Total bytes allocated for active pages.");
    _ = cimgui.c.ImGui_TableSetColumnIndex(2);
    cimgui.c.ImGui_Text(
        "%d KiB",
        units.toKibiBytes(pages.page_size),
    );

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Max Size");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    widgets.helpMarker(
        \\Maximum bytes before pages must be evicated. The total
        \\used bytes may be higher due to minimum individual page
        \\sizes but the next allocation that would exceed this limit
        \\will evict pages from the front of the list to free up space.
    );
    _ = cimgui.c.ImGui_TableSetColumnIndex(2);
    cimgui.c.ImGui_Text(
        "%d KiB",
        units.toKibiBytes(pages.maxSize()),
    );

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Viewport");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    widgets.helpMarker("Current viewport anchoring mode.");
    _ = cimgui.c.ImGui_TableSetColumnIndex(2);
    cimgui.c.ImGui_Text("%s", @tagName(pages.viewport).ptr);

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Tracked Pins");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    widgets.helpMarker("Number of pins tracked for automatic updates.");
    _ = cimgui.c.ImGui_TableSetColumnIndex(2);
    cimgui.c.ImGui_Text("%d", pages.countTrackedPins());
}

fn scrollbarInfo(pages: *PageList) void {
    const scrollbar = pages.scrollbar();

    // If we have a scrollbar, show it.
    if (scrollbar.total > 0) {
        var delta_row: isize = 0;
        scrollbarWidget(&scrollbar, &delta_row);
        if (delta_row != 0) {
            pages.scroll(.{ .delta_row = delta_row });
        }
    }

    if (!cimgui.c.ImGui_BeginTable(
        "scrollbar_info",
        3,
        cimgui.c.ImGuiTableFlags_BordersInnerV |
            cimgui.c.ImGuiTableFlags_RowBg |
            cimgui.c.ImGuiTableFlags_SizingFixedFit,
    )) return;
    defer cimgui.c.ImGui_EndTable();

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Total");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    widgets.helpMarker("Total number of scrollable rows including scrollback and active area.");
    _ = cimgui.c.ImGui_TableSetColumnIndex(2);
    cimgui.c.ImGui_Text("%d", scrollbar.total);

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Offset");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    widgets.helpMarker("Current scroll position as row offset from the top of scrollback.");
    _ = cimgui.c.ImGui_TableSetColumnIndex(2);
    cimgui.c.ImGui_Text("%d", scrollbar.offset);

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Length");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    widgets.helpMarker("Number of rows visible in the viewport.");
    _ = cimgui.c.ImGui_TableSetColumnIndex(2);
    cimgui.c.ImGui_Text("%d", scrollbar.len);
}

fn regionsTable(pages: *PageList) void {
    if (!cimgui.c.ImGui_BeginTable(
        "pagelist_regions",
        4,
        cimgui.c.ImGuiTableFlags_BordersInnerV |
            cimgui.c.ImGuiTableFlags_RowBg |
            cimgui.c.ImGuiTableFlags_SizingFixedFit,
    )) return;
    defer cimgui.c.ImGui_EndTable();

    cimgui.c.ImGui_TableSetupColumn("Region", cimgui.c.ImGuiTableColumnFlags_WidthFixed);
    cimgui.c.ImGui_TableSetupColumn("", cimgui.c.ImGuiTableColumnFlags_WidthFixed);
    cimgui.c.ImGui_TableSetupColumn("Top-Left", cimgui.c.ImGuiTableColumnFlags_WidthFixed);
    cimgui.c.ImGui_TableSetupColumn("Bottom-Right", cimgui.c.ImGuiTableColumnFlags_WidthStretch);
    cimgui.c.ImGui_TableHeadersRow();

    inline for (comptime std.meta.tags(terminal.point.Tag)) |tag| {
        regionRow(pages, tag);
    }
}

fn regionRow(pages: *const PageList, comptime tag: terminal.point.Tag) void {
    const tl_pin = pages.getTopLeft(tag);
    const br_pin = pages.getBottomRight(tag);

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("%s", @tagName(tag).ptr);

    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    widgets.helpMarker(comptime regionHelpText(tag));

    _ = cimgui.c.ImGui_TableSetColumnIndex(2);
    if (pages.pointFromPin(tag, tl_pin)) |pt| {
        const coord = pt.coord();
        cimgui.c.ImGui_Text("(%d, %d)", coord.x, coord.y);
    } else {
        cimgui.c.ImGui_TextDisabled("(n/a)");
    }

    _ = cimgui.c.ImGui_TableSetColumnIndex(3);
    if (br_pin) |br| {
        if (pages.pointFromPin(tag, br)) |pt| {
            const coord = pt.coord();
            cimgui.c.ImGui_Text("(%d, %d)", coord.x, coord.y);
        } else {
            cimgui.c.ImGui_TextDisabled("(n/a)");
        }
    } else {
        cimgui.c.ImGui_TextDisabled("(empty)");
    }
}

fn regionHelpText(comptime tag: terminal.point.Tag) [:0]const u8 {
    return switch (tag) {
        .active => "The active area where a running program can jump the cursor " ++
            "and make changes. This is the 'editable' part of the screen. " ++
            "Bottom-right includes the full height of the screen, including " ++
            "rows that may not be written yet.",
        .viewport => "The visible viewport. If the user has scrolled, top-left changes. " ++
            "Bottom-right is the last written row from the top-left.",
        .screen => "Top-left is the furthest back in scrollback history. Bottom-right " ++
            "is the last written row. Unlike 'active', this only contains " ++
            "written rows.",
        .history => "Same top-left as 'screen' but bottom-right is the line just before " ++
            "the top of 'active'. Contains only the scrollback history.",
    };
}

fn trackedPinsTable(pages: *const PageList) void {
    if (!cimgui.c.ImGui_BeginTable(
        "tracked_pins",
        5,
        cimgui.c.ImGuiTableFlags_Borders |
            cimgui.c.ImGuiTableFlags_RowBg |
            cimgui.c.ImGuiTableFlags_SizingFixedFit,
    )) return;
    defer cimgui.c.ImGui_EndTable();

    cimgui.c.ImGui_TableSetupColumn("Index", cimgui.c.ImGuiTableColumnFlags_WidthFixed);
    cimgui.c.ImGui_TableSetupColumn("Pin", cimgui.c.ImGuiTableColumnFlags_WidthFixed);
    cimgui.c.ImGui_TableSetupColumn("Context", cimgui.c.ImGuiTableColumnFlags_WidthFixed);
    cimgui.c.ImGui_TableSetupColumn("Dirty", cimgui.c.ImGuiTableColumnFlags_WidthFixed);
    cimgui.c.ImGui_TableSetupColumn("State", cimgui.c.ImGuiTableColumnFlags_WidthFixed);
    cimgui.c.ImGui_TableHeadersRow();

    const active_pin = pages.getTopLeft(.active);
    const viewport_pin = pages.getTopLeft(.viewport);

    for (pages.trackedPins(), 0..) |tracked, idx| {
        const pin = tracked.*;
        cimgui.c.ImGui_TableNextRow();
        _ = cimgui.c.ImGui_TableSetColumnIndex(0);
        cimgui.c.ImGui_Text("%d", idx);

        _ = cimgui.c.ImGui_TableSetColumnIndex(1);
        if (pin.garbage) {
            cimgui.c.ImGui_TextColored(.{ .x = 1.0, .y = 0.5, .z = 0.3, .w = 1.0 }, "(%d, %d)", pin.x, pin.y);
        } else {
            cimgui.c.ImGui_Text("(%d, %d)", pin.x, pin.y);
        }

        _ = cimgui.c.ImGui_TableSetColumnIndex(2);
        if (pages.pointFromPin(.screen, pin)) |pt| {
            const coord = pt.coord();
            cimgui.c.ImGui_Text(
                "screen (%d, %d)",
                coord.x,
                coord.y,
            );
        } else {
            cimgui.c.ImGui_TextDisabled("screen (out of range)");
        }

        _ = cimgui.c.ImGui_TableSetColumnIndex(3);
        const dirty = pin.isDirty();
        if (dirty) {
            cimgui.c.ImGui_TextColored(.{ .x = 1.0, .y = 0.4, .z = 0.4, .w = 1.0 }, "dirty");
        } else {
            cimgui.c.ImGui_TextDisabled("clean");
        }

        _ = cimgui.c.ImGui_TableSetColumnIndex(4);
        if (pin.eql(active_pin)) {
            cimgui.c.ImGui_TextColored(.{ .x = 0.4, .y = 0.9, .z = 0.4, .w = 1.0 }, "active top");
        } else if (pin.eql(viewport_pin)) {
            cimgui.c.ImGui_TextColored(.{ .x = 0.4, .y = 0.8, .z = 1.0, .w = 1.0 }, "viewport top");
        } else if (pin.garbage) {
            cimgui.c.ImGui_TextColored(.{ .x = 1.0, .y = 0.5, .z = 0.3, .w = 1.0 }, "garbage");
        } else if (tracked == pages.viewport_pin) {
            cimgui.c.ImGui_Text("viewport pin");
        } else {
            cimgui.c.ImGui_TextDisabled("tracked");
        }
    }
}

fn scrollbarWidget(
    scrollbar: *const PageList.Scrollbar,
    delta_row: *isize,
) void {
    delta_row.* = 0;

    const avail_width = cimgui.c.ImGui_GetContentRegionAvail().x;
    const bar_height: f32 = cimgui.c.ImGui_GetFrameHeight();
    const cursor_pos = cimgui.c.ImGui_GetCursorScreenPos();

    const total_f: f32 = @floatFromInt(scrollbar.total);
    const offset_f: f32 = @floatFromInt(scrollbar.offset);
    const len_f: f32 = @floatFromInt(scrollbar.len);

    const grab_start = (offset_f / total_f) * avail_width;
    const grab_width = @max((len_f / total_f) * avail_width, 4.0);

    const draw_list = cimgui.c.ImGui_GetWindowDrawList();
    const bg_color = cimgui.c.ImGui_GetColorU32(cimgui.c.ImGuiCol_ScrollbarBg);
    const grab_color = cimgui.c.ImGui_GetColorU32(cimgui.c.ImGuiCol_ScrollbarGrab);

    const bg_min: cimgui.c.ImVec2 = cursor_pos;
    const bg_max: cimgui.c.ImVec2 = .{ .x = cursor_pos.x + avail_width, .y = cursor_pos.y + bar_height };
    cimgui.c.ImDrawList_AddRectFilledEx(
        draw_list,
        bg_min,
        bg_max,
        bg_color,
        0,
        0,
    );

    const grab_min: cimgui.c.ImVec2 = .{
        .x = cursor_pos.x + grab_start,
        .y = cursor_pos.y,
    };
    const grab_max: cimgui.c.ImVec2 = .{
        .x = cursor_pos.x + grab_start + grab_width,
        .y = cursor_pos.y + bar_height,
    };
    cimgui.c.ImDrawList_AddRectFilledEx(
        draw_list,
        grab_min,
        grab_max,
        grab_color,
        0,
        0,
    );
    _ = cimgui.c.ImGui_InvisibleButton(
        "scrollbar_drag",
        .{ .x = avail_width, .y = bar_height },
        0,
    );
    if (cimgui.c.ImGui_IsItemActive()) {
        const drag_delta = cimgui.c.ImGui_GetMouseDragDelta(
            cimgui.c.ImGuiMouseButton_Left,
            0.0,
        );
        if (drag_delta.x != 0) {
            const row_delta = (drag_delta.x / avail_width) * total_f;
            delta_row.* = @intFromFloat(row_delta);
            cimgui.c.ImGui_ResetMouseDragDelta();
        }
    }

    if (cimgui.c.ImGui_IsItemHovered(cimgui.c.ImGuiHoveredFlags_DelayShort)) {
        cimgui.c.ImGui_SetTooltip(
            "offset=%d len=%d total=%d",
            scrollbar.offset,
            scrollbar.len,
            scrollbar.total,
        );
    }
}

/// Grid inspector widget for choosing and inspecting a specific cell.
pub const CellChooser = struct {
    lookup_region: terminal.point.Tag,
    lookup_coord: terminal.point.Coordinate,
    cell_info: CellInfo,

    pub const empty: CellChooser = .{
        .lookup_region = .viewport,
        .lookup_coord = .{ .x = 0, .y = 0 },
        .cell_info = .empty,
    };

    pub fn draw(
        self: *CellChooser,
        pages: *const PageList,
    ) void {
        cimgui.c.ImGui_TextWrapped(
            "Inspect a cell by choosing a coordinate space and entering the X/Y position. " ++
                "The inspector resolves the point into the page list and displays the cell contents.",
        );

        cimgui.c.ImGui_SeparatorText("Cell Inspector");

        const region_max = maxCoord(pages, self.lookup_region);
        if (region_max) |coord| {
            self.lookup_coord.x = @min(self.lookup_coord.x, coord.x);
            self.lookup_coord.y = @min(self.lookup_coord.y, coord.y);
        } else {
            self.lookup_coord = .{ .x = 0, .y = 0 };
        }

        {
            const disabled = region_max == null;
            cimgui.c.ImGui_BeginDisabled(disabled);
            defer cimgui.c.ImGui_EndDisabled();

            const preview = @tagName(self.lookup_region);
            const combo_width = comptime blk: {
                var max_len: usize = 0;
                for (std.meta.tags(terminal.point.Tag)) |tag| {
                    max_len = @max(max_len, @tagName(tag).len);
                }
                break :blk max_len + 4;
            };
            cimgui.c.ImGui_SetNextItemWidth(cimgui.c.ImGui_CalcTextSize("X" ** combo_width).x);
            if (cimgui.c.ImGui_BeginCombo(
                "##grid_region",
                preview.ptr,
                cimgui.c.ImGuiComboFlags_HeightSmall,
            )) {
                inline for (comptime std.meta.tags(terminal.point.Tag)) |tag| {
                    const selected = tag == self.lookup_region;
                    if (cimgui.c.ImGui_SelectableEx(
                        @tagName(tag).ptr,
                        selected,
                        cimgui.c.ImGuiSelectableFlags_None,
                        .{ .x = 0, .y = 0 },
                    )) {
                        self.lookup_region = tag;
                    }
                    if (selected) cimgui.c.ImGui_SetItemDefaultFocus();
                }
                cimgui.c.ImGui_EndCombo();
            }

            cimgui.c.ImGui_SameLine();

            const width = cimgui.c.ImGui_CalcTextSize("00000").x;
            var x_value: terminal.size.CellCountInt = self.lookup_coord.x;
            var y_value: u32 = self.lookup_coord.y;
            var changed = false;

            cimgui.c.ImGui_AlignTextToFramePadding();
            cimgui.c.ImGui_Text("x:");
            cimgui.c.ImGui_SameLine();
            cimgui.c.ImGui_SetNextItemWidth(width);
            if (cimgui.c.ImGui_InputScalar(
                "##grid_x",
                cimgui.c.ImGuiDataType_U16,
                &x_value,
            )) changed = true;

            cimgui.c.ImGui_SameLine();
            cimgui.c.ImGui_AlignTextToFramePadding();
            cimgui.c.ImGui_Text("y:");
            cimgui.c.ImGui_SameLine();
            cimgui.c.ImGui_SetNextItemWidth(width);
            if (cimgui.c.ImGui_InputScalar(
                "##grid_y",
                cimgui.c.ImGuiDataType_U32,
                &y_value,
            )) changed = true;

            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("Choose the coordinate space and X/Y position (0-indexed).");

            if (changed) {
                if (region_max) |coord| {
                    self.lookup_coord.x = @min(x_value, coord.x);
                    self.lookup_coord.y = @min(y_value, coord.y);
                }
            }
        }

        if (region_max) |coord| {
            cimgui.c.ImGui_TextDisabled(
                "Range: x 0..%d, y 0..%d",
                coord.x,
                coord.y,
            );
        } else {
            cimgui.c.ImGui_TextDisabled("(region has no rows)");
            return;
        }

        const pt = switch (self.lookup_region) {
            .active => terminal.Point{ .active = self.lookup_coord },
            .viewport => terminal.Point{ .viewport = self.lookup_coord },
            .screen => terminal.Point{ .screen = self.lookup_coord },
            .history => terminal.Point{ .history = self.lookup_coord },
        };

        const cell = pages.getCell(pt) orelse {
            cimgui.c.ImGui_TextDisabled("(cell out of range)");
            return;
        };

        self.cell_info.draw(cell, pt);

        if (cell.cell.style_id != stylepkg.default_id) {
            cimgui.c.ImGui_SeparatorText("Style");
            const style = cell.node.data.styles.get(
                cell.node.data.memory,
                cell.cell.style_id,
            ).*;
            widgets.style.table(style, null);
        }

        if (cell.cell.hyperlink) {
            cimgui.c.ImGui_SeparatorText("Hyperlink");
            hyperlinkTable(cell);
        }

        if (cell.cell.hasGrapheme()) {
            cimgui.c.ImGui_SeparatorText("Grapheme");
            graphemeTable(cell);
        }
    }
};

fn maxCoord(
    pages: *const PageList,
    tag: terminal.point.Tag,
) ?terminal.point.Coordinate {
    const br_pin = pages.getBottomRight(tag) orelse return null;
    const br_point = pages.pointFromPin(tag, br_pin) orelse return null;
    return br_point.coord();
}

fn hyperlinkTable(cell: PageList.Cell) void {
    if (!cimgui.c.ImGui_BeginTable(
        "cell_hyperlink",
        2,
        cimgui.c.ImGuiTableFlags_None,
    )) return;
    defer cimgui.c.ImGui_EndTable();

    const page = &cell.node.data;
    const link_id = page.lookupHyperlink(cell.cell) orelse {
        cimgui.c.ImGui_TableNextRow();
        _ = cimgui.c.ImGui_TableSetColumnIndex(0);
        cimgui.c.ImGui_Text("Status");
        _ = cimgui.c.ImGui_TableSetColumnIndex(1);
        cimgui.c.ImGui_TextDisabled("(missing link data)");
        return;
    };

    const entry = page.hyperlink_set.get(page.memory, link_id);

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("ID");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    switch (entry.id) {
        .implicit => |value| cimgui.c.ImGui_Text("implicit %d", value),
        .explicit => |slice| {
            const id = slice.slice(page.memory);
            if (id.len == 0) {
                cimgui.c.ImGui_TextDisabled("(empty)");
            } else {
                cimgui.c.ImGui_Text("%.*s", id.len, id.ptr);
            }
        },
    }

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("URI");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    const uri = entry.uri.slice(page.memory);
    if (uri.len == 0) {
        cimgui.c.ImGui_TextDisabled("(empty)");
    } else {
        cimgui.c.ImGui_Text("%.*s", uri.len, uri.ptr);
    }

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Ref Count");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    const refs = page.hyperlink_set.refCount(page.memory, link_id);
    cimgui.c.ImGui_Text("%d", refs);
}

fn graphemeTable(cell: PageList.Cell) void {
    if (!cimgui.c.ImGui_BeginTable(
        "cell_grapheme",
        2,
        cimgui.c.ImGuiTableFlags_None,
    )) return;
    defer cimgui.c.ImGui_EndTable();

    const page = &cell.node.data;
    const cps = page.lookupGrapheme(cell.cell) orelse {
        cimgui.c.ImGui_TableNextRow();
        _ = cimgui.c.ImGui_TableSetColumnIndex(0);
        cimgui.c.ImGui_Text("Status");
        _ = cimgui.c.ImGui_TableSetColumnIndex(1);
        cimgui.c.ImGui_TextDisabled("(missing grapheme data)");
        return;
    };

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Extra Codepoints");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    if (cps.len == 0) {
        cimgui.c.ImGui_TextDisabled("(none)");
        return;
    }

    var buf: [96]u8 = undefined;
    if (cimgui.c.ImGui_BeginListBox("##grapheme_list", .{ .x = 0, .y = 0 })) {
        defer cimgui.c.ImGui_EndListBox();
        for (cps) |cp| {
            const label = std.fmt.bufPrintZ(&buf, "U+{X}", .{cp}) catch "U+?";
            _ = cimgui.c.ImGui_SelectableEx(
                label.ptr,
                false,
                cimgui.c.ImGuiSelectableFlags_None,
                .{ .x = 0, .y = 0 },
            );
        }
    }
}

/// Cell inspector widget.
pub const CellInfo = struct {
    pub const empty: CellInfo = .{};

    pub fn draw(
        _: *const CellInfo,
        cell: PageList.Cell,
        point: terminal.Point,
    ) void {
        if (!cimgui.c.ImGui_BeginTable(
            "cell_info",
            3,
            cimgui.c.ImGuiTableFlags_BordersInnerV |
                cimgui.c.ImGuiTableFlags_RowBg |
                cimgui.c.ImGuiTableFlags_SizingFixedFit,
        )) return;
        defer cimgui.c.ImGui_EndTable();

        {
            cimgui.c.ImGui_TableNextRow();
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Grid Position");
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            widgets.helpMarker("The cell's X/Y coordinates in the selected region.");
            _ = cimgui.c.ImGui_TableSetColumnIndex(2);
            const coord = point.coord();
            cimgui.c.ImGui_Text("(%d, %d)", coord.x, coord.y);
        }

        {
            cimgui.c.ImGui_TableNextRow();
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Page Location");
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            widgets.helpMarker("Row and column indices within the backing page.");
            _ = cimgui.c.ImGui_TableSetColumnIndex(2);
            cimgui.c.ImGui_Text("row=%d col=%d", cell.row_idx, cell.col_idx);
        }

        {
            cimgui.c.ImGui_TableNextRow();
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Content");
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            widgets.helpMarker("Content tag describing how the cell data is stored.");
            _ = cimgui.c.ImGui_TableSetColumnIndex(2);
            cimgui.c.ImGui_Text("%s", @tagName(cell.cell.content_tag).ptr);
        }

        {
            cimgui.c.ImGui_TableNextRow();
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Codepoint");
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            widgets.helpMarker("Primary Unicode codepoint for the cell.");
            _ = cimgui.c.ImGui_TableSetColumnIndex(2);
            const cp = cell.cell.codepoint();
            if (cp == 0) {
                cimgui.c.ImGui_TextDisabled("(empty)");
            } else {
                cimgui.c.ImGui_Text("U+%04X", @as(u32, cp));
            }
        }

        if (cell.cell.hasGrapheme()) {
            cimgui.c.ImGui_TableNextRow();
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Grapheme");
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            widgets.helpMarker("Extra codepoints that combine with the primary codepoint to form the grapheme cluster.");
            _ = cimgui.c.ImGui_TableSetColumnIndex(2);
            if (cimgui.c.ImGui_BeginListBox("##cell_grapheme", .{ .x = 0, .y = 0 })) {
                defer cimgui.c.ImGui_EndListBox();
                if (cell.node.data.lookupGrapheme(cell.cell)) |cps| {
                    var buf: [96]u8 = undefined;
                    for (cps) |cp| {
                        const label = std.fmt.bufPrintZ(&buf, "U+{X}", .{cp}) catch "U+?";
                        _ = cimgui.c.ImGui_SelectableEx(
                            label.ptr,
                            false,
                            cimgui.c.ImGuiSelectableFlags_None,
                            .{ .x = 0, .y = 0 },
                        );
                    }
                } else {
                    _ = cimgui.c.ImGui_SelectableEx(
                        "(missing)",
                        false,
                        cimgui.c.ImGuiSelectableFlags_None,
                        .{ .x = 0, .y = 0 },
                    );
                }
            }
        }

        {
            cimgui.c.ImGui_TableNextRow();
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Width Property");
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            widgets.helpMarker("Character width property (narrow, wide, spacer, etc.).");
            _ = cimgui.c.ImGui_TableSetColumnIndex(2);
            cimgui.c.ImGui_Text("%s", @tagName(cell.cell.wide).ptr);
        }

        {
            cimgui.c.ImGui_TableNextRow();
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Row Flags");
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            widgets.helpMarker("Flags set on the row containing this cell.");
            _ = cimgui.c.ImGui_TableSetColumnIndex(2);
            const row = cell.row;
            if (row.wrap or row.wrap_continuation or row.grapheme or row.styled or row.hyperlink) {
                if (row.wrap) {
                    cimgui.c.ImGui_TextColored(.{ .x = 0.4, .y = 0.8, .z = 1.0, .w = 1.0 }, "wrap");
                    cimgui.c.ImGui_SameLine();
                }
                if (row.wrap_continuation) {
                    cimgui.c.ImGui_TextColored(.{ .x = 0.4, .y = 0.8, .z = 1.0, .w = 1.0 }, "cont");
                    cimgui.c.ImGui_SameLine();
                }
                if (row.grapheme) {
                    cimgui.c.ImGui_TextColored(.{ .x = 0.9, .y = 0.7, .z = 0.3, .w = 1.0 }, "grapheme");
                    cimgui.c.ImGui_SameLine();
                }
                if (row.styled) {
                    cimgui.c.ImGui_TextColored(.{ .x = 0.7, .y = 0.9, .z = 0.5, .w = 1.0 }, "styled");
                    cimgui.c.ImGui_SameLine();
                }
                if (row.hyperlink) {
                    cimgui.c.ImGui_TextColored(.{ .x = 0.8, .y = 0.6, .z = 1.0, .w = 1.0 }, "link");
                    cimgui.c.ImGui_SameLine();
                }
            } else {
                cimgui.c.ImGui_TextDisabled("(none)");
            }
        }

        {
            cimgui.c.ImGui_TableNextRow();
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Style ID");
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            widgets.helpMarker("Internal style reference ID for this cell.");
            _ = cimgui.c.ImGui_TableSetColumnIndex(2);
            cimgui.c.ImGui_Text("%d", cell.cell.style_id);
        }

        {
            cimgui.c.ImGui_TableNextRow();
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Style");
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            widgets.helpMarker("Resolved style for the cell (colors, attributes, etc.).");
            _ = cimgui.c.ImGui_TableSetColumnIndex(2);
            if (cell.cell.style_id == stylepkg.default_id) {
                cimgui.c.ImGui_TextDisabled("(default)");
            } else {
                cimgui.c.ImGui_TextDisabled("(see below)");
            }
        }

        if (cell.cell.hyperlink) {
            cimgui.c.ImGui_TableNextRow();
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Hyperlink");
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            widgets.helpMarker("OSC8 hyperlink ID associated with this cell.");
            _ = cimgui.c.ImGui_TableSetColumnIndex(2);

            const link_id = cell.node.data.lookupHyperlink(cell.cell) orelse 0;
            cimgui.c.ImGui_Text("id=%d", link_id);
        }
    }
};
