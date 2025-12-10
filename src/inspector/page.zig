const std = @import("std");
const Allocator = std.mem.Allocator;
const cimgui = @import("cimgui");
const terminal = @import("../terminal/main.zig");
const units = @import("units.zig");

pub fn render(page: *const terminal.Page) void {
    cimgui.c.igPushID_Ptr(page);
    defer cimgui.c.igPopID();

    _ = cimgui.c.igBeginTable(
        "##page_state",
        2,
        cimgui.c.ImGuiTableFlags_None,
        .{ .x = 0, .y = 0 },
        0,
    );
    defer cimgui.c.igEndTable();

    {
        cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
        {
            _ = cimgui.c.igTableSetColumnIndex(0);
            cimgui.c.igText("Memory Size");
        }
        {
            _ = cimgui.c.igTableSetColumnIndex(1);
            cimgui.c.igText("%d bytes (%d KiB)", page.memory.len, units.toKibiBytes(page.memory.len));
            cimgui.c.igText("%d VM pages", page.memory.len / std.heap.page_size_min);
        }
    }
    {
        cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
        {
            _ = cimgui.c.igTableSetColumnIndex(0);
            cimgui.c.igText("Unique Styles");
        }
        {
            _ = cimgui.c.igTableSetColumnIndex(1);
            cimgui.c.igText("%d", page.styles.count());
        }
    }
    {
        cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
        {
            _ = cimgui.c.igTableSetColumnIndex(0);
            cimgui.c.igText("Grapheme Entries");
        }
        {
            _ = cimgui.c.igTableSetColumnIndex(1);
            cimgui.c.igText("%d", page.graphemeCount());
        }
    }
    {
        cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
        {
            _ = cimgui.c.igTableSetColumnIndex(0);
            cimgui.c.igText("Capacity");
        }
        {
            _ = cimgui.c.igTableSetColumnIndex(1);
            _ = cimgui.c.igBeginTable(
                "##capacity",
                2,
                cimgui.c.ImGuiTableFlags_None,
                .{ .x = 0, .y = 0 },
                0,
            );
            defer cimgui.c.igEndTable();

            const cap = page.capacity;
            {
                cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
                {
                    _ = cimgui.c.igTableSetColumnIndex(0);
                    cimgui.c.igText("Columns");
                }

                {
                    _ = cimgui.c.igTableSetColumnIndex(1);
                    cimgui.c.igText("%d", @as(u32, @intCast(cap.cols)));
                }
            }

            {
                cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
                {
                    _ = cimgui.c.igTableSetColumnIndex(0);
                    cimgui.c.igText("Rows");
                }

                {
                    _ = cimgui.c.igTableSetColumnIndex(1);
                    cimgui.c.igText("%d", @as(u32, @intCast(cap.rows)));
                }
            }

            {
                cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
                {
                    _ = cimgui.c.igTableSetColumnIndex(0);
                    cimgui.c.igText("Unique Styles");
                }

                {
                    _ = cimgui.c.igTableSetColumnIndex(1);
                    cimgui.c.igText("%d", @as(u32, @intCast(cap.styles)));
                }
            }

            {
                cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
                {
                    _ = cimgui.c.igTableSetColumnIndex(0);
                    cimgui.c.igText("Grapheme Bytes");
                }

                {
                    _ = cimgui.c.igTableSetColumnIndex(1);
                    cimgui.c.igText("%d", cap.grapheme_bytes);
                }
            }
        }
    }
    {
        cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
        {
            _ = cimgui.c.igTableSetColumnIndex(0);
            cimgui.c.igText("Size");
        }
        {
            _ = cimgui.c.igTableSetColumnIndex(1);
            _ = cimgui.c.igBeginTable(
                "##size",
                2,
                cimgui.c.ImGuiTableFlags_None,
                .{ .x = 0, .y = 0 },
                0,
            );
            defer cimgui.c.igEndTable();

            const size = page.size;
            {
                cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
                {
                    _ = cimgui.c.igTableSetColumnIndex(0);
                    cimgui.c.igText("Columns");
                }

                {
                    _ = cimgui.c.igTableSetColumnIndex(1);
                    cimgui.c.igText("%d", @as(u32, @intCast(size.cols)));
                }
            }
            {
                cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
                {
                    _ = cimgui.c.igTableSetColumnIndex(0);
                    cimgui.c.igText("Rows");
                }

                {
                    _ = cimgui.c.igTableSetColumnIndex(1);
                    cimgui.c.igText("%d", @as(u32, @intCast(size.rows)));
                }
            }
        }
    } // size table
}
