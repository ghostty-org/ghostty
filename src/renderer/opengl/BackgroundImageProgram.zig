/// The OpenGL program for rendering terminal cells.
const BackgroundImageProgram = @This();

const std = @import("std");
const gl = @import("opengl");
const configpkg = @import("../../config.zig");

pub const Input = extern struct {
    /// vec2 terminal_size
    terminal_width: u32 = 0,
    terminal_height: u32 = 0,

    /// uint mode
    mode: configpkg.BackgroundImageMode = .contain,
};

program: gl.Program,
vao: gl.VertexArray,
ebo: gl.Buffer,
vbo: gl.Buffer,

pub fn init() !BackgroundImageProgram {
    // Load and compile our shaders.
    const program = try gl.Program.createVF(
        @embedFile("../shaders/bgimage.v.glsl"),
        @embedFile("../shaders/bgimage.f.glsl"),
    );
    errdefer program.destroy();

    // Set our program uniforms
    const pbind = try program.use();
    defer pbind.unbind();

    // Set all of our texture indexes
    try program.setUniform("image", 0);

    // Setup our VAO
    const vao = try gl.VertexArray.create();
    errdefer vao.destroy();
    const vaobind = try vao.bind();
    defer vaobind.unbind();

    // Element buffer (EBO)
    const ebo = try gl.Buffer.create();
    errdefer ebo.destroy();
    var ebobind = try ebo.bind(.element_array);
    defer ebobind.unbind();
    try ebobind.setData([6]u8{
        0, 1, 3, // Top-left triangle
        1, 2, 3, // Bottom-right triangle
    }, .static_draw);

    // Vertex buffer (VBO)
    const vbo = try gl.Buffer.create();
    errdefer vbo.destroy();
    var vbobind = try vbo.bind(.array);
    defer vbobind.unbind();
    var offset: usize = 0;
    try vbobind.attributeAdvanced(0, 2, gl.c.GL_UNSIGNED_INT, false, @sizeOf(Input), offset);
    offset += 2 * @sizeOf(u32);
    try vbobind.attributeIAdvanced(1, 1, gl.c.GL_UNSIGNED_BYTE, @sizeOf(Input), offset);
    offset += 1 * @sizeOf(u8);
    try vbobind.enableAttribArray(0);
    try vbobind.enableAttribArray(1);
    try vbobind.attributeDivisor(0, 1);
    try vbobind.attributeDivisor(1, 1);

    return .{
        .program = program,
        .vao = vao,
        .ebo = ebo,
        .vbo = vbo,
    };
}

pub fn bind(self: BackgroundImageProgram) !Binding {
    const program = try self.program.use();
    errdefer program.unbind();

    const vao = try self.vao.bind();
    errdefer vao.unbind();

    const ebo = try self.ebo.bind(.element_array);
    errdefer ebo.unbind();

    const vbo = try self.vbo.bind(.array);
    errdefer vbo.unbind();

    return .{
        .program = program,
        .vao = vao,
        .ebo = ebo,
        .vbo = vbo,
    };
}

pub fn deinit(self: BackgroundImageProgram) void {
    self.ebo.destroy();
    self.vao.destroy();
    self.vbo.destroy();
    self.program.destroy();
}

pub const Binding = struct {
    program: gl.Program.Binding,
    vao: gl.VertexArray.Binding,
    ebo: gl.Buffer.Binding,
    vbo: gl.Buffer.Binding,

    pub fn unbind(self: Binding) void {
        self.ebo.unbind();
        self.vao.unbind();
        self.vbo.unbind();
        self.program.unbind();
    }
};
