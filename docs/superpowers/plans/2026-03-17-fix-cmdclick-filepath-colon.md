# Fix cmd-click on file paths with colon/trailing dot

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix cmd-click failing on file paths containing `:line[:col]` suffixes (e.g., `file.rb:52`) and paths followed by sentence-ending periods.

**Architecture:** Two independent fixes — (1) add `no_trailing_punctuation` to the path regex branches in `url.zig` so trailing `.` and `,` aren't included in path matches, and (2) add a `stripLineCol` helper to `url.zig` that strips `:line[:col]` suffixes, then use it in `Surface.zig`'s `resolvePathForOpening` so that file existence checks use the actual filename.

**Tech Stack:** Zig, Oniguruma regex

**References:**
- GitHub Discussion: https://github.com/ghostty-org/ghostty/discussions/11466
- Build: `zig build`
- Test: `zig build test -Dtest-filter="<test name>"`
- Format: `zig fmt .`

---

## Chunk 1: Fix trailing punctuation in path regex

The URL regex already has a `no_trailing_punctuation` assertion (`(?<![,.])`), but it's only applied to the scheme URL branch. File path branches (rooted/relative and bare relative) use `no_trailing_colon` but NOT `no_trailing_punctuation`, causing sentence-ending periods and commas to be included in the matched path.

### Task 1: Add trailing punctuation exclusion to path regex branches

**Files:**
- Modify: `src/config/url.zig:88-102` (rooted_or_relative_path_branch)
- Modify: `src/config/url.zig:109-114` (bare_relative_path_branch)

- [ ] **Step 1: Add `no_trailing_punctuation` to `rooted_or_relative_path_branch`**

In `src/config/url.zig`, the `rooted_or_relative_path_branch` has two sub-branches (dotted and non-dotted). Both currently end with `no_trailing_colon ++ trailing_spaces_at_eol`. Add `no_trailing_punctuation` right before `no_trailing_colon` in both sub-branches.

Change lines 88-102 from:

```zig
const rooted_or_relative_path_branch =
    rooted_or_relative_path_prefix ++
    "(?:" ++
    dotted_path_lookahead ++
    path_chars ++ "+" ++
    dotted_path_space_segments ++
    no_trailing_colon ++
    trailing_spaces_at_eol ++
    "|" ++
    non_dotted_path_lookahead ++
    path_chars ++ "+" ++
    any_path_space_segments ++
    no_trailing_colon ++
    trailing_spaces_at_eol ++
    ")";
```

To:

```zig
const rooted_or_relative_path_branch =
    rooted_or_relative_path_prefix ++
    "(?:" ++
    dotted_path_lookahead ++
    path_chars ++ "+" ++
    dotted_path_space_segments ++
    no_trailing_punctuation ++
    no_trailing_colon ++
    trailing_spaces_at_eol ++
    "|" ++
    non_dotted_path_lookahead ++
    path_chars ++ "+" ++
    any_path_space_segments ++
    no_trailing_punctuation ++
    no_trailing_colon ++
    trailing_spaces_at_eol ++
    ")";
```

- [ ] **Step 2: Add `no_trailing_punctuation` to `bare_relative_path_branch`**

Change lines 109-114 from:

```zig
const bare_relative_path_branch =
    dotted_path_lookahead ++
    bare_relative_path_prefix ++
    path_chars ++ "+" ++
    no_trailing_colon ++
    trailing_spaces_at_eol;
```

To:

```zig
const bare_relative_path_branch =
    dotted_path_lookahead ++
    bare_relative_path_prefix ++
    path_chars ++ "+" ++
    no_trailing_punctuation ++
    no_trailing_colon ++
    trailing_spaces_at_eol;
```

- [ ] **Step 3: Update the `./spaces-end.` test case**

The existing test at line 346 expects `./spaces-end.   ` to match with the trailing dot. With the new `no_trailing_punctuation`, the dot gets excluded. Update this test case.

Change:

```zig
        .{
            .input = "./spaces-end.   ",
            .expect = "./spaces-end.   ",
        },
```

To:

```zig
        .{
            .input = "./spaces-end.   ",
            .expect = "./spaces-end",
        },
```

- [ ] **Step 4: Add new test cases for trailing punctuation on paths**

Add these test cases to the `cases` array in the `"url regex"` test, after the existing trailing colon tests (after line 482):

```zig
        // trailing period should not be part of the path (sentence-ending dot)
        .{
            .input = "Here is my path app/models/transaction/payment_intent.",
            .expect = "app/models/transaction/payment_intent",
        },
        .{
            .input = "Check /tmp/foo.txt. It has data.",
            .expect = "/tmp/foo.txt",
        },
        .{
            .input = "See ../example.py. More text.",
            .expect = "../example.py",
        },
        // trailing comma should not be part of the path
        .{
            .input = "Edit /tmp/foo.txt, then restart.",
            .expect = "/tmp/foo.txt",
        },
```

- [ ] **Step 5: Run the url regex tests**

Run: `zig build test -Dtest-filter="url regex"`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/config/url.zig
git commit -m "fix: exclude trailing punctuation from file path regex matches

Add no_trailing_punctuation to rooted/relative and bare relative path
branches so that sentence-ending periods and commas are not included in
the matched file path. Previously only scheme URLs excluded these.

Fixes part of ghostty-org/ghostty#11466"
```

---

## Chunk 2: Strip `:line[:col]` suffix in path resolution

The regex correctly matches `file.rb:52` including the `:52`. But `resolvePathForOpening` in `Surface.zig` passes the entire string (including `:52`) to `std.fs.accessAbsolute`, which fails because no file is literally named `file.rb:52`. The function needs to strip the `:line[:col]` suffix before checking file existence.

### Task 2: Add `stripLineCol` helper to `url.zig`

**Files:**
- Modify: `src/config/url.zig` (add public helper function + tests)

- [ ] **Step 1: Write the test for `stripLineCol`**

Add a new test block at the end of `src/config/url.zig` (after the closing of the `"url regex"` test):

```zig
test "stripLineCol" {
    const testing = std.testing;

    // No line/col suffix
    try testing.expectEqualStrings("file.rb", stripLineCol("file.rb"));

    // Line number only
    try testing.expectEqualStrings("file.rb", stripLineCol("file.rb:52"));

    // Line and column
    try testing.expectEqualStrings("file.rb", stripLineCol("file.rb:42:10"));

    // Just a colon with no digits (should not strip)
    try testing.expectEqualStrings("file.rb:", stripLineCol("file.rb:"));

    // Empty string
    try testing.expectEqualStrings("", stripLineCol(""));

    // Just digits (no colon before them)
    try testing.expectEqualStrings("12345", stripLineCol("12345"));

    // Absolute path with line
    try testing.expectEqualStrings("/home/user/file.rb", stripLineCol("/home/user/file.rb:42"));

    // Absolute path with line and column
    try testing.expectEqualStrings("/home/user/file.rb", stripLineCol("/home/user/file.rb:42:10"));
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test -Dtest-filter="stripLineCol"`
Expected: FAIL — `stripLineCol` is not defined yet.

- [ ] **Step 3: Implement `stripLineCol` and its helper**

Add these two functions to `src/config/url.zig`, just above the `test "url regex"` block (before line 123):

```zig
/// Strips a trailing `:<digits>` suffix from a path. Used to remove
/// a single `:line` or `:col` component.
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
pub fn stripLineCol(path: []const u8) []const u8 {
    // Strip :col (rightmost numeric suffix)
    const after_col = stripTrailingDigitsAndColon(path);
    // Strip :line (next numeric suffix)
    return stripTrailingDigitsAndColon(after_col);
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build test -Dtest-filter="stripLineCol"`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/config/url.zig
git commit -m "feat: add stripLineCol helper for file path line/col parsing

Strips trailing :<line>[:<col>] suffixes from file paths so that
paths like 'file.rb:42:10' resolve to 'file.rb' for file existence
checks."
```

### Task 3: Use `stripLineCol` in `resolvePathForOpening`

**Files:**
- Modify: `src/Surface.zig:2044-2064` (resolvePathForOpening)

- [ ] **Step 1: Update `resolvePathForOpening` to strip line/col before resolution**

Change `src/Surface.zig` lines 2044-2064 from:

```zig
fn resolvePathForOpening(
    self: *Surface,
    path: []const u8,
) Allocator.Error!?[]const u8 {
    if (!std.fs.path.isAbsolute(path)) {
        const terminal_pwd = self.io.terminal.getPwd() orelse {
            return null;
        };

        const resolved = try std.fs.path.resolve(self.alloc, &.{ terminal_pwd, path });

        std.fs.accessAbsolute(resolved, .{}) catch {
            self.alloc.free(resolved);
            return null;
        };

        return resolved;
    }

    return null;
}
```

To:

```zig
fn resolvePathForOpening(
    self: *Surface,
    path: []const u8,
) Allocator.Error!?[]const u8 {
    // Strip :line[:col] suffix so "file.rb:52" resolves as "file.rb".
    const clean = configpkg.url.stripLineCol(path);

    if (std.fs.path.isAbsolute(clean)) {
        // For absolute paths, only return when we stripped a suffix;
        // otherwise the caller already has a usable path.
        if (clean.len != path.len) {
            std.fs.accessAbsolute(clean, .{}) catch return null;
            return try self.alloc.dupe(u8, clean);
        }
        return null;
    }

    const terminal_pwd = self.io.terminal.getPwd() orelse {
        return null;
    };

    const resolved = try std.fs.path.resolve(self.alloc, &.{ terminal_pwd, clean });

    std.fs.accessAbsolute(resolved, .{}) catch {
        self.alloc.free(resolved);
        return null;
    };

    return resolved;
}
```

Key changes:
1. Call `configpkg.url.stripLineCol(path)` to get the path without `:line[:col]`.
2. For absolute paths with a suffix, verify the file exists and return the cleaned path.
3. For relative paths, resolve using the cleaned path.

Note: `configpkg` is already imported at line 32 of `Surface.zig`, and `configpkg.url` maps to `src/config/url.zig` (see `src/config.zig:10`).

- [ ] **Step 2: Run the url-related tests**

Run: `zig build test -Dtest-filter="url regex"` and `zig build test -Dtest-filter="stripLineCol"`
Expected: All tests pass.

- [ ] **Step 3: Format the code**

Run: `zig fmt src/config/url.zig src/Surface.zig`
Expected: No formatting changes needed (or minor auto-fixes).

- [ ] **Step 4: Manual smoke test (if possible)**

Build Ghostty with `zig build`, launch it, and verify:
1. `echo "src/config/url.zig:42:10"` — cmd-click should open the file
2. `echo "Check src/config/url.zig. More text."` — cmd-click should open the file (no trailing dot)
3. `echo "src/config/url.zig"` — cmd-click should still work as before (regression check)

- [ ] **Step 5: Commit**

```bash
git add src/Surface.zig
git commit -m "fix: strip :line[:col] suffix before checking file existence

resolvePathForOpening now strips trailing :<line>[:<col>] from paths
before calling accessAbsolute, so cmd-clicking 'file.rb:52' correctly
resolves to 'file.rb'. Also handles absolute paths with line/col
suffixes.

Fixes ghostty-org/ghostty#11466"
```
