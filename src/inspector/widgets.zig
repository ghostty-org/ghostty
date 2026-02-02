const cimgui = @import("dcimgui");

pub const page = @import("widgets/page.zig");
pub const pagelist = @import("widgets/pagelist.zig");
pub const key = @import("widgets/key.zig");
pub const renderer = @import("widgets/renderer.zig");
pub const screen = @import("widgets/screen.zig");
pub const style = @import("widgets/style.zig");
pub const surface = @import("widgets/surface.zig");
pub const terminal = @import("widgets/terminal.zig");
pub const termio = @import("widgets/termio.zig");

/// Draws a "(?)" disabled text marker that shows some help text
/// on hover.
pub fn helpMarker(text: [:0]const u8) void {
    cimgui.c.ImGui_TextDisabled("(?)");
    if (!cimgui.c.ImGui_BeginItemTooltip()) return;
    defer cimgui.c.ImGui_EndTooltip();

    cimgui.c.ImGui_PushTextWrapPos(cimgui.c.ImGui_GetFontSize() * 35.0);
    defer cimgui.c.ImGui_PopTextWrapPos();

    cimgui.c.ImGui_TextUnformatted(text.ptr);
}

/// DetachableHeader allows rendering a collapsing header that can be
/// detached into its own window.
pub const DetachableHeader = struct {
    /// Set whether the window is detached.
    detached: bool = false,

    /// If true, detaching will move the item into a docking position
    /// to the right.
    dock: bool = true,

    // Internal state do not touch.
    window_first: bool = true,

    pub fn windowEnd(self: *DetachableHeader) void {
        _ = self;

        // If we started the window, we need to end it.
        cimgui.c.ImGui_End();
    }

    /// Returns null if there is no window created (not detached).
    /// Otherwise returns whether the window is open.
    pub fn window(
        self: *DetachableHeader,
        label: [:0]const u8,
    ) ?bool {
        // If we're not detached, we don't create a window.
        if (!self.detached) {
            self.window_first = true;
            return null;
        }

        // If this is our first time showing the window then we need to
        // setup docking. We only do this on the first time because we
        // don't want to reset a user's docking behavior later.
        if (self.window_first) dock: {
            self.window_first = false;
            if (!self.dock) break :dock;
            const dock_id = cimgui.c.ImGui_GetWindowDockID();
            if (dock_id == 0) break :dock;
            var dock_id_right: cimgui.c.ImGuiID = 0;
            var dock_id_left: cimgui.c.ImGuiID = 0;
            _ = cimgui.ImGui_DockBuilderSplitNode(
                dock_id,
                cimgui.c.ImGuiDir_Right,
                0.4,
                &dock_id_right,
                &dock_id_left,
            );
            cimgui.ImGui_DockBuilderDockWindow(label, dock_id_right);
            cimgui.ImGui_DockBuilderFinish(dock_id);
        }

        return cimgui.c.ImGui_Begin(
            label,
            &self.detached,
            cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
        );
    }

    pub fn header(
        self: *DetachableHeader,
        label: [:0]const u8,
    ) bool {
        // If we're detached, create a separate window.
        if (self.detached) return false;

        // Make sure all headers have a unique ID in the stack. We only
        // need to do this for the header side because creating a window
        // automatically creates an ID.
        cimgui.c.ImGui_PushID(label);
        defer cimgui.c.ImGui_PopID();

        // Create the collapsing header with the pop out button overlaid.
        cimgui.c.ImGui_SetNextItemAllowOverlap();
        const is_open = cimgui.c.ImGui_CollapsingHeader(
            label,
            cimgui.c.ImGuiTreeNodeFlags_None,
        );

        // Place pop-out button inside the header bar
        const header_max = cimgui.c.ImGui_GetItemRectMax();
        const header_min = cimgui.c.ImGui_GetItemRectMin();
        const frame_height = cimgui.c.ImGui_GetFrameHeight();
        const button_size = frame_height - 4;
        const padding = 4;

        cimgui.c.ImGui_SameLine();
        cimgui.c.ImGui_SetCursorScreenPos(.{
            .x = header_max.x - button_size - padding,
            .y = header_min.y + 2,
        });
        {
            cimgui.c.ImGui_PushStyleVarImVec2(
                cimgui.c.ImGuiStyleVar_FramePadding,
                .{ .x = 0, .y = 0 },
            );
            defer cimgui.c.ImGui_PopStyleVar();
            if (cimgui.c.ImGui_ButtonEx(
                ">>##detach",
                .{ .x = button_size, .y = button_size },
            )) {
                self.detached = true;
            }
        }

        if (cimgui.c.ImGui_IsItemHovered(cimgui.c.ImGuiHoveredFlags_DelayShort)) {
            cimgui.c.ImGui_SetTooltip("Detach into separate window");
        }

        return is_open;
    }
};

pub const DetachableHeaderState = struct {
    show_window: bool = false,

    /// Internal state. Don't touch.
    first_show: bool = false,
};

/// Render a collapsing header that can be detached into its own window.
/// When detached, renders as a separate window with a close button.
/// When attached, renders as a collapsing header with a pop-out button.
pub fn detachableHeader(
    label: [:0]const u8,
    state: *DetachableHeaderState,
    ctx: anytype,
    comptime contentFn: fn (@TypeOf(ctx)) void,
) void {
    cimgui.c.ImGui_PushID(label);
    defer cimgui.c.ImGui_PopID();

    if (state.show_window) {
        // On first show, dock this window to the right of the parent window's dock.
        // We only do this once so the user can freely reposition the window afterward
        // without it snapping back to the right on every frame.
        if (!state.first_show) {
            state.first_show = true;
            const current_dock_id = cimgui.c.ImGui_GetWindowDockID();
            if (current_dock_id != 0) {
                var dock_id_right: cimgui.c.ImGuiID = 0;
                var dock_id_left: cimgui.c.ImGuiID = 0;
                _ = cimgui.ImGui_DockBuilderSplitNode(
                    current_dock_id,
                    cimgui.c.ImGuiDir_Right,
                    0.3,
                    &dock_id_right,
                    &dock_id_left,
                );
                cimgui.ImGui_DockBuilderDockWindow(label, dock_id_right);
                cimgui.ImGui_DockBuilderFinish(current_dock_id);
            }
        }

        defer cimgui.c.ImGui_End();
        if (cimgui.c.ImGui_Begin(
            label,
            &state.show_window,
            cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
        )) contentFn(ctx);
        return;
    }

    // Reset first_show when window is closed so next open docks again
    state.first_show = false;

    cimgui.c.ImGui_SetNextItemAllowOverlap();
    const is_open = cimgui.c.ImGui_CollapsingHeader(
        label,
        cimgui.c.ImGuiTreeNodeFlags_None,
    );

    // Place pop-out button inside the header bar
    const header_max = cimgui.c.ImGui_GetItemRectMax();
    const header_min = cimgui.c.ImGui_GetItemRectMin();
    const frame_height = cimgui.c.ImGui_GetFrameHeight();
    const button_size = frame_height - 4;
    const padding = 4;

    cimgui.c.ImGui_SameLine();
    cimgui.c.ImGui_SetCursorScreenPos(.{
        .x = header_max.x - button_size - padding,
        .y = header_min.y + 2,
    });
    cimgui.c.ImGui_PushStyleVarImVec2(
        cimgui.c.ImGuiStyleVar_FramePadding,
        .{ .x = 0, .y = 0 },
    );
    if (cimgui.c.ImGui_ButtonEx(
        ">>##detach",
        .{ .x = button_size, .y = button_size },
    )) {
        state.show_window = true;
    }
    cimgui.c.ImGui_PopStyleVar();
    if (cimgui.c.ImGui_IsItemHovered(cimgui.c.ImGuiHoveredFlags_DelayShort)) {
        cimgui.c.ImGui_SetTooltip("Pop out into separate window");
    }

    if (is_open) contentFn(ctx);
}
