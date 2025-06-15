const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const macos = @import("macos");
const objc = @import("objc");
const internal_os = @import("main.zig");
const i18n = internal_os.i18n;

const log = std.log.scoped(.os_locale);

/// Ensure that the locale is set.
pub fn ensureLocale(alloc: std.mem.Allocator) !void {
    assert(builtin.link_libc);

    // Get our LANG env var. We use this many times but we also need
    // the original value later.
    const lang = try internal_os.getenv(alloc, "LANG");
    defer if (lang) |v| v.deinit(alloc);

    // On macOS, pre-populate the LANG env var with system preferences.
    // When launching the .app, LANG is not set so we must query it from the
    // OS. When launching from the CLI, LANG is usually set by the parent
    // process.
    if (comptime builtin.target.os.tag.isDarwin()) {
        // Set the lang if it is not set or if its empty.
        if (lang == null or lang.?.value.len == 0) {
            setLangFromCocoa();
        }
    }

    // Set the locale to whatever is set in env vars.
    if (setlocale(LC_ALL, "")) |v| {
        log.info("setlocale from env result={s}", .{v});
        return;
    }

    // setlocale failed. This is probably because the LANG env var is
    // invalid. Try to set it without the LANG var set to use the system
    // default.
    if ((try internal_os.getenv(alloc, "LANG"))) |old_lang| {
        defer old_lang.deinit(alloc);
        if (old_lang.value.len > 0) {
            // We don't need to do both of these things but we do them
            // both to be sure that lang is either empty or unset completely.
            _ = internal_os.setenv("LANG", "");
            _ = internal_os.unsetenv("LANG");

            if (setlocale(LC_ALL, "")) |v| {
                log.info("setlocale after unset lang result={s}", .{v});

                // If we try to setlocale to an unsupported locale it'll return "C"
                // as the POSIX/C fallback, if that's the case we want to not use
                // it and move to our fallback of en_US.UTF-8
                if (!std.mem.eql(u8, std.mem.sliceTo(v, 0), "C")) return;
            }
        }
    }

    // Failure again... fallback to en_US.UTF-8
    log.warn("setlocale failed with LANG and system default. Falling back to en_US.UTF-8", .{});
    if (setlocale(LC_ALL, "en_US.UTF-8")) |v| {
        _ = internal_os.setenv("LANG", "en_US.UTF-8");
        log.info("setlocale default result={s}", .{v});
        return;
    } else log.warn("setlocale failed even with the fallback, uncertain results", .{});
}

/// This sets the LANG environment variable based on the macOS system
/// preferences selected locale settings.
fn setLangFromCocoa() void {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    // The classes we're going to need.
    const NSLocale = objc.getClass("NSLocale") orelse {
        log.warn("NSLocale class not found. Locale may be incorrect.", .{});
        return;
    };

    // Get our current locale and extract the language code ("en") and
    // country code ("US")
    const locale = NSLocale.msgSend(objc.Object, objc.sel("currentLocale"), .{});
    const lang = locale.getProperty(objc.Object, "languageCode");
    const country = locale.getProperty(objc.Object, "countryCode");

    // Get our UTF8 string values
    const c_lang = lang.getProperty([*:0]const u8, "UTF8String");
    const c_country = country.getProperty([*:0]const u8, "UTF8String");

    // Convert them to Zig slices
    const z_lang = std.mem.sliceTo(c_lang, 0);
    const z_country = std.mem.sliceTo(c_country, 0);

    // Format our locale as "<lang>_<country>.UTF-8" and set it as LANG.
    {
        var buf: [128]u8 = undefined;
        const env_value = std.fmt.bufPrintZ(&buf, "{s}_{s}.UTF-8", .{ z_lang, z_country }) catch |err| {
            log.warn("error setting locale from system. err={}", .{err});
            return;
        };
        log.info("detected system locale={s}", .{env_value});

        // Set it onto our environment
        if (internal_os.setenv("LANG", env_value) < 0) {
            log.warn("error setting locale env var", .{});
            return;
        }
    }

    // Get our preferred languages and set that to the LANGUAGE
    // env var in case our language differs from our locale.
    language: {
        var buf: [1024]u8 = undefined;
        const pref_ = preferredLanguageFromCocoa(
            &buf,
            NSLocale,
        ) catch |err| {
            log.warn("error getting preferred languages. err={}", .{err});
            break :language;
        };

        const pref = pref_ orelse break :language;
        log.debug(
            "setting LANGUAGE from preferred languages value={s}",
            .{pref},
        );
        _ = internal_os.setenv("LANGUAGE", pref);
    }
}

/// Sets the LANGUAGE environment variable based on the preferred languages
/// as reported by NSLocale.
///
/// macOS has a concept of preferred languages separate from the system
/// locale. The set of preferred languages is a list in priority order
/// of what translations the user prefers. A user can have, for example,
/// "fr_FR" as their locale but "en" as their preferred language. This would
/// mean that they want to use French units, date formats, etc. but they
/// prefer English translations.
///
/// gettext uses the LANGUAGE environment variable to override only
/// translations and a priority order can be specified by separating
/// the languages with colons. For example, "en:fr" would mean that
/// English translations are preferred but if they are not available
/// then French translations should be used.
///
/// To further complicate things, Apple reports the languages in BCP-47
/// format which is not compatible with gettext's POSIX locale format so
/// we have to canonicalize them.
fn preferredLanguageFromCocoa(
    buf: []u8,
    NSLocale: objc.Class,
) error{NoSpaceLeft}!?[:0]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();

    // We need to get our app's preferred languages. These may not
    // match the system locale (NSLocale.currentLocale).
    const preferred: *macos.foundation.Array = array: {
        const ns = NSLocale.msgSend(
            objc.Object,
            objc.sel("preferredLanguages"),
            .{},
        );
        break :array @ptrCast(ns.value);
    };
    for (0..preferred.getCount()) |i| {
        var str_buf: [255:0]u8 = undefined;
        const str = preferred.getValueAtIndex(macos.foundation.String, i);
        const c_str = str.cstring(&str_buf, .utf8) orelse {
            // I don't think this can happen but if it does then I want
            // to know about it if a user has translation issues.
            log.warn("failed to convert a preferred language to UTF-8", .{});
            continue;
        };

        // Append our separator if we have any previous languages
        if (fbs.pos > 0) {
            _ = writer.writeByte(':') catch
                return error.NoSpaceLeft;
        }

        // Apple languages are in BCP-47 format, and we need to
        // canonicalize them to the POSIX format.
        const canon = try i18n.canonicalizeLocale(
            fbs.buffer[fbs.pos..],
            c_str,
        );
        fbs.seekBy(@intCast(canon.len)) catch unreachable;

        // The canonicalized locale never contains the encoding and
        // all of our translations require UTF-8 so we add that.
        _ = writer.writeAll(".UTF-8") catch return error.NoSpaceLeft;
    }

    // If we had no preferred languages then we return nothing.
    if (fbs.pos == 0) return null;

    // Null terminate it
    _ = writer.writeByte(0) catch return error.NoSpaceLeft;

    // Get our slice, this won't be null terminated so we have to
    // reslice it with the null terminator.
    const slice = fbs.getWritten();
    return slice[0 .. slice.len - 1 :0];
}

const LC_ALL: c_int = 6; // from locale.h
const LC_ALL_MASK: c_int = 0x7fffffff; // from locale.h
const locale_t = ?*anyopaque;
extern "c" fn setlocale(category: c_int, locale: ?[*]const u8) ?[*:0]u8;
extern "c" fn newlocale(category: c_int, locale: ?[*]const u8, base: locale_t) locale_t;
extern "c" fn freelocale(v: locale_t) void;
