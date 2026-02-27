const std = @import("std");

/// Used to iterate over matching key/values in the metadata
pub fn Iterator(comptime Option: type, comptime isValidMetadataValue: fn ([]const u8) bool, comptime key: Option) type {
    return struct {
        const Self = @This();

        metadata: []const u8,
        pos: usize,

        pub fn init(metadata: []const u8) Self {
            return .{
                .metadata = metadata,
                .pos = 0,
            };
        }

        /// Return the value of the next matching key. The value is guaranteed
        /// to be `null` or a valid metadata value.
        pub fn next(self: *Self) ?[]const u8 {
            // bail if we are out of metadata
            if (self.pos >= self.metadata.len) return null;
            while (self.pos < self.metadata.len) {
                // skip any whitespace
                while (self.pos < self.metadata.len and std.ascii.isWhitespace(self.metadata[self.pos])) self.pos += 1;
                // bail if we are out of metadata
                if (self.pos >= self.metadata.len) return null;
                if (!std.mem.startsWith(u8, self.metadata[self.pos..], @tagName(key))) {
                    // this isn't the key we are looking for, skip to the next option, or bail if
                    // there is no next option
                    self.pos = std.mem.indexOfScalarPos(u8, self.metadata, self.pos, ':') orelse {
                        self.pos = self.metadata.len;
                        return null;
                    };
                    self.pos += 1;
                    continue;
                }
                // skip past the key
                self.pos += @tagName(key).len;
                // skip any whitespace
                while (self.pos < self.metadata.len and std.ascii.isWhitespace(self.metadata[self.pos])) self.pos += 1;
                // bail if we are out of metadata
                if (self.pos >= self.metadata.len) return null;
                // a valid option has an '='
                if (self.metadata[self.pos] != '=') return null;
                // the end of the value is bounded by a ':' or the end of the metadata
                const end = std.mem.indexOfScalarPos(u8, self.metadata, self.pos, ':') orelse self.metadata.len;
                const start = self.pos + 1;
                self.pos = end + 1;
                // strip any leading or trailing whitespace
                const value = std.mem.trim(u8, self.metadata[start..end], &std.ascii.whitespace);
                // if this is not a valid value, skip it
                if (!@call(.always_inline, isValidMetadataValue, .{value})) continue;
                // return the value
                return value;
            }
            // the key was not found
            return null;
        }
    };
}
