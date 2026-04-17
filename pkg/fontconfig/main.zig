const initpkg = @import("init.zig");
const char_set = @import("char_set.zig");
const common = @import("common.zig");
const config = @import("config.zig");
const errorpkg = @import("error.zig");
const font_set = @import("font_set.zig");
const lang_set = @import("lang_set.zig");
const matrix = @import("matrix.zig");
const object_set = @import("object_set.zig");
const pattern = @import("pattern.zig");
const range = @import("range.zig");
const value = @import("value.zig");

pub const c = @import("c");
pub const init = initpkg.init;
pub const fini = initpkg.fini;
pub const initLoadConfig = initpkg.initLoadConfig;
pub const initLoadConfigAndFonts = initpkg.initLoadConfigAndFonts;
pub const version = initpkg.version;
pub const CharSet = char_set.CharSet;
pub const Weight = common.Weight;
pub const Slant = common.Slant;
pub const Spacing = common.Spacing;
pub const Property = common.Property;
pub const Result = common.Result;
pub const MatchKind = common.MatchKind;
pub const Config = config.Config;
pub const Error = errorpkg.Error;
pub const FontSet = font_set.FontSet;
pub const LangSet = lang_set.LangSet;
pub const Matrix = matrix.Matrix;
pub const ObjectSet = object_set.ObjectSet;
pub const Pattern = pattern.Pattern;
pub const Range = range.Range;
pub const Type = value.Type;
pub const Value = value.Value;
pub const ValueBinding = value.ValueBinding;

test {
    @import("std").testing.refAllDecls(@This());
}

test {
    _ = @import("test.zig");
}
