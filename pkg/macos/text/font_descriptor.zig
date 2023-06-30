const std = @import("std");
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const c = @import("c.zig");

pub const FontDescriptor = opaque {
    pub fn createWithNameAndSize(name: *foundation.String, size: f64) Allocator.Error!*FontDescriptor {
        return @as(
            ?*FontDescriptor,
            @ptrFromInt(@intFromPtr(c.CTFontDescriptorCreateWithNameAndSize(@ptrCast(name), size))),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn createWithAttributes(dict: *foundation.Dictionary) Allocator.Error!*FontDescriptor {
        return @as(
            ?*FontDescriptor,
            @ptrFromInt(@intFromPtr(c.CTFontDescriptorCreateWithAttributes(@ptrCast(dict)))),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn createCopyWithAttributes(
        original: *FontDescriptor,
        dict: *foundation.Dictionary,
    ) Allocator.Error!*FontDescriptor {
        return @as(
            ?*FontDescriptor,
            @ptrFromInt(@intFromPtr(c.CTFontDescriptorCreateCopyWithAttributes(
                @ptrCast(original),
                @ptrCast(dict),
            ))),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn release(self: *FontDescriptor) void {
        c.CFRelease(self);
    }

    pub fn copyAttribute(self: *FontDescriptor, comptime attr: FontAttribute) attr.Value() {
        return @ptrFromInt(@intFromPtr(c.CTFontDescriptorCopyAttribute(
            @ptrCast(self),
            @ptrCast(attr.key()),
        )));
    }

    pub fn copyAttributes(self: *FontDescriptor) *foundation.Dictionary {
        return @ptrFromInt(@intFromPtr(c.CTFontDescriptorCopyAttributes(
            @ptrCast(self),
        )));
    }
};

pub const FontAttribute = enum {
    url,
    name,
    display_name,
    family_name,
    style_name,
    traits,
    variation,
    size,
    matrix,
    cascade_list,
    character_set,
    languages,
    baseline_adjust,
    macintosh_encodings,
    features,
    feature_settings,
    fixed_advance,
    orientation,
    format,
    registration_scope,
    priority,
    enabled,
    downloadable,
    downloaded,

    pub fn key(self: FontAttribute) *foundation.String {
        return @as(*foundation.String, @ptrFromInt(@intFromPtr(switch (self) {
            .url => c.kCTFontURLAttribute,
            .name => c.kCTFontNameAttribute,
            .display_name => c.kCTFontDisplayNameAttribute,
            .family_name => c.kCTFontFamilyNameAttribute,
            .style_name => c.kCTFontStyleNameAttribute,
            .traits => c.kCTFontTraitsAttribute,
            .variation => c.kCTFontVariationAttribute,
            .size => c.kCTFontSizeAttribute,
            .matrix => c.kCTFontMatrixAttribute,
            .cascade_list => c.kCTFontCascadeListAttribute,
            .character_set => c.kCTFontCharacterSetAttribute,
            .languages => c.kCTFontLanguagesAttribute,
            .baseline_adjust => c.kCTFontBaselineAdjustAttribute,
            .macintosh_encodings => c.kCTFontMacintoshEncodingsAttribute,
            .features => c.kCTFontFeaturesAttribute,
            .feature_settings => c.kCTFontFeatureSettingsAttribute,
            .fixed_advance => c.kCTFontFixedAdvanceAttribute,
            .orientation => c.kCTFontOrientationAttribute,
            .format => c.kCTFontFormatAttribute,
            .registration_scope => c.kCTFontRegistrationScopeAttribute,
            .priority => c.kCTFontPriorityAttribute,
            .enabled => c.kCTFontEnabledAttribute,
            .downloadable => c.kCTFontDownloadableAttribute,
            .downloaded => c.kCTFontDownloadedAttribute,
        })));
    }

    pub fn Value(comptime self: FontAttribute) type {
        return switch (self) {
            .url => *foundation.URL,
            .name => *foundation.String,
            .display_name => *foundation.String,
            .family_name => *foundation.String,
            .style_name => *foundation.String,
            .traits => *foundation.Dictionary,
            .variation => *foundation.Dictionary,
            .size => *foundation.Number,
            .matrix => *anyopaque, // CFDataRef
            .cascade_list => *foundation.Array,
            .character_set => *anyopaque, // CFCharacterSetRef
            .languages => *foundation.Array,
            .baseline_adjust => *foundation.Number,
            .macintosh_encodings => *foundation.Number,
            .features => *foundation.Array,
            .feature_settings => *foundation.Array,
            .fixed_advance => *foundation.Number,
            .orientation => *foundation.Number,
            .format => *foundation.Number,
            .registration_scope => *foundation.Number,
            .priority => *foundation.Number,
            .enabled => *foundation.Number,
            .downloadable => *anyopaque, // CFBoolean
            .downloaded => *anyopaque, // CFBoolean
        };
    }
};

pub const FontTraitKey = enum {
    symbolic,
    weight,
    width,
    slant,

    pub fn key(self: FontTraitKey) *foundation.String {
        return @as(*foundation.String, @ptrFromInt(@intFromPtr(switch (self) {
            .symbolic => c.kCTFontSymbolicTrait,
            .weight => c.kCTFontWeightTrait,
            .width => c.kCTFontWidthTrait,
            .slant => c.kCTFontSlantTrait,
        })));
    }

    pub fn Value(self: FontTraitKey) type {
        return switch (self) {
            .symbolic => *foundation.Number,
            .weight => *foundation.Number,
            .width => *foundation.Number,
            .slant => *foundation.Number,
        };
    }
};

pub const FontSymbolicTraits = packed struct {
    italic: bool = false,
    bold: bool = false,
    _unused1: u3 = 0,
    expanded: bool = false,
    condensed: bool = false,
    _unused2: u3 = 0,
    monospace: bool = false,
    vertical: bool = false,
    ui_optimized: bool = false,
    color_glyphs: bool = false,
    composite: bool = false,
    _padding: u17 = 0,

    pub fn init(num: *foundation.Number) FontSymbolicTraits {
        var raw: i32 = undefined;
        _ = num.getValue(.sint32, &raw);
        return @as(FontSymbolicTraits, @bitCast(raw));
    }

    pub fn cval(self: FontSymbolicTraits) c.CTFontSymbolicTraits {
        return @as(c.CTFontSymbolicTraits, @bitCast(self));
    }

    test {
        try std.testing.expectEqual(
            @bitSizeOf(c.CTFontSymbolicTraits),
            @bitSizeOf(FontSymbolicTraits),
        );
    }

    test "bitcast" {
        const actual: c.CTFontSymbolicTraits = c.kCTFontTraitMonoSpace | c.kCTFontTraitExpanded;
        const expected: FontSymbolicTraits = .{
            .monospace = true,
            .expanded = true,
        };

        try std.testing.expectEqual(actual, @as(c.CTFontSymbolicTraits, @bitCast(expected)));
    }

    test "number" {
        const raw: i32 = c.kCTFontTraitMonoSpace | c.kCTFontTraitExpanded;
        const num = try foundation.Number.create(.sint32, &raw);
        defer num.release();

        const expected: FontSymbolicTraits = .{ .monospace = true, .expanded = true };
        const actual = FontSymbolicTraits.init(num);
        try std.testing.expect(std.meta.eql(expected, actual));
    }
};

test {
    @import("std").testing.refAllDecls(@This());
}

test "descriptor" {
    const testing = std.testing;

    const name = try foundation.String.createWithBytes("foo", .utf8, false);
    defer name.release();

    const v = try FontDescriptor.createWithNameAndSize(name, 12);
    defer v.release();

    const copy_name = v.copyAttribute(.name);
    defer copy_name.release();

    {
        var buf: [128]u8 = undefined;
        const cstr = copy_name.cstring(&buf, .utf8).?;
        try testing.expectEqualStrings("foo", cstr);
    }
}
