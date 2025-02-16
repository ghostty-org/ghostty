const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");
const Size = @import("../size.zig").Size;

const log = std.log.scoped(.opengl_custom);

/// The "INDEX" is the index into the global GL state and the
/// "BINDING" is the binding location in the shader.
const UNIFORM_INDEX: gl.c.GLuint = 0;
const UNIFORM_BINDING: gl.c.GLuint = 0;

/// Global uniforms for custom shaders.
pub const Uniforms = extern struct {
    resolution: [3]f32 align(16) = .{ 0, 0, 0 },
    time: f32 align(4) = 1,
    time_delta: f32 align(4) = 1,
    frame_rate: f32 align(4) = 1,
    frame: i32 align(4) = 1,
    channel_time: [4][4]f32 align(16) = [1][4]f32{.{ 0, 0, 0, 0 }} ** 4,
    channel_resolution: [4][4]f32 align(16) = [1][4]f32{.{ 0, 0, 0, 0 }} ** 4,
    mouse: [4]f32 align(16) = .{ 0, 0, 0, 0 },
    date: [4]f32 align(16) = .{ 0, 0, 0, 0 },
    sample_rate: f32 align(4) = 1,
};

/// The state associated with custom shaders. This should only be initialized
/// if there is at least one custom shader.
///
/// To use this, the main terminal shader should render to the framebuffer
/// specified by "fbo". The resulting "fb_texture" will contain the color
/// attachment. This is then used as the iChannel0 input to the custom
/// shader.
pub const State = struct {
    /// The uniform data
    uniforms: Uniforms,

    /// The OpenGL buffers
    fbo: gl.Framebuffer,
    ubo: gl.Buffer,
    vao: gl.VertexArray,
    ebo: gl.Buffer,
    fb_texture: gl.Texture,

    /// The set of programs for the custom shaders.
    programs: []const Program,

    /// The first time a frame was drawn. This is used to update
    /// the time uniform.
    first_frame_time: std.time.Instant,

    /// The last time a frame was drawn. This is used to update
    /// the time uniform.
    last_frame_time: std.time.Instant,

    pub fn init(
        alloc: Allocator,
        srcs: []const [:0]const u8,
    ) !State {
        if (srcs.len == 0) return error.OneCustomShaderRequired;

        // Create our programs
        var programs = std.ArrayList(Program).init(alloc);
        defer programs.deinit();
        errdefer for (programs.items) |p| p.deinit();
        for (srcs) |src| {
            try programs.append(try Program.init(src));
        }

        // Create the texture for the framebuffer
        const fb_tex = try gl.Texture.create();
        errdefer fb_tex.destroy();
        {
            const texbind = try fb_tex.bind(.@"2D");
            try texbind.parameter(.WrapS, gl.c.GL_CLAMP_TO_EDGE);
            try texbind.parameter(.WrapT, gl.c.GL_CLAMP_TO_EDGE);
            try texbind.parameter(.MinFilter, gl.c.GL_LINEAR);
            try texbind.parameter(.MagFilter, gl.c.GL_LINEAR);
            try texbind.image2D(
                0,
                .rgb,
                1,
                1,
                0,
                .rgb,
                .UnsignedByte,
                null,
            );
        }

        // Create our framebuffer for rendering off screen.
        // The shader prior to custom shaders should use this
        // framebuffer.
        const fbo = try gl.Framebuffer.create();
        errdefer fbo.destroy();
        const fbbind = try fbo.bind(.framebuffer);
        defer fbbind.unbind();
        try fbbind.texture2D(.color0, .@"2D", fb_tex, 0);
        const fbstatus = fbbind.checkStatus();
        if (fbstatus != .complete) {
            log.warn(
                "framebuffer is not complete state={}",
                .{fbstatus},
            );
            return error.InvalidFramebuffer;
        }

        // Create our uniform buffer that is shared across all
        // custom shaders
        const ubo = try gl.Buffer.create();
        errdefer ubo.destroy();
        {
            var ubobind = try ubo.bind(.uniform);
            defer ubobind.unbind();
            try ubobind.setDataNull(Uniforms, .static_draw);
        }

        // Setup our VAO for the custom shader.
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

        return .{
            .programs = try programs.toOwnedSlice(),
            .uniforms = .{},
            .fbo = fbo,
            .ubo = ubo,
            .vao = vao,
            .ebo = ebo,
            .fb_texture = fb_tex,
            .first_frame_time = try std.time.Instant.now(),
            .last_frame_time = try std.time.Instant.now(),
        };
    }

    pub fn deinit(self: *const State, alloc: Allocator) void {
        for (self.programs) |p| p.deinit();
        alloc.free(self.programs);
        self.ubo.destroy();
        self.ebo.destroy();
        self.vao.destroy();
        self.fb_texture.destroy();
        self.fbo.destroy();
    }

    pub fn setScreenSize(self: *State, size: Size) !void {
        // Update our uniforms
        self.uniforms.resolution = .{
            @floatFromInt(size.screen.width),
            @floatFromInt(size.screen.height),
            1,
        };
        try self.syncUniforms();

        // Update our texture
        const texbind = try self.fb_texture.bind(.@"2D");
        try texbind.image2D(
            0,
            .rgb,
            @intCast(size.screen.width),
            @intCast(size.screen.height),
            0,
            .rgb,
            .UnsignedByte,
            null,
        );
    }

    /// Call this prior to drawing a frame to update the time
    /// and synchronize the uniforms. This synchronizes uniforms
    /// so you should make changes to uniforms prior to calling
    /// this.
    pub fn newFrame(self: *State) !void {
        // Update our frame time
        const now = std.time.Instant.now() catch self.first_frame_time;
        const since_ns: f32 = @floatFromInt(now.since(self.first_frame_time));
        const delta_ns: f32 = @floatFromInt(now.since(self.last_frame_time));
        self.uniforms.time = since_ns / std.time.ns_per_s;
        self.uniforms.time_delta = delta_ns / std.time.ns_per_s;
        self.last_frame_time = now;

        // Sync our uniform changes
        try self.syncUniforms();
    }

    fn syncUniforms(self: *State) !void {
        var ubobind = try self.ubo.bind(.uniform);
        defer ubobind.unbind();
        try ubobind.setData(self.uniforms, .static_draw);
    }

    /// Call this to bind all the necessary OpenGL resources for
    /// all custom shaders. Each individual shader needs to be bound
    /// one at a time too.
    pub fn bind(self: *const State) !Binding {
        // Move our uniform buffer into proper global index. Note that
        // in theory we can do this globally once and never worry about
        // it again. I don't think we're high-performance enough at all
        // to worry about that and this makes it so you can just move
        // around CustomProgram usage without worrying about clobbering
        // the global state.
        try self.ubo.bindBase(.uniform, UNIFORM_INDEX);

        // Bind our texture that is shared amongst all
        try gl.Texture.active(gl.c.GL_TEXTURE0);
        var texbind = try self.fb_texture.bind(.@"2D");
        errdefer texbind.unbind();

        const vao = try self.vao.bind();
        errdefer vao.unbind();

        const ebo = try self.ebo.bind(.element_array);
        errdefer ebo.unbind();

        return .{
            .vao = vao,
            .ebo = ebo,
            .fb_texture = texbind,
        };
    }

    /// Copy the fbo's attached texture to the backbuffer.
    pub fn copyFramebuffer(self: *State) !void {
        const texbind = try self.fb_texture.bind(.@"2D");
        errdefer texbind.unbind();
        try texbind.copySubImage2D(
            0,
            0,
            0,
            0,
            0,
            @intFromFloat(self.uniforms.resolution[0]),
            @intFromFloat(self.uniforms.resolution[1]),
        );
    }

    pub const Binding = struct {
        vao: gl.VertexArray.Binding,
        ebo: gl.Buffer.Binding,
        fb_texture: gl.Texture.Binding,

        pub fn unbind(self: Binding) void {
            self.ebo.unbind();
            self.vao.unbind();
            self.fb_texture.unbind();
        }
    };
};

/// A single OpenGL program (combined shaders) for custom shaders.
pub const Program = struct {
    program: gl.Program,

    pub fn init(src: [:0]const u8) !Program {
        const program = try gl.Program.createVF(
            @embedFile("../shaders/custom.v.glsl"),
            src,
        );
        errdefer program.destroy();

        // Map our uniform buffer to the global GL state
        try program.uniformBlockBinding(UNIFORM_INDEX, UNIFORM_BINDING);

        return .{ .program = program };
    }

    pub fn deinit(self: *const Program) void {
        self.program.destroy();
    }

    /// Bind the program for use. This should be called so that draw can
    /// be called.
    pub fn bind(self: *const Program) !Binding {
        const program = try self.program.use();
        errdefer program.unbind();

        return .{
            .program = program,
        };
    }

    pub const Binding = struct {
        program: gl.Program.Binding,

        pub fn unbind(self: Binding) void {
            self.program.unbind();
        }

        pub fn draw(self: Binding) !void {
            _ = self;
            try gl.drawElementsInstanced(
                gl.c.GL_TRIANGLES,
                6,
                gl.c.GL_UNSIGNED_BYTE,
                1,
            );
        }
    };
};
