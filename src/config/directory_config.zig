const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const cli = @import("../cli.zig");
const internal_os = @import("../os/main.zig");
const formatterpkg = @import("formatter.zig");

const log = std.log.scoped(.directory_config);

/// Settings that are allowed to be overridden by directory configs.
/// This is an explicit allowlist - only these visual/surface-scoped
/// settings will be merged from directory config files.
pub const allowed_directory_config_fields = [_][]const u8{
    // Fonts
    "font-family",
    "font-family-bold",
    "font-family-italic",
    "font-family-bold-italic",
    "font-size",
    "font-style",
    "font-style-bold",
    "font-style-italic",
    "font-style-bold-italic",
    "font-synthetic-style",
    "font-feature",
    "font-variation",
    "adjust-cell-width",
    "adjust-cell-height",
    "adjust-font-baseline",
    "adjust-underline-position",
    "adjust-underline-thickness",
    "adjust-strikethrough-position",
    "adjust-strikethrough-thickness",
    "adjust-overline-position",
    "adjust-overline-thickness",
    "adjust-cursor-thickness",
    "adjust-cursor-height",
    "adjust-box-thickness",
    // Colors
    "background",
    "foreground",
    "palette",
    "cursor-color",
    "cursor-text",
    "cursor-opacity",
    "selection-foreground",
    "selection-background",
    "selection-invert-fg-bg",
    "minimum-contrast",
    "bold-is-bright",
    // Visual effects
    "background-opacity",
    "background-blur",
    "custom-shader",
    "custom-shader-animation",
    "unfocused-split-opacity",
    "unfocused-split-fill",
    "split-divider-color",
    // Layout
    "window-padding-x",
    "window-padding-y",
    "window-padding-balance",
    "window-padding-color",
};

/// Check if a field name is allowed in directory configs.
pub fn isAllowedField(field_name: []const u8) bool {
    for (allowed_directory_config_fields) |allowed| {
        if (std.mem.eql(u8, field_name, allowed)) return true;
    }
    return false;
}

pub const ParseError = error{
    ValueRequired,
    InvalidFormat,
} || Allocator.Error;

/// A single directory-config mapping: pattern -> config file path.
/// Format: "pattern:config-path"
/// Example: "~/work/*:~/.config/ghostty/work.conf"
pub const DirectoryConfig = struct {
    /// The glob pattern to match against the current working directory.
    /// Supports:
    /// - Exact paths: "/home/user/project"
    /// - Single-level wildcard: "~/work/*" matches "~/work/foo" but not "~/work/foo/bar"
    /// - Recursive wildcard: "~/work/**" matches "~/work/foo/bar/baz"
    pattern: [:0]const u8,

    /// The path to the config file to load when the pattern matches.
    config_path: [:0]const u8,

    /// Priority for this pattern. Higher priority wins when multiple patterns match.
    /// Default is 0.
    priority: u16 = 0,

    /// Parse a directory-config value in the format "pattern:config-path".
    pub fn parse(
        arena_alloc: Allocator,
        input: ?[]const u8,
    ) ParseError!?DirectoryConfig {
        const value = input orelse return error.ValueRequired;
        if (value.len == 0) return null;

        // Find the separator between pattern and config path.
        // We need to handle the case where pattern or path contains ':'
        // (e.g., Windows paths or URLs). The convention is:
        // - On Unix: first ':' after any leading '~/' or '/' separates pattern from path
        // - For simplicity, we'll use the last ':' as the separator when there are multiple
        const sep_idx = findSeparator(value) orelse return error.InvalidFormat;

        const pattern = value[0..sep_idx];
        const config_path = value[sep_idx + 1 ..];

        if (pattern.len == 0 or config_path.len == 0) return error.InvalidFormat;

        return .{
            .pattern = try arena_alloc.dupeZ(u8, pattern),
            .config_path = try arena_alloc.dupeZ(u8, config_path),
            .priority = 0,
        };
    }

    /// Find the separator index between pattern and config path.
    /// Returns the index of the ':' that separates them.
    fn findSeparator(value: []const u8) ?usize {
        // Strategy: Find the last ':' that makes sense as a separator.
        // A ':' is a valid separator if what follows looks like a path.
        var last_valid: ?usize = null;

        for (value, 0..) |c, i| {
            if (c == ':') {
                // Check if what follows looks like a path
                if (i + 1 < value.len) {
                    const next = value[i + 1];
                    // Path-like starts: ~, /, ., or alphanumeric
                    if (next == '~' or next == '/' or next == '.' or
                        std.ascii.isAlphanumeric(next) or next == '?')
                    {
                        last_valid = i;
                    }
                }
            }
        }

        return last_valid;
    }

    /// Clone this DirectoryConfig.
    pub fn clone(self: DirectoryConfig, arena_alloc: Allocator) Allocator.Error!DirectoryConfig {
        return .{
            .pattern = try arena_alloc.dupeZ(u8, self.pattern),
            .config_path = try arena_alloc.dupeZ(u8, self.config_path),
            .priority = self.priority,
        };
    }

    /// Check if two DirectoryConfig are equal.
    pub fn equal(self: DirectoryConfig, other: DirectoryConfig) bool {
        return std.mem.eql(u8, self.pattern, other.pattern) and
            std.mem.eql(u8, self.config_path, other.config_path) and
            self.priority == other.priority;
    }

    /// Check if a directory path matches this pattern.
    pub fn matches(self: DirectoryConfig, pwd: []const u8) bool {
        return matchGlob(self.pattern, pwd);
    }

    /// Expand paths (both pattern and config_path) relative to the base directory.
    pub fn expand(
        self: *DirectoryConfig,
        arena_alloc: Allocator,
        base: []const u8,
        diags: *cli.DiagnosticList,
    ) !void {
        // Expand the config path (similar to Path.expand)
        self.config_path = try expandPath(arena_alloc, self.config_path, base, diags);

        // Expand the pattern's home directory prefix if present
        self.pattern = try expandPatternHome(arena_alloc, self.pattern, diags);
    }

    /// Format for config file output.
    pub fn formatEntry(self: *const DirectoryConfig, formatter: formatterpkg.EntryFormatter) !void {
        var buf: [std.fs.max_path_bytes * 2 + 2]u8 = undefined;
        const value = std.fmt.bufPrint(
            &buf,
            "{s}:{s}",
            .{ self.pattern, self.config_path },
        ) catch |err| switch (err) {
            error.NoSpaceLeft => return error.OutOfMemory,
        };
        try formatter.formatEntry([]const u8, value);
    }
};

/// Repeatable version of DirectoryConfig for multiple directory-config entries.
pub const RepeatableDirectoryConfig = struct {
    value: std.ArrayListUnmanaged(DirectoryConfig) = .{},

    pub fn parseCLI(self: *RepeatableDirectoryConfig, alloc: Allocator, input: ?[]const u8) ParseError!void {
        const item = try DirectoryConfig.parse(alloc, input) orelse {
            self.value.clearRetainingCapacity();
            return;
        };
        try self.value.append(alloc, item);
    }

    /// Deep copy.
    pub fn clone(self: *const RepeatableDirectoryConfig, alloc: Allocator) Allocator.Error!RepeatableDirectoryConfig {
        const value = try self.value.clone(alloc);
        for (value.items) |*item| {
            item.* = try item.clone(alloc);
        }
        return .{ .value = value };
    }

    /// Compare equality.
    pub fn equal(self: RepeatableDirectoryConfig, other: RepeatableDirectoryConfig) bool {
        if (self.value.items.len != other.value.items.len) return false;
        for (self.value.items, other.value.items) |a, b| {
            if (!a.equal(b)) return false;
        }
        return true;
    }

    /// Format for config output.
    pub fn formatEntry(self: RepeatableDirectoryConfig, formatter: formatterpkg.EntryFormatter) !void {
        if (self.value.items.len == 0) {
            try formatter.formatEntry(void, {});
            return;
        }
        for (self.value.items) |*item| {
            try item.formatEntry(formatter);
        }
    }

    /// Expand all paths.
    pub fn expand(
        self: *RepeatableDirectoryConfig,
        alloc: Allocator,
        base: []const u8,
        diags: *cli.DiagnosticList,
    ) !void {
        for (self.value.items) |*item| {
            try item.expand(alloc, base, diags);
        }
    }

    /// Find the best matching config for a given pwd.
    /// Returns the DirectoryConfig with the highest priority among matches,
    /// or the longest pattern match if priorities are equal.
    pub fn findMatch(self: *const RepeatableDirectoryConfig, pwd: []const u8) ?*const DirectoryConfig {
        var best: ?*const DirectoryConfig = null;
        var best_priority: u16 = 0;
        var best_specificity: usize = 0;

        for (self.value.items) |*item| {
            if (item.matches(pwd)) {
                const specificity = patternSpecificity(item.pattern);
                // Higher priority wins, then higher specificity (longer match)
                if (best == null or
                    item.priority > best_priority or
                    (item.priority == best_priority and specificity > best_specificity))
                {
                    best = item;
                    best_priority = item.priority;
                    best_specificity = specificity;
                }
            }
        }

        return best;
    }
};

/// Calculate pattern specificity (for tie-breaking).
/// More specific patterns have higher values.
fn patternSpecificity(pattern: []const u8) usize {
    // Count non-wildcard characters as a measure of specificity
    var count: usize = 0;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '*') {
            // Skip wildcards
            if (i + 1 < pattern.len and pattern[i + 1] == '*') {
                i += 1; // Skip second *
            }
        } else {
            count += 1;
        }
    }
    return count;
}

/// Maximum recursion depth for glob matching to prevent stack overflow.
const MAX_GLOB_DEPTH = 100;

/// Maximum total matching attempts to prevent exponential backtracking DoS.
/// With multiple ** wildcards, backtracking can be O(N^k) where k = number of **.
/// This counter limits the total work done regardless of pattern structure.
const MAX_MATCH_ATTEMPTS = 10000;

/// Match a glob pattern against a path.
/// Supports:
/// - `*` matches any characters within a single path component
/// - `**` matches any characters across path components
/// - Literal characters match exactly
pub fn matchGlob(pattern: []const u8, path: []const u8) bool {
    var attempts: usize = 0;
    return matchGlobImpl(pattern, path, 0, 0, 0, &attempts);
}

fn matchGlobImpl(pattern: []const u8, path: []const u8, pi: usize, pathi: usize, depth: usize, attempts: *usize) bool {
    // Prevent stack overflow from deep recursion
    if (depth > MAX_GLOB_DEPTH) return false;

    // Prevent exponential backtracking DoS
    attempts.* += 1;
    if (attempts.* > MAX_MATCH_ATTEMPTS) return false;

    var pattern_idx = pi;
    var path_idx = pathi;

    while (pattern_idx < pattern.len) {
        if (pattern_idx + 1 < pattern.len and
            pattern[pattern_idx] == '*' and pattern[pattern_idx + 1] == '*')
        {
            // ** matches zero or more path components
            pattern_idx += 2;

            // Skip trailing slash after **
            if (pattern_idx < pattern.len and pattern[pattern_idx] == '/') {
                pattern_idx += 1;
            }

            // If ** is at end, match everything
            if (pattern_idx >= pattern.len) {
                return true;
            }

            // Try matching the rest of the pattern at every position
            var try_idx = path_idx;
            while (try_idx <= path.len) : (try_idx += 1) {
                if (matchGlobImpl(pattern, path, pattern_idx, try_idx, depth + 1, attempts)) {
                    return true;
                }
                // Early exit if we've exceeded attempt limit
                if (attempts.* > MAX_MATCH_ATTEMPTS) return false;
            }
            return false;
        } else if (pattern[pattern_idx] == '*') {
            // * matches any characters except /
            pattern_idx += 1;

            // If * is at end of pattern (or followed by end/slash), match to end of component
            if (pattern_idx >= pattern.len) {
                // Match rest of current component (no more slashes)
                while (path_idx < path.len and path[path_idx] != '/') {
                    path_idx += 1;
                }
                return path_idx == path.len;
            }

            // Try matching the rest at every position within this component
            while (path_idx < path.len and path[path_idx] != '/') {
                if (matchGlobImpl(pattern, path, pattern_idx, path_idx, depth + 1, attempts)) {
                    return true;
                }
                // Early exit if we've exceeded attempt limit
                if (attempts.* > MAX_MATCH_ATTEMPTS) return false;
                path_idx += 1;
            }
            // Also try matching at current position (for zero-length match)
            return matchGlobImpl(pattern, path, pattern_idx, path_idx, depth + 1, attempts);
        } else {
            // Literal character match
            if (path_idx >= path.len) {
                // Path exhausted - check if remaining pattern can match zero characters
                // This handles cases like "/path/**" matching "/path" exactly
                break;
            }
            if (pattern[pattern_idx] != path[path_idx]) {
                return false;
            }
            pattern_idx += 1;
            path_idx += 1;
        }
    }

    // Pattern exhausted - path must also be exhausted (or have trailing slash)
    if (pattern_idx >= pattern.len) {
        return path_idx >= path.len or (path_idx == path.len - 1 and path[path_idx] == '/');
    }

    // Path exhausted but pattern remains - check if remaining pattern can match empty string
    // Skip any trailing slash in pattern
    if (pattern_idx < pattern.len and pattern[pattern_idx] == '/') {
        pattern_idx += 1;
    }

    // Check if remaining pattern is just ** (which matches zero or more components)
    if (pattern_idx + 2 <= pattern.len and
        pattern[pattern_idx] == '*' and pattern[pattern_idx + 1] == '*')
    {
        pattern_idx += 2;
        // Skip any trailing slash after **
        if (pattern_idx < pattern.len and pattern[pattern_idx] == '/') {
            pattern_idx += 1;
        }
    }

    // Match only if entire pattern is consumed
    return pattern_idx >= pattern.len;
}

/// Expand a path relative to base directory.
fn expandPath(
    arena_alloc: Allocator,
    path: [:0]const u8,
    base: []const u8,
    diags: *cli.DiagnosticList,
) ![:0]const u8 {
    assert(std.fs.path.isAbsolute(base));
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return path;

    var buf: [std.fs.max_path_bytes]u8 = undefined;

    // Expand home directory
    if (std.mem.startsWith(u8, path, "~/")) {
        if (comptime builtin.os.tag == .windows) return path;

        const expanded = internal_os.expandHome(path, &buf) catch |err| {
            try diags.append(arena_alloc, .{
                .message = try std.fmt.allocPrintSentinel(
                    arena_alloc,
                    "error expanding home directory for path {s}: {}",
                    .{ path, err },
                    0,
                ),
            });
            return path;
        };
        return try arena_alloc.dupeZ(u8, expanded);
    }

    // Resolve relative to base
    var dir = std.fs.openDirAbsolute(base, .{}) catch |err| {
        try diags.append(arena_alloc, .{
            .message = try std.fmt.allocPrintSentinel(
                arena_alloc,
                "error opening base directory {s}: {}",
                .{ base, err },
                0,
            ),
        });
        return path;
    };
    defer dir.close();

    const abs = dir.realpath(path, &buf) catch |err| {
        if (err == error.FileNotFound) {
            const resolved = try std.fs.path.resolve(arena_alloc, &.{ base, path });
            defer arena_alloc.free(resolved);
            return try arena_alloc.dupeZ(u8, resolved);
        }

        try diags.append(arena_alloc, .{
            .message = try std.fmt.allocPrintSentinel(
                arena_alloc,
                "error resolving path {s}: {}",
                .{ path, err },
                0,
            ),
        });
        return path;
    };

    return try arena_alloc.dupeZ(u8, abs);
}

/// Expand home directory prefix in a pattern.
fn expandPatternHome(
    arena_alloc: Allocator,
    pattern: [:0]const u8,
    diags: *cli.DiagnosticList,
) ![:0]const u8 {
    if (!std.mem.startsWith(u8, pattern, "~/")) return pattern;
    if (comptime builtin.os.tag == .windows) return pattern;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const expanded = internal_os.expandHome(pattern, &buf) catch |err| {
        try diags.append(arena_alloc, .{
            .message = try std.fmt.allocPrintSentinel(
                arena_alloc,
                "error expanding home directory in pattern {s}: {}",
                .{ pattern, err },
                0,
            ),
        });
        return pattern;
    };
    return try arena_alloc.dupeZ(u8, expanded);
}

// ============================================================================
// Tests
// ============================================================================

test "DirectoryConfig.parse basic" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    {
        const item = (try DirectoryConfig.parse(alloc, "~/work/*:~/.config/ghostty/work.conf")).?;
        try testing.expectEqualStrings("~/work/*", item.pattern);
        try testing.expectEqualStrings("~/.config/ghostty/work.conf", item.config_path);
    }

    {
        const item = (try DirectoryConfig.parse(alloc, "/home/user/projects:./project.conf")).?;
        try testing.expectEqualStrings("/home/user/projects", item.pattern);
        try testing.expectEqualStrings("./project.conf", item.config_path);
    }
}

test "DirectoryConfig.parse empty" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try testing.expectEqual(@as(?DirectoryConfig, null), try DirectoryConfig.parse(alloc, ""));
    try testing.expectError(error.ValueRequired, DirectoryConfig.parse(alloc, null));
    try testing.expectError(error.InvalidFormat, DirectoryConfig.parse(alloc, "nocolon"));
    try testing.expectError(error.InvalidFormat, DirectoryConfig.parse(alloc, ":path"));
    try testing.expectError(error.InvalidFormat, DirectoryConfig.parse(alloc, "pattern:"));
}

test "matchGlob exact" {
    const testing = std.testing;

    try testing.expect(matchGlob("/home/user/work", "/home/user/work"));
    try testing.expect(!matchGlob("/home/user/work", "/home/user/work2"));
    try testing.expect(!matchGlob("/home/user/work", "/home/user"));
}

test "matchGlob single wildcard" {
    const testing = std.testing;

    // * matches within component
    try testing.expect(matchGlob("/home/user/*", "/home/user/foo"));
    try testing.expect(matchGlob("/home/user/*", "/home/user/bar"));
    try testing.expect(!matchGlob("/home/user/*", "/home/user/foo/bar"));
    try testing.expect(!matchGlob("/home/user/*", "/home/other/foo"));

    // * in middle
    try testing.expect(matchGlob("/home/*/work", "/home/user/work"));
    try testing.expect(matchGlob("/home/*/work", "/home/admin/work"));
    try testing.expect(!matchGlob("/home/*/work", "/home/user/other"));
}

test "matchGlob double wildcard" {
    const testing = std.testing;

    // ** matches across components
    try testing.expect(matchGlob("/home/user/**", "/home/user/foo"));
    try testing.expect(matchGlob("/home/user/**", "/home/user/foo/bar"));
    try testing.expect(matchGlob("/home/user/**", "/home/user/foo/bar/baz"));
    try testing.expect(!matchGlob("/home/user/**", "/home/other/foo"));

    // ** matches zero components (base directory itself)
    try testing.expect(matchGlob("/home/user/**", "/home/user"));
    try testing.expect(matchGlob("/Documents/Obsidian/**", "/Documents/Obsidian"));

    // Test the user's exact patterns (with full path)
    try testing.expect(matchGlob("/Users/michael/Documents/Obsidian/**", "/Users/michael/Documents/Obsidian"));
    try testing.expect(matchGlob("/Users/michael/Documents/Obsidian/**", "/Users/michael/Documents/Obsidian/notes"));
    try testing.expect(matchGlob("/Users/michael/Documents/GitHub/network-config/**", "/Users/michael/Documents/GitHub/network-config"));
    try testing.expect(matchGlob("/Users/michael/Documents/GitHub/network-config/**", "/Users/michael/Documents/GitHub/network-config/foo"));
    // Should NOT match other directories
    try testing.expect(!matchGlob("/Users/michael/Documents/Obsidian/**", "/Users/michael"));
    try testing.expect(!matchGlob("/Users/michael/Documents/Obsidian/**", "/Users/michael/Documents"));

    // ** in middle
    try testing.expect(matchGlob("/home/**/work", "/home/work"));
    try testing.expect(matchGlob("/home/**/work", "/home/user/work"));
    try testing.expect(matchGlob("/home/**/work", "/home/user/projects/work"));
}

test "RepeatableDirectoryConfig.findMatch" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var list: RepeatableDirectoryConfig = .{};
    try list.parseCLI(alloc, "/home/user/work/*:/work.conf");
    try list.parseCLI(alloc, "/home/user/personal/*:/personal.conf");
    try list.parseCLI(alloc, "/home/user/**:/default.conf");

    {
        const match = list.findMatch("/home/user/work/project");
        try testing.expect(match != null);
        try testing.expectEqualStrings("/work.conf", match.?.config_path);
    }

    {
        const match = list.findMatch("/home/user/personal/stuff");
        try testing.expect(match != null);
        try testing.expectEqualStrings("/personal.conf", match.?.config_path);
    }

    {
        const match = list.findMatch("/home/user/other/thing");
        try testing.expect(match != null);
        try testing.expectEqualStrings("/default.conf", match.?.config_path);
    }

    {
        const match = list.findMatch("/other/path");
        try testing.expect(match == null);
    }
}

test "patternSpecificity" {
    const testing = std.testing;

    // More literal characters = higher specificity
    try testing.expect(patternSpecificity("/home/user/work/*") > patternSpecificity("/home/*"));
    try testing.expect(patternSpecificity("/home/user/**") > patternSpecificity("/**"));
}
