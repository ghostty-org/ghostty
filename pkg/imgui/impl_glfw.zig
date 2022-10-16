const std = @import("std");
const c = @import("c.zig");
const imgui = @import("main.zig");
const Allocator = std.mem.Allocator;

pub const ImplGlfw = struct {
    pub const GLFWWindow = opaque {};

    pub fn initForOpenGL(win: *GLFWWindow, install_callbacks: bool) bool {
        // https://github.com/ocornut/imgui/issues/5785
        defer _ = glfwGetError(null);

        return ImGui_ImplGlfw_InitForOpenGL(win, install_callbacks);
    }

    pub fn shutdown() void {
        return ImGui_ImplGlfw_Shutdown();
    }

    pub fn newFrame() void {
        return ImGui_ImplGlfw_NewFrame();
    }

    extern "c" fn glfwGetError(?*const anyopaque) c_int;
    extern "c" fn ImGui_ImplGlfw_InitForOpenGL(*GLFWWindow, bool) bool;
    extern "c" fn ImGui_ImplGlfw_Shutdown() void;
    extern "c" fn ImGui_ImplGlfw_NewFrame() void;
};
