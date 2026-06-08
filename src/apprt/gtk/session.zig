//! Session save/restore for the GTK apprt.
//!
//! This persists the set of open windows, their tabs, and each tab's working
//! directory to disk when Ghostty exits, and restores them on the next launch.
//! This brings a subset of the macOS-only `window-save-state` behavior to
//! Linux. Splits and scrollback are intentionally not handled here yet (see
//! the plan / future work); the JSON schema is versioned and tolerant of
//! unknown fields so those can be added later without breaking older files.

const std = @import("std");
const Allocator = std.mem.Allocator;

const internal_os = @import("../../os/main.zig");
const configpkg = @import("../../config.zig");
const CoreConfig = configpkg.Config;

const log = std.log.scoped(.gtk_session);

/// The subdirectory (under the XDG state directory) and filename we use.
const subdir = "ghostty";
const filename = "session.json";
const filename_tmp = "session.json.tmp";

/// Maximum size of the session file we're willing to read. Session files are
/// tiny (a few KB at most) so this is a generous sanity bound.
const max_read_size = 1024 * 1024;

/// The current schema version. Bump this when the structure changes in a way
/// that older Ghostty versions cannot understand. Readers reject mismatched
/// versions (treating them as "no session") and ignore unknown fields.
pub const version: u32 = 1;

pub const Session = struct {
    version: u32 = version,
    windows: []const Window = &.{},

    pub const Window = struct {
        /// Stable random identifier for this window (see `newId`). 0 means
        /// "unset" (e.g. a session file written before ids existed).
        id: u64 = 0,

        /// Window geometry. Restored via setDefaultSize when present.
        width: ?i32 = null,
        height: ?i32 = null,

        /// The index (within `tabs`) of the tab that was selected/focused.
        focused_tab: ?u32 = null,

        tabs: []const Tab = &.{},
    };

    pub const Tab = struct {
        /// Stable random identifier for this tab (see `newId`). This is the
        /// key for the tab's scrollback file (`<id>.vt`). 0 means "unset".
        id: u64 = 0,

        /// The working directory for this tab. If null, the tab is restored
        /// using the normal default working directory (e.g. when shell
        /// integration wasn't reporting a pwd).
        working_directory: ?[]const u8 = null,

        /// The tab title, if one was known.
        title: ?[]const u8 = null,
    };
};

/// Generate a new stable random id for a window or tab. Kept to 52 bits so it
/// round-trips exactly through JSON (and tools like jq/python that use f64),
/// and is never 0 (which is the "unset" sentinel). Collisions across the small
/// number of live windows/tabs are astronomically unlikely.
pub fn newId() u64 {
    const mask: u64 = (1 << 52) - 1;
    const id = std.crypto.random.int(u64) & mask;
    return if (id == 0) 1 else id;
}

/// Returns true if window state should be written to disk on exit.
///
/// On Linux there is no OS-level restoration mechanism, so `default` behaves
/// like `always` ("just works"). `never` disables saving entirely.
pub fn shouldSaveState(config: *const CoreConfig) bool {
    return switch (config.@"window-save-state") {
        .never => false,
        .default, .always => true,
    };
}

/// Returns true if a previously saved session should be restored on launch.
pub fn shouldRestoreState(config: *const CoreConfig) bool {
    return switch (config.@"window-save-state") {
        .never => false,
        .default, .always => true,
    };
}

/// Compute the absolute path to the session file. Caller owns the memory.
pub fn path(alloc: Allocator) ![]u8 {
    const dir = try internal_os.xdg.state(alloc, .{ .subdir = subdir });
    defer alloc.free(dir);
    return try std.fs.path.join(alloc, &.{ dir, filename });
}

/// Serialize a session to indented JSON. Caller owns the returned memory.
pub fn serialize(alloc: Allocator, session: Session) ![]u8 {
    var buffer: std.Io.Writer.Allocating = .init(alloc);
    errdefer buffer.deinit();
    try buffer.writer.print("{f}", .{std.json.fmt(
        session,
        .{ .whitespace = .indent_2 },
    )});
    return try buffer.toOwnedSlice();
}

/// Atomically write pre-serialized session bytes to the session file,
/// creating the state directory (and any missing parents) if needed. Errors
/// are returned to the caller, which is expected to log and swallow them.
pub fn writeBytes(alloc: Allocator, bytes: []const u8) !void {
    const dir = try internal_os.xdg.state(alloc, .{ .subdir = subdir });
    defer alloc.free(dir);

    // Create/open the state directory, creating any missing parent dirs.
    var d = try std.fs.cwd().makeOpenPath(dir, .{});
    defer d.close();

    // Write to a temp file then rename over the target so a crash mid-write
    // never leaves a corrupt session file.
    try d.writeFile(.{ .sub_path = filename_tmp, .data = bytes });
    try d.rename(filename_tmp, filename);

    log.info("session written to {s}/{s} ({d} bytes)", .{ dir, filename, bytes.len });
}

/// Serialize and atomically write a session to disk in one step.
pub fn save(alloc: Allocator, session: Session) !void {
    const bytes = try serialize(alloc, session);
    defer alloc.free(bytes);
    try writeBytes(alloc, bytes);
}

/// Load and parse the session file. Returns null if there is no session file,
/// it can't be read/parsed, or its version doesn't match the current schema.
/// The returned value must be freed with `.deinit()`.
pub fn load(alloc: Allocator) !?std.json.Parsed(Session) {
    const dir = try internal_os.xdg.state(alloc, .{ .subdir = subdir });
    defer alloc.free(dir);

    var d = std.fs.cwd().openDir(dir, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            log.info("no session directory at {s}", .{dir});
            return null;
        },
        else => return err,
    };
    defer d.close();

    const file = d.openFile(filename, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            log.info("no session file at {s}/{s}", .{ dir, filename });
            return null;
        },
        else => return err,
    };
    defer file.close();

    log.info("loading session from {s}/{s}", .{ dir, filename });

    const bytes = try file.readToEndAlloc(alloc, max_read_size);
    defer alloc.free(bytes);

    const parsed = std.json.parseFromSlice(
        Session,
        alloc,
        bytes,
        .{
            .ignore_unknown_fields = true,
            // Copy all strings into the parsed arena so the result is fully
            // self-contained and we can free `bytes` below without dangling.
            .allocate = .alloc_always,
        },
    ) catch |err| {
        log.warn("failed to parse session file, ignoring err={}", .{err});
        return null;
    };

    // Reject a session written by an incompatible schema version.
    if (parsed.value.version != version) {
        log.info(
            "ignoring session file with unsupported version={}",
            .{parsed.value.version},
        );
        parsed.deinit();
        return null;
    }

    return parsed;
}

/// Delete the session file if it exists. Used when saving is disabled
/// (`window-save-state = never`) so that a stale file is not restored.
pub fn delete(alloc: Allocator) void {
    const p = path(alloc) catch return;
    defer alloc.free(p);
    std.fs.cwd().deleteFile(p) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            log.warn("failed to delete session file err={}", .{err});
            return;
        },
    };
    log.info("deleted session file {s}", .{p});
}

// ---------------------------------------------------------------------------
// Scrollback persistence
//
// Each tab's scrollback is stored in its own file under a `scrollback`
// subdirectory, named `<id>.vt` (keyed by the tab's stable id), holding styled
// VT bytes. Keying by a stable id (rather than an enumeration index) means a
// tab always reads/writes the same file regardless of how windows/tabs are
// added or reordered, and lets the save path safely skip never-realized tabs.

const scrollback_subdir = "scrollback";

/// Open (creating if needed) the scrollback directory. Caller closes the Dir.
fn scrollbackDir(alloc: Allocator) !std.fs.Dir {
    const dir = try internal_os.xdg.state(alloc, .{ .subdir = subdir });
    defer alloc.free(dir);
    var base = try std.fs.cwd().makeOpenPath(dir, .{});
    defer base.close();
    return try base.makeOpenPath(scrollback_subdir, .{});
}

/// Write a tab's scrollback bytes to its id-keyed file.
pub fn writeScrollback(alloc: Allocator, id: u64, bytes: []const u8) !void {
    var dir = try scrollbackDir(alloc);
    defer dir.close();

    var name_buf: [32]u8 = undefined;
    var tmp_buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "{d}.vt", .{id});
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{d}.vt.tmp", .{id});

    try dir.writeFile(.{ .sub_path = tmp, .data = bytes });
    try dir.rename(tmp, name);
    log.info("scrollback id {d} written ({d} bytes)", .{ id, bytes.len });
}

/// Read a tab's scrollback bytes from its id-keyed file. Returns null if there
/// is no scrollback for that id. Caller owns the returned memory.
pub fn readScrollback(alloc: Allocator, id: u64) !?[]u8 {
    var dir = scrollbackDir(alloc) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close();

    var name_buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "{d}.vt", .{id});

    const file = dir.openFile(name, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    // Generous bound; scrollback is capped by the config size anyway.
    const bytes = try file.readToEndAlloc(alloc, 64 * 1024 * 1024);
    if (bytes.len == 0) {
        alloc.free(bytes);
        return null;
    }
    return bytes;
}

/// Delete a tab's scrollback file, if it exists (e.g. a realized tab whose
/// scrollback is now empty).
pub fn deleteScrollback(alloc: Allocator, id: u64) void {
    var dir = scrollbackDir(alloc) catch return;
    defer dir.close();
    var name_buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{d}.vt", .{id}) catch return;
    dir.deleteFile(name) catch {};
}

/// Delete any scrollback files whose id is not in `keep`. Used to clean up
/// files for tabs that have been closed (and legacy index-named files). We
/// collect names first and delete afterwards so we never mutate the directory
/// mid-iteration.
pub fn pruneScrollback(alloc: Allocator, keep: []const u64) void {
    var dir = scrollbackDir(alloc) catch return;
    defer dir.close();

    var to_delete: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (to_delete.items) |n| alloc.free(n);
        to_delete.deinit(alloc);
    }

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        const del = del: {
            // Remove stale temp files unconditionally.
            if (std.mem.endsWith(u8, name, ".vt.tmp")) break :del true;
            // Only "<id>.vt" files are candidates.
            if (!std.mem.endsWith(u8, name, ".vt")) break :del false;
            const id = std.fmt.parseInt(u64, name[0 .. name.len - 3], 10) catch
                break :del false;
            for (keep) |k| if (k == id) break :del false;
            break :del true;
        };
        if (del) {
            const dup = alloc.dupe(u8, name) catch continue;
            to_delete.append(alloc, dup) catch alloc.free(dup);
        }
    }

    for (to_delete.items) |n| dir.deleteFile(n) catch {};
}

test "shouldSaveState mapping" {
    const testing = std.testing;
    var c = try CoreConfig.default(testing.allocator);
    defer c.deinit();

    c.@"window-save-state" = .never;
    try testing.expect(!shouldSaveState(&c));
    try testing.expect(!shouldRestoreState(&c));

    c.@"window-save-state" = .default;
    try testing.expect(shouldSaveState(&c));
    try testing.expect(shouldRestoreState(&c));

    c.@"window-save-state" = .always;
    try testing.expect(shouldSaveState(&c));
    try testing.expect(shouldRestoreState(&c));
}
