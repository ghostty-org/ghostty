//! Global constructor initialization for the libghostty-vt Windows DLL.
//!
//! Zig's `std.start` exports a `_DllMainCRTStartup` for any dynamic library
//! that returns TRUE without doing any C runtime work, and because it is the
//! image's entry point the real CRT bootstrap never runs: on MSVC that is
//! `__scrt_dllmain_crt_initialize`, and on MinGW it is `dllcrt2.obj`, which
//! is linked but never reached. Executables don't have this problem, which
//! is why `zig build test` and the static-linking examples pass while the
//! shipped DLL crashes.
//!
//! What we have to do by hand is run the C++ global constructors. Note that
//! we do *not* have to bootstrap the CRT itself: libghostty-vt links the
//! DLL-based CRT (the image imports `api-ms-win-crt-*.dll` and
//! `vcruntime140.dll`), and those DLLs initialize their own state from their
//! own `DllMain`. The static-CRT entry points (`__vcrt_initialize`,
//! `__acrt_initialize`) live in `libvcruntime.lib`/`libucrt.lib`, which are
//! not linked into libghostty-vt, so calling them is both unnecessary and a
//! link error. The full libghostty DLL is different: it links the static CRT
//! and bootstraps it from its own `DllMain` in `main_c.zig`.
//!
//! Running the initializers matters because we build the vendored simdutf
//! with `SIMDUTF_NO_LIBCXX`, which makes simdutf define
//! `SIMDUTF_USE_STATIC_INITIALIZATION` and hold its active-kernel pointer and
//! every kernel singleton in translation-unit-scope statics rather than in
//! lazily initialized function-scope ones (thread-safe function-scope statics
//! would need libc++abi's guard functions). Left unconstructed those are all
//! null, so the first call into simdutf makes a virtual call through a null
//! `implementation*` and the process dies reading near address zero. Pure
//! ASCII never reaches simdutf, which is why only multi-byte UTF-8 crashes.
//!
//! This is all a workaround for the toolchain. Remove it when Zig runs
//! global constructors for Windows dynamic libraries itself.
const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

const DLL_PROCESS_ATTACH: windows.DWORD = 1;

/// A global constructor, as the linker collects them.
const Initializer = *const fn () callconv(.c) void;

/// MSVC collects global constructors into `.CRT$XCU`. The linker concatenates
/// `.CRT$*` sections in alphabetical order, so a marker in `.CRT$XCA` and one
/// in `.CRT$XCZ` bracket every initializer in the image. This is how the CRT's
/// own `_initterm` finds them.
export const ghostty_crt_xc_a: ?Initializer linksection(".CRT$XCA") = null;
export const ghostty_crt_xc_z: ?Initializer linksection(".CRT$XCZ") = null;

/// MinGW collects global constructors into `__CTOR_LIST__` instead: a
/// sentinel of -1, then the initializers, then a null terminator. This is
/// the list that `dllcrt2.obj` would have walked.
extern var __CTOR_LIST__: ?Initializer;

pub fn DllMain(
    hinstDLL: windows.HINSTANCE,
    fdwReason: windows.DWORD,
    lpReserved: windows.LPVOID,
) callconv(.winapi) windows.BOOL {
    _ = hinstDLL;
    _ = lpReserved;

    switch (fdwReason) {
        DLL_PROCESS_ATTACH => runGlobalConstructors(),
        else => {},
    }

    return .TRUE;
}

fn runGlobalConstructors() void {
    if (comptime builtin.abi != .msvc) {
        // We walk `__CTOR_LIST__` ourselves rather than calling `__main`,
        // which is what an executable would use. `__main` also performs
        // atexit and exception-handling registration that is not safe from
        // `DllMain`; doing it there corrupts the heap before the loader
        // even returns.
        const list: [*]const ?Initializer = @ptrCast(&__CTOR_LIST__);
        var len: usize = 0;
        while (list[len + 1] != null) len += 1;

        // MinGW runs these in reverse list order.
        var i: usize = len;
        while (i >= 1) : (i -= 1) list[i].?();
        return;
    }

    const start: [*]const ?Initializer = @ptrCast(&ghostty_crt_xc_a);
    const end: [*]const ?Initializer = @ptrCast(&ghostty_crt_xc_z);
    const len = (@intFromPtr(end) - @intFromPtr(start)) / @sizeOf(?Initializer);
    for (start[0..len]) |initializer| if (initializer) |f| f();
}
