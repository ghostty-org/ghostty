const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const cimgui = @import("cimgui");
const terminal = @import("../terminal/main.zig");

/// A cell being inspected. This duplicates much of the data in
/// the terminal data structure because we want the inspector to
/// not have a reference to the terminal state or to grab any
/// locks.
pub const Cell = struct {
    /// The main codepoint for this cell.
    codepoint: u21,

    /// Codepoints for this cell to produce a single grapheme cluster.
    /// This is only non-empty if the cell is part of a multi-codepoint
    /// grapheme cluster. This does NOT include the primary codepoint.
    cps: []const u21,

    /// The style of this cell.
    style: terminal.Style,

    pub fn init(
        alloc: Allocator,
        pin: terminal.Pin,
    ) !Cell {
        const cell = pin.rowAndCell().cell;
        const style = pin.style(cell);
        const cps: []const u21 = if (cell.hasGrapheme()) cps: {
            const src = pin.grapheme(cell).?;
            assert(src.len > 0);
            break :cps try alloc.dupe(u21, src);
        } else &.{};
        errdefer if (cps.len > 0) alloc.free(cps);

        return .{
            .codepoint = cell.codepoint(),
            .cps = cps,
            .style = style,
        };
    }

    pub fn deinit(self: *Cell, alloc: Allocator) void {
        if (self.cps.len > 0) alloc.free(self.cps);
    }

    pub fn renderTable(
        self: *const Cell,
        t: *const terminal.Terminal,
        x: usize,
        y: usize,
    ) void {
        // We have a selected cell, show information about it.
        _ = cimgui.c.igBeginTable(
            "table_cursor",
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
                cimgui.c.igText("Grid Position");
            }
            {
                _ = cimgui.c.igTableSetColumnIndex(1);
                cimgui.c.igText("row=%d col=%d", y, x);
            }
        }

        // NOTE: we don't currently write the character itself because
        // we haven't hooked up imgui to our font system. That's hard! We
        // can/should instead hook up our renderer to imgui and just render
        // the single glyph in an image view so it looks _identical_ to the
        // terminal.
        codepoint: {
            cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
            {
                _ = cimgui.c.igTableSetColumnIndex(0);
                cimgui.c.igText("Codepoint");
            }
            {
                _ = cimgui.c.igTableSetColumnIndex(1);
                if (self.codepoint == 0) {
                    cimgui.c.igTextDisabled("(empty)");
                    break :codepoint;
                }

                cimgui.c.igText("U+%X", @as(u32, @intCast(self.codepoint)));
            }
        }

        // If we have a color then we show the color
        cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
        _ = cimgui.c.igTableSetColumnIndex(0);
        cimgui.c.igText("Foreground Color");
        _ = cimgui.c.igTableSetColumnIndex(1);
        switch (self.style.fg_color) {
            .none => cimgui.c.igText("default"),
            .palette => |idx| {
                const rgb = t.color_palette.colors[idx];
                cimgui.c.igValue_Int("Palette", idx);
                var color: [3]f32 = .{
                    @as(f32, @floatFromInt(rgb.r)) / 255,
                    @as(f32, @floatFromInt(rgb.g)) / 255,
                    @as(f32, @floatFromInt(rgb.b)) / 255,
                };
                _ = cimgui.c.igColorEdit3(
                    "color_fg",
                    &color,
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
                    cimgui.c.ImGuiColorEditFlags_NoPicker |
                        cimgui.c.ImGuiColorEditFlags_NoLabel,
                );
            },
        }

        cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
        _ = cimgui.c.igTableSetColumnIndex(0);
        cimgui.c.igText("Background Color");
        _ = cimgui.c.igTableSetColumnIndex(1);
        switch (self.style.bg_color) {
            .none => cimgui.c.igText("default"),
            .palette => |idx| {
                const rgb = t.color_palette.colors[idx];
                cimgui.c.igValue_Int("Palette", idx);
                var color: [3]f32 = .{
                    @as(f32, @floatFromInt(rgb.r)) / 255,
                    @as(f32, @floatFromInt(rgb.g)) / 255,
                    @as(f32, @floatFromInt(rgb.b)) / 255,
                };
                _ = cimgui.c.igColorEdit3(
                    "color_bg",
                    &color,
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
            if (!@field(self.style.flags, style)) break :style;

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

        cimgui.c.igTextDisabled("(Any styles not shown are not currently set)");
    }
};
