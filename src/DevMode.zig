//! This file implements the "dev mode" interface for the terminal. This
//! includes state managements and rendering.
const DevMode = @This();

const imgui = @import("imgui");

/// If this is false, the rest of the terminal will be compiled without
/// dev mode support at all.
pub const enabled = true;

/// The global DevMode instance that can be used app-wide. Assume all functions
/// are NOT thread-safe unless otherwise noted.
pub var instance: DevMode = .{};

/// Whether to show the dev mode UI currently.
visible: bool = false,

/// Update the state associated with the dev mode. This should generally
/// only be called paired with a render since it otherwise wastes CPU
/// cycles.
pub fn update(self: DevMode) void {
    _ = self;
    imgui.ImplOpenGL3.newFrame();
    imgui.ImplGlfw.newFrame();
    imgui.newFrame();

    // Just demo for now
    imgui.showDemoWindow(null);
}

/// Render the scene and return the draw data. The caller must be imgui-aware
/// in order to render the draw data. This lets this file be renderer/backend
/// agnostic.
pub fn render(self: DevMode) !*imgui.DrawData {
    _ = self;
    imgui.render();
    return try imgui.DrawData.get();
}
