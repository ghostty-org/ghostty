# Bare Filename Link Detection

## Goal

Detect bare filenames (e.g., `README.md`, `Makefile`, `.gitignore`) as clickable links when Cmd is held, by checking if they exist on disk in the terminal's working directory. This closes the gap where paths containing `/` are detected by the URL regex but bare filenames are not.

## Background

Ghostty's current link detection is purely regex-based. The URL regex in `src/config/url.zig` requires at least one `/` to recognize text as a file path (`src/config/url.zig` matches, but `README.md` does not). This is intentional — bare words with dots (`hello.world`, `v2.0`, `google.com`) produce too many false positives for a regex-only approach.

iTerm2 solves this by checking whether the text under the cursor actually exists as a file on disk. This spec brings a similar capability to Ghostty.

## Architecture

### Detection Pipeline

`linkAtPos` currently runs two phases:

1. **OSC 8 hyperlinks** — if the cell has an OSC 8 hyperlink, return it
2. **Regex links** — delegates to `linkAtPin`, which iterates over configured link regexes

This spec adds a third phase, back in `linkAtPos` after `linkAtPin` returns null:

3. **Existing file check** — extract the "word" under the cursor, resolve it against the terminal's PWD, and check if the file exists on disk

The insertion point is in `linkAtPos` (not inside `linkAtPin`), after the `try self.linkAtPin(mouse_pin, mouse_mods)` call returns null. This keeps the regex matching logic in `linkAtPin` untouched.

The order ensures regex links always take priority. The existing file check is a fallback for text that looks like a filename but doesn't contain `/`.

### Async Filesystem Check

The filesystem check runs asynchronously to avoid blocking the renderer or main thread.

**Thread model:** A dedicated `FileCheckThread` per Surface, modeled after `src/terminal/search/Thread.zig`. It receives requests via a `BlockingQueue`. Since the file check is pure request-response (no timers or periodic refresh), the thread can use a simple blocking loop rather than a full `xev.Loop` — it blocks on the queue, processes the request, sends the result, and blocks again.

**Flow:**

1. `linkAtPos` extracts the candidate word and gets the terminal's PWD
2. Checks the result cache:
   - Cache hit + file exists → return a `Link` with `._open_file` action
   - Cache hit + file does not exist → return `null`
   - Cache miss → submit request to `FileCheckThread`, return `null`
3. `FileCheckThread` resolves `pwd + "/" + candidate`, calls `stat()`
4. Sends result back via `surface_mailbox.push(.{ .file_check_result = ... })`
5. `Surface.handleMessage` receives the result, updates the cache, triggers `mouseRefreshLinks`
6. `mouseRefreshLinks` calls `linkAtPos` again — this time the cache hits and the link appears with an underline

**On click:** `processLinks` consults the cache and opens the resolved path directly — no second filesystem check.

### Cache

Uses Ghostty's existing `CacheTable` from `src/datastruct/cache_table.zig` — a fixed-size hash table with LRU eviction per bucket.

- **Type:** `CacheTable(u64, CachedResult, CacheContext, 64, 4)` — 64 buckets, 4 slots each = 256 entries max
- **Key:** `u64` hash of `(word, pwd)` pair
- **Value:** `CachedResult` — a struct containing a boolean `exists` flag and a fixed-size `[std.fs.max_path_bytes]u8` buffer for the resolved path
- **Invalidation:** cleared on `pwd_change` events
- **Thread safety:** the cache lives on the Surface and is only accessed from the main/app thread (inside `linkAtPos` and `handleMessage`), so no mutex is needed

### Word Extraction

When the existing file phase fires, a candidate filename is extracted from the terminal text at the cursor position using a character-set-based scan.

**Filename character set:** `a-zA-Z0-9 . - _ + ~ : @`

Colons and digits are included so `README.md:42:10` is extracted as one word. The `stripLineCol` function from `src/config/url.zig` (added by the `:line[:col]` fix on branch `fix/cmdclick-filepath-colon`) cleans it to `README.md` before the filesystem check. If that branch has not been merged, `WordExtractor` should include its own equivalent stripping logic.

**Scan algorithm:**

1. From the cursor position, scan left and right until hitting a character NOT in the filename charset
2. **Escape-aware:** if scanning left hits a space preceded by `\`, continue through it. The backslash is stripped from the result before the filesystem check.
3. **Quote-aware:** before scanning with the character set, check if the cursor is inside `"..."` or `'...'`. If so, extract the full quoted content instead.

**Post-extraction cleanup:**

1. Strip enclosing quotes if present
2. Strip trailing punctuation (`. , : ; ! ?`)
3. Apply `stripLineCol` to remove `:line[:col]` suffix
4. Replace `\ ` with ` ` (unescape spaces)

The resulting string is the candidate filename passed to the filesystem check.

### Link Action

A new internal `Link.Action` variant:

```
_open_file: void
```

When clicked, `processLinks` looks up the cache for the resolved absolute path and opens it via `openUrl`. This avoids a redundant filesystem check in `resolvePathForOpening`.

### Highlight Behavior

The bare filename link uses `hover_mods` (Cmd held), matching the existing URL regex link behavior. The link is only underlined when:

- Cmd is held, AND
- The file exists on disk (confirmed by async check)

## New Files

### `src/terminal/file_check/Thread.zig`

The async file existence checker thread. Modeled after `src/terminal/search/Thread.zig`.

Responsibilities:
- Owns a `BlockingQueue` for incoming requests (simple blocking loop, no `xev.Loop` needed)
- Receives `(word, pwd)` pairs
- Resolves the path: `std.fs.path.resolve(pwd, word)`
- Calls `std.fs.accessAbsolute` to check existence
- Calls `std.fs.statAbsolute` to confirm it's a regular file (not a directory)
- Sends `file_check_result` message back via the surface mailbox

Lifecycle:
- Spawned eagerly at Surface init (alongside the renderer and IO threads). This avoids the complexity of lazy initialization inside mutex-held contexts. The thread is lightweight when idle — it just blocks on its empty queue.
- Stopped when the Surface is destroyed

### `src/terminal/file_check/WordExtractor.zig`

Pure function module for character-set-based word extraction.

Responsibilities:
- Given terminal text (a line string) and a cursor column offset, returns a candidate filename string
- Implements the filename character set scan
- Handles escape-aware scanning (`\ `)
- Handles quote-aware extraction (`"..."`, `'...'`)
- Applies post-extraction cleanup (trailing punctuation, `stripLineCol`, unescape)

This is independently unit-testable without needing a Surface, thread, or terminal instance.

## Modified Files

### `src/apprt/surface.zig`

Add a new `file_check_result` variant to the `Message` union:

```
file_check_result: FileCheckResult
```

The `FileCheckResult` uses fixed-size inline buffers following the `MessageData` pattern used elsewhere in the `Message` union. Specifically:

- `word`: inline `[255]u8` (filename, bounded — filenames over 255 bytes are skipped)
- `pwd`: `WriteReq` (`MessageData(u8, 255)`) — may need heap allocation for long paths
- `resolved_path`: `?WriteReq` — the resolved absolute path if the file exists, `null` if not

The receiver (`handleMessage`) is responsible for freeing any `WriteReq` with `.alloc` storage via `deinit()`, following the existing pattern used by `pwd_change`.

### `src/Surface.zig`

- **New fields:** `FileCheckThread` handle, result cache (`CacheTable`)
- **`init`:** spawn the `FileCheckThread` alongside existing threads
- **`linkAtPos`:** after `linkAtPin` returns null, run the existing file phase (extract word, check cache, submit async request). Only when Cmd is held.
- **`handleMessage`:** handle `.file_check_result` — update cache, call `mouseRefreshLinks` to re-evaluate
- **`mouseRefreshLinks`:** handle `._open_file` in the `switch (link.action)` — display the resolved path in the link preview status bar
- **`processLinks`:** handle `._open_file` action — look up cache, open the resolved path via `openUrl`
- **`deinit`:** stop the `FileCheckThread`
- **`pwd_change` handler:** clear the file check cache
- **Double-click:** the bare filename phase does NOT fire for double-click selection (`mouse_mods = null`). It only fires when Cmd modifier is detected.

### `src/input/Link.zig`

Add `_open_file: void` to the `Action` union. This is an internal-only action (prefixed with `_`), not user-configurable.

## Error Handling and Edge Cases

### No PWD available

If `getPwd()` returns null (no shell integration, no OSC 7), the bare filename phase is skipped entirely. Same graceful degradation as relative paths today.

### File disappears after cache hit

The cache says the file exists, user clicks, but the file was deleted between hover and click. `processLinks` tries to open it and lets the OS handle the error. The race window is tiny and the failure is benign.

### Fast mouse movement

User hovers over `README.md`, async check fires, then immediately moves to `Makefile`. The first result arrives but the cursor is no longer there. `mouseRefreshLinks` re-evaluates at the current position — the stale result just populates the cache. The new position triggers its own async check.

### Symlinks

`stat()` follows symlinks by default. Symlinks to files resolve correctly.

### Directories

`stat()` succeeds for directories too. We check that the result is a regular file, not a directory. Directories are not linked.

## Scope Boundaries

### In scope

- Bare filenames without `/` (e.g., `README.md`, `Makefile`, `.env`)
- Escape-aware word extraction (`my\ file.txt`)
- Quote-aware word extraction (`"my file.txt"`)
- Line/column suffix stripping (`file.rb:42:10`)
- Async filesystem check with caching
- Cmd+hover only

### Out of scope

- Paths with `/` — these are handled by the existing regex pipeline
- Running without Cmd held — no filesystem checks on plain mouse movement
- Directory opening — files only
- Network filesystem performance optimization — single `stat()` is acceptable
- Unquoted, unescaped spaces in filenames — too ambiguous
