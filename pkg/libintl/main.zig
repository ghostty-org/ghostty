const std = @import("std");
const c = @import("c.zig");

pub const Category = enum(c_int) {
    messages = c.locale.LC_MESSAGES,
    collate = c.locale.LC_COLLATE,
    ctype = c.locale.LC_CTYPE,
    monetary = c.locale.LC_MONETARY,
    numeric = c.locale.LC_NUMERIC,
    time = c.locale.LC_TIME,
    _,
};

pub const Query = struct {
    msg: [:0]const u8,
    plural: ?struct {
        msg: [:0]const u8,
        number: c_ulong,
    } = null,
    domain: ?[:0]const u8 = null,
    category: ?Category = null,
};

pub const _ = gettext;

pub fn gettext(comptime msg: [:0]const u8) [:0]const u8 {
    return std.mem.span(c.gettext(msg));
}
pub fn dgettext(comptime msg: [:0]const u8, domain: [:0]const u8) [:0]const u8 {
    return std.mem.span(c.dgettext(domain, msg));
}
pub fn dcgettext(comptime msg: [:0]const u8, domain: [:0]const u8, category: Category) [:0]const u8 {
    return std.mem.span(c.dcgettext(domain, msg, category));
}
pub fn ngettext(
    comptime msg: [:0]const u8,
    comptime msg_plural: [:0]const u8,
    number: c_ulong,
) [:0]const u8 {
    return std.mem.span(c.ngettext(msg, msg_plural, number));
}
pub fn dngettext(
    comptime msg: [:0]const u8,
    comptime msg_plural: [:0]const u8,
    number: c_ulong,
    domain: [:0]const u8,
) [:0]const u8 {
    return std.mem.span(c.dngettext(domain, msg, msg_plural, number));
}
pub fn dcngettext(
    comptime msg: [:0]const u8,
    comptime msg_plural: [:0]const u8,
    number: c_ulong,
    domain: [:0]const u8,
    category: Category,
) [:0]const u8 {
    return std.mem.span(c.dcngettext(
        domain,
        msg,
        msg_plural,
        number,
        category,
    ));
}

pub fn bindTextDomain(domain: [:0]const u8, dir: [:0]const u8) std.mem.Allocator.Error!void {
    // ENOMEM is the only possible error
    if (c.bindtextdomain(domain, dir) == null) return error.OutOfMemory;
}
pub fn setTextDomain(domain: [:0]const u8) std.mem.Allocator.Error!void {
    // ENOMEM is the only possible error
    if (c.textdomain(domain) == null) return error.OutOfMemory;
}
