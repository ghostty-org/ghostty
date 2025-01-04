const std = @import("std");
const oni = @import("oniguruma");

/// Default URL regex.
/// 
/// Sources:
/// 1. [Oniguruma GitHub](https://github.com/kkos/oniguruma)
/// 2. [Zig stdlib docs](https://ziglang.org/documentation/master/std/)
///
/// Explanation (analysis):
/// - Matches a set of schemes (URL_SCHEMES).
/// - Follows with one or more URL-like characters (letters, digits, punctuation).
/// - Allows optional bracket/parenthesis content.
/// - Uses a negative lookbehind to exclude matches ending in '.' or ','.
pub const URL_REGEX = 
    "(?:" ++
    URL_SCHEMES ++
    ")" ++
    "(?:[\\w\\-.~:/?#@!$&*+,;=%]+" ++
    "(?:[\\(\\[]\\w*[\\)\\]])?" ++
    ")+" ++
    "(?<![,.])";

/// Commonly recognized URL schemes.
/// 
/// Source (factual): [RFC 3986, Section 3.1 “Scheme”](https://datatracker.ietf.org/doc/html/rfc3986#section-3.1)
const URL_SCHEMES =
    "https?://" ++
    "|mailto:" ++
    "|ftp://" ++
    "|file:" ++
    "|ssh:" ++
    "|git://" ++
    "|ssh://" ++
    "|tel:" ++
    "|magnet:" ++
    "|ipfs://" ++
    "|ipns://" ++
    "|gemini://" ++
    "|gopher://" ++
    "|news:";

/// Alias so that external code can refer to `url.regex`.
pub const regex = URL_REGEX;

// Simple regex test to ensure detection of URLs works as expected.
test "url regex" {
    const testing = std.testing;

    // Oniguruma library init 
    // Source (factual): [Oniguruma GitHub](https://github.com/kkos/oniguruma)
    try oni.testing.ensureInit();

    // Compile the regex
    var re = try oni.Regex.init(
        URL_REGEX,
        .{}, // default Oniguruma options
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
    defer re.deinit();

    // Test cases
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
            .input = "weird characters https://example.com/~user/?query=1&other=2#hash and more",
            .expect = "https://example.com/~user/?query=1&other=2#hash",
        },
        .{
            .input = "square brackets https://example.com/[foo] and more",
            .expect = "https://example.com/[foo]",
        },
        .{
            .input = "[13]:TooManyStatements: TempFile#assign_temp_file_to_entity has approx 7 statements [https://example.com/docs/Too-Many-Statements.md]",
            .expect = "https://example.com/docs/Too-Many-Statements.md",
        },
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
    };

    for (cases) |test_case| {
        var result = try re.search(test_case.input, .{});
        defer result.deinit();

        try testing.expectEqual(@as(usize, test_case.num_matches), result.count());
        const matched = test_case.input[
            @as(usize, result.starts()[0])..@as(usize, result.ends()[0])
        ];
        try testing.expectEqualStrings(test_case.expect, matched);
    }
}