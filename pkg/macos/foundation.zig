const array = @import("foundation/array.zig");
const attributed_string = @import("foundation/attributed_string.zig");
const base = @import("foundation/base.zig");
const character_set = @import("foundation/character_set.zig");
const data = @import("foundation/data.zig");
const dictionary = @import("foundation/dictionary.zig");
const number = @import("foundation/number.zig");
const string = @import("foundation/string.zig");
const typepkg = @import("foundation/type.zig");
const url = @import("foundation/url.zig");

pub const c = @import("foundation/c.zig").c;
pub const Array = array.Array;
pub const MutableArray = array.MutableArray;
pub const AttributedString = attributed_string.AttributedString;
pub const MutableAttributedString = attributed_string.MutableAttributedString;
pub const ComparisonResult = base.ComparisonResult;
pub const Range = base.Range;
pub const FourCharCode = base.FourCharCode;
pub const CharacterSet = character_set.CharacterSet;
pub const Data = data.Data;
pub const Dictionary = dictionary.Dictionary;
pub const MutableDictionary = dictionary.MutableDictionary;
pub const Number = number.Number;
pub const String = string.String;
pub const MutableString = string.MutableString;
pub const StringComparison = string.StringComparison;
pub const StringEncoding = string.StringEncoding;
pub const stringGetSurrogatePairForLongCharacter = string.stringGetSurrogatePairForLongCharacter;
pub const URL = url.URL;
pub const URLPathStyle = url.URLPathStyle;
pub const CFRelease = typepkg.CFRelease;
pub const CFRetain = typepkg.CFRetain;

test {
    @import("std").testing.refAllDecls(@This());
}
