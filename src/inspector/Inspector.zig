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
const terminal = @import("../terminal/main.zig");
const inspector = @import("main.zig");
const widgets = @import("widgets.zig");

/// Mouse state that we track in addition to normal mouse states that
/// Ghostty always knows about.
mouse: widgets.surface.Mouse = .{},

// ImGui state
gui: widgets.surface.Inspector,

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

pub fn init(alloc: Allocator) !Inspector {
    var gui: widgets.surface.Inspector = try .init(alloc);
    errdefer gui.deinit(alloc);
    return .{ .gui = gui };
}

pub fn deinit(self: *Inspector, alloc: Allocator) void {
    self.gui.deinit(alloc);
}

/// Returns the renderer info panel. This is a convenience function
/// to access and find this state to read and modify.
pub fn rendererInfo(self: *Inspector) *widgets.renderer.Info {
    return &self.gui.renderer_info;
}

/// Record a keyboard event.
pub fn recordKeyEvent(
    self: *Inspector,
    alloc: Allocator,
    ev: inspector.KeyEvent,
) Allocator.Error!void {
    const max_capacity = 50;

    const events: *widgets.key.EventRing = &self.gui.key_stream.events;
    events.append(ev) catch |err| switch (err) {
        error.OutOfMemory => if (events.capacity() < max_capacity) {
            // We're out of memory, but we can allocate to our capacity.
            const new_capacity = @min(events.capacity() * 2, max_capacity);
            try events.resize(alloc, new_capacity);
            try events.append(ev);
        } else {
            var it = events.iterator(.forward);
            if (it.next()) |old_ev| old_ev.deinit(alloc);
            events.deleteOldest(1);
            try events.append(ev);
        },
    };
}

/// Record data read from the pty.
pub fn recordPtyRead(
    self: *Inspector,
    alloc: Allocator,
    t: *terminal.Terminal,
    data: []const u8,
) !void {
    try self.gui.vt_stream.recordPtyRead(
        alloc,
        t,
        data,
    );
}

/// Render the frame.
pub fn render(
    self: *Inspector,
    surface: *Surface,
) void {

    // Draw the UI
    self.gui.draw(
        surface,
        self.mouse,
    );

    // TODO: Strictly, we should trigger a terminal render when either feature
    // is toggled. For now just render when either is enabled and let a normal
    // terminal render clear highlight. Instead to make an idle terminal
    // renderer measurable. Just feature gate redraws.
    const features = &self.gui.renderer_info.features;
    if (features.contains(.highlight_hyperlinks) or
        features.contains(.semantic_prompts))
    {
        surface.queueRender() catch {};
    }
}
