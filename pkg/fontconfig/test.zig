const std = @import("std");
const fontconfig = @import("main.zig");

test "fc-list" {
    const testing = std.testing;

    var cfg = fontconfig.initLoadConfigAndFonts();
    defer cfg.destroy();

    var pat = fontconfig.Pattern.create();
    defer pat.destroy();

    var os = fontconfig.ObjectSet.create();
    defer os.destroy();

    var fs = cfg.fontList(pat, os);
    defer fs.destroy();

    // Note: this is environmental, but in general we expect all our
    // testing environments to have at least one font.
    try testing.expect(fs.fonts().len > 0);
}

test "fc-match" {
    const testing = std.testing;

    var cfg = fontconfig.initLoadConfigAndFonts();
    defer cfg.destroy();

    var pat = fontconfig.Pattern.create();
    errdefer pat.destroy();
    try testing.expect(cfg.substituteWithPat(pat, .pattern));
    pat.defaultSubstitute();

    const result = cfg.fontSort(pat, false, null);
    errdefer result.fs.destroy();

    var fs = fontconfig.FontSet.create();
    defer fs.destroy();
    defer for (fs.fonts()) |font| font.destroy();

    {
        const fonts = result.fs.fonts();
        try testing.expect(fonts.len > 0);
        for (fonts) |font| {
            const pat_prep = try cfg.fontRenderPrepare(pat, font);
            try testing.expect(fs.add(pat_prep));
        }
        result.fs.destroy();
        pat.destroy();
    }

    {
        for (fs.fonts()) |font| {
            var it = font.objectIterator();
            while (it.next()) {
                try testing.expect(it.object().len > 0);
                try testing.expect(it.valueLen() > 0);
                var value_it = it.valueIterator();
                while (value_it.next()) |entry| {
                    try testing.expect(entry.value != .unknown);
                }
            }
        }
    }
}
