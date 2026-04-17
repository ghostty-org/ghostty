const foundation = @import("../foundation.zig");
const c = @import("c");

pub const StringAttribute = enum {
    font,
    paragraph_style,
    writing_direction,

    pub fn key(self: StringAttribute) *foundation.String {
        return @ptrFromInt(@intFromPtr(switch (self) {
            .font => c.kCTFontAttributeName,
            .paragraph_style => c.kCTParagraphStyleAttributeName,
            .writing_direction => c.kCTWritingDirectionAttributeName,
        }));
    }
};
