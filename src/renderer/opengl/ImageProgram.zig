/// The OpenGL program for rendering terminal cells.
const ImageProgram = @This();

const std = @import("std");
const gl = @import("opengl");

program: gl.Program,
vao: gl.VertexArray,
ebo: gl.Buffer,
vbo: gl.Buffer,

pub const Input = extern struct {
    /// vec2 grid_coord
    grid_col: i32,
    grid_row: i32,

    /// vec2 cell_offset
    cell_offset_x: u32 = 0,
    cell_offset_y: u32 = 0,

    /// vec4 source_rect
    source_x: u32 = 0,
    source_y: u32 = 0,
    source_width: u32 = 0,
    source_height: u32 = 0,

    /// vec2 dest_size
    dest_width: u32 = 0,
    dest_height: u32 = 0,
};

pub fn init() !ImageProgram {
    // Load and compile our shaders.
    const program = try gl.Program.createVF(
        @embedFile("../shaders/image.v.glsl"),
        @embedFile("../shaders/image.f.glsl"),
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
    try vbobind.attributeAdvanced(0, 2, gl.c.GL_INT, false, @sizeOf(Input), offset);
    offset += 2 * @sizeOf(i32);
    try vbobind.attributeAdvanced(1, 2, gl.c.GL_UNSIGNED_INT, false, @sizeOf(Input), offset);
    offset += 2 * @sizeOf(u32);
    try vbobind.attributeAdvanced(2, 4, gl.c.GL_UNSIGNED_INT, false, @sizeOf(Input), offset);
    offset += 4 * @sizeOf(u32);
    try vbobind.attributeAdvanced(3, 2, gl.c.GL_UNSIGNED_INT, false, @sizeOf(Input), offset);
    offset += 2 * @sizeOf(u32);
    try vbobind.enableAttribArray(0);
    try vbobind.enableAttribArray(1);
    try vbobind.enableAttribArray(2);
    try vbobind.enableAttribArray(3);
    try vbobind.attributeDivisor(0, 1);
    try vbobind.attributeDivisor(1, 1);
    try vbobind.attributeDivisor(2, 1);
    try vbobind.attributeDivisor(3, 1);

    return .{
        .program = program,
        .vao = vao,
        .ebo = ebo,
        .vbo = vbo,
    };
}

pub fn bind(self: ImageProgram) !Binding {
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

pub fn deinit(self: ImageProgram) void {
    self.vbo.destroy();
    self.ebo.destroy();
    self.vao.destroy();
    self.program.destroy();
}

pub const Binding = struct {
    program: gl.Program.Binding,
    vao: gl.VertexArray.Binding,
    ebo: gl.Buffer.Binding,
    vbo: gl.Buffer.Binding,

    pub fn unbind(self: Binding) void {
        self.vbo.unbind();
        self.ebo.unbind();
        self.vao.unbind();
        self.program.unbind();
    }
};
