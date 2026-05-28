const initpkg = @import("init.zig");
const program = @import("program.zig");
const shader = @import("shader.zig");

pub const c = @import("c.zig").c;
pub const testing = @import("test.zig");
pub const vk = @import("vk.zig");

pub const init = initpkg.init;
pub const initWithAtexit = initpkg.initWithAtexit;
pub const finalize = initpkg.finalize;
pub const Program = program.Program;
pub const Shader = shader.Shader;

test {
    @import("std").testing.refAllDecls(@This());
}
