pub const c = @import("c.zig").c;

// OpenGL
pub extern fn ImGui_ImplOpenGL3_Init(?[*:0]const u8) callconv(.c) bool;
pub extern fn ImGui_ImplOpenGL3_Shutdown() callconv(.c) void;
pub extern fn ImGui_ImplOpenGL3_NewFrame() callconv(.c) void;
pub extern fn ImGui_ImplOpenGL3_RenderDrawData(*c.ImDrawData) callconv(.c) void;

// Metal
pub extern fn ImGui_ImplMetal_Init(*anyopaque) callconv(.c) bool;
pub extern fn ImGui_ImplMetal_Shutdown() callconv(.c) void;
pub extern fn ImGui_ImplMetal_NewFrame(*anyopaque) callconv(.c) void;
pub extern fn ImGui_ImplMetal_RenderDrawData(*c.ImDrawData, *anyopaque, *anyopaque) callconv(.c) void;

// OSX
pub extern fn ImGui_ImplOSX_Init(*anyopaque) callconv(.c) bool;
pub extern fn ImGui_ImplOSX_Shutdown() callconv(.c) void;
pub extern fn ImGui_ImplOSX_NewFrame(*anyopaque) callconv(.c) void;

test {}
