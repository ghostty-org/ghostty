//! Implements the `org.gnome.Shell.SearchProvider2` D-Bus interface so that
//! open terminals show up in the GNOME Shell overview search.
//!
//! See: https://developer.gnome.org/documentation/tutorials/search-provider.html
//!
//! Results are the currently open surfaces. Each surface's title and
//! working directory are joined into a single haystack and fuzzy matched
//! against the search terms with `zf`, the same library the theme picker
//! uses, so results are ranked by match quality and a term can name
//! either field. Both sides are case folded first, so matching ignores
//! case across all of Unicode, but they aren't normalized: a title with a
//! precomposed "é" doesn't match a term typed as "e" plus a combining
//! accent, or the other way around. See `appendFolded`.
//!
//! Activating a result presents that surface directly with
//! `Surface.present` rather than through the `present-surface` action, so
//! that it can carry the timestamp GNOME Shell gives us; see
//! `presentSurface`.
//!
//! The registration file we install sets `AutoStart=false`, so GNOME Shell
//! will only ever talk to us if Ghostty is already running. That's the
//! behavior we want: there are no terminals to find if we're not running,
//! and typing in the overview shouldn't launch a terminal in the background.
//!
//! The registration file is generated at build time, so the bus name and
//! object path in it are those of the default application ID. A user who
//! sets `class` to something else runs under a different bus name, and
//! GNOME Shell, still asking for the default one, finds nobody there and
//! shows no results. The `.desktop`, D-Bus service and systemd files have
//! the same limitation, and the `class` documentation says so.
//!
//! ## Where our results appear
//!
//! The order of the providers' sections in the overview is the user's to
//! choose, not ours: nothing in the registration file or the D-Bus
//! interface lets a provider ask to be placed higher. GNOME Shell lists
//! the providers named in the `sort-order` key of the
//! `org.gnome.desktop.search-providers` schema first, in that order, and
//! every other provider after them, alphabetically by application name.
//! Ghostty isn't in the default list, so out of the box our results come
//! after Files, Characters and the other GNOME applications.
//!
//! A user who wants terminals nearer the top can drag Ghostty up the list
//! on the Search page of GNOME Settings, which is also where the provider
//! can be switched off. That page writes the `sort-order` key, so the same
//! change can be made with `gsettings`. The entries are desktop file IDs:
//! `com.mitchellh.ghostty.desktop` for a release build and
//! `com.mitchellh.ghostty-debug.desktop` for a debug one.
//!
//! ```
//! gsettings get org.gnome.desktop.search-providers sort-order
//! gsettings set org.gnome.desktop.search-providers sort-order \
//!   "['com.mitchellh.ghostty.desktop', 'org.gnome.Nautilus.desktop']"
//! ```
//!
//! `set` replaces the whole list, so start from what `get` printed.
//!
//! ## Focus stealing prevention
//!
//! `ActivateResult` and `LaunchSearch` are handed the timestamp of the
//! interaction that picked the result, and we pass it down to
//! `gtk_window_present_with_time` so that the window manager can tell that
//! the focus change was asked for by the user. Without it the request
//! looks unsolicited and gets refused.
//!
//! On X11 that is the whole story. On Wayland GTK ignores the timestamp
//! and instead asks the compositor for an xdg-activation token, proving
//! that the request was wanted with the serial of the last input event we
//! received. We have no recent one: the interaction that ran the search
//! went to GNOME Shell, not to us. Mutter therefore refuses the token and
//! only flags the window as demanding attention, which GNOME Shell shows
//! as a "Ghostty is ready" notification that the user has to click.
//!
//! `SearchProvider2` has no way to pass an activation token, so on Wayland
//! the window protocol layer makes the request another way; see
//! `winproto.wayland.Window.present`. That only works on GNOME, but GNOME
//! is the only place this interface exists.
//!
//! That other way gets the focus whatever the timestamp says, so anyone
//! able to hand us a timestamp could steal the focus with it, and anything
//! on the session bus can call `ActivateResult`. We therefore only pass on
//! the timestamp of a request that came from the current owner of
//! `org.gnome.Shell`. Anyone else's request still presents the surface,
//! but without a timestamp, so it is subject to focus stealing prevention
//! like any other.
//!
//! ## Testing
//!
//! The interface can be exercised with `gdbus` without involving GNOME
//! Shell at all, which is much faster than restarting the shell. On a
//! release build the bus name is `com.mitchellh.ghostty` and the object
//! path is `/com/mitchellh/ghostty/SearchProvider`; on a debug build they
//! are `com.mitchellh.ghostty-debug` and
//! `/com/mitchellh/ghostty_debug/SearchProvider` (GApplication replaces
//! characters that aren't valid in an object path with `_`).
//!
//! Check that we're exported at all:
//!
//! ```
//! gdbus introspect --session \
//!   --dest com.mitchellh.ghostty \
//!   --object-path /com/mitchellh/ghostty/SearchProvider
//! ```
//!
//! Search for open terminals. This returns an array of surface IDs:
//!
//! ```
//! gdbus call --session \
//!   --dest com.mitchellh.ghostty \
//!   --object-path /com/mitchellh/ghostty/SearchProvider \
//!   --method org.gnome.Shell.SearchProvider2.GetInitialResultSet \
//!   '["vim"]'
//! ```
//!
//! Get the metadata that the shell would display for a result. Substitute
//! an ID from the previous call:
//!
//! ```
//! gdbus call --session \
//!   --dest com.mitchellh.ghostty \
//!   --object-path /com/mitchellh/ghostty/SearchProvider \
//!   --method org.gnome.Shell.SearchProvider2.GetResultMetas \
//!   '["1"]'
//! ```
//!
//! Activate a result, which presents that surface. The final argument is
//! the timestamp of the interaction that picked the result, but since a
//! call from `gdbus` doesn't come from GNOME Shell its timestamp is
//! ignored, so this behaves like any other unsolicited request: it
//! switches to the right tab, but the window manager may only flag the
//! window as demanding attention rather than focusing it. Picking the
//! result in the real overview is the only way to see the focus change:
//!
//! ```
//! gdbus call --session \
//!   --dest com.mitchellh.ghostty \
//!   --object-path /com/mitchellh/ghostty/SearchProvider \
//!   --method org.gnome.Shell.SearchProvider2.ActivateResult \
//!   '1' '["vim"]' 1
//! ```
//!
//! To test the real thing end to end, copy the generated
//! `share/gnome-shell/search-providers/*.ini` into a
//! `gnome-shell/search-providers/` directory under one of GNOME Shell's
//! `XDG_DATA_DIRS` and restart GNOME Shell (`Alt+F2` then `r` on X11, or
//! log out and back in on Wayland). The shell only looks in the system
//! data directories, so `~/.local/share` doesn't work.
const SearchProvider = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const gio = @import("gio");
const glib = @import("glib");
const uucode = @import("uucode");
const zf = @import("zf");

const Application = @import("class/application.zig").Application;

const log = std.log.scoped(.gtk_search_provider);

/// The interface we implement.
const interface_name = "org.gnome.Shell.SearchProvider2";

/// The object path we export at, relative to the object path that
/// GApplication uses for its own D-Bus API.
const object_path_suffix = "/SearchProvider";

/// The most results we'll ever return for a single search. GNOME Shell
/// truncates the list for display anyway, this just bounds the work we do
/// for a user with a lot of terminals open.
const max_results = 20;

const interface_xml =
    \\<node>
    \\  <interface name="org.gnome.Shell.SearchProvider2">
    \\    <method name="GetInitialResultSet">
    \\      <arg type="as" name="terms" direction="in"/>
    \\      <arg type="as" name="results" direction="out"/>
    \\    </method>
    \\    <method name="GetSubsearchResultSet">
    \\      <arg type="as" name="previous_results" direction="in"/>
    \\      <arg type="as" name="terms" direction="in"/>
    \\      <arg type="as" name="results" direction="out"/>
    \\    </method>
    \\    <method name="GetResultMetas">
    \\      <arg type="as" name="identifiers" direction="in"/>
    \\      <arg type="aa{sv}" name="metas" direction="out"/>
    \\    </method>
    \\    <method name="ActivateResult">
    \\      <arg type="s" name="identifier" direction="in"/>
    \\      <arg type="as" name="terms" direction="in"/>
    \\      <arg type="u" name="timestamp" direction="in"/>
    \\    </method>
    \\    <method name="LaunchSearch">
    \\      <arg type="as" name="terms" direction="in"/>
    \\      <arg type="u" name="timestamp" direction="in"/>
    \\    </method>
    \\  </interface>
    \\</node>
;

const vtable: gio.DBusInterfaceVTable = .{
    .f_method_call = &methodCall,
    .f_get_property = null,
    .f_set_property = null,

    // Reserved by GDBus for future expansion, it is never read.
    .f_padding = undefined,
};

/// The parsed interface definition, non-null while we're registered.
node_info: ?*gio.DBusNodeInfo = null,

/// The registration ID returned by `registerObject`. Zero is never a valid
/// registration ID so we use it to mean "not registered".
registration_id: c_uint = 0,

/// The watch on GNOME Shell's bus name returned by
/// `busWatchNameOnConnection`, or zero if we aren't watching it.
shell_watch_id: c_uint = 0,

/// The unique bus name that currently owns GNOME Shell's well-known name,
/// or null if nobody does. Allocated by GLib and freed with `glib.free`.
/// See `activationTimestamp` for why we need it.
shell_owner: ?[*:0]u8 = null,

pub const Error = error{
    InvalidInterface,
    RegistrationFailed,
} || Allocator.Error;

/// Export the search provider on the given connection. `base_path` is the
/// object path that GApplication exports its own API on, we hang off of it.
pub fn register(
    self: *SearchProvider,
    alloc: Allocator,
    connection: *gio.DBusConnection,
    base_path: [*:0]const u8,
) Error!void {
    assert(self.registration_id == 0);

    var err_: ?*glib.Error = null;
    const node_info = gio.DBusNodeInfo.newForXml(interface_xml, &err_) orelse {
        defer if (err_) |err| err.free();
        log.warn(
            "unable to parse interface definition err={s}",
            .{errorMessage(err_)},
        );
        return error.InvalidInterface;
    };
    errdefer node_info.unref();

    const interface_info = node_info.lookupInterface(interface_name) orelse
        return error.InvalidInterface;

    // The object path is copied by GDBus so we only need it for the call.
    const path = try std.fmt.allocPrintSentinel(
        alloc,
        "{s}{s}",
        .{ std.mem.span(base_path), object_path_suffix },
        0,
    );
    defer alloc.free(path);

    // We outlive the registration, so the bindings' required destroy
    // notify has nothing to do.
    const registration_id = connection.registerObject(
        path.ptr,
        interface_info,
        &vtable,
        self,
        &noopDestroy,
        &err_,
    );
    if (registration_id == 0) {
        defer if (err_) |err| err.free();
        log.warn(
            "unable to export search provider err={s}",
            .{errorMessage(err_)},
        );
        return error.RegistrationFailed;
    }

    self.node_info = node_info;
    self.registration_id = registration_id;

    // Until the first callback arrives we don't know who GNOME Shell is,
    // so activation requests in the meantime are treated as untrusted.
    self.shell_watch_id = gio.busWatchNameOnConnection(
        connection,
        shell_bus_name,
        .{},
        &shellAppeared,
        &shellVanished,
        self,
        null,
    );

    log.debug("search provider exported path={s}", .{path});
}

/// Unexport the search provider. Safe to call if we were never registered.
pub fn unregister(
    self: *SearchProvider,
    connection: *gio.DBusConnection,
) void {
    if (self.registration_id != 0) {
        _ = connection.unregisterObject(self.registration_id);
        self.registration_id = 0;
    }

    // GLib promises no more callbacks once this returns, so it is safe to
    // free the owner right after.
    if (self.shell_watch_id != 0) {
        gio.busUnwatchName(self.shell_watch_id);
        self.shell_watch_id = 0;
    }
    self.setShellOwner(null);

    if (self.node_info) |node_info| {
        node_info.unref();
        self.node_info = null;
    }
}

fn noopDestroy(_: ?*anyopaque) callconv(.c) void {}

/// GNOME Shell's well-known bus name.
const shell_bus_name = "org.gnome.Shell";

fn shellAppeared(
    _: *gio.DBusConnection,
    _: [*:0]const u8,
    owner: [*:0]const u8,
    ud: ?*anyopaque,
) callconv(.c) void {
    const self: *SearchProvider = @ptrCast(@alignCast(ud orelse return));
    self.setShellOwner(owner);
}

fn shellVanished(
    _: *gio.DBusConnection,
    _: [*:0]const u8,
    ud: ?*anyopaque,
) callconv(.c) void {
    const self: *SearchProvider = @ptrCast(@alignCast(ud orelse return));
    self.setShellOwner(null);
}

fn setShellOwner(self: *SearchProvider, owner: ?[*:0]const u8) void {
    if (self.shell_owner) |v| glib.free(v);
    self.shell_owner = if (owner) |v| glib.strdup(v) else null;
}

/// The timestamp to present a surface with for an activation request from
/// `sender`, given the timestamp the request carried.
///
/// On Wayland a non-zero timestamp makes us raise the window through
/// `winproto.wayland.Window.present`, which Mutter grants regardless of
/// what the timestamp says, so a timestamp is as good as permission to
/// steal the focus. Only GNOME Shell actually saw the interaction that
/// picked a result, so only its word counts. Anyone else on the session
/// bus gets a zero timestamp: the surface is still presented, but through
/// `gtk_window_present`, where focus stealing prevention applies as it
/// does to any other request.
fn activationTimestamp(
    self: *const SearchProvider,
    sender: ?[*:0]const u8,
    timestamp: *glib.Variant,
) c_uint {
    const value: c_uint = @intCast(timestamp.getUint32());
    const owner = self.shell_owner orelse return 0;
    const from = sender orelse return 0;
    if (std.mem.orderZ(u8, owner, from) != .eq) {
        log.info(
            "activation request from {s}, which isn't GNOME Shell; not passing on its timestamp",
            .{from},
        );
        return 0;
    }
    return value;
}

fn errorMessage(err_: ?*glib.Error) [:0]const u8 {
    const err = err_ orelse return "(unknown)";
    const message = err.f_message orelse return "(unknown)";
    return std.mem.sliceTo(message, 0);
}

//---------------------------------------------------------------
// D-Bus method handling
//
// These all run on the main thread: the connection GApplication hands us
// is bound to the main thread's GMainContext, so it is safe to reach into
// the application state directly.

fn methodCall(
    _: *gio.DBusConnection,
    sender: ?[*:0]const u8,
    _: [*:0]const u8,
    _: ?[*:0]const u8,
    method_name: [*:0]const u8,
    parameters: *glib.Variant,
    invocation: *gio.DBusMethodInvocation,
    ud: ?*anyopaque,
) callconv(.c) void {
    const self: *SearchProvider = @ptrCast(@alignCast(ud.?));
    const method = std.mem.span(method_name);

    if (std.mem.eql(u8, method, "GetInitialResultSet")) {
        const terms = parameters.getChildValue(0);
        defer terms.unref();
        returnResultSet(invocation, terms);
        return;
    }

    if (std.mem.eql(u8, method, "GetSubsearchResultSet")) {
        // We don't use the previous result set: re-running the search is
        // just as cheap and can't go stale.
        const terms = parameters.getChildValue(1);
        defer terms.unref();
        returnResultSet(invocation, terms);
        return;
    }

    if (std.mem.eql(u8, method, "GetResultMetas")) {
        const identifiers = parameters.getChildValue(0);
        defer identifiers.unref();
        returnResultMetas(invocation, identifiers);
        return;
    }

    if (std.mem.eql(u8, method, "ActivateResult")) {
        const identifier = parameters.getChildValue(0);
        defer identifier.unref();
        const timestamp = parameters.getChildValue(2);
        defer timestamp.unref();

        if (parseId(identifier)) |id| presentSurface(
            id,
            self.activationTimestamp(sender, timestamp),
        );
        invocation.returnValue(null);
        return;
    }

    if (std.mem.eql(u8, method, "LaunchSearch")) {
        // There's no "show all results" UI in Ghostty, so the best we can
        // do is focus the first thing we would have matched.
        const terms = parameters.getChildValue(0);
        defer terms.unref();
        const timestamp = parameters.getChildValue(1);
        defer timestamp.unref();

        var results: [max_results]u64 = undefined;
        if (search(terms, &results) > 0) presentSurface(
            results[0],
            self.activationTimestamp(sender, timestamp),
        );
        invocation.returnValue(null);
        return;
    }

    // GDBus rejects methods that aren't in our interface definition before
    // they get here, so this is purely defensive.
    log.warn("unknown method called method={s}", .{method});
    invocation.returnErrorLiteral(
        gio.DBusError.quark(),
        @backingInt(gio.DBusError.unknown_method),
        "unknown method",
    );
}

/// Find the surfaces matching all of the given terms, writing their IDs to
/// `results` best match first and returning how many were written.
fn search(terms: *glib.Variant, results: *[max_results]u64) usize {
    const app = Application.default();
    const alloc = app.allocator();

    var parsed = Terms.init(alloc, terms) catch |err| {
        // Out of memory. Returning no results is a much better outcome than
        // failing the D-Bus call, which the shell would log as an error.
        log.warn("unable to read search terms err={}", .{err});
        return 0;
    };
    defer parsed.deinit(alloc);
    if (parsed.values.len == 0) return 0;

    // Reused across surfaces so we do at most one allocation per search
    // rather than one per surface.
    var haystack: std.ArrayList(u8) = .empty;
    defer haystack.deinit(alloc);

    var matches: Matches = .{};
    for (app.core().surfaces.items) |rt_surface| {
        const surface = rt_surface.gobj();
        const core_surface = surface.core() orelse continue;

        buildHaystack(
            alloc,
            &haystack,
            surface.getEffectiveTitle() orelse "",
            surface.getPwd(),
        ) catch |err| {
            log.warn("unable to build search haystack err={}", .{err});
            continue;
        };

        const rank = zf.rank(
            haystack.items,
            parsed.values,
            rank_options,
        ) orelse continue;

        matches.insert(.{ .id = core_surface.id, .rank = rank });
    }

    for (matches.items[0..matches.len], results[0..matches.len]) |match, *id| {
        id.* = match.id;
    }

    return matches.len;
}

/// How we ask zf to rank a haystack against the terms.
const rank_options: zf.RankOptions = .{
    // The haystack and the terms are both already case folded (see
    // `appendFolded`), which covers case across all of Unicode, though
    // not normalization. zf's own case insensitivity only lowercases
    // ASCII, so it would add nothing.
    .case_sensitive = true,

    // Our haystack is a title glued to a path, not a path, so the
    // filepath heuristics (basename boosting in particular) would just
    // make the ranking harder to predict.
    .plain = true,
};

/// The string we fuzzy match against for a single surface: its title and
/// its working directory, so that a search can name either one (or both),
/// case folded so that it can be compared with the folded terms.
fn buildHaystack(
    alloc: Allocator,
    buf: *std.ArrayList(u8),
    title: []const u8,
    pwd: ?[]const u8,
) Allocator.Error!void {
    buf.clearRetainingCapacity();
    try appendFolded(alloc, buf, title);
    if (pwd) |v| {
        if (title.len > 0) try buf.append(alloc, ' ');
        try appendFolded(alloc, buf, v);
    }
}

/// Append `text` to `buf` with Unicode full case folding applied, so that
/// "Übersicht" and "übersicht" compare equal, as do "Straße" and
/// "STRASSE". Text that isn't valid UTF-8 is appended unchanged.
///
/// This doesn't normalize: a precomposed "é" and an "e" followed by a
/// combining accent still differ. In practice titles, paths and typed
/// terms almost always arrive precomposed (NFC), so this rarely matters.
///
/// If it ever does, matching only needs both sides in the same form, so
/// canonical decomposition (NFD) is enough and NFC isn't needed. Unicode's
/// definition of a caseless match (D145) is NFD(casefold(NFD(x))). NFD
/// needs uucode's `canonical_combining_class`, `decomposition_type` and
/// `decomposition_mapping` fields, which our build doesn't enable today,
/// plus the algorithmic decomposition of Hangul syllables. uucode has no
/// normalization of its own, so the algorithm would have to be written on
/// top of that data.
fn appendFolded(
    alloc: Allocator,
    buf: *std.ArrayList(u8),
    text: []const u8,
) Allocator.Error!void {
    const view = std.unicode.Utf8View.init(text) catch
        return buf.appendSlice(alloc, text);

    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        var single: [1]u21 = undefined;
        for (uucode.get(.case_folding_full, cp).with(&single, cp)) |folded| {
            var encoded: [4]u8 = undefined;
            // Folding a valid codepoint never yields a surrogate half or
            // anything out of range.
            const len = std.unicode.utf8Encode(folded, &encoded) catch unreachable;
            try buf.appendSlice(alloc, encoded[0..len]);
        }
    }
}

/// `appendFolded` into a newly allocated slice owned by the caller.
fn foldAlloc(alloc: Allocator, text: []const u8) Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try appendFolded(alloc, &buf, text);
    return buf.toOwnedSlice(alloc);
}

/// Handle `GetInitialResultSet`/`GetSubsearchResultSet`.
fn returnResultSet(
    invocation: *gio.DBusMethodInvocation,
    terms: *glib.Variant,
) void {
    var results: [max_results]u64 = undefined;
    const count = search(terms, &results);

    const as = glib.VariantType.new("as");
    defer as.free();

    const tuple = glib.VariantType.new("(as)");
    defer tuple.free();

    var builder: glib.VariantBuilder = undefined;
    builder.init(tuple);

    {
        var array: glib.VariantBuilder = undefined;
        array.init(as);

        for (results[0..count]) |id| {
            var buf: [17]u8 = undefined;
            const str = std.fmt.bufPrintSentinel(&buf, "{x:0>16}", .{id}, 0) catch continue;
            array.addValue(glib.Variant.newString(str.ptr));
        }

        builder.addValue(array.end());
    }

    invocation.returnValue(builder.end());
}

/// Handle `GetResultMetas` by describing each surface that still exists.
fn returnResultMetas(
    invocation: *gio.DBusMethodInvocation,
    identifiers: *glib.Variant,
) void {
    const metas_type = glib.VariantType.new("aa{sv}");
    defer metas_type.free();

    const dict_type = glib.VariantType.new("a{sv}");
    defer dict_type.free();

    const tuple = glib.VariantType.new("(aa{sv})");
    defer tuple.free();

    var builder: glib.VariantBuilder = undefined;
    builder.init(tuple);

    {
        var metas: glib.VariantBuilder = undefined;
        metas.init(metas_type);

        const app = Application.default();
        const icon = app.as(gio.Application).getApplicationId();

        for (0..identifiers.nChildren()) |i| {
            const identifier = identifiers.getChildValue(i);
            defer identifier.unref();

            // A surface can close between the search and the metadata
            // request. Silently drop results that are gone.
            const id = parseId(identifier) orelse continue;
            const core_surface = app.core().findSurfaceByID(id) orelse continue;
            const surface = core_surface.rt_surface.gobj();

            const title = surface.getEffectiveTitle() orelse "Ghostty";

            var meta: glib.VariantBuilder = undefined;
            meta.init(dict_type);

            addDictEntry(&meta, "id", glib.Variant.newString(
                identifier.getString(null),
            ));
            addDictEntry(&meta, "name", glib.Variant.newString(title.ptr));

            // Only show the working directory if it isn't already part of
            // the title, matching what the command palette does.
            if (surface.getPwd()) |pwd| {
                if (std.mem.find(u8, title, pwd) == null) {
                    addDictEntry(
                        &meta,
                        "description",
                        glib.Variant.newString(pwd.ptr),
                    );
                }
            }

            // Our application ID is also our icon name, and a bare icon
            // name is a valid serialized GIcon.
            if (icon) |v| addDictEntry(
                &meta,
                "gicon",
                glib.Variant.newString(v),
            );

            metas.addValue(meta.end());
        }

        builder.addValue(metas.end());
    }

    invocation.returnValue(builder.end());
}

fn addDictEntry(
    builder: *glib.VariantBuilder,
    key: [*:0]const u8,
    value: *glib.Variant,
) void {
    // Built directly rather than with `open`/`close`, which would need a
    // `GVariantType` for `{sv}` parsed and freed for every entry.
    builder.addValue(glib.Variant.newDictEntry(
        glib.Variant.newString(key),
        glib.Variant.newVariant(value),
    ));
}

/// Parse a result ID (a surface ID rendered as hex) back into a surface
/// ID. Returns null if it isn't one of ours.
fn parseId(identifier: *glib.Variant) ?u64 {
    const str = std.mem.span(identifier.getString(null));
    return std.fmt.parseInt(u64, str, 16) catch null;
}

/// Focus the surface with the given ID. Does nothing if the surface has
/// been closed since we handed out its ID.
///
/// `timestamp` is the one GNOME Shell gave us for the interaction that
/// picked this result, or zero if the request didn't come from GNOME
/// Shell (see `activationTimestamp`). We can't go through the
/// `present-surface` action that desktop notifications use because that
/// action has no way to carry it, and without it a window manager is
/// within its rights to refuse to change the focus. See `Surface.present`.
fn presentSurface(id: u64, timestamp: c_uint) void {
    const core_surface = Application.default().core().findSurfaceByID(id) orelse return;
    core_surface.rt_surface.gobj().present(timestamp);
}

//---------------------------------------------------------------
// Matching

/// The search terms for a single request, case folded to match the
/// haystack built by `buildHaystack`.
const Terms = struct {
    /// The individual terms, each owned by us.
    values: [][]const u8,

    fn init(alloc: Allocator, variant: *glib.Variant) Allocator.Error!Terms {
        // The array has to be freed but the strings in it belong to the
        // variant. We copy what we need, so it can go as soon as we're done.
        var len: usize = 0;
        const raw = variant.getStrv(&len);
        defer glib.free(@ptrCast(raw));

        // zf rejects every haystack for an empty needle, so a single empty
        // term would hide all of the results. Skip them.
        var nonempty: usize = 0;
        for (raw[0..len]) |term| {
            if (term.?[0] != 0) nonempty += 1;
        }

        const values = try alloc.alloc([]const u8, nonempty);
        var count: usize = 0;
        errdefer {
            for (values[0..count]) |v| alloc.free(v);
            alloc.free(values);
        }

        for (raw[0..len]) |term| {
            if (term.?[0] == 0) continue;
            values[count] = try foldAlloc(alloc, std.mem.span(term.?));
            count += 1;
        }

        return .{ .values = values };
    }

    fn deinit(self: *Terms, alloc: Allocator) void {
        for (self.values) |v| alloc.free(v);
        alloc.free(self.values);
        self.* = undefined;
    }
};

const Match = struct {
    id: u64,
    rank: f64,
};

/// The best `max_results` matches seen so far, kept sorted by rank. zf
/// ranks are a cost, so a lower rank is a better match.
const Matches = struct {
    items: [max_results]Match = undefined,
    len: usize = 0,

    fn insert(self: *Matches, match: Match) void {
        // Find where this match belongs. Ties keep the earlier surface,
        // which means creation order breaks ties.
        var i: usize = 0;
        while (i < self.len and self.items[i].rank <= match.rank) i += 1;

        // Worse than everything we're willing to keep.
        if (i >= self.items.len) return;

        // Shift the tail right, dropping the worst match if we're full.
        var j = @min(self.len, self.items.len - 1);
        while (j > i) : (j -= 1) self.items[j] = self.items[j - 1];

        self.items[i] = match;
        if (self.len < self.items.len) self.len += 1;
    }
};

test "Matches keeps the best matches in rank order" {
    const testing = std.testing;

    var matches: Matches = .{};
    matches.insert(.{ .id = 1, .rank = 3.0 });
    matches.insert(.{ .id = 2, .rank = 1.0 });
    matches.insert(.{ .id = 3, .rank = 2.0 });

    try testing.expectEqual(@as(usize, 3), matches.len);
    try testing.expectEqual(@as(u64, 2), matches.items[0].id);
    try testing.expectEqual(@as(u64, 3), matches.items[1].id);
    try testing.expectEqual(@as(u64, 1), matches.items[2].id);
}

test "Matches ties keep insertion order" {
    const testing = std.testing;

    var matches: Matches = .{};
    matches.insert(.{ .id = 1, .rank = 1.0 });
    matches.insert(.{ .id = 2, .rank = 1.0 });

    try testing.expectEqual(@as(u64, 1), matches.items[0].id);
    try testing.expectEqual(@as(u64, 2), matches.items[1].id);
}

test "Matches drops the worst once full" {
    const testing = std.testing;

    var matches: Matches = .{};
    for (0..max_results) |i| matches.insert(.{
        .id = i,
        .rank = @floatFromInt(max_results - i),
    });
    try testing.expectEqual(max_results, matches.len);

    // Better than everything: goes to the front and evicts the worst.
    matches.insert(.{ .id = 1000, .rank = 0.0 });
    try testing.expectEqual(max_results, matches.len);
    try testing.expectEqual(@as(u64, 1000), matches.items[0].id);

    // Worse than everything we kept: dropped entirely.
    matches.insert(.{ .id = 1001, .rank = 1000.0 });
    try testing.expectEqual(max_results, matches.len);
    for (matches.items) |match| try testing.expect(match.id != 1001);
}

test "buildHaystack" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try buildHaystack(alloc, &buf, "vim", "/home/user");
    try testing.expectEqualStrings("vim /home/user", buf.items);

    // Reusing the buffer must not leave the previous contents behind.
    try buildHaystack(alloc, &buf, "emacs", null);
    try testing.expectEqualStrings("emacs", buf.items);

    // An untitled surface shouldn't get a leading separator.
    try buildHaystack(alloc, &buf, "", "/home/user");
    try testing.expectEqualStrings("/home/user", buf.items);
}

test "ranking matches title and pwd" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buildHaystack(alloc, &buf, "vim src/Surface.zig", "/home/user/dev/ghostty");

    const opts = rank_options;

    // Terms can match either field, including one of each.
    try testing.expect(zf.rank(buf.items, &.{"vim"}, opts) != null);
    try testing.expect(zf.rank(buf.items, &.{"ghostty"}, opts) != null);
    try testing.expect(zf.rank(buf.items, &.{ "vim", "ghostty" }, opts) != null);

    // Every term has to match something.
    try testing.expect(zf.rank(buf.items, &.{ "vim", "emacs" }, opts) == null);

    // Fuzzy: a subsequence matches where a substring wouldn't.
    try testing.expect(zf.rank(buf.items, &.{"vmsrf"}, opts) != null);

    // A closer match ranks better (lower) than a scattered one.
    const tight = zf.rank(buf.items, &.{"surface"}, opts).?;
    const loose = zf.rank(buf.items, &.{"vmsrf"}, opts).?;
    try testing.expect(tight < loose);
}

test "appendFolded" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const cases = [_]struct { []const u8, []const u8 }{
        .{ "Ghostty", "ghostty" },
        // Beyond ASCII, which zf alone wouldn't fold.
        .{ "Übersicht", "übersicht" },
        .{ "ΣΊΣΥΦΟΣ", "σίσυφοσ" },
        // Full folding can produce more than one codepoint.
        .{ "Straße", "strasse" },
        // Not valid UTF-8: passed through untouched.
        .{ "A\xffB", "A\xffB" },
        .{ "", "" },
    };

    for (cases) |case| {
        const folded = try foldAlloc(alloc, case[0]);
        defer alloc.free(folded);
        try testing.expectEqualStrings(case[1], folded);
    }
}

test "ranking ignores case beyond ASCII" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buildHaystack(alloc, &buf, "Übersicht", "/home/user/STRASSE");

    for ([_][]const u8{ "übersicht", "ÜBERSICHT", "straße", "Strasse" }) |term| {
        const folded = try foldAlloc(alloc, term);
        defer alloc.free(folded);
        try testing.expect(zf.rank(buf.items, &.{folded}, rank_options) != null);
    }
}

test "ranking does not normalize" {
    // Pins a known limitation (see `appendFolded`) so that it can't change
    // unnoticed: if normalization is ever added, this should flip to
    // expect a match and say so.
    const testing = std.testing;
    const alloc = testing.allocator;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    // "été" with each "é" a precomposed U+00E9, then as "e" and U+0301.
    const precomposed = "\u{e9}t\u{e9}";
    const decomposed = "e\u{301}te\u{301}";

    try buildHaystack(alloc, &buf, precomposed, null);
    try testing.expect(zf.rank(buf.items, &.{decomposed}, rank_options) == null);
    try testing.expect(zf.rank(buf.items, &.{precomposed}, rank_options) != null);
}
