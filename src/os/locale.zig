//! This file provides functions to ensure the OS locale is correctly set.
//! On Darwin (macOS), if `LANG` is unset or empty, we attempt to pull the locale
//! settings from the system preferences. Otherwise, we rely on the environment
//! variables. If everything fails, we fall back to `en_US.UTF-8`.

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc");
const internal_os = @import("main.zig");

const assert = std.debug.assert;
const log = std.log.scoped(.os);

// ─────────────────────────────────────────────────────────────────────────────
// External definitions referencing libc symbols.
//
// References:
//   - POSIX setlocale: https://pubs.opengroup.org/onlinepubs/9699919799/functions/setlocale.html
//   - newlocale/freelocale: https://pubs.opengroup.org/onlinepubs/9699919799/functions/newlocale.html
// ─────────────────────────────────────────────────────────────────────────────

const LC_ALL: c_int = 6;                // from C <locale.h>
const LC_ALL_MASK: c_int = 0x7fffffff;  // from C <locale.h>
const locale_t = ?*anyopaque;

extern "c" fn setlocale(category: c_int, locale: ?[*]const u8) ?[*:0]u8;
extern "c" fn newlocale(category: c_int, locale: ?[*]const u8, base: locale_t) locale_t;
extern "c" fn freelocale(v: locale_t) void;

// ─────────────────────────────────────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────────────────────────────────────

/// Ensures that the locale is set correctly. If `LANG` is unset or empty
/// on Darwin (macOS), attempts to query the system locale via Cocoa.
/// Otherwise, tries to use the existing environment variable values, and
/// if that fails, falls back to `en_US.UTF-8`.
///
/// # Parameters
/// - `alloc`: A valid allocator for temporary allocations.
///
/// # Returns
/// An error if reading or modifying environment variables fails.
///
/// # References
/// - Zig standard library environment handling: https://ziglang.org/documentation/master/std/#std;mem
/// - Darwin/macOS locale logic (analysis): It's common for macOS apps to
///   lack a `LANG` variable when launched from Finder, so we use the Cocoa
///   API to derive one.
///
/// # Analysis
/// This function tries several fallbacks to ensure the user is not left
/// in a broken or unsupported locale scenario.
pub fn ensureLocale(alloc: std.mem.Allocator) !void {
    assert(builtin.link_libc);

    // Attempt to read `LANG` from the environment.
    // Reference: Zig environment variable handling: https://ziglang.org/documentation/master/std/#std;os
    const maybe_lang = try internal_os.getenv(alloc, "LANG");
    defer if (maybe_lang) |lang_buffer| lang_buffer.deinit(alloc);

    // On macOS, if `LANG` is unset or empty, we attempt to set it via Cocoa.
    // Reference: Apple docs for NSLocale:
    //   https://developer.apple.com/documentation/foundation/nslocale
    if (comptime builtin.target.isDarwin()) {
        if (maybe_lang == null or maybe_lang.?.value.len == 0) {
            setLangFromCocoa();
        }
    }

    // Attempt to set locale from environment variables.
    // If successful, we're done.
    if (setlocale(LC_ALL, "")) |setloc_result| {
        log.info("Locale set from environment: {s}", .{setloc_result});
        return;
    }

    // The call to setlocale failed, likely due to an invalid LANG value.
    // We try unsetting `LANG` altogether and re-attempting.
    if (maybe_lang) |old_lang| {
        if (old_lang.value.len > 0) {
            // Clear/unset LANG to force the system default locale.
            _ = internal_os.setenv("LANG", "");
            _ = internal_os.unsetenv("LANG");

            if (setlocale(LC_ALL, "")) |setloc_result| {
                log.info("Locale set after unsetting LANG: {s}", .{setloc_result});

                // Some systems fall back to "C" if the specified locale doesn't exist.
                // If that's the case, we prefer not to rely on "C" and instead will
                // later force "en_US.UTF-8".
                if (!std.mem.eql(u8, std.mem.sliceTo(setloc_result, 0), "C")) {
                    return;
                }
            }
        }
    }

    // If we get here, everything has failed, so fallback to en_US.UTF-8.
    log.warn("All attempts to set a locale have failed. Falling back to en_US.UTF-8.", .{});
    if (setlocale(LC_ALL, "en_US.UTF-8")) |fallback_setloc| {
        _ = internal_os.setenv("LANG", "en_US.UTF-8");
        log.info("Locale forced to en_US.UTF-8: {s}", .{fallback_setloc});
        return;
    } else {
        // Even the fallback has failed, which is quite unusual.
        log.err("setlocale failed even with en_US.UTF-8 fallback. Proceeding with uncertain results.", .{});
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Sets the LANG environment variable on Darwin/macOS based on the system
/// preferences selected locale settings.
///
/// # Analysis
/// If the Cocoa calls or the class lookups fail, a warning is logged and
/// the function returns without modifying any environment variables.
fn setLangFromCocoa() void {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    // Attempt to obtain references to Foundation classes.
    // Reference: Apple Objective-C runtime: https://developer.apple.com/documentation/objectivec
    const NSLocale = objc.getClass("NSLocale") orelse {
        log.err("NSLocale class not found. Locale may be incorrect.", .{});
        return;
    };

    // msgSend allows sending a message to the class instance:
    //   - `currentLocale` returns the current user locale.
    // Reference: https://developer.apple.com/documentation/foundation/nslocale/1642833-currentlocale
    const locale_obj = NSLocale.msgSend(objc.Object, objc.sel("currentLocale"), .{});
    const lang_obj = locale_obj.getProperty(objc.Object, "languageCode");
    const country_obj = locale_obj.getProperty(objc.Object, "countryCode");

    // Retrieve the `UTF8String` property from the Objective-C strings.
    // If these calls fail, they will return null pointers, which we can
    // detect by zero-length slices in Zig.
    const c_lang_ptr = lang_obj.getProperty([*:0]const u8, "UTF8String");
    const c_country_ptr = country_obj.getProperty([*:0]const u8, "UTF8String");

    const z_lang = std.mem.sliceTo(c_lang_ptr, 0);
    const z_country = std.mem.sliceTo(c_country_ptr, 0);

    var buf: [128]u8 = undefined;
    // Attempt to format a string like "en_US.UTF-8" into a buffer.
    const env_value = std.fmt.bufPrintZ(
        &buf,
        "{s}_{s}.UTF-8",
        .{ z_lang, z_country }
    ) catch |err| {
        log.err("Error constructing locale string from system preferences. err={}", .{err});
        return;
    };

    log.info("Detected system locale: {s}", .{env_value});

    // Finally, set `LANG` using our internal OS helper.
    // If setenv fails, it returns a negative integer.
    if (internal_os.setenv("LANG", env_value) < 0) {
        log.err("Error setting the LANG environment variable to '{s}'.", .{env_value});
    }
}