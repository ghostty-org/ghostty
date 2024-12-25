const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc");
const internal_os = @import("main.zig");

const assert = std.debug.assert;
const log = std.log.scoped(.os);

const LC_ALL: c_int = 6;                 // from C <locale.h>
const LC_ALL_MASK: c_int = 0x7fffffff;   // from C <locale.h>
const locale_t = ?*anyopaque;

extern "c" fn setlocale(category: c_int, locale: ?[*]const u8) ?[*:0]u8;
extern "c" fn newlocale(category: c_int, locale: ?[*]const u8, base: locale_t) locale_t;
extern "c" fn freelocale(v: locale_t) void;

/// Ensures that the locale is set correctly. If `LANG` is unset or empty
/// on Darwin (macOS), attempts to query the system locale via Cocoa.
/// Otherwise, uses environment variables. If everything fails, falls back to
/// `en_US.UTF-8`.
pub fn ensureLocale(alloc: std.mem.Allocator) !void {
    assert(builtin.link_libc);

    const maybe_lang = try internal_os.getenv(alloc, "LANG");
    defer if (maybe_lang) |lang| lang.deinit(alloc);

    if (comptime builtin.target.isDarwin()) {
        if (maybe_lang == null or maybe_lang.?.value.len == 0) {
            setLangFromCocoa();
        }
    }

    if (setlocale(LC_ALL, "")) |loc| {
        log.info("Locale set from environment: {s}", .{loc});
        return;
    }

    if (maybe_lang) |old_lang| {
        if (old_lang.value.len > 0) {
            const rc_unset = internal_os.unsetenv("LANG");
            if (rc_unset < 0) {
                log.err("Failed to unset LANG.", .{});
                // Could return an error if desired:
                // return error.CannotUnsetLang;
            }

            // Retry
            if (setlocale(LC_ALL, "")) |loc| {
                log.info("Locale set after unsetting LANG: {s}", .{loc});
                if (!std.mem.eql(u8, std.mem.sliceTo(loc, 0), "C")) {
                    return;
                }
            }
        }
    }

    // Final fallback
    log.warn("All attempts to set a locale have failed. Falling back to en_US.UTF-8.", .{});

    if (setlocale(LC_ALL, "en_US.UTF-8")) |fallback_loc| {
        const rc_env = internal_os.setenv("LANG", "en_US.UTF-8");
        if (rc_env < 0) {
            log.err("Failed to set LANG to en_US.UTF-8.", .{});
            // Could return an error or just continue
        }
        log.info("Locale forced to en_US.UTF-8: {s}", .{fallback_loc});
    } else {
        // Even fallback failed
        log.err("setlocale('en_US.UTF-8') failed. Proceeding with uncertain results.", .{});
    }
}

fn setLangFromCocoa() void {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    const NSLocale = objc.getClass("NSLocale") orelse {
        log.err("NSLocale class not found. Locale may be incorrect.", .{});
        return;
    };
    const locale_obj = NSLocale.msgSend(objc.Object, objc.sel("currentLocale"), .{});
    const lang_obj = locale_obj.getProperty(objc.Object, "languageCode");
    const country_obj = locale_obj.getProperty(objc.Object, "countryCode");

    const c_lang_ptr = lang_obj.getProperty([*:0]const u8, "UTF8String");
    const c_country_ptr = country_obj.getProperty([*:0]const u8, "UTF8String");

    const z_lang = std.mem.sliceTo(c_lang_ptr, 0);
    const z_country = std.mem.sliceTo(c_country_ptr, 0);

    var buf: [128]u8 = undefined;
    const env_value = std.fmt.bufPrintZ(&buf, "{s}_{s}.UTF-8", .{ z_lang, z_country }) catch |err| {
        log.err("Error constructing locale string. err={}", .{err});
        return;
    };

    log.info("Detected system locale: {s}", .{env_value});

    const rc = internal_os.setenv("LANG", env_value);
    if (rc < 0) {
        log.err("Error setting the LANG environment variable to '{s}'.", .{env_value});
    }
}