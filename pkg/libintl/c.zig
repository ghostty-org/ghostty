pub const locale = @cImport(@cInclude("locale.h"));

pub extern fn gettext(
    msgid: [*:0]const u8,
) [*:0]const u8;
pub extern fn dgettext(
    domainname: [*:0]const u8,
    msgid: [*:0]const u8,
) [*:0]const u8;
pub extern fn dcgettext(
    domainname: [*:0]const u8,
    msgid: [*:0]const u8,
    category: c_int,
) [*:0]const u8;

pub extern fn ngettext(
    msgid1: [*:0]const u8,
    msgid2: [*:0]const u8,
    n: c_ulong,
) [*:0]const u8;
pub extern fn dngettext(
    domainname: [*:0]const u8,
    msgid1: [*:0]const u8,
    msgid2: [*:0]const u8,
    n: c_ulong,
) [*:0]const u8;
pub extern fn dcngettext(
    domainname: [*:0]const u8,
    msgid1: [*:0]const u8,
    msgid2: [*:0]const u8,
    n: c_ulong,
    category: c_int,
) [*:0]const u8;

pub extern fn bindtextdomain(
    domainname: [*:0]const u8,
    dirname: [*:0]const u8,
) ?[*]const u8;
pub extern fn textdomain(
    domainname: ?[*:0]const u8,
) ?[*]const u8;
