const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.font_shaper);

/// Represents an OpenType font feature setting, which consists of a tag and
/// a numeric parameter >= 0. Most features are boolean, so only parameters
/// of 0 and 1 make sense for them, but some (e.g. 'cv01'..'cv99') can take
/// parameters to choose between multiple variants of a given character or
/// characters.
///
/// Ref:
/// - https://learn.microsoft.com/en-us/typography/opentype/spec/chapter2#features-and-lookups
/// - https://harfbuzz.github.io/shaping-opentype-features.html
pub const Feature = struct {
    tag: [4]u8,
    value: u32,

    pub fn fromString(str: []const u8) ?Feature {
        var fbs = std.io.fixedBufferStream(str);
        const reader = fbs.reader();
        return .fromReader(reader);
    }

    /// Parse a single font feature setting from a std.io.Reader, with a version
    /// of the syntax of HarfBuzz's font feature strings. Stops at end of stream
    /// or when a ',' is encountered.
    ///
    /// This parsing aims to be as error-tolerant as possible while avoiding any
    /// assumptions in ambiguous scenarios. When invalid syntax is encountered,
    /// the reader is advanced to the next boundary (end-of-stream or ',') so
    /// that further features may be read.
    ///
    /// Ref: https://harfbuzz.github.io/harfbuzz-hb-common.html#hb-feature-from-string
    pub fn fromReader(reader: anytype) ?Feature {
        var tag_buf: [4]u8 = undefined;
        var tag: []u8 = tag_buf[0..0];
        var value: ?u32 = null;

        state: switch ((enum {
            /// Initial state.
            start,
            /// Parsing the tag.
            tag,
            /// In the space between the tag and the value.
            space,
            /// Parsing an integer parameter directly in to `value`.
            int,
            /// Parsing a boolean keyword parameter ("on"/"off").
            bool,
            /// Encountered an unrecoverable syntax error, advancing to boundary.
            err,
            /// Done parsing feature, skip whitespace until end.
            done,
        }).start) {
            // If we're done then we skip whitespace until we see a ','.
            .done => while (true) switch (reader.readByte() catch ',') {
                ' ', '\t' => continue,
                ',' => break,
                // If we see something other than whitespace or a ','
                // then this is an error since the intent is unclear.
                else => continue :state .err,
            },

            // If we're fast-forwarding from an error we just wanna
            // stop at the first boundary and ignore all other bytes.
            .err => {
                reader.skipUntilDelimiterOrEof(',') catch {};
                return null;
            },

            .start => while (true) switch (reader.readByte() catch ',') {
                // Ignore leading whitespace.
                ' ', '\t' => continue,
                // Empty feature string.
                ',' => return null,
                // '+' prefix to explicitly enable feature.
                '+' => {
                    value = 1;
                    continue :state .tag;
                },
                // '-' prefix to explicitly disable feature.
                '-' => {
                    value = 0;
                    continue :state .tag;
                },
                // Quote mark introducing a tag.
                '"', '\'' => {
                    continue :state .tag;
                },
                // First letter of tag.
                else => |byte| {
                    tag.len = 1;
                    tag[0] = byte;
                    continue :state .tag;
                },
            },

            .tag => while (true) switch (reader.readByte() catch ',') {
                // If the tag is interrupted by a comma it's invalid.
                ',' => return null,
                // Ignore quote marks. This does technically ignore cases like
                // "'k'e'r'n' = 0", but it's unambiguous so if someone really
                // wants to do that in their config then... sure why not.
                '"', '\'' => continue,
                // In all other cases we add the byte to our tag.
                else => |byte| {
                    tag.len += 1;
                    tag[tag.len - 1] = byte;
                    if (tag.len == 4) continue :state .space;
                },
            },

            .space => while (true) switch (reader.readByte() catch ',') {
                ' ', '\t' => continue,
                // Ignore quote marks since we might have a
                // closing quote from the tag still ahead.
                '"', '\'' => continue,
                // Allow an '=' (which we can safely ignore)
                // only if we don't already have a value due
                // to a '+' or '-' prefix.
                '=' => if (value != null) continue :state .err,
                ',' => {
                    // Specifying only a tag turns a feature on.
                    if (value == null) value = 1;
                    break;
                },
                '0'...'9' => |byte| {
                    // If we already have value because of a
                    // '+' or '-' prefix then this is an error.
                    if (value != null) continue :state .err;
                    value = byte - '0';
                    continue :state .int;
                },
                'o', 'O' => {
                    // If we already have value because of a
                    // '+' or '-' prefix then this is an error.
                    if (value != null) continue :state .err;
                    continue :state .bool;
                },
                else => continue :state .err,
            },

            .int => while (true) switch (reader.readByte() catch ',') {
                ',' => break,
                '0'...'9' => |byte| {
                    // If our value gets too big while
                    // parsing we consider it an error.
                    value = std.math.mul(u32, value.?, 10) catch {
                        continue :state .err;
                    };
                    value.? += byte - '0';
                },
                else => continue :state .err,
            },

            .bool => while (true) switch (reader.readByte() catch ',') {
                ',' => return null,
                'n', 'N' => {
                    // "ofn"
                    if (value != null) {
                        assert(value == 0);
                        continue :state .err;
                    }
                    value = 1;
                    continue :state .done;
                },
                'f', 'F' => {
                    // To make sure we consume two 'f's.
                    if (value == null) {
                        value = 0;
                    } else {
                        assert(value == 0);
                        continue :state .done;
                    }
                },
                else => continue :state .err,
            },
        }

        assert(value != null);
        assert(tag.len == 4);

        return .{
            .tag = tag_buf,
            .value = value.?,
        };
    }

    /// Serialize this feature to the provided buffer.
    /// The string that this produces should be valid to parse.
    pub fn toString(self: *const Feature, buf: []u8) !void {
        var fbs = std.io.fixedBufferStream(buf);
        try self.format("", .{}, fbs.writer());
    }

    /// Formatter for logging
    pub fn format(
        self: Feature,
        comptime layout: []const u8,
        opts: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = layout;
        _ = opts;
        if (self.value <= 1) {
            // Format boolean options as "+tag" for on and "-tag" for off.
            try std.fmt.format(writer, "{c}{s}", .{
                "-+"[self.value],
                self.tag,
            });
        } else {
            // Format non-boolean tags as "tag=value".
            try std.fmt.format(writer, "{s}={d}", .{
                self.tag,
                self.value,
            });
        }
    }
};

/// A list of font feature settings (see `Feature` for more documentation).
pub const FeatureList = struct {
    features: std.ArrayListUnmanaged(Feature) = .{},

    pub fn deinit(self: *FeatureList, alloc: Allocator) void {
        self.features.deinit(alloc);
    }

    /// Parse a comma separated list of features.
    /// See `Feature.fromReader` for more docs.
    pub fn fromString(alloc: Allocator, str: []const u8) !FeatureList {
        var self: FeatureList = .{};
        try self.appendFromString(alloc, str);
        return self;
    }

    /// Append features to this list from a string with a comma separated list.
    /// See `Feature.fromReader` for more docs.
    pub fn appendFromString(
        self: *FeatureList,
        alloc: Allocator,
        str: []const u8,
    ) !void {
        var fbs = std.io.fixedBufferStream(str);
        const reader = fbs.reader();
        while (fbs.pos < fbs.buffer.len) {
            const i = fbs.pos;
            if (Feature.fromReader(reader)) |feature| {
                try self.features.append(alloc, feature);
            } else log.warn(
                "failed to parse font feature setting: \"{s}\"",
                .{fbs.buffer[i..fbs.pos]},
            );
        }
    }

    /// Formatter for logging
    pub fn format(
        self: FeatureList,
        comptime layout: []const u8,
        opts: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        for (self.features.items, 0..) |feature, i| {
            try feature.format(layout, opts, writer);
            if (i != std.features.items.len - 1) try writer.writeAll(", ");
        }
        if (self.value <= 1) {
            // Format boolean options as "+tag" for on and "-tag" for off.
            try std.fmt.format(writer, "{c}{s}", .{
                "-+"[self.value],
                self.tag,
            });
        } else {
            // Format non-boolean tags as "tag=value".
            try std.fmt.format(writer, "{s}={d}", .{
                self.tag,
                self.value,
            });
        }
    }
};

/// These features are hardcoded to always be on by default. Users
/// can turn them off by setting the features to "-liga" for example.
pub const default_features = [_]Feature{
    .{ .tag = "dlig".*, .value = 1 },
    .{ .tag = "liga".*, .value = 1 },
};

test "Feature.fromString" {
    const testing = std.testing;

    // This is not *complete* coverage of every possible
    // combination of syntax, but it covers quite a few.

    // Boolean settings (on)
    const kern_on = Feature{ .tag = "kern".*, .value = 1 };
    try testing.expectEqual(kern_on, Feature.fromString("kern"));
    try testing.expectEqual(kern_on, Feature.fromString("kern, "));
    try testing.expectEqual(kern_on, Feature.fromString("kern on"));
    try testing.expectEqual(kern_on, Feature.fromString("kern on, "));
    try testing.expectEqual(kern_on, Feature.fromString("+kern"));
    try testing.expectEqual(kern_on, Feature.fromString("+kern, "));
    try testing.expectEqual(kern_on, Feature.fromString("\"kern\" = 1"));
    try testing.expectEqual(kern_on, Feature.fromString("\"kern\" = 1, "));

    // Boolean settings (off)
    const kern_off = Feature{ .tag = "kern".*, .value = 0 };
    try testing.expectEqual(kern_off, Feature.fromString("kern off"));
    try testing.expectEqual(kern_off, Feature.fromString("kern off, "));
    try testing.expectEqual(kern_off, Feature.fromString("-'kern'"));
    try testing.expectEqual(kern_off, Feature.fromString("-'kern', "));
    try testing.expectEqual(kern_off, Feature.fromString("\"kern\" = 0"));
    try testing.expectEqual(kern_off, Feature.fromString("\"kern\" = 0, "));

    // Non-boolean settings
    const aalt_2 = Feature{ .tag = "aalt".*, .value = 2 };
    try testing.expectEqual(aalt_2, Feature.fromString("aalt=2"));
    try testing.expectEqual(aalt_2, Feature.fromString("aalt=2, "));
    try testing.expectEqual(aalt_2, Feature.fromString("'aalt' 2"));
    try testing.expectEqual(aalt_2, Feature.fromString("'aalt' 2, "));

    // Various ambiguous/error cases which should be null
    try testing.expectEqual(null, Feature.fromString("aalt=2x")); // bad number
    try testing.expectEqual(null, Feature.fromString("toolong")); // tag too long
    try testing.expectEqual(null, Feature.fromString("sht")); // tag too short
    try testing.expectEqual(null, Feature.fromString("-kern 1")); // redundant/conflicting
    try testing.expectEqual(null, Feature.fromString("-kern on")); // redundant/conflicting
    try testing.expectEqual(null, Feature.fromString("aalt=o,")); // bad keyword
    try testing.expectEqual(null, Feature.fromString("aalt=ofn,")); // bad keyword
}

test "FeatureList.fromString" {
    const testing = std.testing;

    const str =
        "  kern, kern on , +kern, \"kern\"  = 1," ++ // Boolean settings (on)
        "kern    off, -'kern' , \"kern\"=0," ++ // Boolean settings (off)
        "aalt=2,  'aalt'\t2," ++ // Non-boolean settings
        "aalt=2x, toolong, sht, -kern 1, -kern on, aalt=o, aalt=ofn," ++ // Invalid cases
        "last"; // To ensure final element is included correctly.
    var feats = try FeatureList.fromString(testing.allocator, str);
    defer feats.deinit(testing.allocator);
    try testing.expectEqualSlices(
        Feature,
        &(.{Feature{ .tag = "kern".*, .value = 1 }} ** 4 ++
            .{Feature{ .tag = "kern".*, .value = 0 }} ** 3 ++
            .{Feature{ .tag = "aalt".*, .value = 2 }} ** 2 ++
            .{Feature{ .tag = "last".*, .value = 1 }}),
        feats.features.items,
    );
}
