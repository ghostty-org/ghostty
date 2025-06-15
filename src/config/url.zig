const std = @import("std");
const oni = @import("oniguruma");

/// Default URL regex. This is used to detect URLs in terminal output.
/// This is here in the config package because one day the matchers will be
/// configurable and this will be a default.
///
/// This regex is liberal in what it accepts after the scheme, with exceptions
/// for URLs ending with . or ). Although such URLs are perfectly valid, it is
/// common for text to contain URLs surrounded by parentheses (such as in
/// Markdown links) or at the end of sentences. Therefore, this regex excludes
/// them as follows:
///
/// 1. Do not match regexes ending with .
/// 2. Do not match regexes ending with ), except for ones which contain a (
///    without a subsequent )
///
/// Rule 2 means that that we handle the following two cases:
///
///   "https://en.wikipedia.org/wiki/Rust_(video_game)" (include parens)
///   "(https://example.com)" (do not include the parens)
///
/// There are many complicated cases where these heuristics break down, but
/// handling them well requires a non-regex approach.
pub const regex =
    "(?:" ++ url_schemes ++
    \\)(?:
    ++ ipv6_url_pattern ++
    \\|[\w\-.~:/?#@!$&*+,;=%]+(?:[\(\[]\w*[\)\]])?)+(?<![,.])|(?:\.\.\/|\.\/|\/)[\w\-.~:\/?#@!$&*+,;=%]+(?:\/[\w\-.~:\/?#@!$&*+,;=%]*)*
    ;
const url_schemes =
    \\https?://|mailto:|ftp://|file:|ssh:|git://|ssh://|tel:|magnet:|ipfs://|ipns://|gemini://|gopher://|news:
;

const ipv6_url_pattern =
    \\(?:\[[:0-9a-fA-F]+(?:[:0-9a-fA-F]*)+\](?::[0-9]+)?)
;

test "url regex" {
    const testing = std.testing;

    try oni.testing.ensureInit();
    var re = try oni.Regex.init(
        regex,
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
    defer re.deinit();

    // The URL cases to test what our regex matches. Feel free to add to this
    // as we find bugs or just want more coverage.
    const cases = [_]struct {
        input: []const u8,
        expect: []const u8,
        num_matches: usize = 1,
    }{
        .{
            .input = "hello https://example.com world",
            .expect = "https://example.com",
        },
        .{
            .input = "https://example.com/foo(bar) more",
            .expect = "https://example.com/foo(bar)",
        },
        .{
            .input = "https://example.com/foo(bar)baz more",
            .expect = "https://example.com/foo(bar)baz",
        },
        .{
            .input = "Link inside (https://example.com) parens",
            .expect = "https://example.com",
        },
        .{
            .input = "Link period https://example.com. More text.",
            .expect = "https://example.com",
        },
        .{
            .input = "Link trailing colon https://example.com, more text.",
            .expect = "https://example.com",
        },
        .{
            .input = "Link in double quotes \"https://example.com\" and more",
            .expect = "https://example.com",
        },
        .{
            .input = "Link in single quotes 'https://example.com' and more",
            .expect = "https://example.com",
        },
        .{
            .input = "some file with https://google.com https://duckduckgo.com links.",
            .expect = "https://google.com",
        },
        .{
            .input = "and links in it. links https://yahoo.com mailto:test@example.com ssh://1.2.3.4",
            .expect = "https://yahoo.com",
        },
        .{
            .input = "also match http://example.com non-secure links",
            .expect = "http://example.com",
        },
        .{
            .input = "match tel://+12123456789 phone numbers",
            .expect = "tel://+12123456789",
        },
        .{
            .input = "match with query url https://example.com?query=1&other=2 and more text.",
            .expect = "https://example.com?query=1&other=2",
        },
        .{
            .input = "url with dashes [mode 2027](https://github.com/contour-terminal/terminal-unicode-core) for better unicode support",
            .expect = "https://github.com/contour-terminal/terminal-unicode-core",
        },
        .{
            .input = "dot.http://example.com",
            .expect = "http://example.com",
        },
        // weird characters in URL
        .{
            .input = "weird characters https://example.com/~user/?query=1&other=2#hash and more",
            .expect = "https://example.com/~user/?query=1&other=2#hash",
        },
        // square brackets in URL
        .{
            .input = "square brackets https://example.com/[foo] and more",
            .expect = "https://example.com/[foo]",
        },
        // square bracket following url
        .{
            .input = "[13]:TooManyStatements: TempFile#assign_temp_file_to_entity has approx 7 statements [https://example.com/docs/Too-Many-Statements.md]",
            .expect = "https://example.com/docs/Too-Many-Statements.md",
        },
        // remaining URL schemes tests
        .{
            .input = "match ftp://example.com ftp links",
            .expect = "ftp://example.com",
        },
        .{
            .input = "match file://example.com file links",
            .expect = "file://example.com",
        },
        .{
            .input = "match ssh://example.com ssh links",
            .expect = "ssh://example.com",
        },
        .{
            .input = "match git://example.com git links",
            .expect = "git://example.com",
        },
        .{
            .input = "match tel:+18005551234 tel links",
            .expect = "tel:+18005551234",
        },
        .{
            .input = "match magnet:?xt=urn:btih:1234567890 magnet links",
            .expect = "magnet:?xt=urn:btih:1234567890",
        },
        .{
            .input = "match ipfs://QmSomeHashValue ipfs links",
            .expect = "ipfs://QmSomeHashValue",
        },
        .{
            .input = "match ipns://QmSomeHashValue ipns links",
            .expect = "ipns://QmSomeHashValue",
        },
        .{
            .input = "match gemini://example.com gemini links",
            .expect = "gemini://example.com",
        },
        .{
            .input = "match gopher://example.com gopher links",
            .expect = "gopher://example.com",
        },
        .{
            .input = "match news:comp.infosystems.www.servers.unix news links",
            .expect = "news:comp.infosystems.www.servers.unix",
        },
        .{
            .input = "/Users/ghostty.user/code/example.py",
            .expect = "/Users/ghostty.user/code/example.py",
        },
        .{
            .input = "/Users/ghostty.user/code/../example.py",
            .expect = "/Users/ghostty.user/code/../example.py",
        },
        .{
            .input = "/Users/ghostty.user/code/../example.py hello world",
            .expect = "/Users/ghostty.user/code/../example.py",
        },
        .{
            .input = "../example.py",
            .expect = "../example.py",
        },
        .{
            .input = "../example.py ",
            .expect = "../example.py",
        },
        .{
            .input = "first time ../example.py contributor ",
            .expect = "../example.py",
        },
        .{
            .input = "[link](/home/user/ghostty.user/example)",
            .expect = "/home/user/ghostty.user/example",
        },
        // IPv6 URL tests - Basic tests
        .{
            .input = "Serving HTTP on :: port 8000 (http://[::]:8000/)",
            .expect = "http://[::]:8000/",
        },
        .{
            .input = "IPv6 address https://[2001:db8::1]:8080/path",
            .expect = "https://[2001:db8::1]:8080/path",
        },
        .{
            .input = "IPv6 localhost http://[::1]:3000",
            .expect = "http://[::1]:3000",
        },
        .{
            .input = "Complex IPv6 https://[2001:db8:85a3:8d3:1319:8a2e:370:7348]:443/",
            .expect = "https://[2001:db8:85a3:8d3:1319:8a2e:370:7348]:443/",
        },
        // IPv6 URL tests - URLs with paths and query parameters
        .{
            .input = "IPv6 with path https://[2001:db8::1]/path/to/resource",
            .expect = "https://[2001:db8::1]/path/to/resource",
        },
        .{
            .input = "IPv6 with query https://[2001:db8::1]:8080/api?param=value&other=123",
            .expect = "https://[2001:db8::1]:8080/api?param=value&other=123",
        },
        // IPv6 URL tests - Compressed forms
        .{
            .input = "IPv6 compressed http://[2001:db8::]:80/",
            .expect = "http://[2001:db8::]:80/",
        },
        .{
            .input = "IPv6 multiple zeros http://[2001:0:0:0:0:0:0:1]",
            .expect = "http://[2001:0:0:0:0:0:0:1]",
        },
        // IPv6 URL tests - Special cases
        .{
            .input = "IPv6 link-local https://[fe80::1234:5678:9abc]",
            .expect = "https://[fe80::1234:5678:9abc]",
        },
        .{
            .input = "IPv6 multicast http://[ff02::1]/stream",
            .expect = "http://[ff02::1]/stream",
        },
        // IPv6 URL tests - Mixed scenarios
        .{
            .input = "IPv6 in markdown [link](http://[2001:db8::1]/docs)",
            .expect = "http://[2001:db8::1]/docs",
        },
    };

    for (cases) |case| {
        //std.debug.print("input: {s}\n", .{case.input});
        //std.debug.print("match: {s}\n", .{case.expect});
        var reg = try re.search(case.input, .{});
        //std.debug.print("count: {d}\n", .{@as(usize, reg.count())});
        //std.debug.print("starts: {d}\n", .{reg.starts()});
        //std.debug.print("ends: {d}\n", .{reg.ends()});
        defer reg.deinit();
        try testing.expectEqual(@as(usize, case.num_matches), reg.count());
        const match = case.input[@intCast(reg.starts()[0])..@intCast(reg.ends()[0])];
        try testing.expectEqualStrings(case.expect, match);
    }
}
