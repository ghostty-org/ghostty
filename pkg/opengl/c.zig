const builtin = @import("builtin");
pub const c = if (builtin.cpu.arch != .wasm32) @cImport({
    @cInclude("glad/gl.h");
}) else struct {
    pub extern fn glBindBufferBase(_: c_uint, _: c_uint, _: c_uint) void;
    pub extern fn glDrawElementsInstanced(_: GLenum, _: GLsizei, _: GLenum, _: ?*const anyopaque, _: GLsizei) void;
    pub extern fn glUniform4f(_: c_int, _: f32, _: f32, _: f32, _: f32) void;
    pub extern fn glUniform4fv(_: c_int, _: f32, _: f32, _: f32, _: f32) void;
    pub extern fn glBindFramebuffer(_: c_uint, _: c_uint) void;
    pub extern fn glGetIntegerv(_: GLenum, _: *GLint) void;
    pub extern fn glTexSubImage2D(_: c_uint, _: c_int, _: c_int, _: isize, _: isize, _: c_int, _: c_uint, _: c_uint, _: ?*const anyopaque) void;
    pub extern fn glDeleteFramebuffers(_: c_int, _: [*c]const c_uint) void;
    pub extern fn glGenFramebuffers(_: c_int, _: [*c]c_uint) void;
    pub extern fn glVertexAttribDivisor(_: c_uint, _: c_uint) void;
    pub extern fn glVertexAttribIPointer(_: c_uint, _: c_int, _: c_uint, _: isize, _: ?*const anyopaque) void;
    pub extern fn glBufferSubData(_: GLenum, _: isize, _: isize, _: ?*const anyopaque) void;
    pub extern fn glViewport(_: c_int, _: c_int, _: isize, _: isize) void;
    pub extern fn glClearColor(_: f32, _: f32, _: f32, _: f32) void;
    pub extern fn glEnable(_: c_uint) void;
    pub extern fn glDisable(_: c_uint) void;
    pub extern fn glDepthFunc(_: c_uint) void;
    pub extern fn glBlendFunc(_: c_uint, _: c_uint) void;
    pub extern fn glClear(_: c_uint) void;
    pub extern fn glGetAttribLocation(_: c_uint, _: [*]const u8, _: c_uint) c_int;
    pub extern fn glGetUniformLocation(_: c_uint, _: [*]const u8) c_int;
    pub extern fn glUniform1i(_: c_int, _: c_int) void;
    pub extern fn glUniform1f(_: c_int, _: f32) void;
    pub extern fn glUniformMatrix4fv(_: c_int, _: c_int, _: c_uint, _: *const f32) void;
    pub extern fn glCreateVertexArray() c_uint;
    pub extern fn glGenVertexArrays(_: c_int, [*c]c_uint) void;
    pub extern fn glDeleteVertexArrays(_: c_int, [*c]const c_uint) void;
    pub extern fn glBindVertexArray(_: c_uint) void;
    pub extern fn glCreateBuffer() c_uint;
    pub extern fn glGenBuffers(_: c_int, _: [*c]c_uint) void;
    pub extern fn glDeleteBuffers(_: c_int, _: [*c]const c_uint) void;
    pub extern fn glDeleteBuffer(_: c_uint) void;
    pub extern fn glBindBuffer(_: c_uint, _: c_uint) void;
    pub extern fn glBufferData(_: c_uint, _: isize, _: ?*const anyopaque, _: c_uint) void;
    pub extern fn glPixelStorei(_: c_uint, _: c_int) void;
    pub extern fn glAttachShader(_: c_uint, _: c_uint) void;
    pub extern fn glDetachShader(_: c_uint, _: c_uint) void;
    pub extern fn glDeleteShader(_: c_uint) void;
    pub extern fn glCreateShader(_: c_uint) c_uint;
    pub extern fn glCompileShader(_: c_uint) void;
    pub extern fn glShaderSource(_: c_uint, _: c_uint, _: *const [*c]const u8, _: ?*GLint) void;
    pub extern fn glCreateProgram() c_uint;
    pub extern fn glGetShaderiv(_: c_uint, _: c_uint, _: [*c]c_int) void;
    pub extern fn glGetShaderInfoLog(_: c_uint, _: c_int, _: [*c]c_int, _: [*c]u8) void;
    pub extern fn glGetProgramiv(_: c_uint, _: c_uint, _: [*c]c_int) void;
    pub extern fn glLinkProgram(_: c_uint) void;
    pub extern fn glUseProgram(_: c_uint) void;
    pub extern fn glGetProgramInfoLog(_: c_uint, _: c_int, _: [*c]c_int, _: [*c]u8) void;
    pub extern fn glDeleteProgram(_: c_uint) void;
    pub extern fn glEnableVertexAttribArray(_: c_uint) void;
    pub extern fn glVertexAttribPointer(_: c_uint, _: c_int, _: c_uint, _: c_uint, _: isize, _: ?*const anyopaque) void;
    pub extern fn glDrawArrays(_: c_uint, _: c_uint, _: c_int) void;
    pub extern fn glCreateTexture() c_uint;
    pub extern fn glGenTextures(_: c_int, _: [*c]c_uint) void;
    pub extern fn glDeleteTextures(_: c_int, _: [*c]const c_uint) void;
    pub extern fn glDeleteTexture(_: c_uint) void;
    pub extern fn glBindTexture(_: c_uint, _: c_uint) void;
    pub extern fn glTexImage2D(_: GLenum, _: GLint, _: c_int, _: c_int, _: c_int, _: c_int, _: c_uint, _: c_uint, _: ?*const anyopaque) void;
    pub extern fn glTexParameteri(_: c_uint, _: c_uint, _: c_int) void;
    pub extern fn glActiveTexture(_: c_uint) void;
    pub extern fn glGenerateMipmap(_: c_uint) void;
    pub extern fn glGetError() c_int;
    pub extern fn glGetString(_: c_int) c_int;
    pub extern fn glGetShaderParameter(_: c_uint, _: c_uint) c_int;
    pub extern fn glUniform2f(_: c_int, _: f32, _: f32) void;

    // Types.
    pub const GLuint = c_uint;
    pub const GLenum = c_uint;
    pub const GLbitfield = c_uint;
    pub const GLint = c_int;
    pub const GLsizei = isize;
    pub const GLfloat = f32;
    pub const GLboolean = u8;

    // https://developer.mozilla.org/en-US/docs/Web/API/WebGL_API/Constants
    pub const GL_FALSE = 0;
    pub const GL_TRUE = 1;
    pub const GL_TRIANGLES = 4;
    pub const GL_DEPTH_BUFFER_BIT = 256;
    pub const GL_SRC_ALPHA = 770;
    pub const GL_ONE_MINUS_SRC_ALPHA = 771;
    pub const GL_FLOAT = 5126;
    pub const GL_CULL_FACE = 2884;
    pub const GL_DEPTH_TEST = 2929;
    pub const GL_BLEND = 3042;
    pub const GL_TEXTURE_2D = 3553;
    pub const GL_UNSIGNED_BYTE = 5121;
    pub const GL_RED = 6403;
    pub const GL_RGBA = 6408;
    pub const GL_VERSION = 7938;
    pub const GL_LINEAR: GLint = 9729;
    pub const GL_TEXTURE_MAG_FILTER = 10240;
    pub const GL_TEXTURE_MIN_FILTER = 10241;
    pub const GL_TEXTURE_WRAP_S = 10242;
    pub const GL_TEXTURE_WRAP_T = 10243;
    pub const GL_COLOR_BUFFER_BIT = 16384;
    pub const GL_CLAMP_TO_EDGE: GLint = 33071;
    pub const GL_RG = 33319;
    pub const GL_RG32F = 33327;
    pub const GL_TEXTURE0 = 33984;
    pub const GL_TEXTURE1 = 33985;
    pub const GL_TEXTURE2 = 33986;
    pub const GL_TEXTURE3 = 33987;
    pub const GL_TEXTURE4 = 33988;
    pub const GL_TEXTURE5 = 33989;
    pub const GL_RGBA32F = 34836;
    pub const GL_ARRAY_BUFFER = 34962;
    pub const GL_STATIC_DRAW = 35044;
    pub const GL_FRAGMENT_SHADER = 35632;
    pub const GL_VERTEX_SHADER = 35633;
    pub const GL_COMPILE_STATUS = 35713;
    pub const GL_LINK_STATUS = 35714;
    pub const GL_FRAMEBUFFER_COMPLETE = 36053;
    pub const GL_COLOR_ATTACHMENT0 = 36064;
    pub const GL_COLOR_ATTACHMENT1 = 36065;
    pub const GL_COLOR_ATTACHMENT2 = 36066;
    pub const GL_DEPTH_ATTACHMENT = 36096;
    pub const GL_FRAMEBUFFER = 36160;
    pub const GL_RENDERBUFFER = 36161;

    pub const GL_NO_ERROR = 0;
    pub const GL_INVALID_ENUM = 0x0500;
    pub const GL_INVALID_FRAMEBUFFER_OPERATION = 0x0506;
    pub const GL_INVALID_OPERATION = 0x0502;
    pub const GL_INVALID_VALUE = 0x0501;
    pub const GL_OUT_OF_MEMORY = 0x0505;
    pub const GL_ONE = 1;

    pub const GL_TEXTURE_1D = 0x0DE0;
    pub const GL_TEXTURE_2D_ARRAY = 0x8C1A;
    pub const GL_TEXTURE_1D_ARRAY = 0x8C18;
    pub const GL_TEXTURE_3D = 0x806F;
    pub const GL_TEXTURE_RECTANGLE = 0x84F5;
    pub const GL_TEXTURE_CUBE_MAP = 0x8513;
    pub const GL_TEXTURE_BUFFER = 0x8C2A;
    pub const GL_TEXTURE_2D_MULTISAMPLE = 0x9100;
    pub const GL_TEXTURE_2D_MULTISAMPLE_ARRAY = 0x9102;
    pub const GL_TEXTURE_BASE_LEVEL = 0x813C;
    pub const GL_TEXTURE_SWIZZLE_A = 0x8E45;
    pub const GL_TEXTURE_SWIZZLE_B = 0x8E44;
    pub const GL_TEXTURE_SWIZZLE_G = 0x8E43;
    pub const GL_TEXTURE_SWIZZLE_R = 0x8E42;
    pub const GL_TEXTURE_COMPARE_FUNC = 0x884D;
    pub const GL_TEXTURE_COMPARE_MODE = 0x884C;
    pub const GL_TEXTURE_LOD_BIAS = 0x8501;
    pub const GL_TEXTURE_MIN_LOD = 0x813A;
    pub const GL_TEXTURE_MAX_LOD = 0x813B;
    pub const GL_TEXTURE_MAX_LEVEL = 0x813D;
    pub const GL_TEXTURE_WRAP_R = 0x8072;
    pub const GL_RGB = 0x1907;
    pub const GL_BGRA = 0x80E1;
    pub const GL_ELEMENT_ARRAY_BUFFER = 0x8893;
    pub const GL_UNIFORM_BUFFER = 0x8A11;
    pub const GL_STREAM_COPY = 0x88E2;
    pub const GL_STREAM_DRAW = 0x88E0;
    pub const GL_STREAM_READ = 0x88E1;
    pub const GL_STATIC_COPY = 0x88E6;
    pub const GL_STATIC_READ = 0x88E5;
    pub const GL_DYNAMIC_COPY = 0x88EA;
    pub const GL_DYNAMIC_DRAW = 0x88E8;
    pub const GL_DYNAMIC_READ = 0x88E9;
    pub const GL_UNSIGNED_SHORT = 0x1403;
    pub const GL_INT = 0x1404;
    pub const GL_UNSIGNED_INT = 0x1405;
    pub const GL_DRAW_FRAMEBUFFER = 0x8CA9;
    pub const GL_READ_FRAMEBUFFER_BINDING = 0x8CAA;
    pub const GL_READ_FRAMEBUFFER = 0x8CA8;
    pub const GL_FRAMEBUFFER_BINDING = 0x8CA6;
    pub const GladGLContext = struct {
        pub fn init(self: *GladGLContext) void {
            self.* = .{
                .Enable = glEnable,
                .GetError = glGetError,
                .BlendFunc = glBlendFunc,
                .BindTexture = glBindTexture,
                .GenTextures = glGenTextures,
                .DeleteTextures = glDeleteTextures,
                .TexImage2D = glTexImage2D,
                .CreateShader = glCreateShader,
                .CompileShader = glCompileShader,
                .DeleteShader = glDeleteShader,
                .AttachShader = glAttachShader,
                .ShaderSource = glShaderSource,
                .GetShaderiv = glGetShaderiv,
                .GetShaderInfoLog = glGetShaderInfoLog,
                .CreateProgram = glCreateProgram,
                .LinkProgram = glLinkProgram,
                .GetProgramiv = glGetProgramiv,
                .GetProgramInfoLog = glGetProgramInfoLog,
                .UseProgram = glUseProgram,
                .DeleteProgram = glDeleteProgram,
                .GetUniformLocation = glGetUniformLocation,
                .Uniform4fv = glUniform4fv,
                .Uniform1i = glUniform1i,
                .Uniform1f = glUniform1f,
                .Uniform2f = glUniform2f,
                .UniformMatrix4fv = glUniformMatrix4fv,
                .GenVertexArrays = glGenVertexArrays,
                .DeleteVertexArrays = glDeleteVertexArrays,
                .BindVertexArray = glBindVertexArray,
                .GenBuffers = glGenBuffers,
                .DeleteBuffers = glDeleteBuffers,
                .DeleteBuffer = glDeleteBuffer,
                .BindBuffer = glBindBuffer,
                .BufferData = glBufferData,
                .BufferSubData = glBufferSubData,
                .VertexAttribPointer = glVertexAttribPointer,
                .VertexAttribIPointer = glVertexAttribIPointer,
                .EnableVertexAttribArray = glEnableVertexAttribArray,
                .VertexAttribDivisor = glVertexAttribDivisor,
                .GenFramebuffers = glGenFramebuffers,
                .DeleteFramebuffers = glDeleteFramebuffers,
                .TexSubImage2D = glTexSubImage2D,
                .GetIntegerv = glGetIntegerv,
                .BindFramebuffer = glBindFramebuffer,
                .ClearColor = glClearColor,
                .Clear = glClear,
                .Viewport = glViewport,
                .Uniform4f = glUniform4f,
                .ActiveTexture = glActiveTexture,
                .DrawElementsInstanced = glDrawElementsInstanced,
                .BindBufferBase = glBindBufferBase,
                .TexParameteri = glTexParameteri,
            };
        }
        Enable: ?*const fn (_: GLenum) callconv(.C) void,
        GetError: ?*const fn () callconv(.C) c_int,
        BlendFunc: ?*const fn (_: c_uint, _: c_uint) callconv(.C) void,
        BindTexture: ?*const fn (_: c_uint, _: c_uint) callconv(.C) void,
        GenTextures: ?*const fn (_: c_int, _: [*c]c_uint) callconv(.C) void,
        DeleteTextures: ?*const fn (_: c_int, _: [*c]const c_uint) callconv(.C) void,
        TexImage2D: ?*const fn (_: GLenum, _: GLint, _: c_int, _: c_int, _: c_int, _: c_int, _: c_uint, _: c_uint, _: ?*const anyopaque) callconv(.C) void,
        CreateShader: ?*const fn (_: GLenum) callconv(.C) GLuint,
        CompileShader: ?*const fn (_: c_uint) callconv(.C) void,
        DeleteShader: ?*const fn (_: c_uint) callconv(.C) void,
        AttachShader: ?*const fn (_: c_uint, _: c_uint) callconv(.C) void,
        ShaderSource: ?*const fn (_: c_uint, _: c_uint, _: *const [*c]const u8, _: ?*GLint) callconv(.C) void,
        GetShaderiv: ?*const fn (_: c_uint, _: c_uint, _: [*c]c_int) callconv(.C) void,
        GetShaderInfoLog: ?*const fn (_: c_uint, _: c_int, _: [*c]c_int, _: [*c]u8) callconv(.C) void,
        CreateProgram: ?*const fn () callconv(.C) c_uint,
        LinkProgram: ?*const fn (_: c_uint) callconv(.C) void,
        GetProgramiv: ?*const fn (_: c_uint, _: c_uint, _: [*c]c_int) callconv(.C) void,
        GetProgramInfoLog: ?*const fn (_: c_uint, _: c_int, _: [*c]c_int, _: [*c]u8) callconv(.C) void,
        UseProgram: ?*const fn (_: c_uint) callconv(.C) void,
        DeleteProgram: ?*const fn (_: c_uint) callconv(.C) void,
        GetUniformLocation: ?*const fn (_: c_uint, _: [*]const u8) callconv(.C) c_int,
        Uniform4fv: ?*const fn (_: c_int, _: f32, _: f32, _: f32, _: f32) callconv(.C) void,
        Uniform1i: ?*const fn (_: c_int, _: c_int) callconv(.C) void,
        Uniform1f: ?*const fn (_: c_int, _: f32) callconv(.C) void,
        Uniform2f: ?*const fn (_: c_int, _: f32, _: f32) callconv(.C) void,
        UniformMatrix4fv: ?*const fn (_: c_int, _: c_int, _: c_uint, _: *const f32) callconv(.C) void,
        GenVertexArrays: ?*const fn (_: c_int, [*c]c_uint) callconv(.C) void,
        DeleteVertexArrays: ?*const fn (_: c_int, [*c]const c_uint) callconv(.C) void,
        BindVertexArray: ?*const fn (_: c_uint) callconv(.C) void,
        GenBuffers: ?*const fn (_: c_int, _: [*c]c_uint) callconv(.C) void,
        DeleteBuffers: ?*const fn (_: c_int, _: [*c]const c_uint) callconv(.C) void,
        DeleteBuffer: ?*const fn (_: c_uint) callconv(.C) void,
        BindBuffer: ?*const fn (_: c_uint, _: c_uint) callconv(.C) void,
        BufferData: ?*const fn (_: c_uint, _: isize, _: ?*const anyopaque, _: c_uint) callconv(.C) void,
        BufferSubData: ?*const fn (_: GLenum, _: isize, _: isize, _: ?*const anyopaque) callconv(.C) void,
        VertexAttribPointer: ?*const fn (_: c_uint, _: c_int, _: c_uint, _: c_uint, _: isize, _: ?*const anyopaque) callconv(.C) void,
        VertexAttribIPointer: ?*const fn (_: c_uint, _: c_int, _: c_uint, _: isize, _: ?*const anyopaque) callconv(.C) void,
        EnableVertexAttribArray: ?*const fn (_: c_uint) callconv(.C) void,
        VertexAttribDivisor: ?*const fn (_: c_uint, _: c_uint) callconv(.C) void,
        GenFramebuffers: ?*const fn (_: c_int, _: [*c]c_uint) callconv(.C) void,
        DeleteFramebuffers: ?*const fn (_: c_int, _: [*c]const c_uint) callconv(.C) void,
        TexSubImage2D: ?*const fn (_: c_uint, _: c_int, _: c_int, _: isize, _: isize, _: c_int, _: c_uint, _: c_uint, _: ?*const anyopaque) callconv(.C) void,
        GetIntegerv: ?*const fn (_: GLenum, _: *GLint) callconv(.C) void,
        BindFramebuffer: ?*const fn (_: c_uint, _: c_uint) callconv(.C) void,
        ClearColor: ?*const fn (_: f32, _: f32, _: f32, _: f32) callconv(.C) void,
        Clear: ?*const fn (_: c_uint) callconv(.C) void,
        Viewport: ?*const fn (_: c_int, _: c_int, _: isize, _: isize) callconv(.C) void,
        Uniform4f: ?*const fn (_: c_int, _: f32, _: f32, _: f32, _: f32) callconv(.C) void,
        ActiveTexture: ?*const fn (_: c_uint) callconv(.C) void,
        DrawElementsInstanced: ?*const fn (_: GLenum, _: GLsizei, _: GLenum, _: ?*const anyopaque, _: GLsizei) callconv(.C) void,
        BindBufferBase: ?*const fn (_: c_uint, _: c_uint, _: c_uint) callconv(.C) void,
        TexParameteri: ?*const fn (_: c_uint, _: c_uint, _: c_int) callconv(.C) void,
    };
};
