const font = @import("text/font.zig");
const font_collection = @import("text/font_collection.zig");
const font_descriptor = @import("text/font_descriptor.zig");
const font_manager = @import("text/font_manager.zig");
const frame = @import("text/frame.zig");
const framesetter = @import("text/framesetter.zig");
const typesetter = @import("text/typesetter.zig");
const line = @import("text/line.zig");
const paragraph_style = @import("text/paragraph_style.zig");
const run = @import("text/run.zig");
const stylized_strings = @import("text/stylized_strings.zig");

pub const c = @import("text/c.zig").c;
pub const Font = font.Font;
pub const FontTableTag = font.FontTableTag;
pub const FontCollection = font_collection.FontCollection;
pub const FontDescriptor = font_descriptor.FontDescriptor;
pub const FontAttribute = font_descriptor.FontAttribute;
pub const FontTraitKey = font_descriptor.FontTraitKey;
pub const FontVariationAxisKey = font_descriptor.FontVariationAxisKey;
pub const FontSymbolicTraits = font_descriptor.FontSymbolicTraits;
pub const createFontDescriptorsFromURL = font_manager.createFontDescriptorsFromURL;
pub const createFontDescriptorsFromData = font_manager.createFontDescriptorsFromData;
pub const createFontDescriptorFromData = font_manager.createFontDescriptorFromData;
pub const Frame = frame.Frame;
pub const Framesetter = framesetter.Framesetter;
pub const Typesetter = typesetter.Typesetter;
pub const Line = line.Line;
pub const ParagraphStyle = paragraph_style.ParagraphStyle;
pub const ParagraphStyleSetting = paragraph_style.ParagraphStyleSetting;
pub const ParagraphStyleSpecifier = paragraph_style.ParagraphStyleSpecifier;
pub const WritingDirection = paragraph_style.WritingDirection;
pub const Run = run.Run;
pub const StringAttribute = stylized_strings.StringAttribute;

test {
    @import("std").testing.refAllDecls(@This());
}
