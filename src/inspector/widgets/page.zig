const std = @import("std");
const cimgui = @import("dcimgui");
const terminal = @import("../../terminal/main.zig");
const units = @import("../units.zig");
const widgets = @import("../widgets.zig");

const PageList = terminal.PageList;
const Page = terminal.Page;

pub fn inspector(page: *const terminal.Page) void {
    cimgui.c.ImGui_SeparatorText("Managed Memory");
    managedMemory(page);

    cimgui.c.ImGui_SeparatorText("Styles");
    stylesList(page);

    cimgui.c.ImGui_SeparatorText("Hyperlinks");
    hyperlinksList(page);

    cimgui.c.ImGui_SeparatorText("Rows");
    rowsTable(page);
}

/// Draw a tree node header with metadata about this page. Returns if
/// the tree node is open or not. If it is open you must close it with
/// TreePop.
pub fn treeNode(state: struct {
    /// The page
    page: *const terminal.Page,
    /// The index of the page in a page list, used for headers.
    index: usize,
    /// The range of rows this page covers, inclusive.
    row_range: [2]usize,
    /// Whether this page is the active or viewport node.
    active: bool,
    viewport: bool,
}) bool {
    // Setup our node.
    const open = open: {
        var label_buf: [160]u8 = undefined;
        const label = std.fmt.bufPrintZ(
            &label_buf,
            "Page {d}",
            .{state.index},
        ) catch "Page";

        const flags = cimgui.c.ImGuiTreeNodeFlags_AllowOverlap |
            cimgui.c.ImGuiTreeNodeFlags_SpanFullWidth |
            cimgui.c.ImGuiTreeNodeFlags_FramePadding;
        break :open cimgui.c.ImGui_TreeNodeEx(label.ptr, flags);
    };

    // Move our cursor into the tree header so we can add extra info.
    const header_min = cimgui.c.ImGui_GetItemRectMin();
    const header_max = cimgui.c.ImGui_GetItemRectMax();
    const header_height = header_max.y - header_min.y;
    const text_line = cimgui.c.ImGui_GetTextLineHeight();
    const y_center = header_min.y + (header_height - text_line) * 0.5;
    cimgui.c.ImGui_SetCursorScreenPos(.{ .x = header_min.x + 170, .y = y_center });

    // Metadata
    cimgui.c.ImGui_TextDisabled(
        "%dc x %dr",
        state.page.size.cols,
        state.page.size.rows,
    );
    cimgui.c.ImGui_SameLine();
    cimgui.c.ImGui_Text("rows %d..%d", state.row_range[0], state.row_range[1]);

    // Labels
    if (state.active) {
        cimgui.c.ImGui_SameLine();
        cimgui.c.ImGui_TextColored(.{ .x = 0.4, .y = 0.9, .z = 0.4, .w = 1.0 }, "active");
    }
    if (state.viewport) {
        cimgui.c.ImGui_SameLine();
        cimgui.c.ImGui_TextColored(.{ .x = 0.4, .y = 0.8, .z = 1.0, .w = 1.0 }, "viewport");
    }
    if (state.page.isDirty()) {
        cimgui.c.ImGui_SameLine();
        cimgui.c.ImGui_TextColored(.{ .x = 1.0, .y = 0.4, .z = 0.4, .w = 1.0 }, "dirty");
    }

    return open;
}

pub fn managedMemory(page: *const Page) void {
    if (cimgui.c.ImGui_BeginTable(
        "##overview",
        3,
        cimgui.c.ImGuiTableFlags_BordersInnerV |
            cimgui.c.ImGuiTableFlags_RowBg |
            cimgui.c.ImGuiTableFlags_SizingFixedFit,
    )) {
        defer cimgui.c.ImGui_EndTable();

        cimgui.c.ImGui_TableNextRow();
        _ = cimgui.c.ImGui_TableSetColumnIndex(0);
        cimgui.c.ImGui_Text("Memory Size");
        _ = cimgui.c.ImGui_TableSetColumnIndex(1);
        widgets.helpMarker(
            "Memory allocated for this page. Note the backing memory " ++
                "may be a larger allocation from which this page " ++
                "uses a portion.",
        );
        _ = cimgui.c.ImGui_TableSetColumnIndex(2);
        cimgui.c.ImGui_Text(
            "%d KiB",
            units.toKibiBytes(page.memory.len),
        );
    }

    if (cimgui.c.ImGui_BeginTable(
        "##managed",
        4,
        cimgui.c.ImGuiTableFlags_BordersInnerV |
            cimgui.c.ImGuiTableFlags_RowBg |
            cimgui.c.ImGuiTableFlags_SizingFixedFit,
    )) {
        defer cimgui.c.ImGui_EndTable();

        cimgui.c.ImGui_TableSetupColumn("Resource", cimgui.c.ImGuiTableColumnFlags_WidthFixed);
        cimgui.c.ImGui_TableSetupColumn("", cimgui.c.ImGuiTableColumnFlags_WidthFixed);
        cimgui.c.ImGui_TableSetupColumn("Used", cimgui.c.ImGuiTableColumnFlags_WidthFixed);
        cimgui.c.ImGui_TableSetupColumn("Capacity", cimgui.c.ImGuiTableColumnFlags_WidthFixed);
        cimgui.c.ImGui_TableHeadersRow();

        const size = page.size;
        const cap = page.capacity;
        cimgui.c.ImGui_TableNextRow();
        _ = cimgui.c.ImGui_TableSetColumnIndex(0);
        cimgui.c.ImGui_Text("Columns");
        _ = cimgui.c.ImGui_TableSetColumnIndex(1);
        widgets.helpMarker("Number of columns in the terminal grid.");
        _ = cimgui.c.ImGui_TableSetColumnIndex(2);
        cimgui.c.ImGui_Text("%d", size.cols);
        _ = cimgui.c.ImGui_TableSetColumnIndex(3);
        cimgui.c.ImGui_Text("%d", cap.cols);

        cimgui.c.ImGui_TableNextRow();
        _ = cimgui.c.ImGui_TableSetColumnIndex(0);
        cimgui.c.ImGui_Text("Rows");
        _ = cimgui.c.ImGui_TableSetColumnIndex(1);
        widgets.helpMarker("Number of rows in this page.");
        _ = cimgui.c.ImGui_TableSetColumnIndex(2);
        cimgui.c.ImGui_Text("%d", size.rows);
        _ = cimgui.c.ImGui_TableSetColumnIndex(3);
        cimgui.c.ImGui_Text("%d", cap.rows);

        cimgui.c.ImGui_TableNextRow();
        _ = cimgui.c.ImGui_TableSetColumnIndex(0);
        cimgui.c.ImGui_Text("Styles");
        _ = cimgui.c.ImGui_TableSetColumnIndex(1);
        widgets.helpMarker("Unique text styles (colors, attributes) currently in use.");
        _ = cimgui.c.ImGui_TableSetColumnIndex(2);
        cimgui.c.ImGui_Text("%d", page.styles.count());
        _ = cimgui.c.ImGui_TableSetColumnIndex(3);
        cimgui.c.ImGui_Text("%d", page.styles.layout.cap);

        cimgui.c.ImGui_TableNextRow();
        _ = cimgui.c.ImGui_TableSetColumnIndex(0);
        cimgui.c.ImGui_Text("Graphemes");
        _ = cimgui.c.ImGui_TableSetColumnIndex(1);
        widgets.helpMarker("Extended grapheme clusters for multi-codepoint characters.");
        _ = cimgui.c.ImGui_TableSetColumnIndex(2);
        cimgui.c.ImGui_Text("%d", page.graphemeCount());
        _ = cimgui.c.ImGui_TableSetColumnIndex(3);
        cimgui.c.ImGui_Text("%d", page.graphemeCapacity());

        cimgui.c.ImGui_TableNextRow();
        _ = cimgui.c.ImGui_TableSetColumnIndex(0);
        cimgui.c.ImGui_Text("Strings (bytes)");
        _ = cimgui.c.ImGui_TableSetColumnIndex(1);
        widgets.helpMarker("String storage for hyperlink URIs and other text data.");
        _ = cimgui.c.ImGui_TableSetColumnIndex(2);
        cimgui.c.ImGui_Text("%d", page.string_alloc.usedBytes(page.memory));
        _ = cimgui.c.ImGui_TableSetColumnIndex(3);
        cimgui.c.ImGui_Text("%d", page.string_alloc.capacityBytes());

        const hyperlink_map = page.hyperlink_map.map(page.memory);
        cimgui.c.ImGui_TableNextRow();
        _ = cimgui.c.ImGui_TableSetColumnIndex(0);
        cimgui.c.ImGui_Text("Hyperlink Map");
        _ = cimgui.c.ImGui_TableSetColumnIndex(1);
        widgets.helpMarker("Maps cell positions to hyperlink IDs.");
        _ = cimgui.c.ImGui_TableSetColumnIndex(2);
        cimgui.c.ImGui_Text("%d", hyperlink_map.count());
        _ = cimgui.c.ImGui_TableSetColumnIndex(3);
        cimgui.c.ImGui_Text("%d", hyperlink_map.capacity());

        cimgui.c.ImGui_TableNextRow();
        _ = cimgui.c.ImGui_TableSetColumnIndex(0);
        cimgui.c.ImGui_Text("Hyperlink IDs");
        _ = cimgui.c.ImGui_TableSetColumnIndex(1);
        widgets.helpMarker("Unique hyperlink definitions (URI + optional ID).");
        _ = cimgui.c.ImGui_TableSetColumnIndex(2);
        cimgui.c.ImGui_Text("%d", page.hyperlink_set.count());
        _ = cimgui.c.ImGui_TableSetColumnIndex(3);
        cimgui.c.ImGui_Text("%d", page.hyperlink_set.layout.cap);
    }
}

fn rowsTable(page: *const terminal.Page) void {
    const visible_rows: usize = @min(page.size.rows, 12);
    const row_height: f32 = cimgui.c.ImGui_GetTextLineHeightWithSpacing();
    const child_height: f32 = row_height * (@as(f32, @floatFromInt(visible_rows)) + 2.0);

    // Child window so scrolling is separate.
    // This defer first is not a bug, EndChild always needs to be called.
    defer cimgui.c.ImGui_EndChild();
    if (!cimgui.c.ImGui_BeginChild(
        "##page_rows",
        .{ .x = 0.0, .y = child_height },
        cimgui.c.ImGuiChildFlags_Borders,
        cimgui.c.ImGuiWindowFlags_None,
    )) return;

    if (!cimgui.c.ImGui_BeginTable(
        "##page_rows_table",
        10,
        cimgui.c.ImGuiTableFlags_BordersInnerV |
            cimgui.c.ImGuiTableFlags_RowBg |
            cimgui.c.ImGuiTableFlags_SizingFixedFit,
    )) return;
    defer cimgui.c.ImGui_EndTable();

    cimgui.c.ImGui_TableSetupScrollFreeze(0, 1);
    cimgui.c.ImGui_TableSetupColumn("Row", cimgui.c.ImGuiTableColumnFlags_WidthFixed);
    cimgui.c.ImGui_TableSetupColumn("Text", cimgui.c.ImGuiTableColumnFlags_WidthFixed);
    cimgui.c.ImGui_TableSetupColumn("Dirty", cimgui.c.ImGuiTableColumnFlags_WidthFixed);
    cimgui.c.ImGui_TableSetupColumn("Wrap", cimgui.c.ImGuiTableColumnFlags_WidthFixed);
    cimgui.c.ImGui_TableSetupColumn("Cont", cimgui.c.ImGuiTableColumnFlags_WidthFixed);
    cimgui.c.ImGui_TableSetupColumn("Styled", cimgui.c.ImGuiTableColumnFlags_WidthFixed);
    cimgui.c.ImGui_TableSetupColumn("Grapheme", cimgui.c.ImGuiTableColumnFlags_WidthFixed);
    cimgui.c.ImGui_TableSetupColumn("Link", cimgui.c.ImGuiTableColumnFlags_WidthFixed);
    cimgui.c.ImGui_TableSetupColumn("Prompt", cimgui.c.ImGuiTableColumnFlags_WidthFixed);
    cimgui.c.ImGui_TableSetupColumn("Kitty", cimgui.c.ImGuiTableColumnFlags_WidthFixed);
    cimgui.c.ImGui_TableHeadersRow();

    const rows = page.rows.ptr(page.memory)[0..page.size.rows];
    for (rows, 0..) |*row, row_index| {
        var text_cells: usize = 0;
        const cells = page.getCells(row);
        for (cells) |cell| {
            if (cell.hasText()) {
                text_cells += 1;
            }
        }

        cimgui.c.ImGui_TableNextRow();

        _ = cimgui.c.ImGui_TableSetColumnIndex(0);
        cimgui.c.ImGui_Text("%d", row_index);

        _ = cimgui.c.ImGui_TableSetColumnIndex(1);
        if (text_cells == 0) {
            cimgui.c.ImGui_TextDisabled("0");
        } else {
            cimgui.c.ImGui_Text("%d", text_cells);
        }

        _ = cimgui.c.ImGui_TableSetColumnIndex(2);
        flagCell(row.dirty);

        _ = cimgui.c.ImGui_TableSetColumnIndex(3);
        flagCell(row.wrap);

        _ = cimgui.c.ImGui_TableSetColumnIndex(4);
        flagCell(row.wrap_continuation);

        _ = cimgui.c.ImGui_TableSetColumnIndex(5);
        flagCell(row.styled);

        _ = cimgui.c.ImGui_TableSetColumnIndex(6);
        flagCell(row.grapheme);

        _ = cimgui.c.ImGui_TableSetColumnIndex(7);
        flagCell(row.hyperlink);

        _ = cimgui.c.ImGui_TableSetColumnIndex(8);
        cimgui.c.ImGui_Text("%s", @tagName(row.semantic_prompt).ptr);

        _ = cimgui.c.ImGui_TableSetColumnIndex(9);
        flagCell(row.kitty_virtual_placeholder);
    }
}

fn stylesList(page: *const Page) void {
    const items = page.styles.items.ptr(page.memory)[0..page.styles.layout.cap];

    var count: usize = 0;
    for (items, 0..) |item, index| {
        if (index == 0) continue;
        if (item.meta.ref == 0) continue;
        count += 1;
    }

    if (count == 0) {
        cimgui.c.ImGui_TextDisabled("(no styles in use)");
        return;
    }

    const visible_rows: usize = @min(count, 8);
    const row_height: f32 = cimgui.c.ImGui_GetTextLineHeightWithSpacing();
    const child_height: f32 = row_height * (@as(f32, @floatFromInt(visible_rows)) + 2.0);

    defer cimgui.c.ImGui_EndChild();
    if (!cimgui.c.ImGui_BeginChild(
        "##page_styles",
        .{ .x = 0.0, .y = child_height },
        cimgui.c.ImGuiChildFlags_Borders,
        cimgui.c.ImGuiWindowFlags_None,
    )) return;

    if (!cimgui.c.ImGui_BeginTable(
        "##page_styles_table",
        3,
        cimgui.c.ImGuiTableFlags_BordersInnerV |
            cimgui.c.ImGuiTableFlags_RowBg |
            cimgui.c.ImGuiTableFlags_SizingFixedFit,
    )) return;
    defer cimgui.c.ImGui_EndTable();

    cimgui.c.ImGui_TableSetupScrollFreeze(0, 1);
    cimgui.c.ImGui_TableSetupColumn("ID", cimgui.c.ImGuiTableColumnFlags_WidthFixed);
    cimgui.c.ImGui_TableSetupColumn("Refs", cimgui.c.ImGuiTableColumnFlags_WidthFixed);
    cimgui.c.ImGui_TableSetupColumn("Style", cimgui.c.ImGuiTableColumnFlags_WidthStretch);
    cimgui.c.ImGui_TableHeadersRow();

    for (items, 0..) |item, index| {
        if (index == 0) continue;
        if (item.meta.ref == 0) continue;

        cimgui.c.ImGui_TableNextRow();
        cimgui.c.ImGui_PushIDInt(@intCast(index));
        defer cimgui.c.ImGui_PopID();

        _ = cimgui.c.ImGui_TableSetColumnIndex(0);
        cimgui.c.ImGui_Text("%d", index);

        _ = cimgui.c.ImGui_TableSetColumnIndex(1);
        cimgui.c.ImGui_Text("%d", item.meta.ref);

        _ = cimgui.c.ImGui_TableSetColumnIndex(2);
        if (cimgui.c.ImGui_TreeNodeEx("Details", cimgui.c.ImGuiTreeNodeFlags_None)) {
            defer cimgui.c.ImGui_TreePop();
            widgets.style.table(item.value, null);
        }
    }
}

fn hyperlinksList(page: *const Page) void {
    const items = page.hyperlink_set.items.ptr(page.memory)[0..page.hyperlink_set.layout.cap];

    var count: usize = 0;
    for (items, 0..) |item, index| {
        if (index == 0) continue;
        if (item.meta.ref == 0) continue;
        count += 1;
    }

    if (count == 0) {
        cimgui.c.ImGui_TextDisabled("(no hyperlinks in use)");
        return;
    }

    const visible_rows: usize = @min(count, 8);
    const row_height: f32 = cimgui.c.ImGui_GetTextLineHeightWithSpacing();
    const child_height: f32 = row_height * (@as(f32, @floatFromInt(visible_rows)) + 2.0);

    defer cimgui.c.ImGui_EndChild();
    if (!cimgui.c.ImGui_BeginChild(
        "##page_hyperlinks",
        .{ .x = 0.0, .y = child_height },
        cimgui.c.ImGuiChildFlags_Borders,
        cimgui.c.ImGuiWindowFlags_None,
    )) return;

    if (!cimgui.c.ImGui_BeginTable(
        "##page_hyperlinks_table",
        4,
        cimgui.c.ImGuiTableFlags_BordersInnerV |
            cimgui.c.ImGuiTableFlags_RowBg |
            cimgui.c.ImGuiTableFlags_SizingFixedFit,
    )) return;
    defer cimgui.c.ImGui_EndTable();

    cimgui.c.ImGui_TableSetupScrollFreeze(0, 1);
    cimgui.c.ImGui_TableSetupColumn("ID", cimgui.c.ImGuiTableColumnFlags_WidthFixed);
    cimgui.c.ImGui_TableSetupColumn("Refs", cimgui.c.ImGuiTableColumnFlags_WidthFixed);
    cimgui.c.ImGui_TableSetupColumn("Explicit ID", cimgui.c.ImGuiTableColumnFlags_WidthFixed);
    cimgui.c.ImGui_TableSetupColumn("URI", cimgui.c.ImGuiTableColumnFlags_WidthStretch);
    cimgui.c.ImGui_TableHeadersRow();

    for (items, 0..) |item, index| {
        if (index == 0) continue;
        if (item.meta.ref == 0) continue;

        cimgui.c.ImGui_TableNextRow();

        _ = cimgui.c.ImGui_TableSetColumnIndex(0);
        cimgui.c.ImGui_Text("%d", index);

        _ = cimgui.c.ImGui_TableSetColumnIndex(1);
        cimgui.c.ImGui_Text("%d", item.meta.ref);

        _ = cimgui.c.ImGui_TableSetColumnIndex(2);
        switch (item.value.id) {
            .explicit => |slice| {
                const explicit_id = slice.slice(page.memory);
                cimgui.c.ImGui_Text("%.*s", explicit_id.len, explicit_id.ptr);
            },
            .implicit => cimgui.c.ImGui_TextDisabled("-"),
        }

        _ = cimgui.c.ImGui_TableSetColumnIndex(3);
        const uri = item.value.uri.slice(page.memory);
        cimgui.c.ImGui_Text("%.*s", uri.len, uri.ptr);
    }
}

fn flagCell(value: bool) void {
    if (value) {
        cimgui.c.ImGui_TextColored(.{ .x = 0.4, .y = 0.9, .z = 0.4, .w = 1.0 }, "yes");
    } else {
        cimgui.c.ImGui_TextDisabled("-");
    }
}
