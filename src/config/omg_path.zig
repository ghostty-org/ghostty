//! Lower-priority macOS Cmd-click candidates. The host checks existence using
//! the source pane's filesystem before a candidate is underlined or opened, so
//! these patterns only need to find plausible spans, never prove a path.
const std = @import("std");
const oni = @import("oniguruma");

pub const quoted_regex =
    \\'(?![A-Za-z][A-Za-z0-9+.-]*:)[^'"\r\n]+'|"(?![A-Za-z][A-Za-z0-9+.-]*:)[^"'\r\n]+"
;

// Plain ls -l (including localized month names), without Nerd Font icons.
// Consume the metadata as context, but \K makes only the filename clickable.
// Do not accept arbitrary bare words: owner/size/date columns stay unlinked.
const listing_regex =
    \\(?m)^[d-][rwxstST-]{9}[+@.]?[ \t]+\d+[ \t]+\S+[ \t]+\S+[ \t]+\S+[ \t]+(?:\S+[ \t]+\d{1,2}[ \t]+(?:\d{1,2}:\d{2}|\d{4})|\d{4}-\d{2}-\d{2}[ \t]+\d{1,2}:\d{2})[ \t]+\K[\w.\-]+/?(?=[ \t]*(?:\r?$|\x00))
;

pub const regex = listing_regex ++ "|" ++
    \\(?<![\w./~:@$+-])(?!/(?![\w./-]))(?!(?:\.{3,}|[\w.\-/]*\.{3,}))(?![0-9]+(?:[A-Za-z]+)?\.[0-9]+)(?:(?:~|/|\.{1,2}/|[\w.\-]+/)[\w./-]*|\.[A-Za-z0-9_][\w.\-]*(?![\w.\-(])|(?![0-9]+\.[0-9]+)[^\s/:*?"'<>|()\x{2018}-\x{201F}\x{3000}-\x{303F}\x{FF00}-\x{FF65}]+\.(?:7z|[A-Za-z][A-Za-z0-9_]{0,7})|(?:Makefile|Dockerfile|Containerfile|Vagrantfile|Gemfile|Rakefile|LICENSE|LICENCE|README)|\.{1,2}|(?<=[📁📂\x{E000}-\x{F8FF}\x{F0000}-\x{FFFFD}]\s|[📁📂\x{E000}-\x{F8FF}\x{F0000}-\x{FFFFD}]\s\s)[\w.\-]+)(?::[0-9]+(?::[0-9]+)?)?(?![/\w.~@$+-])
;

test "OMG bare path candidates" {
    try oni.testing.ensureInit();
    var re = try oni.Regex.init(quoted_regex ++ "|" ++ regex, .{}, oni.Encoding.utf8, oni.Syntax.default, null);
    defer re.deinit();

    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "README.md", .expected = "README.md" },
        .{ .input = "\"b=Path('/home/user/project/lake_search/ETL/bag_topic_pipeline')\\nfor rel in\"", .expected = "'/home/user/project/lake_search/ETL/bag_topic_pipeline'" },
        .{ .input = "drwx------ 2 chengjisheng chengjisheng 4.0K 10月 12 14:32 adapter", .expected = "adapter" },
        .{ .input = "drwxr-xr-x 12 user group 4096 Oct 12 2025 backend", .expected = "backend" },
        .{ .input = "drwxr-xr-x 2 user group 4096 2026-10-12 14:32 bi_board_server_frontend", .expected = "bi_board_server_frontend" },
        .{ .input = "-rw------- 1 user group 42 Oct 12 14:32 env", .expected = "env" },
        .{ .input = "📁 src", .expected = "src" },
        // Nerd Font icons (eza/lsd) live in the Private Use Area.
        .{ .input = "\u{F07B} nix", .expected = "nix" },
        .{ .input = "\u{F0214} env", .expected = "env" },
        .{ .input = "\u{E5FF}  zig-out", .expected = "zig-out" },
        .{ .input = "chengjisheng 20 Aug 17:45 \u{E779} Makefile", .expected = "Makefile" },
        .{ .input = "'src'", .expected = "'src'" },
        .{ .input = "'README.md'", .expected = "'README.md'" },
        .{ .input = "'App icon.icon'", .expected = "'App icon.icon'" },
        .{ .input = "\"App icon.icon\"", .expected = "\"App icon.icon\"" },
        .{ .input = "'/tmp/App icon.icon'", .expected = "'/tmp/App icon.icon'" },
        .{ .input = "(README.md)", .expected = "README.md" },
        .{ .input = "README.md:12:3", .expected = "README.md:12:3" },
        .{ .input = ".gitignore", .expected = ".gitignore" },
        .{ .input = ".pi/test-runs/safety-state-week-20261105/week-monitor/progress.json", .expected = ".pi/test-runs/safety-state-week-20261105/week-monitor/progress.json" },
        .{ .input = "src/subdir/", .expected = "src/subdir/" },
        .{ .input = "中文.md", .expected = "中文.md" },
        .{ .input = "..", .expected = ".." },
        .{ .input = "README.md,", .expected = "README.md" },
        .{ .input = "~/code/file.txt", .expected = "~/code/file.txt" },
        .{ .input = "/tmp/file", .expected = "/tmp/file" },
        .{ .input = "./run.sh", .expected = "./run.sh" },
        .{ .input = "../parent/file.zig", .expected = "../parent/file.zig" },
        .{ .input = "1.txt", .expected = "1.txt" },
        .{ .input = "archive.7z", .expected = "archive.7z" },
        // CJK prose: full-width punctuation ends the candidate.
        .{ .input = "放到了上层（AgentQuickInput.swift 加了", .expected = "AgentQuickInput.swift" },
        .{ .input = "规则（omg_path.zig）", .expected = "omg_path.zig" },
        .{ .input = "见 omg_path.zig。", .expected = "omg_path.zig" },
    };
    for (cases) |case| {
        var match = try re.search(case.input, .{});
        defer match.deinit();
        try std.testing.expectEqualStrings(
            case.expected,
            case.input[@intCast(match.starts()[0])..@intCast(match.ends()[0])],
        );
    }
    for ([_][]const u8{
        "https://example.com/file",
        "'https://example.com/file'",
        "\"mailto:user@example.com\"",
        "mailto:user@example.com",
        "$HOME",
        "--option",
        "chegnjisheng",
        "main",
        "20:35",
        "1.4M",
        "5.6k",
        "10.2MB",
        "3.14",
        "0.5s",
        "1.2.3",
        ".../Marked",
        "git",
        "status",
        "12:34:56",
        "drwxr-xr-x@",
        "chengjisheng 20 Aug 17:45",
        "/",
        " / ",
        // A method call is not a dotfile.
        ".zIndex(1)",
    }) |input| {
        if (re.search(input, .{})) |result| {
            var match = result;
            match.deinit();
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}
