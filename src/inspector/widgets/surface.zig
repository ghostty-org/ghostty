const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const cimgui = @import("dcimgui");
const inspector = @import("../main.zig");
const widgets = @import("../widgets.zig");
const input = @import("../../input.zig");
const renderer = @import("../../renderer.zig");
const terminal = @import("../../terminal/main.zig");
const Surface = @import("../../Surface.zig");

/// This is discovered via the hardcoded string in the ImGui demo window.
const window_imgui_demo = "Dear ImGui Demo";
const window_keyboard = "Keyboard";
const window_terminal = "Terminal";
const window_surface = "Surface";
const window_termio = "Terminal IO";
const window_renderer = "Renderer";

pub const Inspector = struct {
    /// Internal GUI state
    surface_info: Info,
    key_stream: widgets.key.Stream,
    terminal_info: widgets.terminal.Info,
    vt_stream: widgets.termio.Stream,
    renderer_info: widgets.renderer.Info,
    show_demo_window: bool,

    pub fn init(alloc: Allocator) !Inspector {
        return .{
            .surface_info = .empty,
            .key_stream = try .init(alloc),
            .terminal_info = .empty,
            .vt_stream = try .init(alloc),
            .renderer_info = .empty,
            .show_demo_window = true,
        };
    }

    pub fn deinit(self: *Inspector, alloc: Allocator) void {
        self.key_stream.deinit(alloc);
        self.vt_stream.deinit(alloc);
        self.renderer_info.deinit(alloc);
    }

    pub fn draw(
        self: *Inspector,
        surface: *const Surface,
        mouse: Mouse,
    ) void {
        // Create our dockspace first. If we had to setup our dockspace,
        // then it is a first render.
        const dockspace_id = cimgui.c.ImGui_GetID("Main Dockspace");
        const first_render = createDockSpace(dockspace_id);

        // Draw everything that requires the terminal state mutex.
        {
            surface.renderer_state.mutex.lock();
            defer surface.renderer_state.mutex.unlock();
            const t = surface.renderer_state.terminal;

            // Terminal info window
            {
                const open = cimgui.c.ImGui_Begin(
                    window_terminal,
                    null,
                    cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
                );
                defer cimgui.c.ImGui_End();
                self.terminal_info.draw(open, t);
            }

            // Surface info window
            {
                const open = cimgui.c.ImGui_Begin(
                    window_surface,
                    null,
                    cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
                );
                defer cimgui.c.ImGui_End();
                self.surface_info.draw(
                    open,
                    surface,
                    mouse,
                );
            }

            // Keyboard info window
            {
                const open = cimgui.c.ImGui_Begin(
                    window_keyboard,
                    null,
                    cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
                );
                defer cimgui.c.ImGui_End();
                self.key_stream.draw(
                    open,
                    surface.alloc,
                );
            }

            // Terminal IO window
            {
                const open = cimgui.c.ImGui_Begin(
                    window_termio,
                    null,
                    cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
                );
                defer cimgui.c.ImGui_End();
                if (open) {
                    self.vt_stream.draw(
                        surface.alloc,
                        &t.colors.palette.current,
                    );
                }
            }

            // Renderer info window
            {
                const open = cimgui.c.ImGui_Begin(
                    window_renderer,
                    null,
                    cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
                );
                defer cimgui.c.ImGui_End();
                self.renderer_info.draw(
                    surface.alloc,
                    open,
                );
            }
        }

        // In debug we show the ImGui demo window so we can easily view
        // available widgets and such.
        if (comptime builtin.mode == .Debug) {
            if (self.show_demo_window) {
                cimgui.c.ImGui_ShowDemoWindow(&self.show_demo_window);
            }
        }

        if (first_render) {
            // On first render, setup our initial focus state. We only
            // do this on first render so that we can let the user change
            // focus afterward without it snapping back.
            cimgui.c.ImGui_SetWindowFocusStr(window_terminal);
        }
    }

    /// Create the global dock space for the inspector. A dock space
    /// is a special area where windows can be docked into. The global
    /// dock space fills the entire main viewport.
    ///
    /// Returns true if this was the first time the dock space was created.
    fn createDockSpace(dockspace_id: cimgui.c.ImGuiID) bool {
        const viewport: *cimgui.c.ImGuiViewport = cimgui.c.ImGui_GetMainViewport();

        // Initial Docking setup
        const setup = cimgui.ImGui_DockBuilderGetNode(dockspace_id) == null;
        if (setup) {
            // Register our dockspace node
            assert(cimgui.ImGui_DockBuilderAddNodeEx(
                dockspace_id,
                cimgui.ImGuiDockNodeFlagsPrivate.DockSpace,
            ) == dockspace_id);

            // Ensure it is the full size of the viewport
            cimgui.ImGui_DockBuilderSetNodeSize(
                dockspace_id,
                viewport.Size,
            );

            // We only initialize one central docking point now but
            // this is the point we'd pre-split and so on for the initial
            // layout.
            const dock_id_main: cimgui.c.ImGuiID = dockspace_id;
            cimgui.ImGui_DockBuilderDockWindow(window_imgui_demo, dock_id_main);
            cimgui.ImGui_DockBuilderDockWindow(window_terminal, dock_id_main);
            cimgui.ImGui_DockBuilderDockWindow(window_surface, dock_id_main);
            cimgui.ImGui_DockBuilderDockWindow(window_keyboard, dock_id_main);
            cimgui.ImGui_DockBuilderDockWindow(window_termio, dock_id_main);
            cimgui.ImGui_DockBuilderDockWindow(window_renderer, dock_id_main);
            cimgui.ImGui_DockBuilderFinish(dockspace_id);
        }

        // Put the dockspace over the viewport.
        assert(cimgui.c.ImGui_DockSpaceOverViewportEx(
            dockspace_id,
            viewport,
            cimgui.c.ImGuiDockNodeFlags_PassthruCentralNode,
            null,
        ) == dockspace_id);
        return setup;
    }
};

pub const Mouse = struct {
    /// Last hovered x/y
    last_xpos: f64 = 0,
    last_ypos: f64 = 0,

    // Last hovered screen point
    last_point: ?terminal.Pin = null,
};

/// Surface information inspector widget.
pub const Info = struct {
    pub const empty: Info = .{};

    /// Draw the surface info window.
    pub fn draw(
        self: *Info,
        open: bool,
        surface: *const Surface,
        mouse: Mouse,
    ) void {
        _ = self;
        if (!open) return;

        if (cimgui.c.ImGui_CollapsingHeader(
            "Help",
            cimgui.c.ImGuiTreeNodeFlags_None,
        )) {
            cimgui.c.ImGui_TextWrapped(
                "This window displays information about the surface (window). " ++
                    "A surface is the graphical area that displays the terminal " ++
                    "content. It includes dimensions, font sizing, and mouse state " ++
                    "information specific to this window instance.",
            );
        }

        cimgui.c.ImGui_SeparatorText("Dimensions");
        dimensionsTable(surface);

        cimgui.c.ImGui_SeparatorText("Font");
        fontTable(surface);

        cimgui.c.ImGui_SeparatorText("Mouse");
        mouseTable(surface, mouse);
    }
};

fn dimensionsTable(surface: *const Surface) void {
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
                surface.size.screen.width,
                surface.size.screen.height,
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
            const grid_size = surface.size.grid();
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
                surface.size.cell.width,
                surface.size.cell.height,
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
                surface.size.padding.top,
                surface.size.padding.bottom,
                surface.size.padding.left,
                surface.size.padding.right,
            );
        }
    }
}

fn fontTable(surface: *const Surface) void {
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
                surface.font_size.points,
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
                surface.font_size.pixels(),
            );
        }
    }
}

fn mouseTable(
    surface: *const Surface,
    mouse: Mouse,
) void {
    _ = cimgui.c.ImGui_BeginTable(
        "table_mouse",
        2,
        cimgui.c.ImGuiTableFlags_None,
    );
    defer cimgui.c.ImGui_EndTable();

    const surface_mouse = &surface.mouse;
    const t = surface.renderer_state.terminal;

    {
        const hover_point: terminal.point.Coordinate = pt: {
            const p = mouse.last_point orelse break :pt .{};
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
                .x = mouse.last_xpos,
                .y = mouse.last_ypos,
            },
        }).convert(.terminal, surface.size).terminal;

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

    const any_click = for (surface_mouse.click_state) |state| {
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

            for (surface_mouse.click_state, 0..) |state, i| {
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
            const p = surface_mouse.left_click_pin orelse break :pt .{};
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
                @as(u32, @intFromFloat(surface_mouse.left_click_xpos)),
                @as(u32, @intFromFloat(surface_mouse.left_click_ypos)),
            );
        }
    }
}
