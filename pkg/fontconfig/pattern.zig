const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig").c;
const Error = @import("main.zig").Error;
const ObjectSet = @import("main.zig").ObjectSet;
const Property = @import("main.zig").Property;
const Result = @import("main.zig").Result;
const Value = @import("main.zig").Value;
const ValueBinding = @import("main.zig").ValueBinding;
const Weight = @import("main.zig").Weight;

pub const Pattern = opaque {
    pub fn create() *Pattern {
        return @ptrCast(c.FcPatternCreate());
    }

    pub fn parse(str: [:0]const u8) *Pattern {
        return @ptrCast(c.FcNameParse(str.ptr));
    }

    pub fn destroy(self: *Pattern) void {
        c.FcPatternDestroy(self.cval());
    }

    pub fn defaultSubstitute(self: *Pattern) void {
        c.FcDefaultSubstitute(self.cval());
    }

    pub fn add(self: *Pattern, prop: Property, value: Value, append: bool) bool {
        return c.FcPatternAdd(
            self.cval(),
            prop.cval().ptr,
            value.cval(),
            if (append) c.FcTrue else c.FcFalse,
        ) == c.FcTrue;
    }

    pub fn get(self: *Pattern, prop: Property, id: u32) Error!Value {
        var val: c.struct__FcValue = undefined;
        try @as(Result, @enumFromInt(c.FcPatternGet(
            self.cval(),
            prop.cval().ptr,
            @intCast(id),
            &val,
        ))).toError();

        return .init(&val);
    }

    pub fn delete(self: *Pattern, prop: Property) bool {
        return c.FcPatternDel(self.cval(), prop.cval()) == c.FcTrue;
    }

    pub fn filter(self: *Pattern, os: *const ObjectSet) *Pattern {
        return @ptrCast(c.FcPatternFilter(self.cval(), os.cval()));
    }

    pub fn objectIterator(self: *Pattern) ObjectIterator {
        return .{ .pat = self.cval(), .iter = null };
    }

    pub fn print(self: *Pattern) void {
        c.FcPatternPrint(self.cval());
    }

    pub inline fn cval(self: *Pattern) *c.struct__FcPattern {
        return @ptrCast(self);
    }

    pub const ObjectIterator = struct {
        pat: *c.struct__FcPattern,
        iter: ?c.struct__FcPatternIter,

        /// Move to the next object, returns true if there is another
        /// object and false otherwise. If this is the first call, this
        /// will be the first object.
        pub fn next(self: *ObjectIterator) bool {
            // Null means our first iterator
            if (self.iter == null) {
                // If we have no objects, do not create iterator
                if (c.FcPatternObjectCount(self.pat) == 0) return false;

                var iter: c.struct__FcPatternIter = undefined;
                c.FcPatternIterStart(
                    self.pat,
                    &iter,
                );
                assert(c.FcPatternIterIsValid(self.pat, &iter) == c.FcTrue);
                self.iter = iter;

                // Return right away because the fontconfig iterator pattern
                // is do/while.
                return true;
            }

            return c.FcPatternIterNext(self.pat, @ptrCast(&self.iter)) == c.FcTrue;
        }

        pub fn object(self: *ObjectIterator) []const u8 {
            return std.mem.sliceTo(c.FcPatternIterGetObject(
                self.pat,
                &self.iter.?,
            ), 0);
        }

        pub fn valueLen(self: *ObjectIterator) usize {
            return @intCast(c.FcPatternIterValueCount(self.pat, &self.iter.?));
        }

        pub fn valueIterator(self: *ObjectIterator) ValueIterator {
            return .{
                .pat = self.pat,
                .iter = &self.iter.?,
                .max = c.FcPatternIterValueCount(self.pat, &self.iter.?),
            };
        }
    };

    pub const ValueIterator = struct {
        pat: *c.struct__FcPattern,
        iter: *c.struct__FcPatternIter,
        max: c_int,
        id: c_int = 0,

        pub const Entry = struct {
            result: Result,
            value: Value,
            binding: ValueBinding,
        };

        pub fn next(self: *ValueIterator) ?Entry {
            if (self.id >= self.max) return null;
            var value: c.struct__FcValue = undefined;
            var binding: c.FcValueBinding = undefined;
            const result = c.FcPatternIterGetValue(self.pat, self.iter, self.id, &value, &binding);
            self.id += 1;

            return Entry{
                .result = @enumFromInt(result),
                .binding = @enumFromInt(binding),
                .value = .init(&value),
            };
        }
    };
};

test "create" {
    const testing = std.testing;

    var pat = Pattern.create();
    defer pat.destroy();

    try testing.expect(pat.add(.family, .{ .string = "monospace" }, false));
    try testing.expect(pat.add(.weight, .{ .integer = @intFromEnum(Weight.bold) }, false));

    {
        const val = try pat.get(.family, 0);
        try testing.expect(val == .string);
        try testing.expectEqualStrings("monospace", val.string);
    }
}

test "name parse" {
    var pat = Pattern.parse(":monospace");
    defer pat.destroy();

    pat.defaultSubstitute();
}
