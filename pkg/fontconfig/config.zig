const std = @import("std");
const c = @import("c.zig");
const Error = @import("main.zig").Error;
const CharSet = @import("char_set.zig").CharSet;
const FontSet = @import("font_set.zig").FontSet;
const ObjectSet = @import("object_set.zig").ObjectSet;
const Pattern = @import("pattern.zig").Pattern;
const Result = @import("main.zig").Result;
const MatchKind = @import("main.zig").MatchKind;

pub const Config = opaque {
    pub fn destroy(self: *Config) void {
        c.FcConfigDestroy(@ptrCast(self));
    }

    pub fn fontList(self: *Config, pat: *Pattern, os: *ObjectSet) *FontSet {
        return @ptrCast(c.FcFontList(self.cval(), pat.cval(), os.cval()));
    }

    pub fn fontSort(
        self: *Config,
        pat: *Pattern,
        trim: bool,
        charset: ?[*]*CharSet,
    ) FontSortResult {
        var result: FontSortResult = undefined;
        result.fs = @ptrCast(c.FcFontSort(
            self.cval(),
            pat.cval(),
            if (trim) c.FcTrue else c.FcFalse,
            @ptrCast(charset),
            @ptrCast(&result.result),
        ));

        return result;
    }

    pub fn fontRenderPrepare(self: *Config, pat: *Pattern, font: *Pattern) Error!*Pattern {
        return @as(
            ?*Pattern,
            @ptrCast(c.FcFontRenderPrepare(self.cval(), pat.cval(), font.cval())),
        ) orelse Error.FontconfigFailed;
    }

    pub fn substituteWithPat(self: *Config, pat: *Pattern, kind: MatchKind) bool {
        return c.FcConfigSubstitute(
            self.cval(),
            pat.cval(),
            @intFromEnum(kind),
        ) == c.FcTrue;
    }

    pub inline fn cval(self: *Config) *c.struct__FcConfig {
        return @ptrCast(self);
    }
};

pub const FontSortResult = struct {
    result: Result,
    fs: *FontSet,
};
