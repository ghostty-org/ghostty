//! Implements the `org.gnome.Shell.SearchProvider2` D-Bus interface so that
//! open terminals show up in the GNOME Shell overview search.
//!
//! See: https://developer.gnome.org/documentation/tutorials/search-provider.html
//!
//! Results are the currently open surfaces. Each surface's title and
//! working directory are joined into a single haystack and fuzzy matched
//! against the search terms with `zf`, the same library the theme picker
//! uses, so results are ranked by match quality and a term can name
//! either field. Activating a result focuses that surface by reusing the
//! `present-surface` application action.
//!
//! The registration file we install sets `AutoStart=false`, so GNOME Shell
//! will only ever talk to us if Ghostty is already running. That's the
//! behavior we want: there are no terminals to find if we're not running,
//! and typing in the overview shouldn't launch a terminal in the background.
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
//! Activate a result, which should focus that surface. The final argument
//! is the timestamp of the interaction that picked the result. Any
//! non-zero value will do on Wayland, where it only marks the request as
//! coming from another process; on X11 the window manager compares it
//! with the time of the last user interaction and refuses anything
//! older, so a hand-rolled call like this one is refused there:
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

    // We have no user data, but the bindings require a non-null destroy
    // notify so we hand it a no-op.
    const registration_id = connection.registerObject(
        path.ptr,
        interface_info,
        &vtable,
        null,
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

    if (self.node_info) |node_info| {
        node_info.unref();
        self.node_info = null;
    }
}

fn noopDestroy(_: ?*anyopaque) callconv(.c) void {}

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
    _: ?[*:0]const u8,
    _: [*:0]const u8,
    _: ?[*:0]const u8,
    method_name: [*:0]const u8,
    parameters: *glib.Variant,
    invocation: *gio.DBusMethodInvocation,
    _: ?*anyopaque,
) callconv(.c) void {
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

        if (parseId(identifier)) |id| presentSurface(id, @intCast(timestamp.getUint32()));
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
            @intCast(timestamp.getUint32()),
        );
        invocation.returnValue(null);
        return;
    }

    // GDBus rejects methods that aren't in our interface definition before
    // they get here, so this is purely defensive.
    log.warn("unknown method called method={s}", .{method});
    invocation.returnErrorLiteral(
        gio.DBusError.quark(),
        @intFromEnum(gio.DBusError.unknown_method),
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

        const rank = zf.rank(haystack.items, parsed.values, .{
            .case_sensitive = false,

            // Our haystack is a title glued to a path, not a path, so the
            // filepath heuristics (basename boosting in particular) would
            // just make the ranking harder to predict.
            .plain = true,
        }) orelse continue;

        matches.insert(.{ .id = core_surface.id, .rank = rank });
    }

    for (matches.items[0..matches.len], results[0..matches.len]) |match, *id| {
        id.* = match.id;
    }

    return matches.len;
}

/// The string we fuzzy match against for a single surface: its title and
/// its working directory, so that a search can name either one (or both).
fn buildHaystack(
    alloc: Allocator,
    buf: *std.ArrayList(u8),
    title: []const u8,
    pwd: ?[]const u8,
) Allocator.Error!void {
    buf.clearRetainingCapacity();
    try buf.appendSlice(alloc, title);
    if (pwd) |v| {
        if (title.len > 0) try buf.append(alloc, ' ');
        try buf.appendSlice(alloc, v);
    }
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
            const str = std.fmt.bufPrintZ(&buf, "{x:0>16}", .{id}) catch continue;
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
                if (std.mem.indexOf(u8, title, pwd) == null) {
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
    const entry_type = glib.VariantType.new("{sv}");
    defer entry_type.free();

    builder.open(entry_type);
    builder.addValue(glib.Variant.newString(key));
    builder.addValue(glib.Variant.newVariant(value));
    builder.close();
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
/// picked this result. We can't go through the `present-surface` action
/// that desktop notifications use because that action has no way to carry
/// it, and without it a window manager is within its rights to refuse to
/// change the focus. See `Surface.present`.
fn presentSurface(id: u64, timestamp: c_uint) void {
    const app = Application.default();
    for (app.core().surfaces.items) |rt_surface| {
        const surface = rt_surface.gobj();
        const core_surface = surface.core() orelse continue;
        if (core_surface.id != id) continue;
        surface.present(timestamp);
        return;
    }
}

//---------------------------------------------------------------
// Matching

/// The search terms for a single request.
const Terms = struct {
    /// The individual terms, borrowed from `raw`.
    values: [][]const u8,

    /// The array returned by `getStrv`, which must be freed. The strings
    /// it points to are owned by the variant, not by us.
    raw: [*:null]?[*:0]const u8,

    fn init(alloc: Allocator, variant: *glib.Variant) Allocator.Error!Terms {
        var len: usize = 0;
        const raw = variant.getStrv(&len);
        errdefer glib.free(@ptrCast(raw));

        const values = try alloc.alloc([]const u8, len);
        for (values, 0..) |*value, i| value.* = std.mem.span(raw[i].?);

        return .{ .values = values, .raw = raw };
    }

    fn deinit(self: *Terms, alloc: Allocator) void {
        alloc.free(self.values);
        glib.free(@ptrCast(self.raw));
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

    const opts: zf.RankOptions = .{ .case_sensitive = false, .plain = true };

    // Terms can match either field, including one of each.
    try testing.expect(zf.rank(buf.items, &.{"vim"}, opts) != null);
    try testing.expect(zf.rank(buf.items, &.{"GHOSTTY"}, opts) != null);
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
