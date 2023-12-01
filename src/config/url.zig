const std = @import("std");
const oni = @import("oniguruma");

/// Default URL regex. This is used to detect URLs in terminal output.
/// This is here in the config package because one day the matchers will be
/// configurable and this will be a default.
///
/// This is taken from the Alacritty project.
pub const regex = "(ipfs:|ipns:|magnet:|mailto:|gemini://|gopher://|https://|http://|news:|file:|git://|ssh:|ftp://)[^\u{0000}-\u{001F}\u{007F}-\u{009F}<>\x22\\s{-}\\^⟨⟩\x60]+";

test "url regex" {
    try oni.testing.ensureInit();
    var re = try oni.Regex.init(regex, .{}, oni.Encoding.utf8, oni.Syntax.default, null);
    defer re.deinit();

    // The URL cases to test that our regex matches. Feel free to add to this
    // as we find bugs or just want more coverage.
    const cases: []const []const u8 = &.{
        "https://example.com",
    };

    for (cases) |case| {
        var reg = try re.search(case, .{});
        defer reg.deinit();
    }
}
