# Bare Filename Link Detection Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect bare filenames (e.g., `README.md`, `Makefile`, `.gitignore`) as clickable links when Cmd is held, by checking file existence on disk asynchronously.

**Architecture:** A new phase in `linkAtPos` extracts the "word" under the cursor, checks a cache, and on cache miss submits an async filesystem check to a dedicated background thread. Results are sent back via the surface message system and cached for instant subsequent lookups.

**Tech Stack:** Zig, xev event loop, Ghostty's CacheTable, surface message system

**Spec:** `docs/superpowers/specs/2026-03-18-bare-filename-link-detection-design.md`

**Build:** `zig build -Demit-macos-app=false`
**Test:** `zig build test -Dtest-filter="<test name>" -Demit-macos-app=false`
**Format:** `zig fmt <file>`

**Prerequisites:** The `stripLineCol` function from `src/config/url.zig` (branch `fix/cmdclick-filepath-colon`) should be cherry-picked first: `git cherry-pick fix/cmdclick-filepath-colon`. If not available, Task 1 includes an inline implementation.

---

## Chunk 1: WordExtractor

The pure-function module that extracts a candidate filename from terminal text at a given cursor position. Independently testable with no dependencies on Surface, threads, or terminal state.

### Task 1: Create WordExtractor with tests and implementation

**Files:**
- Create: `src/terminal/file_check/WordExtractor.zig`
- Create: `src/terminal/file_check.zig` (namespace file — follows pattern of `src/terminal/search.zig`)
- Modify: `src/terminal/main.zig` (add `file_check` import)

- [ ] **Step 1: Create the directory and namespace file**

```bash
mkdir -p src/terminal/file_check
```

Create `src/terminal/file_check.zig` (namespace file, following `src/terminal/search.zig` pattern):

```zig
pub const WordExtractor = @import("file_check/WordExtractor.zig");
```

Note: `Thread` import will be added in Chunk 2 after `Thread.zig` is created.

Add to `src/terminal/main.zig` (near line 21, next to `pub const search`):

```zig
pub const file_check = @import("file_check.zig");
```

- [ ] **Step 2: Write the WordExtractor module with tests**

Create `src/terminal/file_check/WordExtractor.zig`:

```zig
const std = @import("std");

/// Result of word extraction. The caller must free `word` using the
/// allocator that was passed to `extract`.
pub const Result = struct {
    /// The cleaned filename (trailing punctuation stripped, line:col
    /// removed, backslash-spaces unescaped).
    word: []const u8,
    /// Start byte index in the original text (before cleanup).
    start: usize,
    /// End byte index (exclusive) in the original text (before cleanup).
    end: usize,
};

/// Characters that are valid in filenames. Scanning stops at the first
/// character NOT in this set (unless escape- or quote-aware rules apply).
fn isFilenameChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9' => true,
        '.', '-', '_', '+', '~', ':', '@' => true,
        else => false,
    };
}

/// Extracts a candidate filename from `text` at the given `offset`.
/// Returns a Result with the cleaned word and its raw bounds, or null
/// if no valid candidate is found at the position.
///
/// The caller must free `result.word` using `alloc`.
pub fn extract(alloc: std.mem.Allocator, text: []const u8, offset: usize) ?Result {
    if (offset >= text.len) return null;
    if (!isFilenameChar(text[offset]) and text[offset] != '"' and text[offset] != '\'') return null;

    // Phase 1: Check if cursor is inside quotes
    if (extractQuoted(alloc, text, offset)) |result| return result;

    // Phase 2: Character-set scan with escape awareness
    return extractWord(alloc, text, offset);
}

/// Checks if offset is inside a quoted string ("..." or '...').
/// If so, returns the content between the quotes.
fn extractQuoted(alloc: std.mem.Allocator, text: []const u8, offset: usize) ?Result {
    // Scan left for an opening quote, recording its position
    var open: usize = undefined;
    const quote_char: u8 = find_quote: {
        var i = offset;
        while (i > 0) {
            i -= 1;
            if (text[i] == '"' or text[i] == '\'') {
                open = i;
                break :find_quote text[i];
            }
            // If we hit a newline or other control char, no quote
            if (text[i] < 0x20) return null;
        }
        return null;
    };

    // Find the closing quote
    var close: usize = offset + 1;
    while (close < text.len) : (close += 1) {
        if (text[close] == quote_char) break;
    } else {
        return null; // No closing quote found
    }

    const content_start = open + 1;
    const content_end = close;
    const content = text[content_start..content_end];
    if (content.len == 0) return null;

    const word = cleanup(alloc, content) orelse return null;
    return .{ .word = word, .start = content_start, .end = content_end };
}

/// Scans outward from offset using the filename charset.
/// Handles backslash-escaped spaces.
fn extractWord(alloc: std.mem.Allocator, text: []const u8, offset: usize) ?Result {
    // Scan left
    var left = offset;
    while (left > 0) {
        const prev = left - 1;
        if (isFilenameChar(text[prev])) {
            left = prev;
            continue;
        }
        // Check for backslash-escaped space: `\ `
        if (text[prev] == ' ' and prev > 0 and text[prev - 1] == '\\') {
            left = prev - 1;
            continue;
        }
        break;
    }

    // Scan right
    var right = offset + 1;
    while (right < text.len) {
        if (isFilenameChar(text[right])) {
            right += 1;
            continue;
        }
        // Check for backslash-escaped space
        if (text[right] == '\\' and right + 1 < text.len and text[right + 1] == ' ') {
            right += 2;
            continue;
        }
        break;
    }

    const raw = text[left..right];
    if (raw.len == 0) return null;

    const word = cleanup(alloc, raw) orelse return null;
    return .{ .word = word, .start = left, .end = right };
}

/// Post-extraction cleanup:
/// 1. Strip trailing punctuation (. , : ; ! ?)
/// 2. Strip :line[:col] suffix
/// 3. Replace `\ ` with ` ` (unescape spaces)
fn cleanup(alloc: std.mem.Allocator, raw: []const u8) ?[]const u8 {
    // Step 1: Strip trailing punctuation
    var end = raw.len;
    while (end > 0) {
        switch (raw[end - 1]) {
            '.', ',', ':', ';', '!', '?' => end -= 1,
            else => break,
        }
    }
    if (end == 0) return null;

    // Step 2: Strip :line[:col] suffix
    const after_strip = stripLineCol(raw[0..end]);
    if (after_strip.len == 0) return null;

    // Step 3: Unescape backslash-spaces
    var escaped_count: usize = 0;
    var i: usize = 0;
    while (i < after_strip.len) : (i += 1) {
        if (i + 1 < after_strip.len and after_strip[i] == '\\' and after_strip[i + 1] == ' ') {
            escaped_count += 1;
            i += 1;
        }
    }

    if (escaped_count == 0) {
        return alloc.dupe(u8, after_strip) catch return null;
    }

    const result = alloc.alloc(u8, after_strip.len - escaped_count) catch return null;
    var out: usize = 0;
    i = 0;
    while (i < after_strip.len) : (i += 1) {
        if (i + 1 < after_strip.len and after_strip[i] == '\\' and after_strip[i + 1] == ' ') {
            result[out] = ' ';
            out += 1;
            i += 1;
        } else {
            result[out] = after_strip[i];
            out += 1;
        }
    }
    return result[0..out];
}

/// Strips a trailing `:<digits>` suffix from a path.
fn stripTrailingDigitsAndColon(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) {
        if (!std.ascii.isDigit(path[i - 1])) break;
        i -= 1;
    }
    if (i > 0 and i < path.len and path[i - 1] == ':') {
        return path[0 .. i - 1];
    }
    return path;
}

/// Strips a trailing `:<line>[:<col>]` suffix from a file path.
/// For example, "file.rb:42:10" becomes "file.rb".
fn stripLineCol(path: []const u8) []const u8 {
    const after_col = stripTrailingDigitsAndColon(path);
    return stripTrailingDigitsAndColon(after_col);
}

// ── Tests ──────────────────────────────────────────────────────────────

test "extract simple filename" {
    const r = extract(std.testing.allocator, "check README.md please", 6) orelse unreachable;
    defer std.testing.allocator.free(r.word);
    try std.testing.expectEqualStrings("README.md", r.word);
    try std.testing.expectEqual(@as(usize, 6), r.start);
    try std.testing.expectEqual(@as(usize, 15), r.end);
}

test "extract filename at start" {
    const r = extract(std.testing.allocator, "Makefile is here", 0) orelse unreachable;
    defer std.testing.allocator.free(r.word);
    try std.testing.expectEqualStrings("Makefile", r.word);
    try std.testing.expectEqual(@as(usize, 0), r.start);
}

test "extract filename at end" {
    const r = extract(std.testing.allocator, "edit .gitignore", 5) orelse unreachable;
    defer std.testing.allocator.free(r.word);
    try std.testing.expectEqualStrings(".gitignore", r.word);
}

test "extract dotfile" {
    const r = extract(std.testing.allocator, "see .env for config", 4) orelse unreachable;
    defer std.testing.allocator.free(r.word);
    try std.testing.expectEqualStrings(".env", r.word);
}

test "extract with line:col suffix" {
    const r = extract(std.testing.allocator, "error in file.rb:42:10 here", 9) orelse unreachable;
    defer std.testing.allocator.free(r.word);
    try std.testing.expectEqualStrings("file.rb", r.word);
}

test "extract with line suffix only" {
    const r = extract(std.testing.allocator, "see file.rb:52", 4) orelse unreachable;
    defer std.testing.allocator.free(r.word);
    try std.testing.expectEqualStrings("file.rb", r.word);
}

test "extract trailing period stripped" {
    const r = extract(std.testing.allocator, "Check README.md. Done.", 6) orelse unreachable;
    defer std.testing.allocator.free(r.word);
    try std.testing.expectEqualStrings("README.md", r.word);
}

test "extract backslash-escaped space" {
    const r = extract(std.testing.allocator, "open my\\ file.txt now", 5) orelse unreachable;
    defer std.testing.allocator.free(r.word);
    try std.testing.expectEqualStrings("my file.txt", r.word);
}

test "extract double-quoted filename" {
    const r = extract(std.testing.allocator, "open \"my file.txt\" now", 7) orelse unreachable;
    defer std.testing.allocator.free(r.word);
    try std.testing.expectEqualStrings("my file.txt", r.word);
}

test "extract single-quoted filename" {
    const r = extract(std.testing.allocator, "open 'my file.txt' now", 7) orelse unreachable;
    defer std.testing.allocator.free(r.word);
    try std.testing.expectEqualStrings("my file.txt", r.word);
}

test "extract returns null for space" {
    try std.testing.expect(extract(std.testing.allocator, "hello world", 5) == null);
}

test "extract returns null for empty" {
    try std.testing.expect(extract(std.testing.allocator, "", 0) == null);
}

test "extract returns null for out-of-bounds offset" {
    try std.testing.expect(extract(std.testing.allocator, "hello", 10) == null);
}

test "extract complex filename" {
    const r = extract(std.testing.allocator, "see my-component.test.tsx for details", 4) orelse unreachable;
    defer std.testing.allocator.free(r.word);
    try std.testing.expectEqualStrings("my-component.test.tsx", r.word);
}

test "extract cursor in middle of word" {
    const r = extract(std.testing.allocator, "edit README.md now", 10) orelse unreachable;
    defer std.testing.allocator.free(r.word);
    try std.testing.expectEqualStrings("README.md", r.word);
    try std.testing.expectEqual(@as(usize, 5), r.start);
    try std.testing.expectEqual(@as(usize, 14), r.end);
}

test "stripLineCol" {
    try std.testing.expectEqualStrings("file.rb", stripLineCol("file.rb"));
    try std.testing.expectEqualStrings("file.rb", stripLineCol("file.rb:52"));
    try std.testing.expectEqualStrings("file.rb", stripLineCol("file.rb:42:10"));
    try std.testing.expectEqualStrings("file.rb:", stripLineCol("file.rb:"));
    try std.testing.expectEqualStrings("", stripLineCol(""));
    try std.testing.expectEqualStrings("12345", stripLineCol("12345"));
}
```

- [ ] **Step 3: Run the WordExtractor tests**

Run: `zig build test -Dtest-filter="extract" -Demit-macos-app=false`
Expected: All tests pass.

- [ ] **Step 4: Format and commit**

```bash
zig fmt src/terminal/file_check/WordExtractor.zig src/terminal/file_check.zig src/terminal/main.zig
git add src/terminal/file_check/ src/terminal/file_check.zig src/terminal/main.zig
git commit -m "feat: add WordExtractor for bare filename detection

Pure-function module that extracts candidate filenames from terminal
text at a cursor position. Returns cleaned word plus raw byte offsets
for building terminal Selections. Handles escape-aware scanning,
quote-aware extraction, trailing punctuation stripping, and
line:col suffix removal."
```

---

## Chunk 2: Thread and Message Infrastructure

The FileCheckThread, the surface message type, and the Link action variant.

### Task 2: Add `_open_file` action to Link.zig

**Files:**
- Modify: `src/input/Link.zig:24-32`

- [ ] **Step 1: Add the new action variant**

In `src/input/Link.zig`, add `_open_file` to the `Action` union (after `_open_osc8`):

```zig
pub const Action = union(enum) {
    /// Open the full matched value using the default open program.
    open: void,

    /// Open the OSC8 hyperlink under the mouse position.
    _open_osc8: void,

    /// Open a file whose existence was confirmed by the async file checker.
    /// The resolved path is retrieved from the Surface's file check cache.
    _open_file: void,
};
```

- [ ] **Step 2: Commit**

```bash
git add src/input/Link.zig
git commit -m "feat: add _open_file action variant to Link

Internal-only action for opening files detected by the async
file existence checker."
```

### Task 3: Add `file_check_result` message to surface.zig

**Files:**
- Modify: `src/apprt/surface.zig:14-132`

- [ ] **Step 1: Add the message variant and result struct**

In `src/apprt/surface.zig`, add the variant after `search_selected` (around line 129):

```zig
    search_selected: ?usize,
    file_check_result: FileCheckResult,
```

Add the struct definition inside the `Message` union (alongside existing inner types like `ChildExited`):

```zig
    pub const FileCheckResult = struct {
        /// The candidate word that was checked.
        word: [255]u8 = undefined,
        word_len: u8 = 0,

        /// The terminal PWD at time of check.
        pwd: WriteReq = .{ .small = .{} },

        /// The resolved absolute path if the file exists, null otherwise.
        resolved_path: ?WriteReq = null,

        pub fn wordSlice(self: FileCheckResult) []const u8 {
            return self.word[0..self.word_len];
        }

        /// Free heap-allocated WriteReq data. Uses value receiver to
        /// match WriteReq.deinit pattern.
        pub fn deinit(self: FileCheckResult) void {
            self.pwd.deinit();
            if (self.resolved_path) |rp| rp.deinit();
        }
    };
```

- [ ] **Step 2: Commit**

```bash
git add src/apprt/surface.zig
git commit -m "feat: add file_check_result message type

Surface message for communicating async file existence check
results from the FileCheckThread back to the Surface."
```

### Task 4: Create FileCheckThread

**Files:**
- Create: `src/terminal/file_check/Thread.zig`
- Modify: `src/terminal/file_check.zig` (add Thread import)

- [ ] **Step 1: Write the FileCheckThread**

Create `src/terminal/file_check/Thread.zig`. This follows the pattern established by `src/terminal/search/Thread.zig`:

```zig
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const xev = @import("../../global.zig").xev;
const apprt = @import("../../apprt.zig");
const BlockingQueue = @import("../../datastruct/main.zig").BlockingQueue;
const internal_os = @import("../../os/main.zig");

const log = std.log.scoped(.file_check);

const Thread = @This();

const Mailbox = BlockingQueue(Message, 32);

pub const Message = union(enum) {
    check: CheckRequest,
};

pub const CheckRequest = struct {
    /// The candidate filename to check.
    word: [255]u8 = undefined,
    word_len: u8 = 0,

    /// The working directory to resolve against.
    pwd: [std.fs.max_path_bytes]u8 = undefined,
    pwd_len: u16 = 0,

    pub fn wordSlice(self: *const CheckRequest) []const u8 {
        return self.word[0..self.word_len];
    }

    pub fn pwdSlice(self: *const CheckRequest) []const u8 {
        return self.pwd[0..self.pwd_len];
    }
};

pub const Options = struct {
    /// Callback for sending results back. Called ON the file check thread.
    result_cb: *const fn (result: apprt.surface.Message.FileCheckResult, ud: ?*anyopaque) void,
    result_userdata: ?*anyopaque = null,
};

// ── Fields ─────────────────────────────────────────────────────────

alloc: Allocator,
mailbox: *Mailbox,
loop: xev.Loop,
wakeup: xev.Async,
wakeup_c: xev.Completion = .{},
stop: xev.Async,
stop_c: xev.Completion = .{},
opts: Options,

// ── Lifecycle ──────────────────────────────────────────────────────

pub fn init(alloc: Allocator, opts: Options) !Thread {
    var mailbox = try Mailbox.create(alloc);
    errdefer mailbox.destroy(alloc);

    var loop = try xev.Loop.init(.{});
    errdefer loop.deinit();

    var wakeup_h = try xev.Async.init();
    errdefer wakeup_h.deinit();

    var stop_h = try xev.Async.init();
    errdefer stop_h.deinit();

    return .{
        .alloc = alloc,
        .mailbox = mailbox,
        .loop = loop,
        .wakeup = wakeup_h,
        .stop = stop_h,
        .opts = opts,
    };
}

pub fn deinit(self: *Thread) void {
    self.wakeup.deinit();
    self.stop.deinit();
    self.loop.deinit();
    self.mailbox.destroy(self.alloc);
}

// ── Thread Entry ───────────────────────────────────────────────────

pub fn threadMain(self: *Thread) void {
    self.threadMain_() catch |err| {
        log.err("file check thread error: {}", .{err});
    };
}

fn threadMain_(self: *Thread) !void {
    if (comptime builtin.os.tag.isDarwin()) {
        internal_os.macos.pthread_setname_np(&"file-check".*);
        const class: internal_os.macos.QosClass = .utility;
        if (internal_os.macos.setQosClass(class)) {
            log.debug("thread QoS class set class={}", .{class});
        } else |err| {
            log.warn("error setting QoS class err={}", .{err});
        }
    }

    // Register async handles (5-arg form matching codebase pattern)
    self.wakeup.wait(&self.loop, &self.wakeup_c, Thread, self, wakeupCallback);
    self.stop.wait(&self.loop, &self.stop_c, Thread, self, stopCallback);

    // Initial wakeup to drain any messages queued before thread started
    try self.wakeup.notify();

    log.debug("starting file check thread", .{});

    while (true) {
        if (self.loop.stopped()) {
            // Drain remaining messages on shutdown
            while (self.mailbox.pop()) |msg| {
                _ = msg;
            }
            return;
        }

        // Block until there's work (wakeup or stop signal)
        try self.loop.run(.once);
    }
}

fn wakeupCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.warn("error in wakeup err={}", .{err});
        return .rearm;
    };
    const self = self_.?;
    self.drainMailbox();
    return .rearm;
}

fn stopCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch unreachable;
    self_.?.loop.stop();
    return .disarm;
}

fn drainMailbox(self: *Thread) void {
    while (self.mailbox.pop()) |msg| {
        self.processMessage(msg);
    }
}

fn processMessage(self: *Thread, msg: Message) void {
    switch (msg) {
        .check => |req| self.handleCheck(req),
    }
}

fn handleCheck(self: *Thread, req: CheckRequest) void {
    const word = req.wordSlice();
    const pwd = req.pwdSlice();

    // Resolve the path
    const resolved = std.fs.path.resolve(self.alloc, &.{ pwd, word }) catch {
        self.sendResult(word, pwd, null);
        return;
    };
    defer self.alloc.free(resolved);

    // Check existence and that it's a regular file (not directory)
    const stat = std.fs.cwd().statFile(resolved) catch {
        self.sendResult(word, pwd, null);
        return;
    };

    if (stat.kind != .file) {
        self.sendResult(word, pwd, null);
        return;
    }

    self.sendResult(word, pwd, resolved);
}

fn sendResult(self: *Thread, word: []const u8, pwd: []const u8, resolved: ?[]const u8) void {
    var result: apprt.surface.Message.FileCheckResult = .{};

    // Copy word
    if (word.len > result.word.len) return;
    @memcpy(result.word[0..word.len], word);
    result.word_len = @intCast(word.len);

    // Copy pwd (WriteReq.init returns error union, not optional)
    if (apprt.surface.Message.WriteReq.init(self.alloc, pwd)) |req| {
        result.pwd = req;
    } else |_| {
        return;
    }

    // Copy resolved path
    if (resolved) |path| {
        if (apprt.surface.Message.WriteReq.init(self.alloc, path)) |req| {
            result.resolved_path = req;
        } else |_| {
            result.pwd.deinit();
            return;
        }
    }

    self.opts.result_cb(result, self.opts.result_userdata);
}

/// Submit a check request. Called from the main thread.
pub fn submit(self: *Thread, word: []const u8, pwd: []const u8) void {
    if (word.len > 255 or pwd.len > std.fs.max_path_bytes) return;

    var req: CheckRequest = .{};
    @memcpy(req.word[0..word.len], word);
    req.word_len = @intCast(word.len);
    @memcpy(req.pwd[0..pwd.len], pwd);
    req.pwd_len = @intCast(pwd.len);

    _ = self.mailbox.push(.{ .check = req }, .{ .instant = {} });
    self.wakeup.notify() catch {};
}
```

- [ ] **Step 2: Add Thread import to namespace file**

Update `src/terminal/file_check.zig`:

```zig
pub const WordExtractor = @import("file_check/WordExtractor.zig");
pub const Thread = @import("file_check/Thread.zig");
```

- [ ] **Step 3: Verify compilation**

Run: `zig build -Demit-macos-app=false`
Expected: Compiles without errors.

- [ ] **Step 4: Format and commit**

```bash
zig fmt src/terminal/file_check/Thread.zig src/terminal/file_check.zig
git add src/terminal/file_check/Thread.zig src/terminal/file_check.zig
git commit -m "feat: add FileCheckThread for async file existence checking

Background thread that receives (word, pwd) requests, resolves the
path, stats the file, and sends results back via a callback. Uses
xev event loop pattern consistent with the search thread."
```

---

## Chunk 3: Surface Integration

Wire everything together in Surface.zig: cache, linkAtPos modification, handleMessage, processLinks, mouseRefreshLinks, and thread lifecycle.

### Task 5: Add cache and thread fields to Surface

**Files:**
- Modify: `src/Surface.zig` (imports, struct fields, types)

- [ ] **Step 1: Add imports**

At the top of `src/Surface.zig`, near the existing imports (around line 32), add:

```zig
const file_check = @import("terminal/file_check.zig");
```

And for CacheTable (following `src/font/shaper/Cache.zig` pattern):

```zig
const CacheTable = @import("datastruct/main.zig").CacheTable;
```

- [ ] **Step 2: Add struct fields and types**

After the `search` field (line 166), add:

```zig
    /// Async file existence checker for bare filename detection.
    file_check_thread: ?FileCheck = null,
    file_check_cache: FileCheckCache = .{ .context = .{} },
```

Add the `FileCheck` struct near the existing `Search` struct (around line 191):

```zig
const FileCheck = struct {
    state: file_check.Thread,
    thread: std.Thread,

    pub fn deinit(self: *FileCheck) void {
        self.state.stop.notify() catch |err| log.err(
            "error notifying file check thread to stop, may stall err={}",
            .{err},
        );
        self.thread.join();
        self.state.deinit();
    }
};

const FileCheckCacheEntry = struct {
    exists: bool,
    resolved_path: [std.fs.max_path_bytes]u8 = undefined,
    resolved_path_len: u16 = 0,

    fn resolvedPathSlice(self: *const FileCheckCacheEntry) ?[]const u8 {
        if (!self.exists) return null;
        return self.resolved_path[0..self.resolved_path_len];
    }
};

const FileCheckCacheContext = struct {
    pub fn hash(_: @This(), key: u64) u64 {
        return key;
    }
    pub fn eql(_: @This(), a: u64, b: u64) bool {
        return a == b;
    }
};

const FileCheckCache = CacheTable(u64, FileCheckCacheEntry, FileCheckCacheContext, 64, 4);
```

- [ ] **Step 3: Commit**

```bash
git add src/Surface.zig
git commit -m "feat: add FileCheck thread and cache fields to Surface"
```

### Task 6: Thread lifecycle — init and deinit

**Files:**
- Modify: `src/Surface.zig` (init, deinit, callback)

- [ ] **Step 1: Spawn FileCheckThread in init**

In `src/Surface.zig`, after the IO thread spawn (around line 714). Key: assign `self.file_check_thread` FIRST with `.thread = undefined`, THEN get a stable pointer, THEN spawn. This follows the search thread pattern at line 5116.

```zig
    // Start file check thread
    {
        var fc_state = file_check.Thread.init(self.alloc, .{
            .result_cb = &fileCheckCallback,
            .result_userdata = self,
        }) catch |err| {
            log.warn("failed to init file check thread: {}", .{err});
            break; // file_check_thread stays null
        };
        errdefer fc_state.deinit();

        // Assign first so the pointer is stable for the spawned thread
        self.file_check_thread = .{
            .state = fc_state,
            .thread = undefined,
        };
        const fc: *FileCheck = &self.file_check_thread.?;

        fc.thread = std.Thread.spawn(
            .{},
            file_check.Thread.threadMain,
            .{&fc.state},
        ) catch |err| {
            log.warn("failed to spawn file check thread: {}", .{err});
            fc.state.deinit();
            self.file_check_thread = null;
            break;
        };
        fc.thread.setName("file-check") catch {};
    }
```

Note: the `break` targets a labeled block. Wrap the above in `fc_init: { ... }` and use `break :fc_init` if needed for compile correctness. The implementer should adapt to the surrounding code structure.

- [ ] **Step 2: Stop FileCheckThread in deinit**

In `deinit`, before stopping the renderer thread (around line 778):

```zig
    if (self.file_check_thread) |*fc| fc.deinit();
```

- [ ] **Step 3: Add the callback function**

Near `searchCallback` (around line 1390):

```zig
fn fileCheckCallback(result: apprt.surface.Message.FileCheckResult, ud: ?*anyopaque) void {
    // IMPORTANT: This runs on the FILE CHECK THREAD.
    const self: *Surface = @ptrCast(@alignCast(ud.?));
    _ = self.surfaceMailbox().push(.{ .file_check_result = result }, .{ .instant = {} });
}
```

- [ ] **Step 4: Commit**

```bash
git add src/Surface.zig
git commit -m "feat: spawn and stop FileCheckThread in Surface lifecycle"
```

### Task 7: Handle file_check_result in handleMessage

**Files:**
- Modify: `src/Surface.zig` (handleMessage)

- [ ] **Step 1: Add the message handler**

In `handleMessage` switch, add after `search_selected`:

```zig
            .file_check_result => |result| {
                defer result.deinit();

                const word = result.wordSlice();
                const pwd_slice = result.pwd.slice();
                const cache_key = std.hash.Wyhash.hash(0, word) ^
                    std.hash.Wyhash.hash(1, pwd_slice);

                var entry: FileCheckCacheEntry = .{ .exists = result.resolved_path != null };
                if (result.resolved_path) |rp| {
                    const path = rp.slice();
                    if (path.len <= entry.resolved_path.len) {
                        @memcpy(entry.resolved_path[0..path.len], path);
                        entry.resolved_path_len = @intCast(path.len);
                    } else {
                        entry.exists = false;
                    }
                }

                _ = self.file_check_cache.put(cache_key, entry);

                // Refresh links — must hold renderer mutex
                if (self.mouse.link_point) |link_point| {
                    const pos = self.rt_surface.getCursorPos() catch return;
                    self.renderer_state.mutex.lock();
                    defer self.renderer_state.mutex.unlock();
                    self.mouseRefreshLinks(
                        pos,
                        link_point,
                        self.mouse.over_link,
                    ) catch {};
                }
            },
```

- [ ] **Step 2: Clear cache on pwd_change**

In the existing `.pwd_change` handler, add `self.file_check_cache.clear();` as the first line after `defer w.deinit();`:

```zig
            .pwd_change => |w| {
                defer w.deinit();
                self.file_check_cache.clear();
                // ... rest unchanged
            },
```

- [ ] **Step 3: Commit**

```bash
git add src/Surface.zig
git commit -m "feat: handle file_check_result message and cache management"
```

### Task 8: Integrate into linkAtPos

**Files:**
- Modify: `src/Surface.zig` (linkAtPos, new fileCheckAtPin)

- [ ] **Step 1: Modify linkAtPos**

Replace the last line of `linkAtPos` (currently `return try self.linkAtPin(mouse_pin, mouse_mods);`):

```zig
    // Check regex links first
    if (try self.linkAtPin(mouse_pin, mouse_mods)) |link| return link;

    // Phase 3: Bare filename detection via file existence check.
    // Only when Cmd/Super is held.
    if (!mouse_mods.equal(input.ctrlOrSuper(.{}))) return null;

    return try self.fileCheckAtPin(mouse_pin);
}
```

- [ ] **Step 2: Implement fileCheckAtPin**

Add after `linkAtPin`. This function uses the `StringMap.map` array directly to convert between string offsets and terminal Pins:

```zig
/// Checks if a bare filename exists at the given pin position.
/// Returns a link if the file is confirmed to exist (from cache),
/// or null if not found / pending async check.
fn fileCheckAtPin(self: *Surface, mouse_pin: terminal.Pin) !?Link {
    const screen: *terminal.Screen = self.renderer_state.terminal.screens.active;

    // Get PWD — required for resolving bare filenames
    const pwd = self.io.terminal.getPwd() orelse return null;

    // Get the line text and a string map for position mapping
    const line = screen.selectLine(.{
        .pin = mouse_pin,
        .whitespace = null,
        .semantic_prompt_boundary = false,
    }) orelse return null;

    var strmap: terminal.StringMap = undefined;
    const line_str = try screen.selectionString(self.alloc, .{
        .sel = line,
        .trim = false,
        .map = &strmap,
    });
    defer self.alloc.free(line_str);
    defer strmap.deinit(self.alloc);

    // Find the string offset for mouse_pin by scanning the map array.
    // StringMap.map is []Pin with one entry per byte in .string.
    const offset: usize = offset: {
        for (strmap.map, 0..) |pin, i| {
            // Compare pins by checking if they reference the same position
            const pt_a = screen.pages.pointFromPin(.screen, pin);
            const pt_b = screen.pages.pointFromPin(.screen, mouse_pin);
            if (pt_a != null and pt_b != null and
                std.meta.eql(pt_a.?, pt_b.?))
            {
                break :offset i;
            }
        }
        return null; // mouse_pin not found in this line
    };

    // Extract candidate filename
    const result = file_check.WordExtractor.extract(
        self.alloc,
        line_str,
        offset,
    ) orelse return null;
    defer self.alloc.free(result.word);

    // Skip if the word contains a '/' — handled by regex pipeline
    if (std.mem.indexOfScalar(u8, result.word, '/') != null) return null;

    // Check cache
    const cache_key = std.hash.Wyhash.hash(0, result.word) ^
        std.hash.Wyhash.hash(1, pwd);

    if (self.file_check_cache.get(cache_key)) |entry| {
        if (entry.exists) {
            // Build selection from raw byte offsets via strmap.map
            if (result.start >= strmap.map.len or
                result.end == 0 or
                result.end - 1 >= strmap.map.len) return null;
            const sel_start = strmap.map[result.start];
            const sel_end = strmap.map[result.end - 1];
            const sel = terminal.Selection.init(sel_start, sel_end, false);
            return .{ .action = ._open_file, .selection = sel };
        }
        return null; // cached: file does not exist
    }

    // Cache miss — submit async check
    if (self.file_check_thread) |*fc| {
        fc.state.submit(result.word, pwd);
    }

    return null; // result will arrive via message
}
```

- [ ] **Step 3: Commit**

```bash
git add src/Surface.zig
git commit -m "feat: integrate bare filename detection into linkAtPos

After regex matching returns null, extracts the word under cursor,
checks cache, submits async file existence checks on cache miss.
Uses StringMap.map array for Pin-to-offset conversion."
```

### Task 9: Handle _open_file in processLinks and mouseRefreshLinks

**Files:**
- Modify: `src/Surface.zig` (processLinks, mouseRefreshLinks)

- [ ] **Step 1: Handle _open_file in processLinks**

In the `processLinks` switch on `link.action`, add:

```zig
        ._open_file => {
            const str = try self.io.terminal.screens.active.selectionString(self.alloc, .{
                .sel = link.selection,
                .trim = false,
            });
            defer self.alloc.free(str);

            const pwd = self.io.terminal.getPwd() orelse return false;
            const cache_key = std.hash.Wyhash.hash(0, str) ^
                std.hash.Wyhash.hash(1, pwd);
            const entry = self.file_check_cache.get(cache_key) orelse return false;
            const resolved = entry.resolvedPathSlice() orelse return false;

            try self.openUrl(.{ .kind = .unknown, .url = resolved });
        },
```

- [ ] **Step 2: Handle _open_file in mouseRefreshLinks**

In `mouseRefreshLinks`, in the switch on `link.action` (around line 1585), add:

```zig
            ._open_file => {
                const str = try self.io.terminal.screens.active.selectionString(alloc, .{
                    .sel = link.selection,
                    .trim = false,
                });

                const pwd = self.io.terminal.getPwd();
                const preview_url = if (pwd) |p| preview: {
                    const key = std.hash.Wyhash.hash(0, str) ^
                        std.hash.Wyhash.hash(1, p);
                    if (self.file_check_cache.get(key)) |entry| {
                        break :preview entry.resolvedPathSlice() orelse str;
                    }
                    break :preview str;
                } else str;

                break :link .{
                    .{ .url = try alloc.dupeZ(u8, preview_url) },
                    self.config.link_previews == .true,
                };
            },
```

- [ ] **Step 3: Build to verify compilation**

Run: `zig build -Demit-macos-app=false`
Expected: Compiles without errors.

- [ ] **Step 4: Run all tests**

Run: `zig build test -Demit-macos-app=false`
Expected: All tests pass, no regressions.

- [ ] **Step 5: Format and commit**

```bash
zig fmt src/Surface.zig src/input/Link.zig src/apprt/surface.zig src/terminal/file_check/Thread.zig src/terminal/file_check/WordExtractor.zig src/terminal/file_check.zig src/terminal/main.zig
git add src/Surface.zig src/input/Link.zig src/apprt/surface.zig
git commit -m "feat: complete bare filename link detection

Handle _open_file in processLinks (opens cached resolved path)
and mouseRefreshLinks (shows resolved path in link preview).
Completes the bare filename detection feature."
```

### Task 10: Manual smoke test

- [ ] **Step 1: Build the macOS app**

Run: `zig build`

- [ ] **Step 2: Open the app and test**

```bash
open zig-out/Ghostty.app
```

In the Ghostty terminal, verify:
1. `echo README.md` — Cmd+hover over `README.md` should underline it (if the file exists in cwd)
2. `echo Makefile` — Cmd+hover should underline it
3. `echo .gitignore` — Cmd+hover should underline it
4. `echo nonexistent.xyz` — Cmd+hover should NOT underline it
5. `echo "my file.txt"` — Cmd+hover inside the quotes should underline it (if file exists)
6. Cmd+click on an underlined filename should open it
7. Regular URL links (`https://...`) should still work
8. File paths with `/` (`src/config/url.zig`) should still work via regex
9. `cd /tmp && echo README.md` — should NOT underline (file doesn't exist in /tmp)
