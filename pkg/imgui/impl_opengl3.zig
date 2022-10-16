const std = @import("std");
const c = @import("c.zig");
const imgui = @import("main.zig");
const Allocator = std.mem.Allocator;

pub const ImplOpenGL3 = struct {
    pub fn init(glsl_version: ?[:0]const u8) bool {
        return ImGui_ImplOpenGL3_Init(
            if (glsl_version) |s| s.ptr else null,
        );
    }

    pub fn shutdown() void {
        return ImGui_ImplOpenGL3_Shutdown();
    }

    pub fn newFrame() void {
        return ImGui_ImplOpenGL3_NewFrame();
    }

    pub fn renderDrawData(data: *imgui.DrawData) void {
        ImGui_ImplOpenGL3_RenderDrawData(data);
    }

    extern "c" fn glfwGetError(?*const anyopaque) c_int;
    extern "c" fn ImGui_ImplOpenGL3_Init([*c]const u8) bool;
    extern "c" fn ImGui_ImplOpenGL3_Shutdown() void;
    extern "c" fn ImGui_ImplOpenGL3_NewFrame() void;
    extern "c" fn ImGui_ImplOpenGL3_RenderDrawData(*imgui.DrawData) void;
};
