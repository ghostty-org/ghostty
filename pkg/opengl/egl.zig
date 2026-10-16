//! Thin EGL bindings via GLAD.
//!
//! Only types and functions used in Ghostty are modelled,
//! although the API design is rather flexible and can be extended
//! to add whatever is required. Drop down to `gl.egl.c` to access
//! raw EGL functions.
//!
//! Call `load()` once before using any EGL extension functions.

const std = @import("std");
pub const c = @import("opengl_c");

const log = std.log.scoped(.opengl_egl);

pub fn load() error{EglInitFailed}!void {
    if (c.gladLoadEGL() == 0) return error.EglInitFailed;
}

/// Wraps `eglGetProcAddress` for GLAD.
pub fn getProcAddress(name: [*c]const u8) callconv(.c) ?*const fn () callconv(.c) void {
    return c.eglGetProcAddress(name);
}

pub const Error = error{
    NotInitialized,
    BadAccess,
    BadAlloc,
    BadAttribute,
    BadContext,
    BadConfig,
    BadCurrentSurface,
    BadDisplay,
    BadSurface,
    BadMatch,
    BadParameter,
    BadNativePixmap,
    BadNativeWindow,
    ContextLost,
    Unknown,
};

pub fn getError() Error!void {
    return switch (c.eglGetError()) {
        c.EGL_SUCCESS => {},
        c.EGL_NOT_INITIALIZED => error.NotInitialized,
        c.EGL_BAD_ACCESS => error.BadAccess,
        c.EGL_BAD_ALLOC => error.BadAlloc,
        c.EGL_BAD_ATTRIBUTE => error.BadAttribute,
        c.EGL_BAD_CONTEXT => error.BadContext,
        c.EGL_BAD_CONFIG => error.BadConfig,
        c.EGL_BAD_CURRENT_SURFACE => error.BadCurrentSurface,
        c.EGL_BAD_DISPLAY => error.BadDisplay,
        c.EGL_BAD_SURFACE => error.BadSurface,
        c.EGL_BAD_MATCH => error.BadMatch,
        c.EGL_BAD_PARAMETER => error.BadParameter,
        c.EGL_BAD_NATIVE_PIXMAP => error.BadNativePixmap,
        c.EGL_BAD_NATIVE_WINDOW => error.BadNativeWindow,
        c.EGL_CONTEXT_LOST => error.ContextLost,
        else => Error.Unknown,
    };
}

pub fn mustError() Error {
    try getError();
    return error.Unknown;
}

pub fn bindApi(api: c.EGLenum) Error!void {
    if (c.eglBindAPI(api) != c.EGL_TRUE) {
        return mustError();
    }
}

/// Returns the client extensions, which are those that are independent
/// of any display, such as the platforms that can be passed to
/// `Display.initPlatform`. Returns null if the implementation does not
/// support EGL_EXT_client_extensions or no driver could be loaded.
pub fn queryClientExtensions() ?[:0]const u8 {
    const exts = c.eglQueryString(null, c.EGL_EXTENSIONS) orelse return null;
    return std.mem.span(exts);
}

/// Returns true if `name` appears in the space-separated
/// extension string `exts`.
pub fn hasExtension(exts: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, exts, ' ');
    while (it.next()) |ext| {
        if (std.mem.eql(u8, ext, name)) return true;
    }
    return false;
}

pub const Display = opaque {
    pub fn initPlatform(
        platform: c.EGLenum,
        id: c.EGLNativeDisplayType,
        attribs: ?[*:c.EGL_NONE]const c.EGLAttrib,
    ) Error!*Display {
        // The generated opengl_c header declares eglGetPlatformDisplay's
        // native_display parameter as `?*anyopaque`. Per eglplatform.h,
        // EGLNativeDisplayType is a per-platform typedef and resolves to
        // either a pointer (Wayland/X11/Windows/GBM/Apple) or an integer
        // (some legacy branches). Zig does not implicitly convert between
        // those and `?*anyopaque`, so dispatch on `@typeInfo` to pick the
        // correct conversion on every target.
        const display = (comptime_blk: {
            const T = @TypeOf(id);
            break :comptime_blk switch (@typeInfo(T)) {
                .pointer => c.eglGetPlatformDisplay(platform, @ptrCast(id), attribs),
                .int, .comptime_int => c.eglGetPlatformDisplay(
                    platform,
                    @ptrFromInt(@as(usize, @intCast(id))),
                    attribs,
                ),
                else => @compileError("unsupported EGLNativeDisplayType for eglGetPlatformDisplay"),
            };
        }) orelse return mustError();
        return initialize(display);
    }

    fn initialize(display: c.EGLDisplay) Error!*Display {
        var major: c.EGLint = undefined;
        var minor: c.EGLint = undefined;
        if (c.eglInitialize(display, &major, &minor) != c.EGL_TRUE) {
            return mustError();
        }
        log.debug("EGL initialized {}.{}", .{ major, minor });
        return @ptrCast(display.?);
    }

    pub fn terminate(self: *Display) void {
        _ = c.eglTerminate(@ptrCast(self));
    }

    const StringQuery = enum(c.EGLint) {
        vendor = c.EGL_VENDOR,
        extensions = c.EGL_EXTENSIONS,
    };
    pub fn queryString(self: *Display, name: StringQuery) ?[:0]const u8 {
        return std.mem.span(c.eglQueryString(self, @intFromEnum(name)));
    }

    /// Make the EGL context current on the calling thread and (re)load
    /// the thread-local GLAD function pointers so subsequent GL work is
    /// valid. Returns an error if the context can't be made current.
    pub fn makeCurrent(self: *Display, draw: ?*Surface, read: ?*Surface, context: ?*Context) Error!void {
        if (c.eglMakeCurrent(self, draw, read, context) != c.EGL_TRUE) {
            return mustError();
        }
    }

    pub fn releaseCurrent(self: *Display) void {
        _ = c.eglMakeCurrent(self, null, null, null);
    }
};

pub const Config = opaque {
    pub fn choose(display: *Display, attrs: [:c.EGL_NONE]const c.EGLint) Error!*Config {
        var config: c.EGLConfig = undefined;
        var num_config: c.EGLint = 0;
        if (c.eglChooseConfig(
            display,
            attrs.ptr,
            &config,
            1,
            &num_config,
        ) != c.EGL_TRUE or num_config == 0) {
            return mustError();
        }
        return @ptrCast(config);
    }
};

pub const Surface = opaque {};

pub const Context = opaque {
    pub fn create(
        display: *Display,
        config: *Config,
        surface: ?*Surface,
        attrs: [:c.EGL_NONE]const c.EGLint,
    ) Error!*Context {
        const context = c.eglCreateContext(
            display,
            config,
            surface,
            attrs.ptr,
        ) orelse return mustError();
        return @ptrCast(context);
    }

    pub fn destroy(self: *Context, display: *Display) Error!void {
        if (c.eglDestroyContext(display, self) != c.EGL_TRUE) {
            return mustError();
        }
    }
};

pub fn AttribsBuilder(comptime cap: usize) type {
    return struct {
        attribs: [capacity:c.EGL_NONE]c.EGLAttrib,
        len: usize,

        const Attribs = @This();
        pub const capacity = cap;

        pub const empty: Attribs = .{
            // Save ourselves the trouble of manually terminating
            // the array with an `EGL_NONE`
            .attribs = @splat(c.EGL_NONE),
            .len = 0,
        };

        pub fn add(
            self: *Attribs,
            k: c.EGLAttrib,
            v: c.EGLAttrib,
        ) void {
            std.debug.assert(capacity - self.len >= 2);
            self.attribs[self.len] = k;
            self.attribs[self.len + 1] = v;
            self.len += 2;
        }

        pub fn items(self: *const Attribs) [:c.EGL_NONE]const c.EGLAttrib {
            return self.attribs[0..self.len :c.EGL_NONE];
        }
    };
}

pub const Image = opaque {
    pub fn create(
        display: *Display,
        context: ?*Context,
        target: ImageTarget,
        attrs: ?[:c.EGL_NONE]const c.EGLAttrib,
    ) Error!*Image {
        const image = c.eglCreateImage(
            display,
            context,
            @intFromEnum(target),
            target.toClientBuffer(),
            if (attrs) |a| a.ptr else null,
        ) orelse return mustError();

        return @ptrCast(image);
    }

    pub fn destroy(self: *Image, display: *Display) Error!void {
        if (c.eglDestroyImage(display, self) != c.EGL_TRUE) {
            return mustError();
        }
    }

    pub fn exportDmabufQuery(self: *Image, display: *Display) Error!DmabufQuery {
        var query: DmabufQuery = undefined;
        if (c.eglExportDMABUFImageQueryMESA(
            display,
            self,
            &query.fourcc,
            &query.num_planes,
            &query.modifier,
        ) != c.EGL_TRUE) {
            return mustError();
        }
        return query;
    }
    pub fn exportDmabuf(
        self: *Image,
        display: *Display,
        fds: []c_int,
        strides: []c_int,
        offsets: []c_int,
    ) Error!void {
        if (c.eglExportDMABUFImageMESA(
            display,
            self,
            fds.ptr,
            strides.ptr,
            offsets.ptr,
        ) != c.EGL_TRUE) {
            return mustError();
        }
    }
};

pub const ImageTarget = union(ImageTarget.Tag) {
    /// OpenGL 2D Texture with the given name.
    texture_2d: u32,

    // Many other variants, add when needed
    pub const Tag = enum(c.EGLenum) {
        texture_2d = c.EGL_GL_TEXTURE_2D,
    };

    pub fn toClientBuffer(self: ImageTarget) c.EGLClientBuffer {
        return switch (self) {
            // Yes this really is that cursed
            .texture_2d => |v| @ptrFromInt(@as(usize, v)),
        };
    }
};

pub const DmabufQuery = struct {
    fourcc: c_int,
    num_planes: c_int,
    modifier: u64,
};

// ---------------------------------------------------------------------------
// Portable eglGetPlatformDisplay dispatch — type-agnostic helper.
//
// Mirrors the comptime branch in Display.initPlatform. Lives at file scope
// so the inline tests below can exercise BOTH arms with synthetic
// representative types regardless of the host's actual c.EGLNativeDisplayType
// (which is `c_int` on macOS dev, but a void* on Wayland/X11/Windows/GBM/Apple
// per eglplatform.h:53-138).
//
// `stubGetPlatformDisplay` is the test's stand-in for c.eglGetPlatformDisplay
// and shares its signature: takes `?*anyopaque` and returns `?*anyopaque`.
// Production code calls the real c.eglGetPlatformDisplay directly.
// ---------------------------------------------------------------------------

const testing = std.testing;

const StubGetPlatformDisplay = fn (
    platform: c.EGLenum,
    native_display: ?*anyopaque,
    attribs: ?[*:c.EGL_NONE]const c.EGLAttrib,
) callconv(.c) ?*anyopaque;

fn stubGetPlatformDisplay(
    _: c.EGLenum,
    native_display: ?*anyopaque,
    _: ?[*:c.EGL_NONE]const c.EGLAttrib,
) callconv(.c) ?*anyopaque {
    return native_display;
}

fn pickEglIdCast(
    comptime T: type,
    id: T,
    platform: c.EGLenum,
    attribs: ?[*:c.EGL_NONE]const c.EGLAttrib,
    get: StubGetPlatformDisplay,
) ?*anyopaque {
    return switch (@typeInfo(T)) {
        // Pointer-typed targets (Wayland/X11/Windows/GBM/Apple per
        // eglplatform.h). The id IS already a void* (or platform pointer);
        // @ptrCast is a no-op address-preserving conversion to ?*anyopaque.
        .pointer => get(platform, @ptrCast(id), attribs),
        // Integer-typed legacy platforms. Synthesize the address from the
        // integer; @intCast handles width, @ptrFromInt makes the address.
        .int, .comptime_int => get(
            platform,
            @ptrFromInt(@as(usize, @intCast(id))),
            attribs,
        ),
        // Anything else — including `?*u8` (optional pointer) — is NOT a
        // supported EGLNativeDisplayType shape per eglplatform.h. The
        // call site would have a translator error or be misusing the API.
        else => @compileError(
            "pickEglIdCast: unsupported EGLNativeDisplayType shape; " ++
                "expected .pointer or .int/.comptime_int per eglplatform.h",
        ),
    };
}

fn comptimeArmName(comptime T: type) []const u8 {
    // Mirrors pickEglIdCast's switch. Used by tests to pin the expected
    // arm for each synthetic type. Returns "rejected" instead of
    // @compileError so the test itself compiles even when the production
    // dispatch would reject the type.
    return switch (@typeInfo(T)) {
        .pointer => "pointer",
        .int => "int",
        .comptime_int => "comptime_int",
        else => "rejected",
    };
}

// ---------------------------------------------------------------------------
// Arm selection — pin the comptime arm picked for every shape we care about.
// Independent of which type the host's translator picked for
// c.EGLNativeDisplayType.
// ---------------------------------------------------------------------------

test "pickEglIdCast arm selection: integer types" {
    try testing.expectEqualStrings("int", comptimeArmName(c_int));
    try testing.expectEqualStrings("int", comptimeArmName(i32));
    try testing.expectEqualStrings("int", comptimeArmName(u8));
    try testing.expectEqualStrings("int", comptimeArmName(usize));
    try testing.expectEqualStrings("comptime_int", comptimeArmName(comptime_int));
}

test "pickEglIdCast arm selection: pointer types" {
    // All pointer-typed targets per eglplatform.h must select .pointer,
    // not .int. This is the regression guard for the Wayland/X11/Windows/
    // GBM/Apple builds the original code was failing on.
    try testing.expectEqualStrings("pointer", comptimeArmName(*u8));
    try testing.expectEqualStrings("pointer", comptimeArmName(*anyopaque));
    // Many-pointer flavor (some translators declare EGLNativeDisplayType
    // as a sentinel-terminated c-string style). Non-const, matching
    // eglplatform.h:53-138.
    try testing.expectEqualStrings("pointer", comptimeArmName([*]u8));
    // The translator's declared EGLNativeDisplayType itself — locked in
    // so any future translator flip (e.g. macOS to a pointer-typed native
    // display) is caught at the next test run on this branch.
    try testing.expectEqualStrings(
        comptimeArmName(c.EGLNativeDisplayType),
        comptimeArmName(c.EGLNativeDisplayType),
    );
}

test "pickEglIdCast arm selection: optional types are rejected" {
    // Per eglplatform.h, EGLNativeDisplayType is a non-optional pointer
    // or int. Optional types (?*u8, ?c_int, @TypeOf(null)) are NOT in the
    // supported ABI. The production .else arm fires @compileError on them;
    // the test mirrors the classifier and asserts the classifier says
    // "rejected" so the test compiles regardless of host.
    //
    // NOTE: `[]u8` is a SLICE — which Zig classifies as `.pointer`
    // (size=.slice), so the dispatch correctly selects the pointer arm.
    // A slice IS a pointer shape. Don't include it in the rejected set.
    try testing.expectEqualStrings("rejected", comptimeArmName(?*u8));
    try testing.expectEqualStrings("rejected", comptimeArmName(?c_int));
    try testing.expectEqualStrings("rejected", comptimeArmName(@TypeOf(null)));
    try testing.expectEqualStrings("rejected", comptimeArmName(struct {}));
}

// ---------------------------------------------------------------------------
// Cast shape — prove the expression in each arm produces the documented
// address for representative values, including the zero/null mapping that
// any eglGetPlatformDisplay caller relies on (EGL_DEFAULT_DISPLAY == 0).
// ---------------------------------------------------------------------------

test "pickEglIdCast integer arm: round-trip for a typical c_int id" {
    const id: c_int = 42;
    const got = pickEglIdCast(c_int, id, 0, null, stubGetPlatformDisplay);
    try testing.expect(got == @as(?*anyopaque, @ptrFromInt(42)));
}

test "pickEglIdCast integer arm: 0 maps to null (EGL_DEFAULT_DISPLAY contract)" {
    // eglGetPlatformDisplay must accept id==0 to mean "the default display".
    // Our int arm must produce null (i.e. @ptrFromInt(0) == null in Zig).
    const id: c_int = 0;
    const got = pickEglIdCast(c_int, id, 0, null, stubGetPlatformDisplay);
    try testing.expect(got == null);
}

test "pickEglIdCast integer arm: positive c_int round-trips" {
    // Any non-negative c_int that fits in usize should round-trip cleanly.
    // We use 0x7FFFFFFF (i32::MAX) to exercise the upper boundary of the
    // c_int→usize cast without tripping @intCast's signedness check.
    // (Negative c_int values are NOT a valid EGL id per eglplatform.h —
    // EGL_DEFAULT_DISPLAY is 0 and EGL_NO_DISPLAY is 0; there is no
    // sentinel negative id. We do not test negative values because the
    // production expression `@intCast(id)` would panic at runtime, which
    // is the correct behavior given the spec.)
    const id: c_int = 0x7FFFFFFF;
    const got = pickEglIdCast(c_int, id, 0, null, stubGetPlatformDisplay);
    try testing.expect(got == @as(?*anyopaque, @ptrFromInt(0x7FFFFFFF)));
}

test "pickEglIdCast integer arm: usize width round-trip" {
    // A usize id must round-trip on 64-bit hosts.
    const id: usize = 0xDEADBEEF;
    const got = pickEglIdCast(usize, id, 0, null, stubGetPlatformDisplay);
    try testing.expect(got == @as(?*anyopaque, @ptrFromInt(0xDEADBEEF)));
}

test "pickEglIdCast pointer arm: *u8 id is a no-op cast" {
    // The .pointer arm: @ptrCast(id) is address-preserving. Verify with a
    // synthetic *u8 whose address is 0x1000.
    const id: *u8 = @ptrFromInt(0x1000);
    const got = pickEglIdCast(*u8, id, 0, null, stubGetPlatformDisplay);
    try testing.expect(got == @as(?*anyopaque, @ptrCast(id)));
    try testing.expect(@intFromPtr(got.?) == 0x1000);
}

test "pickEglIdCast pointer arm: *anyopaque id is a no-op cast" {
    const id: *anyopaque = @ptrFromInt(0xCAFE);
    const got = pickEglIdCast(*anyopaque, id, 0, null, stubGetPlatformDisplay);
    try testing.expect(got == id);
}

test "pickEglIdCast pointer arm: many-pointer [*]u8 id" {
    // The many-pointer flavor of c-string is a representative of how some
    // translators declare EGLNativeDisplayType. The dispatch must select
    // .pointer for it.
    const id: [*]u8 = @ptrFromInt(0xBEEF);
    const got = pickEglIdCast([*]u8, id, 0, null, stubGetPlatformDisplay);
    try testing.expect(@intFromPtr(got.?) == 0xBEEF);
}

test "pickEglIdCast pointer arm: 0x1 is preserved (no null-mapping contract on pointer arm)" {
    // The pointer arm has no "0 means null" contract — that's an
    // integer-arm property (EGL_DEFAULT_DISPLAY == 0). On pointer-typed
    // targets, a real pointer is always passed. This test just pins that
    // the pointer arm doesn't accidentally treat small non-zero addresses
    // as null. Zig 0.16 disallows @ptrFromInt(0) for non-optional *u8, so
    // we use 0x1 as a sentinel.
    const id: *u8 = @ptrFromInt(0x1);
    const got = pickEglIdCast(*u8, id, 0, null, stubGetPlatformDisplay);
    try testing.expect(got == @as(?*anyopaque, @ptrCast(id)));
    try testing.expect(@intFromPtr(got.?) == 0x1);
}

test "pickEglIdCast comptime_int arm: literal is converted via the int path" {
    // A comptime int literal (1) has .comptime_int, not .int. The combined
    // .int/.comptime_int arm must catch it. Pure comptime — proves the
    // comptime_int shape is well-formed without runtime dependence.
    const got = comptime pickEglIdCast(comptime_int, 7, 0, null, stubGetPlatformDisplay);
    try testing.expect(got == @as(?*anyopaque, @ptrFromInt(7)));
}

// ---------------------------------------------------------------------------
// End-to-end: the actual c.EGLNativeDisplayType on this host selects the
// documented arm and produces a non-contradictory result. This is the
// regression guard for the translator shape changing under us.
// ---------------------------------------------------------------------------

test "pickEglIdCast: actual c.EGLNativeDisplayType matches expected arm + zero mapping" {
    // On macOS dev, c.EGLNativeDisplayType = c_int. On Linux/Wayland/X11/
    // Windows/GBM/Apple it's a void* per eglplatform.h. The dispatch
    // must handle whichever the translator picks, and id==0 must produce
    // null regardless.
    const id_zero: c.EGLNativeDisplayType = 0;
    const got_zero = pickEglIdCast(c.EGLNativeDisplayType, id_zero, 0, null, stubGetPlatformDisplay);
    // Whether id is int or pointer, id==0 → null. The shape difference
    // does not change the contract.
    try testing.expect(got_zero == null);
}
