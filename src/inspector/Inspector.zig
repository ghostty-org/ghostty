//! The Inspector is a development tool to debug the terminal. This is
//! useful for terminal application developers as well as people potentially
//! debugging issues in Ghostty itself.
const Inspector = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const cimgui = @import("cimgui");
const Surface = @import("../Surface.zig");
const font = @import("../font/main.zig");
const input = @import("../input.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const inspector = @import("main.zig");
const units = @import("units.zig");

/// The window names. These are used with docking so we need to have access.
const window_cell = "Cell";
const window_modes = "Modes";
const window_keyboard = "Keyboard";
const window_termio = "Terminal IO";
const window_screen = "Screen";
const window_size = "Surface Info";
const window_imgui_demo = "Dear ImGui Demo";

/// The surface that we're inspecting.
surface: *Surface,

/// This is used to track whether we're rendering for the first time. This
/// is used to set up the initial window positions.
first_render: bool = true,

/// Mouse state that we track in addition to normal mouse states that
/// Ghostty always knows about.
mouse: struct {
    /// Last hovered x/y
    last_xpos: f64 = 0,
    last_ypos: f64 = 0,

    // Last hovered screen point
    last_point: ?terminal.Pin = null,
} = .{},

/// A selected cell.
cell: CellInspect = .{ .idle = {} },

/// The list of keyboard events
key_events: inspector.key.EventRing,

/// The VT stream
vt_events: inspector.termio.VTEventRing,
vt_stream: inspector.termio.Stream,

/// The currently selected event sequence number for keyboard navigation
selected_event_seq: ?u32 = null,

/// Flag indicating whether we need to scroll to the selected item
need_scroll_to_selected: bool = false,

/// Flag indicating whether the selection was made by keyboard
is_keyboard_selection: bool = false,

/// Enum representing keyboard navigation actions
const KeyAction = enum {
    down,
    none,
    up,
};

const CellInspect = union(enum) {
    /// Idle, no cell inspection is requested
    idle: void,

    /// Requested, a cell is being picked.
    requested: void,

    /// The cell has been picked and set to this. This is a copy so that
    /// if the cell contents change we still have the original cell.
    selected: Selected,

    const Selected = struct {
        alloc: Allocator,
        row: usize,
        col: usize,
        cell: inspector.Cell,
    };

    pub fn deinit(self: *CellInspect) void {
        switch (self.*) {
            .idle, .requested => {},
            .selected => |*v| v.cell.deinit(v.alloc),
        }
    }

    pub fn request(self: *CellInspect) void {
        switch (self.*) {
            .idle => self.* = .requested,
            .selected => |*v| {
                v.cell.deinit(v.alloc);
                self.* = .requested;
            },
            .requested => {},
        }
    }

    pub fn select(
        self: *CellInspect,
        alloc: Allocator,
        pin: terminal.Pin,
        x: usize,
        y: usize,
    ) !void {
        assert(self.* == .requested);
        const cell = try inspector.Cell.init(alloc, pin);
        errdefer cell.deinit(alloc);
        self.* = .{ .selected = .{
            .alloc = alloc,
            .row = y,
            .col = x,
            .cell = cell,
        } };
    }
};

/// Setup the ImGui state. This requires an ImGui context to be set.
pub fn setup() void {
    const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();

    // Enable docking, which we use heavily for the UI.
    io.ConfigFlags |= cimgui.c.ImGuiConfigFlags_DockingEnable;

    // Our colorspace is sRGB.
    io.ConfigFlags |= cimgui.c.ImGuiConfigFlags_IsSRGB;

    // Disable the ini file to save layout
    io.IniFilename = null;
    io.LogFilename = null;

    // Use our own embedded font
    {
        // TODO: This will have to be recalculated for different screen DPIs.
        // This is currently hardcoded to a 2x content scale.
        const font_size = 16 * 2;

        const font_config: *cimgui.c.ImFontConfig = cimgui.c.ImFontConfig_ImFontConfig();
        defer cimgui.c.ImFontConfig_destroy(font_config);
        font_config.FontDataOwnedByAtlas = false;
        _ = cimgui.c.ImFontAtlas_AddFontFromMemoryTTF(
            io.Fonts,
            @constCast(@ptrCast(font.embedded.regular)),
            font.embedded.regular.len,
            font_size,
            font_config,
            null,
        );
    }
}

pub fn init(surface: *Surface) !Inspector {
    var key_buf = try inspector.key.EventRing.init(surface.alloc, 2);
    errdefer key_buf.deinit(surface.alloc);

    var vt_events = try inspector.termio.VTEventRing.init(surface.alloc, 2);
    errdefer vt_events.deinit(surface.alloc);

    var vt_handler = inspector.termio.VTHandler.init(surface);
    errdefer vt_handler.deinit();

    return .{
        .surface = surface,
        .key_events = key_buf,
        .vt_events = vt_events,
        .vt_stream = .{
            .handler = vt_handler,
            .parser = .{
                .osc_parser = .{
                    .alloc = surface.alloc,
                },
            },
        },
    };
}

pub fn deinit(self: *Inspector) void {
    self.cell.deinit();

    {
        var it = self.key_events.iterator(.forward);
        while (it.next()) |v| v.deinit(self.surface.alloc);
        self.key_events.deinit(self.surface.alloc);
    }

    {
        var it = self.vt_events.iterator(.forward);
        while (it.next()) |v| v.deinit(self.surface.alloc);
        self.vt_events.deinit(self.surface.alloc);

        self.vt_stream.handler.deinit();
        self.vt_stream.deinit();
    }
}

/// Record a keyboard event.
pub fn recordKeyEvent(self: *Inspector, ev: inspector.key.Event) !void {
    const max_capacity = 50;
    self.key_events.append(ev) catch |err| switch (err) {
        error.OutOfMemory => if (self.key_events.capacity() < max_capacity) {
            // We're out of memory, but we can allocate to our capacity.
            const new_capacity = @min(self.key_events.capacity() * 2, max_capacity);
            try self.key_events.resize(self.surface.alloc, new_capacity);
            try self.key_events.append(ev);
        } else {
            var it = self.key_events.iterator(.forward);
            if (it.next()) |old_ev| old_ev.deinit(self.surface.alloc);
            self.key_events.deleteOldest(1);
            try self.key_events.append(ev);
        },

        else => return err,
    };
}

/// Record data read from the pty.
pub fn recordPtyRead(self: *Inspector, data: []const u8) !void {
    try self.vt_stream.nextSlice(data);
}

/// Render the frame.
pub fn render(self: *Inspector) void {
    const dock_id = cimgui.c.igDockSpaceOverViewport(
        cimgui.c.igGetMainViewport(),
        cimgui.c.ImGuiDockNodeFlags_None,
        null,
    );

    // Render all of our data. We hold the mutex for this duration. This is
    // expensive but this is an initial implementation until it doesn't work
    // anymore.
    {
        self.surface.renderer_state.mutex.lock();
        defer self.surface.renderer_state.mutex.unlock();
        self.renderScreenWindow();
        self.renderModesWindow();
        self.renderKeyboardWindow();
        self.renderTermioWindow();
        self.renderCellWindow();
        self.renderSizeWindow();
    }

    // In debug we show the ImGui demo window so we can easily view available
    // widgets and such.
    if (builtin.mode == .Debug) {
        var show: bool = true;
        cimgui.c.igShowDemoWindow(&show);
    }

    // On first render we set up the layout. We can actually do this at
    // the end of the frame, allowing the individual rendering to also
    // observe the first render flag.
    if (self.first_render) {
        self.first_render = false;
        self.setupLayout(dock_id);
    }
}

fn setupLayout(self: *Inspector, dock_id_main: cimgui.c.ImGuiID) void {
    _ = self;

    // Our initial focus
    cimgui.c.igSetWindowFocus_Str(window_screen);

    // Setup our initial layout.
    const dock_id: struct {
        left: cimgui.c.ImGuiID,
        right: cimgui.c.ImGuiID,
    } = dock_id: {
        var dock_id_left: cimgui.c.ImGuiID = undefined;
        var dock_id_right: cimgui.c.ImGuiID = undefined;
        _ = cimgui.c.igDockBuilderSplitNode(
            dock_id_main,
            cimgui.c.ImGuiDir_Left,
            0.7,
            &dock_id_left,
            &dock_id_right,
        );

        break :dock_id .{
            .left = dock_id_left,
            .right = dock_id_right,
        };
    };

    cimgui.c.igDockBuilderDockWindow(window_cell, dock_id.left);
    cimgui.c.igDockBuilderDockWindow(window_modes, dock_id.left);
    cimgui.c.igDockBuilderDockWindow(window_keyboard, dock_id.left);
    cimgui.c.igDockBuilderDockWindow(window_termio, dock_id.left);
    cimgui.c.igDockBuilderDockWindow(window_screen, dock_id.left);
    cimgui.c.igDockBuilderDockWindow(window_imgui_demo, dock_id.left);
    cimgui.c.igDockBuilderDockWindow(window_size, dock_id.right);
    cimgui.c.igDockBuilderFinish(dock_id_main);
}

fn renderScreenWindow(self: *Inspector) void {
    // Start our window. If we're collapsed we do nothing.
    defer cimgui.c.igEnd();
    if (!cimgui.c.igBegin(
        window_screen,
        null,
        cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
    )) return;

    const t = self.surface.renderer_state.terminal;
    const screen = &t.screen;

    {
        _ = cimgui.c.igBeginTable(
            "table_screen",
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
                cimgui.c.igText("Active Screen");
            }
            {
                _ = cimgui.c.igTableSetColumnIndex(1);
                cimgui.c.igText("%s", @tagName(t.active_screen).ptr);
            }
        }
    }

    if (cimgui.c.igCollapsingHeader_TreeNodeFlags(
        "Cursor",
        cimgui.c.ImGuiTreeNodeFlags_DefaultOpen,
    )) {
        {
            _ = cimgui.c.igBeginTable(
                "table_cursor",
                2,
                cimgui.c.ImGuiTableFlags_None,
                .{ .x = 0, .y = 0 },
                0,
            );
            defer cimgui.c.igEndTable();
            inspector.cursor.renderInTable(
                self.surface.renderer_state.terminal,
                &screen.cursor,
            );
        } // table

        cimgui.c.igTextDisabled("(Any styles not shown are not currently set)");
    } // cursor

    if (cimgui.c.igCollapsingHeader_TreeNodeFlags(
        "Keyboard",
        cimgui.c.ImGuiTreeNodeFlags_DefaultOpen,
    )) {
        {
            _ = cimgui.c.igBeginTable(
                "table_keyboard",
                2,
                cimgui.c.ImGuiTableFlags_None,
                .{ .x = 0, .y = 0 },
                0,
            );
            defer cimgui.c.igEndTable();

            const kitty_flags = screen.kitty_keyboard.current();

            {
                cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
                {
                    _ = cimgui.c.igTableSetColumnIndex(0);
                    cimgui.c.igText("Mode");
                }
                {
                    _ = cimgui.c.igTableSetColumnIndex(1);
                    const mode = if (kitty_flags.int() != 0) "kitty" else "legacy";
                    cimgui.c.igText("%s", mode.ptr);
                }
            }

            if (kitty_flags.int() != 0) {
                const Flags = @TypeOf(kitty_flags);
                inline for (@typeInfo(Flags).Struct.fields) |field| {
                    {
                        const value = @field(kitty_flags, field.name);

                        cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
                        {
                            _ = cimgui.c.igTableSetColumnIndex(0);
                            const name = std.fmt.comptimePrint("{s}", .{field.name});
                            cimgui.c.igText("%s", name.ptr);
                        }
                        {
                            _ = cimgui.c.igTableSetColumnIndex(1);
                            cimgui.c.igText(
                                "%s",
                                if (value) "true".ptr else "false".ptr,
                            );
                        }
                    }
                }
            } else {
                {
                    cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
                    {
                        _ = cimgui.c.igTableSetColumnIndex(0);
                        cimgui.c.igText("Xterm modify keys");
                    }
                    {
                        _ = cimgui.c.igTableSetColumnIndex(1);
                        cimgui.c.igText(
                            "%s",
                            if (t.flags.modify_other_keys_2) "true".ptr else "false".ptr,
                        );
                    }
                }
            } // keyboard mode info
        } // table
    } // keyboard

    if (cimgui.c.igCollapsingHeader_TreeNodeFlags(
        "Kitty Graphics",
        cimgui.c.ImGuiTreeNodeFlags_DefaultOpen,
    )) kitty_gfx: {
        if (!screen.kitty_images.enabled()) {
            cimgui.c.igTextDisabled("(Kitty graphics are disabled)");
            break :kitty_gfx;
        }

        {
            _ = cimgui.c.igBeginTable(
                "##kitty_graphics",
                2,
                cimgui.c.ImGuiTableFlags_None,
                .{ .x = 0, .y = 0 },
                0,
            );
            defer cimgui.c.igEndTable();

            const kitty_images = &screen.kitty_images;

            {
                cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
                {
                    _ = cimgui.c.igTableSetColumnIndex(0);
                    cimgui.c.igText("Memory Usage");
                }
                {
                    _ = cimgui.c.igTableSetColumnIndex(1);
                    cimgui.c.igText("%d bytes (%d KiB)", kitty_images.total_bytes, units.toKibiBytes(kitty_images.total_bytes));
                }
            }

            {
                cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
                {
                    _ = cimgui.c.igTableSetColumnIndex(0);
                    cimgui.c.igText("Memory Limit");
                }
                {
                    _ = cimgui.c.igTableSetColumnIndex(1);
                    cimgui.c.igText("%d bytes (%d KiB)", kitty_images.total_limit, units.toKibiBytes(kitty_images.total_limit));
                }
            }

            {
                cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
                {
                    _ = cimgui.c.igTableSetColumnIndex(0);
                    cimgui.c.igText("Image Count");
                }
                {
                    _ = cimgui.c.igTableSetColumnIndex(1);
                    cimgui.c.igText("%d", kitty_images.images.count());
                }
            }

            {
                cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
                {
                    _ = cimgui.c.igTableSetColumnIndex(0);
                    cimgui.c.igText("Placement Count");
                }
                {
                    _ = cimgui.c.igTableSetColumnIndex(1);
                    cimgui.c.igText("%d", kitty_images.placements.count());
                }
            }

            {
                cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
                {
                    _ = cimgui.c.igTableSetColumnIndex(0);
                    cimgui.c.igText("Image Loading");
                }
                {
                    _ = cimgui.c.igTableSetColumnIndex(1);
                    cimgui.c.igText("%s", if (kitty_images.loading != null) "true".ptr else "false".ptr);
                }
            }
        } // table
    } // kitty graphics

    if (cimgui.c.igCollapsingHeader_TreeNodeFlags(
        "Internal Terminal State",
        cimgui.c.ImGuiTreeNodeFlags_DefaultOpen,
    )) {
        const pages = &screen.pages;

        {
            _ = cimgui.c.igBeginTable(
                "##terminal_state",
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
                    cimgui.c.igText("Memory Usage");
                }
                {
                    _ = cimgui.c.igTableSetColumnIndex(1);
                    cimgui.c.igText("%d bytes (%d KiB)", pages.page_size, units.toKibiBytes(pages.page_size));
                }
            }

            {
                cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
                {
                    _ = cimgui.c.igTableSetColumnIndex(0);
                    cimgui.c.igText("Memory Limit");
                }
                {
                    _ = cimgui.c.igTableSetColumnIndex(1);
                    cimgui.c.igText("%d bytes (%d KiB)", pages.maxSize(), units.toKibiBytes(pages.maxSize()));
                }
            }

            {
                cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
                {
                    _ = cimgui.c.igTableSetColumnIndex(0);
                    cimgui.c.igText("Viewport Location");
                }
                {
                    _ = cimgui.c.igTableSetColumnIndex(1);
                    cimgui.c.igText("%s", @tagName(pages.viewport).ptr);
                }
            }
        } // table
        //
        if (cimgui.c.igCollapsingHeader_TreeNodeFlags(
            "Active Page",
            cimgui.c.ImGuiTreeNodeFlags_DefaultOpen,
        )) {
            inspector.page.render(&pages.pages.last.?.data);
        }
    } // terminal state
}

/// The modes window shows the currently active terminal modes and allows
/// users to toggle them on and off.
fn renderModesWindow(self: *Inspector) void {
    // Start our window. If we're collapsed we do nothing.
    defer cimgui.c.igEnd();
    if (!cimgui.c.igBegin(
        window_modes,
        null,
        cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
    )) return;

    _ = cimgui.c.igBeginTable(
        "table_modes",
        3,
        cimgui.c.ImGuiTableFlags_SizingFixedFit |
            cimgui.c.ImGuiTableFlags_RowBg,
        .{ .x = 0, .y = 0 },
        0,
    );
    defer cimgui.c.igEndTable();

    {
        _ = cimgui.c.igTableSetupColumn("", cimgui.c.ImGuiTableColumnFlags_NoResize, 0, 0);
        _ = cimgui.c.igTableSetupColumn("Number", cimgui.c.ImGuiTableColumnFlags_PreferSortAscending, 0, 0);
        _ = cimgui.c.igTableSetupColumn("Name", cimgui.c.ImGuiTableColumnFlags_WidthStretch, 0, 0);
        cimgui.c.igTableHeadersRow();
    }

    const t = self.surface.renderer_state.terminal;
    inline for (@typeInfo(terminal.Mode).Enum.fields) |field| {
        const tag: terminal.modes.ModeTag = @bitCast(@as(terminal.modes.ModeTag.Backing, field.value));

        cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
        {
            _ = cimgui.c.igTableSetColumnIndex(0);
            var value: bool = t.modes.get(@field(terminal.Mode, field.name));
            _ = cimgui.c.igCheckbox("", &value);
        }
        {
            _ = cimgui.c.igTableSetColumnIndex(1);
            cimgui.c.igText(
                "%s%d",
                if (tag.ansi) "" else "?",
                @as(u32, @intCast(tag.value)),
            );
        }
        {
            _ = cimgui.c.igTableSetColumnIndex(2);
            const name = std.fmt.comptimePrint("{s}", .{field.name});
            cimgui.c.igText("%s", name.ptr);
        }
    }
}

fn renderSizeWindow(self: *Inspector) void {
    // Start our window. If we're collapsed we do nothing.
    defer cimgui.c.igEnd();
    if (!cimgui.c.igBegin(
        window_size,
        null,
        cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
    )) return;

    cimgui.c.igSeparatorText("Dimensions");

    {
        _ = cimgui.c.igBeginTable(
            "table_size",
            2,
            cimgui.c.ImGuiTableFlags_None,
            .{ .x = 0, .y = 0 },
            0,
        );
        defer cimgui.c.igEndTable();

        // Screen Size
        {
            cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
            {
                _ = cimgui.c.igTableSetColumnIndex(0);
                cimgui.c.igText("Screen Size");
            }
            {
                _ = cimgui.c.igTableSetColumnIndex(1);
                cimgui.c.igText(
                    "%dpx x %dpx",
                    self.surface.size.screen.width,
                    self.surface.size.screen.height,
                );
            }
        }

        // Grid Size
        {
            cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
            {
                _ = cimgui.c.igTableSetColumnIndex(0);
                cimgui.c.igText("Grid Size");
            }
            {
                _ = cimgui.c.igTableSetColumnIndex(1);
                const grid_size = self.surface.size.grid();
                cimgui.c.igText(
                    "%dc x %dr",
                    grid_size.columns,
                    grid_size.rows,
                );
            }
        }

        // Cell Size
        {
            cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
            {
                _ = cimgui.c.igTableSetColumnIndex(0);
                cimgui.c.igText("Cell Size");
            }
            {
                _ = cimgui.c.igTableSetColumnIndex(1);
                cimgui.c.igText(
                    "%dpx x %dpx",
                    self.surface.size.cell.width,
                    self.surface.size.cell.height,
                );
            }
        }

        // Padding
        {
            cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
            {
                _ = cimgui.c.igTableSetColumnIndex(0);
                cimgui.c.igText("Window Padding");
            }
            {
                _ = cimgui.c.igTableSetColumnIndex(1);
                cimgui.c.igText(
                    "T=%d B=%d L=%d R=%d px",
                    self.surface.size.padding.top,
                    self.surface.size.padding.bottom,
                    self.surface.size.padding.left,
                    self.surface.size.padding.right,
                );
            }
        }
    }

    cimgui.c.igSeparatorText("Font");

    {
        _ = cimgui.c.igBeginTable(
            "table_font",
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
                cimgui.c.igText("Size (Points)");
            }
            {
                _ = cimgui.c.igTableSetColumnIndex(1);
                cimgui.c.igText(
                    "%.2f pt",
                    self.surface.font_size.points,
                );
            }
        }

        {
            cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
            {
                _ = cimgui.c.igTableSetColumnIndex(0);
                cimgui.c.igText("Size (Pixels)");
            }
            {
                _ = cimgui.c.igTableSetColumnIndex(1);
                cimgui.c.igText(
                    "%d px",
                    self.surface.font_size.pixels(),
                );
            }
        }
    }

    cimgui.c.igSeparatorText("Mouse");

    {
        _ = cimgui.c.igBeginTable(
            "table_mouse",
            2,
            cimgui.c.ImGuiTableFlags_None,
            .{ .x = 0, .y = 0 },
            0,
        );
        defer cimgui.c.igEndTable();

        const mouse = &self.surface.mouse;
        const t = self.surface.renderer_state.terminal;

        {
            const hover_point: terminal.point.Coordinate = pt: {
                const p = self.mouse.last_point orelse break :pt .{};
                const pt = t.screen.pages.pointFromPin(
                    .active,
                    p,
                ) orelse break :pt .{};
                break :pt pt.coord();
            };

            cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
            {
                _ = cimgui.c.igTableSetColumnIndex(0);
                cimgui.c.igText("Hover Grid");
            }
            {
                _ = cimgui.c.igTableSetColumnIndex(1);
                cimgui.c.igText(
                    "row=%d, col=%d",
                    hover_point.y,
                    hover_point.x,
                );
            }
        }

        {
            const coord: renderer.Coordinate.Terminal = (renderer.Coordinate{
                .surface = .{
                    .x = self.mouse.last_xpos,
                    .y = self.mouse.last_ypos,
                },
            }).convert(.terminal, self.surface.size).terminal;

            cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
            {
                _ = cimgui.c.igTableSetColumnIndex(0);
                cimgui.c.igText("Hover Point");
            }
            {
                _ = cimgui.c.igTableSetColumnIndex(1);
                cimgui.c.igText(
                    "(%dpx, %dpx)",
                    @as(i64, @intFromFloat(coord.x)),
                    @as(i64, @intFromFloat(coord.y)),
                );
            }
        }

        const any_click = for (mouse.click_state) |state| {
            if (state == .press) break true;
        } else false;

        click: {
            cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
            {
                _ = cimgui.c.igTableSetColumnIndex(0);
                cimgui.c.igText("Click State");
            }
            {
                _ = cimgui.c.igTableSetColumnIndex(1);
                if (!any_click) {
                    cimgui.c.igText("none");
                    break :click;
                }

                for (mouse.click_state, 0..) |state, i| {
                    if (state != .press) continue;
                    const button: input.MouseButton = @enumFromInt(i);
                    cimgui.c.igSameLine(0, 0);
                    cimgui.c.igText("%s", (switch (button) {
                        .unknown => "?",
                        .left => "L",
                        .middle => "M",
                        .right => "R",
                        .four => "{4}",
                        .five => "{5}",
                        .six => "{6}",
                        .seven => "{7}",
                        .eight => "{8}",
                        .nine => "{9}",
                        .ten => "{10}",
                        .eleven => "{11}",
                    }).ptr);
                }
            }
        }

        {
            const left_click_point: terminal.point.Coordinate = pt: {
                const p = mouse.left_click_pin orelse break :pt .{};
                const pt = t.screen.pages.pointFromPin(
                    .active,
                    p.*,
                ) orelse break :pt .{};
                break :pt pt.coord();
            };

            cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
            {
                _ = cimgui.c.igTableSetColumnIndex(0);
                cimgui.c.igText("Click Grid");
            }
            {
                _ = cimgui.c.igTableSetColumnIndex(1);
                cimgui.c.igText(
                    "row=%d, col=%d",
                    left_click_point.y,
                    left_click_point.x,
                );
            }
        }

        {
            cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
            {
                _ = cimgui.c.igTableSetColumnIndex(0);
                cimgui.c.igText("Click Point");
            }
            {
                _ = cimgui.c.igTableSetColumnIndex(1);
                cimgui.c.igText(
                    "(%dpx, %dpx)",
                    @as(u32, @intFromFloat(mouse.left_click_xpos)),
                    @as(u32, @intFromFloat(mouse.left_click_ypos)),
                );
            }
        }
    }
}

fn renderCellWindow(self: *Inspector) void {
    // Start our window. If we're collapsed we do nothing.
    defer cimgui.c.igEnd();
    if (!cimgui.c.igBegin(
        window_cell,
        null,
        cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
    )) return;

    // Our popup for the picker
    const popup_picker = "Cell Picker";

    if (cimgui.c.igButton("Picker", .{ .x = 0, .y = 0 })) {
        // Request a cell
        self.cell.request();

        cimgui.c.igOpenPopup_Str(
            popup_picker,
            cimgui.c.ImGuiPopupFlags_None,
        );
    }

    if (cimgui.c.igBeginPopupModal(
        popup_picker,
        null,
        cimgui.c.ImGuiWindowFlags_AlwaysAutoResize,
    )) popup: {
        defer cimgui.c.igEndPopup();

        // Once we select a cell, close this popup.
        if (self.cell == .selected) {
            cimgui.c.igCloseCurrentPopup();
            break :popup;
        }

        cimgui.c.igText(
            "Click on a cell in the terminal to inspect it.\n" ++
                "The click will be intercepted by the picker, \n" ++
                "so it won't be sent to the terminal.",
        );
        cimgui.c.igSeparator();

        if (cimgui.c.igButton("Cancel", .{ .x = 0, .y = 0 })) {
            cimgui.c.igCloseCurrentPopup();
        }
    } // cell pick popup

    cimgui.c.igSeparator();

    if (self.cell != .selected) {
        cimgui.c.igText("No cell selected.");
        return;
    }

    const selected = self.cell.selected;
    selected.cell.renderTable(
        self.surface.renderer_state.terminal,
        selected.col,
        selected.row,
    );
}

fn renderKeyboardWindow(self: *Inspector) void {
    // Start our window. If we're collapsed we do nothing.
    defer cimgui.c.igEnd();
    if (!cimgui.c.igBegin(
        window_keyboard,
        null,
        cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
    )) return;

    list: {
        if (self.key_events.empty()) {
            cimgui.c.igText("No recorded key events. Press a key with the " ++
                "terminal focused to record it.");
            break :list;
        }

        if (cimgui.c.igButton("Clear", .{ .x = 0, .y = 0 })) {
            var it = self.key_events.iterator(.forward);
            while (it.next()) |v| v.deinit(self.surface.alloc);
            self.key_events.clear();
            self.vt_stream.handler.current_seq = 1;
        }

        cimgui.c.igSeparator();

        _ = cimgui.c.igBeginTable(
            "table_key_events",
            1,
            //cimgui.c.ImGuiTableFlags_ScrollY |
            cimgui.c.ImGuiTableFlags_RowBg |
                cimgui.c.ImGuiTableFlags_Borders,
            .{ .x = 0, .y = 0 },
            0,
        );
        defer cimgui.c.igEndTable();

        var it = self.key_events.iterator(.reverse);
        while (it.next()) |ev| {
            // Need to push an ID so that our selectable is unique.
            cimgui.c.igPushID_Ptr(ev);
            defer cimgui.c.igPopID();

            cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
            _ = cimgui.c.igTableSetColumnIndex(0);

            var buf: [1024]u8 = undefined;
            const label = ev.label(&buf) catch "Key Event";
            _ = cimgui.c.igSelectable_BoolPtr(
                label.ptr,
                &ev.imgui_state.selected,
                cimgui.c.ImGuiSelectableFlags_None,
                .{ .x = 0, .y = 0 },
            );

            if (!ev.imgui_state.selected) continue;
            ev.render();
        }
    } // table
}

/// Helper function to check keyboard state and determine navigation action.
fn getKeyAction(self: *Inspector) KeyAction {
    _ = self;
    const keys = .{
        .{ .key = cimgui.c.ImGuiKey_J, .action = KeyAction.down },
        .{ .key = cimgui.c.ImGuiKey_DownArrow, .action = KeyAction.down },
        .{ .key = cimgui.c.ImGuiKey_K, .action = KeyAction.up },
        .{ .key = cimgui.c.ImGuiKey_UpArrow, .action = KeyAction.up },
    };

    inline for (keys) |k| {
        if (cimgui.c.igIsKeyPressed_Bool(k.key, false)) {
            return k.action;
        }
    }
    return .none;
}

fn renderTermioWindow(self: *Inspector) void {
    // Start our window. If we're collapsed we do nothing.
    defer cimgui.c.igEnd();
    if (!cimgui.c.igBegin(
        window_termio,
        null,
        cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
    )) return;

    const popup_filter = "Filter";

    list: {
        const pause_play: [:0]const u8 = if (self.vt_stream.handler.active)
            "Pause##pause_play"
        else
            "Resume##pause_play";
        if (cimgui.c.igButton(pause_play.ptr, .{ .x = 0, .y = 0 })) {
            self.vt_stream.handler.active = !self.vt_stream.handler.active;
        }

        cimgui.c.igSameLine(0, cimgui.c.igGetStyle().*.ItemInnerSpacing.x);
        if (cimgui.c.igButton("Filter", .{ .x = 0, .y = 0 })) {
            cimgui.c.igOpenPopup_Str(
                popup_filter,
                cimgui.c.ImGuiPopupFlags_None,
            );
        }

        if (!self.vt_events.empty()) {
            cimgui.c.igSameLine(0, cimgui.c.igGetStyle().*.ItemInnerSpacing.x);
            if (cimgui.c.igButton("Clear", .{ .x = 0, .y = 0 })) {
                var it = self.vt_events.iterator(.forward);
                while (it.next()) |v| v.deinit(self.surface.alloc);
                self.vt_events.clear();

                // We also reset the sequence number.
                self.vt_stream.handler.current_seq = 1;
            }
        }

        cimgui.c.igSeparator();

        if (self.vt_events.empty()) {
            cimgui.c.igText("Waiting for events...");
            break :list;
        }

        _ = cimgui.c.igBeginTable(
            "table_vt_events",
            3,
            cimgui.c.ImGuiTableFlags_RowBg |
                cimgui.c.ImGuiTableFlags_Borders,
            .{ .x = 0, .y = 0 },
            0,
        );
        defer cimgui.c.igEndTable();

        cimgui.c.igTableSetupColumn(
            "Seq",
            cimgui.c.ImGuiTableColumnFlags_WidthFixed,
            0,
            0,
        );
        cimgui.c.igTableSetupColumn(
            "Kind",
            cimgui.c.ImGuiTableColumnFlags_WidthFixed,
            0,
            0,
        );
        cimgui.c.igTableSetupColumn(
            "Description",
            cimgui.c.ImGuiTableColumnFlags_WidthStretch,
            0,
            0,
        );

        // Handle keyboard navigation when window is focused
        if (cimgui.c.igIsWindowFocused(cimgui.c.ImGuiFocusedFlags_RootAndChildWindows)) {
            const key_pressed = self.getKeyAction();

            switch (key_pressed) {
                .none => {},
                .up, .down => {
                    // If no event is selected, select the first/last event based on direction
                    if (self.selected_event_seq == null) {
                        if (!self.vt_events.empty()) {
                            var it = self.vt_events.iterator(if (key_pressed == .up) .forward else .reverse);
                            if (it.next()) |ev| {
                                self.selected_event_seq = @as(u32, @intCast(ev.seq));
                            }
                        }
                    } else {
                        // Find next/previous event based on current selection
                        var it = self.vt_events.iterator(.reverse);
                        switch (key_pressed) {
                            .down => {
                                var found = false;
                                while (it.next()) |ev| {
                                    if (found) {
                                        self.selected_event_seq = @as(u32, @intCast(ev.seq));
                                        break;
                                    }
                                    if (ev.seq == self.selected_event_seq.?) {
                                        found = true;
                                    }
                                }
                            },
                            .up => {
                                var prev_ev: ?*const inspector.termio.VTEvent = null;
                                while (it.next()) |ev| {
                                    if (ev.seq == self.selected_event_seq.?) {
                                        if (prev_ev) |prev| {
                                            self.selected_event_seq = @as(u32, @intCast(prev.seq));
                                            break;
                                        }
                                    }
                                    prev_ev = ev;
                                }
                            },
                            .none => unreachable,
                        }
                    }

                    // Mark that we need to scroll to the newly selected item
                    self.need_scroll_to_selected = true;
                    self.is_keyboard_selection = true;
                },
            }
        }

        var it = self.vt_events.iterator(.reverse);
        while (it.next()) |ev| {
            // Need to push an ID so that our selectable is unique.
            cimgui.c.igPushID_Ptr(ev);
            defer cimgui.c.igPopID();

            cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
            _ = cimgui.c.igTableNextColumn();

            // Store the previous selection state to detect changes
            const was_selected = ev.imgui_selected;

            // Update selection state based on keyboard navigation
            if (self.selected_event_seq) |seq| {
                ev.imgui_selected = (@as(u32, @intCast(ev.seq)) == seq);
            }

            // Handle selectable widget
            if (cimgui.c.igSelectable_BoolPtr(
                "##select",
                &ev.imgui_selected,
                cimgui.c.ImGuiSelectableFlags_SpanAllColumns,
                .{ .x = 0, .y = 0 },
            )) {
                // If selection state changed, update keyboard navigation state
                if (ev.imgui_selected != was_selected) {
                    self.selected_event_seq = if (ev.imgui_selected)
                        @as(u32, @intCast(ev.seq))
                    else
                        null;
                    self.is_keyboard_selection = false;
                }
            }

            cimgui.c.igSameLine(0, 0);
            cimgui.c.igText("%d", ev.seq);
            _ = cimgui.c.igTableNextColumn();
            cimgui.c.igText("%s", @tagName(ev.kind).ptr);
            _ = cimgui.c.igTableNextColumn();
            cimgui.c.igText("%s", ev.str.ptr);

            // If the event is selected, we render info about it. For now
            // we put this in the last column because thats the widest and
            // imgui has no way to make a column span.
            if (ev.imgui_selected) {
                {
                    _ = cimgui.c.igBeginTable(
                        "details",
                        2,
                        cimgui.c.ImGuiTableFlags_None,
                        .{ .x = 0, .y = 0 },
                        0,
                    );
                    defer cimgui.c.igEndTable();
                    inspector.cursor.renderInTable(
                        self.surface.renderer_state.terminal,
                        &ev.cursor,
                    );

                    {
                        cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
                        {
                            _ = cimgui.c.igTableSetColumnIndex(0);
                            cimgui.c.igText("Scroll Region");
                        }
                        {
                            _ = cimgui.c.igTableSetColumnIndex(1);
                            cimgui.c.igText(
                                "T=%d B=%d L=%d R=%d",
                                ev.scrolling_region.top,
                                ev.scrolling_region.bottom,
                                ev.scrolling_region.left,
                                ev.scrolling_region.right,
                            );
                        }
                    }

                    var md_it = ev.metadata.iterator();
                    while (md_it.next()) |entry| {
                        var buf: [256]u8 = undefined;
                        const key = std.fmt.bufPrintZ(&buf, "{s}", .{entry.key_ptr.*}) catch
                            "<internal error>";
                        cimgui.c.igTableNextRow(cimgui.c.ImGuiTableRowFlags_None, 0);
                        _ = cimgui.c.igTableNextColumn();
                        cimgui.c.igText("%s", key.ptr);
                        _ = cimgui.c.igTableNextColumn();
                        cimgui.c.igText("%s", entry.value_ptr.ptr);
                    }
                }

                // If this is the selected event and scrolling is needed, scroll to it
                if (self.need_scroll_to_selected and self.is_keyboard_selection) {
                    cimgui.c.igSetScrollHereY(0.5);
                    self.need_scroll_to_selected = false;
                }
            }
        }
    } // table

    if (cimgui.c.igBeginPopupModal(
        popup_filter,
        null,
        cimgui.c.ImGuiWindowFlags_AlwaysAutoResize,
    )) {
        defer cimgui.c.igEndPopup();

        cimgui.c.igText("Changed filter settings will only affect future events.");

        cimgui.c.igSeparator();

        {
            _ = cimgui.c.igBeginTable(
                "table_filter_kind",
                3,
                cimgui.c.ImGuiTableFlags_None,
                .{ .x = 0, .y = 0 },
                0,
            );
            defer cimgui.c.igEndTable();

            inline for (@typeInfo(terminal.Parser.Action.Tag).Enum.fields) |field| {
                const tag = @field(terminal.Parser.Action.Tag, field.name);
                if (tag == .apc_put or tag == .dcs_put) continue;

                _ = cimgui.c.igTableNextColumn();
                var value = !self.vt_stream.handler.filter_exclude.contains(tag);
                if (cimgui.c.igCheckbox(@tagName(tag).ptr, &value)) {
                    if (value) {
                        self.vt_stream.handler.filter_exclude.remove(tag);
                    } else {
                        self.vt_stream.handler.filter_exclude.insert(tag);
                    }
                }
            }
        } // Filter kind table

        cimgui.c.igSeparator();

        cimgui.c.igText(
            "Filter by string. Empty displays all, \"abc\" finds lines\n" ++
                "containing \"abc\", \"abc,xyz\" finds lines containing \"abc\"\n" ++
                "or \"xyz\", \"-abc\" excludes lines containing \"abc\".",
        );
        _ = cimgui.c.ImGuiTextFilter_Draw(
            self.vt_stream.handler.filter_text,
            "##filter_text",
            0,
        );

        cimgui.c.igSeparator();
        if (cimgui.c.igButton("Close", .{ .x = 0, .y = 0 })) {
            cimgui.c.igCloseCurrentPopup();
        }
    } // filter popup
}
