// SYNTHETIC STUB — generated for isolated test harness only.
//
// This file provides the minimum surface of `opengl_c` required to compile
// and exercise the inline tests in pkg/opengl/egl.zig. It is NOT a real
// binding. Real opengl_c comes from the `opengl` zig package
// (pkg/opengl/build.zig.zon), wired into the test_exe via
// src/build/SharedDeps.zig:520-521.
//
// Lazy analysis: only the symbols referenced by pkg/opengl/egl.zig are
// declared here. If the production code adds new `c.*` references, this
// stub will fail to compile, signaling the gap.
//
// Purpose: allow `zig test pkg/opengl/egl.zig` on a host that lacks
// libEGL.dylib (this macOS dev box) by avoiding the link step entirely.
// Compile-only: the tests are pure comptime/runtime expressions over the
// production `pickEglIdCast` helper. No FFI calls fire at test time; the
// StubGetPlatformDisplay in egl.zig intercepts.
//
// This is a SYNTHETIC test of the production helper. It does NOT validate
// the rest of the opengl_c surface or the linking story.

const std = @import("std");

// ---- error / status constants (EGL_TRUE/EGL_FALSE/EGL_SUCCESS/...) ----

pub const EGL_FALSE: c_int = 0;
pub const EGL_TRUE: c_int = 1;
pub const EGL_NONE: c_int = 0x3038;
pub const EGL_NO_CONTEXT: ?*anyopaque = null;
pub const EGL_NO_DISPLAY: ?*anyopaque = null;
pub const EGL_NO_SURFACE: ?*anyopaque = null;
pub const EGL_DEFAULT_DISPLAY: ?*anyopaque = null;

pub const EGL_SUCCESS: c_int = 0x3000;
pub const EGL_NOT_INITIALIZED: c_int = 0x3001;
pub const EGL_BAD_ACCESS: c_int = 0x3002;
pub const EGL_BAD_ALLOC: c_int = 0x3003;
pub const EGL_BAD_ATTRIBUTE: c_int = 0x3004;
pub const EGL_BAD_CONFIG: c_int = 0x3005;
pub const EGL_BAD_CONTEXT: c_int = 0x3006;
pub const EGL_BAD_CURRENT_SURFACE: c_int = 0x3007;
pub const EGL_BAD_DISPLAY: c_int = 0x3008;
pub const EGL_BAD_SURFACE: c_int = 0x3009;
pub const EGL_BAD_MATCH: c_int = 0x300A;
pub const EGL_BAD_PARAMETER: c_int = 0x300B;
pub const EGL_BAD_NATIVE_PIXMAP: c_int = 0x300C;
pub const EGL_BAD_NATIVE_WINDOW: c_int = 0x300D;
pub const EGL_CONTEXT_LOST: c_int = 0x300E;

pub const EGL_VENDOR: c_int = 0x3053;
pub const EGL_EXTENSIONS: c_int = 0x3055;
pub const EGL_GL_TEXTURE_2D: c_int = 0x305B;
pub const EGL_PLATFORM_DEVICE: c_int = 0x313F;

// ---- core types ----

pub const EGLDisplay = ?*anyopaque;
pub const EGLConfig = ?*anyopaque;
pub const EGLContext = ?*anyopaque;
pub const EGLSurface = ?*anyopaque;
pub const EGLClientBuffer = ?*anyopaque;
pub const EGLenum = c_uint;
pub const EGLint = i32;
pub const EGLAttrib = isize;
pub const EGLNativeDisplayType = c_int; // matches macOS dev host; tests cover both arms
pub const EGLNativePixmapType = ?*anyopaque;
pub const EGLNativeWindowType = ?*anyopaque;

// ---- function stubs (never called at test time; StubGetPlatformDisplay intercepts) ----

pub extern fn eglBindAPI(api: EGLenum) EGLenum;
pub extern fn eglChooseConfig(d: EGLDisplay, attribs: [*]const EGLint, configs: [*]EGLConfig, config_size: EGLint, num_config: [*]EGLint) EGLenum;
pub extern fn eglCreateContext(d: EGLDisplay, config: EGLConfig, share_context: EGLContext, attribs: [*]const EGLint) EGLContext;
pub extern fn eglCreateImage(d: EGLDisplay, ctx: EGLContext, target: EGLenum, buffer: EGLClientBuffer, attribs: [*]const EGLAttrib) EGLImageKHR;
pub extern fn eglDestroyContext(d: EGLDisplay, ctx: EGLContext) EGLenum;
pub extern fn eglDestroyImage(d: EGLDisplay, image: EGLImageKHR) EGLenum;
pub extern fn eglExportDMABUFImageMESA(d: EGLDisplay, image: EGLImageKHR, attrs: [*]c_int, fd: [*]c_int) EGLenum;
pub extern fn eglExportDMABUFImageQueryMESA(d: EGLDisplay, image: EGLImageKHR, fourcc: [*]c_int, num_planes: [*]c_int, modifiers: [*]c_ulonglong) EGLenum;
pub extern fn eglGetError() EGLint;
pub extern fn eglGetPlatformDisplay(platform: EGLenum, native_display: EGLNativeDisplayType, attribs: ?[*]const EGLAttrib) EGLDisplay;
pub extern fn eglGetProcAddress(procname: [*:0]const u8) ?*const fn () callconv(.c) void;
pub extern fn eglInitialize(d: EGLDisplay, major: [*]EGLint, minor: [*]EGLint) EGLenum;
pub extern fn eglMakeCurrent(d: EGLDisplay, draw: EGLSurface, read: EGLSurface, ctx: EGLContext) EGLenum;
pub extern fn eglQueryString(d: EGLDisplay, name: EGLenum) ?[*:0]const u8;
pub extern fn eglTerminate(d: EGLDisplay) EGLenum;
pub extern fn gladLoadEGL(d: EGLDisplay) c_int;

pub const EGLImageKHR = ?*anyopaque;
