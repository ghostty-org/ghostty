pub const build_options = @import("build_options");

pub const c = @cImport({
    // This is set during the build so it also has to be set
    // during import time to get the right types. Without this
    // you get stack size mismatches on some structs.
    @cDefine("IMGUI_USE_WCHAR32", "1");

    @cDefine("IMGUI_HAS_DOCK", "1");
    @cInclude("dcimgui.h");
});

// OpenGL3 backend
pub extern fn ImGui_ImplOpenGL3_Init(glsl_version: ?[*:0]const u8) callconv(.c) bool;
pub extern fn ImGui_ImplOpenGL3_Shutdown() callconv(.c) void;
pub extern fn ImGui_ImplOpenGL3_NewFrame() callconv(.c) void;
pub extern fn ImGui_ImplOpenGL3_RenderDrawData(draw_data: *c.ImDrawData) callconv(.c) void;

// Extension: shutdown the OpenGL3 backend and zero out the imgl3w function
// pointer table so a subsequent Init can re-initialize the loader.
pub extern fn ImGui_ImplOpenGL3_ShutdownWithLoaderCleanup() callconv(.c) void;

// Metal backend
pub extern fn ImGui_ImplMetal_Init(device: *anyopaque) callconv(.c) bool;
pub extern fn ImGui_ImplMetal_Shutdown() callconv(.c) void;
pub extern fn ImGui_ImplMetal_NewFrame(render_pass_descriptor: *anyopaque) callconv(.c) void;
pub extern fn ImGui_ImplMetal_RenderDrawData(draw_data: *c.ImDrawData, command_buffer: *anyopaque, command_encoder: *anyopaque) callconv(.c) void;

// OSX
pub extern fn ImGui_ImplOSX_Init(*anyopaque) callconv(.c) bool;
pub extern fn ImGui_ImplOSX_Shutdown() callconv(.c) void;
pub extern fn ImGui_ImplOSX_NewFrame(*anyopaque) callconv(.c) void;

// Internal API types and functions from dcimgui_internal.h
// We declare these manually because the internal header contains bitfields
// that Zig's cImport cannot translate.
pub const ImGuiDockNodeFlagsPrivate = struct {
    pub const DockSpace: c.ImGuiDockNodeFlags = 1 << 10;
    pub const CentralNode: c.ImGuiDockNodeFlags = 1 << 11;
    pub const NoTabBar: c.ImGuiDockNodeFlags = 1 << 12;
    pub const HiddenTabBar: c.ImGuiDockNodeFlags = 1 << 13;
    pub const NoWindowMenuButton: c.ImGuiDockNodeFlags = 1 << 14;
    pub const NoCloseButton: c.ImGuiDockNodeFlags = 1 << 15;
    pub const NoResizeX: c.ImGuiDockNodeFlags = 1 << 16;
    pub const NoResizeY: c.ImGuiDockNodeFlags = 1 << 17;
    pub const DockedWindowsInFocusRoute: c.ImGuiDockNodeFlags = 1 << 18;
    pub const NoDockingSplitOther: c.ImGuiDockNodeFlags = 1 << 19;
    pub const NoDockingOverMe: c.ImGuiDockNodeFlags = 1 << 20;
    pub const NoDockingOverOther: c.ImGuiDockNodeFlags = 1 << 21;
    pub const NoDockingOverEmpty: c.ImGuiDockNodeFlags = 1 << 22;
};
pub extern fn ImGui_DockBuilderDockWindow(window_name: [*:0]const u8, node_id: c.ImGuiID) callconv(.c) void;
pub extern fn ImGui_DockBuilderGetNode(node_id: c.ImGuiID) callconv(.c) ?*anyopaque;
pub extern fn ImGui_DockBuilderGetCentralNode(node_id: c.ImGuiID) callconv(.c) ?*anyopaque;
pub extern fn ImGui_DockBuilderAddNode() callconv(.c) c.ImGuiID;
pub extern fn ImGui_DockBuilderAddNodeEx(node_id: c.ImGuiID, flags: c.ImGuiDockNodeFlags) callconv(.c) c.ImGuiID;
pub extern fn ImGui_DockBuilderRemoveNode(node_id: c.ImGuiID) callconv(.c) void;
pub extern fn ImGui_DockBuilderRemoveNodeDockedWindows(node_id: c.ImGuiID) callconv(.c) void;
pub extern fn ImGui_DockBuilderRemoveNodeDockedWindowsEx(node_id: c.ImGuiID, clear_settings_refs: bool) callconv(.c) void;
pub extern fn ImGui_DockBuilderRemoveNodeChildNodes(node_id: c.ImGuiID) callconv(.c) void;
pub extern fn ImGui_DockBuilderSetNodePos(node_id: c.ImGuiID, pos: c.ImVec2) callconv(.c) void;
pub extern fn ImGui_DockBuilderSetNodeSize(node_id: c.ImGuiID, size: c.ImVec2) callconv(.c) void;
pub extern fn ImGui_DockBuilderSplitNode(node_id: c.ImGuiID, split_dir: c.ImGuiDir, size_ratio_for_node_at_dir: f32, out_id_at_dir: *c.ImGuiID, out_id_at_opposite_dir: *c.ImGuiID) callconv(.c) c.ImGuiID;
pub extern fn ImGui_DockBuilderCopyDockSpace(src_dockspace_id: c.ImGuiID, dst_dockspace_id: c.ImGuiID, in_window_remap_pairs: *c.ImVector_const_charPtr) callconv(.c) void;
pub extern fn ImGui_DockBuilderCopyNode(src_node_id: c.ImGuiID, dst_node_id: c.ImGuiID, out_node_remap_pairs: *c.ImVector_ImGuiID) callconv(.c) void;
pub extern fn ImGui_DockBuilderCopyWindowSettings(src_name: [*:0]const u8, dst_name: [*:0]const u8) callconv(.c) void;
pub extern fn ImGui_DockBuilderFinish(node_id: c.ImGuiID) callconv(.c) void;

// Extension functions from ext.cpp
pub const ext = struct {
    pub extern fn ImFontConfig_ImFontConfig(self: *c.ImFontConfig) callconv(.c) void;
    pub extern fn ImGuiStyle_ImGuiStyle(self: *c.ImGuiStyle) callconv(.c) void;
};

test {
    _ = c;
}
