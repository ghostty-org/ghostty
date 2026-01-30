//! The Inspector is a development tool to debug the terminal. This is
//! useful for terminal application developers as well as people potentially
//! debugging issues in Ghostty itself.
const Inspector = @This();

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const cimgui = @import("dcimgui");
const Surface = @import("../Surface.zig");
const font = @import("../font/main.zig");
const input = @import("../input.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const inspector = @import("main.zig");
const units = @import("units.zig");
const apprt = @import("../apprt.zig");

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
    const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

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

        var font_config: cimgui.c.ImFontConfig = undefined;
        cimgui.ext.ImFontConfig_ImFontConfig(&font_config);
        font_config.FontDataOwnedByAtlas = false;
        _ = cimgui.c.ImFontAtlas_AddFontFromMemoryTTF(
            io.Fonts,
            @ptrCast(@constCast(font.embedded.regular.ptr)),
            @intCast(font.embedded.regular.len),
            font_size,
            &font_config,
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
        .vt_stream = .initAlloc(surface.alloc, vt_handler),
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
    const dock_id = cimgui.c.ImGui_DockSpaceOverViewport();

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
        cimgui.c.ImGui_ShowDemoWindow(&show);
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
    cimgui.c.ImGui_SetWindowFocusStr(window_screen);

    // Setup our initial layout.
    const dock_id: struct {
        left: cimgui.c.ImGuiID,
        right: cimgui.c.ImGuiID,
    } = dock_id: {
        var dock_id_left: cimgui.c.ImGuiID = undefined;
        var dock_id_right: cimgui.c.ImGuiID = undefined;
        _ = cimgui.ImGui_DockBuilderSplitNode(
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

    cimgui.ImGui_DockBuilderDockWindow(window_cell, dock_id.left);
    cimgui.ImGui_DockBuilderDockWindow(window_modes, dock_id.left);
    cimgui.ImGui_DockBuilderDockWindow(window_keyboard, dock_id.left);
    cimgui.ImGui_DockBuilderDockWindow(window_termio, dock_id.left);
    cimgui.ImGui_DockBuilderDockWindow(window_screen, dock_id.left);
    cimgui.ImGui_DockBuilderDockWindow(window_imgui_demo, dock_id.left);
    cimgui.ImGui_DockBuilderDockWindow(window_size, dock_id.right);
    cimgui.ImGui_DockBuilderFinish(dock_id_main);
}

fn renderScreenWindow(self: *Inspector) void {
    // Start our window. If we're collapsed we do nothing.
    defer cimgui.c.ImGui_End();
    if (!cimgui.c.ImGui_Begin(
        window_screen,
        null,
        cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
    )) return;

    const t = self.surface.renderer_state.terminal;
    const screen: *terminal.Screen = t.screens.active;

    {
        _ = cimgui.c.ImGui_BeginTable(
            "table_screen",
            2,
            cimgui.c.ImGuiTableFlags_None,
        );
        defer cimgui.c.ImGui_EndTable();

        {
            cimgui.c.ImGui_TableNextRow();
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                cimgui.c.ImGui_Text("Active Screen");
            }
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                cimgui.c.ImGui_Text("%s", @tagName(t.screens.active_key).ptr);
            }
        }
    }

    if (cimgui.c.ImGui_CollapsingHeader(
        "Cursor",
        cimgui.c.ImGuiTreeNodeFlags_DefaultOpen,
    )) {
        {
            _ = cimgui.c.ImGui_BeginTable(
                "table_cursor",
                2,
                cimgui.c.ImGuiTableFlags_None,
            );
            defer cimgui.c.ImGui_EndTable();
            inspector.cursor.renderInTable(
                self.surface.renderer_state.terminal,
                &screen.cursor,
            );
        } // table

        cimgui.c.ImGui_TextDisabled("(Any styles not shown are not currently set)");
    } // cursor

    if (cimgui.c.ImGui_CollapsingHeader(
        "Keyboard",
        cimgui.c.ImGuiTreeNodeFlags_DefaultOpen,
    )) {
        {
            _ = cimgui.c.ImGui_BeginTable(
                "table_keyboard",
                2,
                cimgui.c.ImGuiTableFlags_None,
            );
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
                            const name = std.fmt.comptimePrint("{s}", .{field.name});
                            cimgui.c.ImGui_Text("%s", name.ptr);
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
                            if (t.flags.modify_other_keys_2) "true".ptr else "false".ptr,
                        );
                    }
                }
            } // keyboard mode info
        } // table
    } // keyboard

    if (cimgui.c.ImGui_CollapsingHeader(
        "Kitty Graphics",
        cimgui.c.ImGuiTreeNodeFlags_DefaultOpen,
    )) kitty_gfx: {
        if (!screen.kitty_images.enabled()) {
            cimgui.c.ImGui_TextDisabled("(Kitty graphics are disabled)");
            break :kitty_gfx;
        }

        {
            _ = cimgui.c.ImGui_BeginTable(
                "##kitty_graphics",
                2,
                cimgui.c.ImGuiTableFlags_None,
            );
            defer cimgui.c.ImGui_EndTable();

            const kitty_images = &screen.kitty_images;

            {
                cimgui.c.ImGui_TableNextRow();
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                    cimgui.c.ImGui_Text("Memory Usage");
                }
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                    cimgui.c.ImGui_Text("%d bytes (%d KiB)", kitty_images.total_bytes, units.toKibiBytes(kitty_images.total_bytes));
                }
            }

            {
                cimgui.c.ImGui_TableNextRow();
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                    cimgui.c.ImGui_Text("Memory Limit");
                }
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                    cimgui.c.ImGui_Text("%d bytes (%d KiB)", kitty_images.total_limit, units.toKibiBytes(kitty_images.total_limit));
                }
            }

            {
                cimgui.c.ImGui_TableNextRow();
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                    cimgui.c.ImGui_Text("Image Count");
                }
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                    cimgui.c.ImGui_Text("%d", kitty_images.images.count());
                }
            }

            {
                cimgui.c.ImGui_TableNextRow();
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                    cimgui.c.ImGui_Text("Placement Count");
                }
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                    cimgui.c.ImGui_Text("%d", kitty_images.placements.count());
                }
            }

            {
                cimgui.c.ImGui_TableNextRow();
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                    cimgui.c.ImGui_Text("Image Loading");
                }
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                    cimgui.c.ImGui_Text("%s", if (kitty_images.loading != null) "true".ptr else "false".ptr);
                }
            }
        } // table
    } // kitty graphics

    if (cimgui.c.ImGui_CollapsingHeader(
        "Internal Terminal State",
        cimgui.c.ImGuiTreeNodeFlags_DefaultOpen,
    )) {
        const pages = &screen.pages;

        {
            _ = cimgui.c.ImGui_BeginTable(
                "##terminal_state",
                2,
                cimgui.c.ImGuiTableFlags_None,
            );
            defer cimgui.c.ImGui_EndTable();

            {
                cimgui.c.ImGui_TableNextRow();
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                    cimgui.c.ImGui_Text("Memory Usage");
                }
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                    cimgui.c.ImGui_Text("%d bytes (%d KiB)", pages.page_size, units.toKibiBytes(pages.page_size));
                }
            }

            {
                cimgui.c.ImGui_TableNextRow();
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                    cimgui.c.ImGui_Text("Memory Limit");
                }
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                    cimgui.c.ImGui_Text("%d bytes (%d KiB)", pages.maxSize(), units.toKibiBytes(pages.maxSize()));
                }
            }

            {
                cimgui.c.ImGui_TableNextRow();
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                    cimgui.c.ImGui_Text("Viewport Location");
                }
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                    cimgui.c.ImGui_Text("%s", @tagName(pages.viewport).ptr);
                }
            }
        } // table
        //
        if (cimgui.c.ImGui_CollapsingHeader(
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
    defer cimgui.c.ImGui_End();
    if (!cimgui.c.ImGui_Begin(
        window_modes,
        null,
        cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
    )) return;

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

    const t = self.surface.renderer_state.terminal;
    inline for (@typeInfo(terminal.Mode).@"enum".fields) |field| {
        @setEvalBranchQuota(6000);
        const tag: terminal.modes.ModeTag = @bitCast(@as(terminal.modes.ModeTag.Backing, field.value));

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

fn renderSizeWindow(self: *Inspector) void {
    // Start our window. If we're collapsed we do nothing.
    defer cimgui.c.ImGui_End();
    if (!cimgui.c.ImGui_Begin(
        window_size,
        null,
        cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
    )) return;

    cimgui.c.ImGui_SeparatorText("Dimensions");

    {
        _ = cimgui.c.ImGui_BeginTable(
            "table_size",
            2,
            cimgui.c.ImGuiTableFlags_None,
        );
        defer cimgui.c.ImGui_EndTable();

        // Screen Size
        {
            cimgui.c.ImGui_TableNextRow();
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                cimgui.c.ImGui_Text("Screen Size");
            }
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                cimgui.c.ImGui_Text(
                    "%dpx x %dpx",
                    self.surface.size.screen.width,
                    self.surface.size.screen.height,
                );
            }
        }

        // Grid Size
        {
            cimgui.c.ImGui_TableNextRow();
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                cimgui.c.ImGui_Text("Grid Size");
            }
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                const grid_size = self.surface.size.grid();
                cimgui.c.ImGui_Text(
                    "%dc x %dr",
                    grid_size.columns,
                    grid_size.rows,
                );
            }
        }

        // Cell Size
        {
            cimgui.c.ImGui_TableNextRow();
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                cimgui.c.ImGui_Text("Cell Size");
            }
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                cimgui.c.ImGui_Text(
                    "%dpx x %dpx",
                    self.surface.size.cell.width,
                    self.surface.size.cell.height,
                );
            }
        }

        // Padding
        {
            cimgui.c.ImGui_TableNextRow();
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                cimgui.c.ImGui_Text("Window Padding");
            }
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                cimgui.c.ImGui_Text(
                    "T=%d B=%d L=%d R=%d px",
                    self.surface.size.padding.top,
                    self.surface.size.padding.bottom,
                    self.surface.size.padding.left,
                    self.surface.size.padding.right,
                );
            }
        }
    }

    cimgui.c.ImGui_SeparatorText("Font");

    {
        _ = cimgui.c.ImGui_BeginTable(
            "table_font",
            2,
            cimgui.c.ImGuiTableFlags_None,
        );
        defer cimgui.c.ImGui_EndTable();

        {
            cimgui.c.ImGui_TableNextRow();
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                cimgui.c.ImGui_Text("Size (Points)");
            }
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                cimgui.c.ImGui_Text(
                    "%.2f pt",
                    self.surface.font_size.points,
                );
            }
        }

        {
            cimgui.c.ImGui_TableNextRow();
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                cimgui.c.ImGui_Text("Size (Pixels)");
            }
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                cimgui.c.ImGui_Text(
                    "%.2f px",
                    self.surface.font_size.pixels(),
                );
            }
        }
    }

    cimgui.c.ImGui_SeparatorText("Mouse");

    {
        _ = cimgui.c.ImGui_BeginTable(
            "table_mouse",
            2,
            cimgui.c.ImGuiTableFlags_None,
        );
        defer cimgui.c.ImGui_EndTable();

        const mouse = &self.surface.mouse;
        const t = self.surface.renderer_state.terminal;

        {
            const hover_point: terminal.point.Coordinate = pt: {
                const p = self.mouse.last_point orelse break :pt .{};
                const pt = t.screens.active.pages.pointFromPin(
                    .active,
                    p,
                ) orelse break :pt .{};
                break :pt pt.coord();
            };

            cimgui.c.ImGui_TableNextRow();
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                cimgui.c.ImGui_Text("Hover Grid");
            }
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                cimgui.c.ImGui_Text(
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

            cimgui.c.ImGui_TableNextRow();
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                cimgui.c.ImGui_Text("Hover Point");
            }
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                cimgui.c.ImGui_Text(
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
            cimgui.c.ImGui_TableNextRow();
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                cimgui.c.ImGui_Text("Click State");
            }
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                if (!any_click) {
                    cimgui.c.ImGui_Text("none");
                    break :click;
                }

                for (mouse.click_state, 0..) |state, i| {
                    if (state != .press) continue;
                    const button: input.MouseButton = @enumFromInt(i);
                    cimgui.c.ImGui_SameLine();
                    cimgui.c.ImGui_Text("%s", (switch (button) {
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
                const pt = t.screens.active.pages.pointFromPin(
                    .active,
                    p.*,
                ) orelse break :pt .{};
                break :pt pt.coord();
            };

            cimgui.c.ImGui_TableNextRow();
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                cimgui.c.ImGui_Text("Click Grid");
            }
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                cimgui.c.ImGui_Text(
                    "row=%d, col=%d",
                    left_click_point.y,
                    left_click_point.x,
                );
            }
        }

        {
            cimgui.c.ImGui_TableNextRow();
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                cimgui.c.ImGui_Text("Click Point");
            }
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                cimgui.c.ImGui_Text(
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
    defer cimgui.c.ImGui_End();
    if (!cimgui.c.ImGui_Begin(
        window_cell,
        null,
        cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
    )) return;

    // Our popup for the picker
    const popup_picker = "Cell Picker";

    if (cimgui.c.ImGui_Button("Picker")) {
        // Request a cell
        self.cell.request();

        cimgui.c.ImGui_OpenPopup(
            popup_picker,
            cimgui.c.ImGuiPopupFlags_None,
        );
    }

    if (cimgui.c.ImGui_BeginPopupModal(
        popup_picker,
        null,
        cimgui.c.ImGuiWindowFlags_AlwaysAutoResize,
    )) popup: {
        defer cimgui.c.ImGui_EndPopup();

        // Once we select a cell, close this popup.
        if (self.cell == .selected) {
            cimgui.c.ImGui_CloseCurrentPopup();
            break :popup;
        }

        cimgui.c.ImGui_Text(
            "Click on a cell in the terminal to inspect it.\n" ++
                "The click will be intercepted by the picker, \n" ++
                "so it won't be sent to the terminal.",
        );
        cimgui.c.ImGui_Separator();

        if (cimgui.c.ImGui_Button("Cancel")) {
            cimgui.c.ImGui_CloseCurrentPopup();
        }
    } // cell pick popup

    cimgui.c.ImGui_Separator();

    if (self.cell != .selected) {
        cimgui.c.ImGui_Text("No cell selected.");
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
    defer cimgui.c.ImGui_End();
    if (!cimgui.c.ImGui_Begin(
        window_keyboard,
        null,
        cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
    )) return;

    list: {
        if (self.key_events.empty()) {
            cimgui.c.ImGui_Text("No recorded key events. Press a key with the " ++
                "terminal focused to record it.");
            break :list;
        }

        if (cimgui.c.ImGui_Button("Clear")) {
            var it = self.key_events.iterator(.forward);
            while (it.next()) |v| v.deinit(self.surface.alloc);
            self.key_events.clear();
            self.vt_stream.handler.current_seq = 1;
        }

        cimgui.c.ImGui_Separator();

        _ = cimgui.c.ImGui_BeginTable(
            "table_key_events",
            1,
            //cimgui.c.ImGuiTableFlags_ScrollY |
            cimgui.c.ImGuiTableFlags_RowBg |
                cimgui.c.ImGuiTableFlags_Borders,
        );
        defer cimgui.c.ImGui_EndTable();

        var it = self.key_events.iterator(.reverse);
        while (it.next()) |ev| {
            // Need to push an ID so that our selectable is unique.
            cimgui.c.ImGui_PushIDPtr(ev);
            defer cimgui.c.ImGui_PopID();

            cimgui.c.ImGui_TableNextRow();
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);

            var buf: [1024]u8 = undefined;
            const label = ev.label(&buf) catch "Key Event";
            _ = cimgui.c.ImGui_SelectableBoolPtr(
                label.ptr,
                &ev.imgui_state.selected,
                cimgui.c.ImGuiSelectableFlags_None,
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
        if (cimgui.c.ImGui_IsKeyPressed(k.key)) {
            return k.action;
        }
    }
    return .none;
}

fn renderTermioWindow(self: *Inspector) void {
    // Start our window. If we're collapsed we do nothing.
    defer cimgui.c.ImGui_End();
    if (!cimgui.c.ImGui_Begin(
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
        if (cimgui.c.ImGui_Button(pause_play.ptr)) {
            self.vt_stream.handler.active = !self.vt_stream.handler.active;
        }

        cimgui.c.ImGui_SameLineEx(0, cimgui.c.ImGui_GetStyle().*.ItemInnerSpacing.x);
        if (cimgui.c.ImGui_Button("Filter")) {
            cimgui.c.ImGui_OpenPopup(
                popup_filter,
                cimgui.c.ImGuiPopupFlags_None,
            );
        }

        if (!self.vt_events.empty()) {
            cimgui.c.ImGui_SameLineEx(0, cimgui.c.ImGui_GetStyle().*.ItemInnerSpacing.x);
            if (cimgui.c.ImGui_Button("Clear")) {
                var it = self.vt_events.iterator(.forward);
                while (it.next()) |v| v.deinit(self.surface.alloc);
                self.vt_events.clear();

                // We also reset the sequence number.
                self.vt_stream.handler.current_seq = 1;
            }
        }

        if (!self.vt_events.empty()) {
            cimgui.c.ImGui_SameLineEx(0, cimgui.c.ImGui_GetStyle().*.ItemInnerSpacing.x);
            if (cimgui.c.ImGui_Button("Copy")) {
                // Build a string from all events
                var buf: std.ArrayListUnmanaged(u8) = .empty;
                defer buf.deinit(self.surface.alloc);

                var it = self.vt_events.iterator(.forward);
                while (it.next()) |ev| {
                    buf.writer(self.surface.alloc).print("{d}\t{s}\t{s}\n", .{
                        ev.seq,
                        @tagName(ev.kind),
                        ev.str,
                    }) catch break;
                }

                // Copy to clipboard - need to add sentinel
                if (buf.items.len > 0) {
                    buf.append(self.surface.alloc, 0) catch {};
                    const str: [:0]const u8 = buf.items[0 .. buf.items.len - 1 :0];
                    self.surface.rt_surface.setClipboard(
                        .standard,
                        &.{.{ .mime = "text/plain", .data = str }},
                        false,
                    ) catch |err| {
                        std.log.warn("failed to copy to clipboard: {}", .{err});
                    };
                }
            }
        }

        cimgui.c.ImGui_Separator();

        if (self.vt_events.empty()) {
            cimgui.c.ImGui_Text("Waiting for events...");
            break :list;
        }

        _ = cimgui.c.ImGui_BeginTable(
            "table_vt_events",
            3,
            cimgui.c.ImGuiTableFlags_RowBg |
                cimgui.c.ImGuiTableFlags_Borders,
        );
        defer cimgui.c.ImGui_EndTable();

        cimgui.c.ImGui_TableSetupColumn(
            "Seq",
            cimgui.c.ImGuiTableColumnFlags_WidthFixed,
        );
        cimgui.c.ImGui_TableSetupColumn(
            "Kind",
            cimgui.c.ImGuiTableColumnFlags_WidthFixed,
        );
        cimgui.c.ImGui_TableSetupColumn(
            "Description",
            cimgui.c.ImGuiTableColumnFlags_WidthStretch,
        );

        // Handle keyboard navigation when window is focused
        if (cimgui.c.ImGui_IsWindowFocused(cimgui.c.ImGuiFocusedFlags_RootAndChildWindows)) {
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
            cimgui.c.ImGui_PushIDPtr(ev);
            defer cimgui.c.ImGui_PopID();

            cimgui.c.ImGui_TableNextRow();
            _ = cimgui.c.ImGui_TableNextColumn();

            // Store the previous selection state to detect changes
            const was_selected = ev.imgui_selected;

            // Update selection state based on keyboard navigation
            if (self.selected_event_seq) |seq| {
                ev.imgui_selected = (@as(u32, @intCast(ev.seq)) == seq);
            }

            // Handle selectable widget
            if (cimgui.c.ImGui_SelectableBoolPtr(
                "##select",
                &ev.imgui_selected,
                cimgui.c.ImGuiSelectableFlags_SpanAllColumns,
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

            cimgui.c.ImGui_SameLine();
            cimgui.c.ImGui_Text("%d", ev.seq);
            _ = cimgui.c.ImGui_TableNextColumn();
            cimgui.c.ImGui_Text("%s", @tagName(ev.kind).ptr);
            _ = cimgui.c.ImGui_TableNextColumn();
            cimgui.c.ImGui_Text("%s", ev.str.ptr);

            // If the event is selected, we render info about it. For now
            // we put this in the last column because that's the widest and
            // imgui has no way to make a column span.
            if (ev.imgui_selected) {
                {
                    _ = cimgui.c.ImGui_BeginTable(
                        "details",
                        2,
                        cimgui.c.ImGuiTableFlags_None,
                    );
                    defer cimgui.c.ImGui_EndTable();
                    inspector.cursor.renderInTable(
                        self.surface.renderer_state.terminal,
                        &ev.cursor,
                    );

                    {
                        cimgui.c.ImGui_TableNextRow();
                        {
                            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                            cimgui.c.ImGui_Text("Scroll Region");
                        }
                        {
                            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                            cimgui.c.ImGui_Text(
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
                        cimgui.c.ImGui_TableNextRow();
                        _ = cimgui.c.ImGui_TableNextColumn();
                        cimgui.c.ImGui_Text("%s", key.ptr);
                        _ = cimgui.c.ImGui_TableNextColumn();
                        cimgui.c.ImGui_Text("%s", entry.value_ptr.ptr);
                    }
                }

                // If this is the selected event and scrolling is needed, scroll to it
                if (self.need_scroll_to_selected and self.is_keyboard_selection) {
                    cimgui.c.ImGui_SetScrollHereY(0.5);
                    self.need_scroll_to_selected = false;
                }
            }
        }
    } // table

    if (cimgui.c.ImGui_BeginPopupModal(
        popup_filter,
        null,
        cimgui.c.ImGuiWindowFlags_AlwaysAutoResize,
    )) {
        defer cimgui.c.ImGui_EndPopup();

        cimgui.c.ImGui_Text("Changed filter settings will only affect future events.");

        cimgui.c.ImGui_Separator();

        {
            _ = cimgui.c.ImGui_BeginTable(
                "table_filter_kind",
                3,
                cimgui.c.ImGuiTableFlags_None,
            );
            defer cimgui.c.ImGui_EndTable();

            inline for (@typeInfo(terminal.Parser.Action.Tag).@"enum".fields) |field| {
                const tag = @field(terminal.Parser.Action.Tag, field.name);
                if (tag == .apc_put or tag == .dcs_put) continue;

                _ = cimgui.c.ImGui_TableNextColumn();
                var value = !self.vt_stream.handler.filter_exclude.contains(tag);
                if (cimgui.c.ImGui_Checkbox(@tagName(tag).ptr, &value)) {
                    if (value) {
                        self.vt_stream.handler.filter_exclude.remove(tag);
                    } else {
                        self.vt_stream.handler.filter_exclude.insert(tag);
                    }
                }
            }
        } // Filter kind table

        cimgui.c.ImGui_Separator();

        cimgui.c.ImGui_Text(
            "Filter by string. Empty displays all, \"abc\" finds lines\n" ++
                "containing \"abc\", \"abc,xyz\" finds lines containing \"abc\"\n" ++
                "or \"xyz\", \"-abc\" excludes lines containing \"abc\".",
        );
        _ = cimgui.c.ImGuiTextFilter_Draw(
            &self.vt_stream.handler.filter_text,
            "##filter_text",
            0,
        );

        cimgui.c.ImGui_Separator();
        if (cimgui.c.ImGui_Button("Close")) {
            cimgui.c.ImGui_CloseCurrentPopup();
        }
    } // filter popup
}
