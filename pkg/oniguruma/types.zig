const std = @import("std");
const c = @import("c.zig");

pub const Encoding = opaque {
    pub const ascii: *Encoding = @ptrCast(c.ONIG_ENCODING_ASCII);
    pub const iso_8859_1: *Encoding = @ptrCast(c.ONIG_ENCODING_ISO_8859_1);
    pub const iso_8859_2: *Encoding = @ptrCast(c.ONIG_ENCODING_ISO_8859_2);
    pub const iso_8859_3: *Encoding = @ptrCast(c.ONIG_ENCODING_ISO_8859_3);
    pub const iso_8859_4: *Encoding = @ptrCast(c.ONIG_ENCODING_ISO_8859_4);
    pub const iso_8859_5: *Encoding = @ptrCast(c.ONIG_ENCODING_ISO_8859_5);
    pub const iso_8859_6: *Encoding = @ptrCast(c.ONIG_ENCODING_ISO_8859_6);
    pub const iso_8859_7: *Encoding = @ptrCast(c.ONIG_ENCODING_ISO_8859_7);
    pub const iso_8859_8: *Encoding = @ptrCast(c.ONIG_ENCODING_ISO_8859_8);
    pub const iso_8859_9: *Encoding = @ptrCast(c.ONIG_ENCODING_ISO_8859_9);
    pub const iso_8859_10: *Encoding = @ptrCast(c.ONIG_ENCODING_ISO_8859_10);
    pub const iso_8859_11: *Encoding = @ptrCast(c.ONIG_ENCODING_ISO_8859_11);
    pub const iso_8859_13: *Encoding = @ptrCast(c.ONIG_ENCODING_ISO_8859_13);
    pub const iso_8859_14: *Encoding = @ptrCast(c.ONIG_ENCODING_ISO_8859_14);
    pub const iso_8859_15: *Encoding = @ptrCast(c.ONIG_ENCODING_ISO_8859_15);
    pub const iso_8859_16: *Encoding = @ptrCast(c.ONIG_ENCODING_ISO_8859_16);
    pub const utf8: *Encoding = @ptrCast(c.ONIG_ENCODING_UTF8);
    pub const utf16_be: *Encoding = @ptrCast(c.ONIG_ENCODING_UTF16_BE);
    pub const utf16_le: *Encoding = @ptrCast(c.ONIG_ENCODING_UTF16_LE);
    pub const utf32_be: *Encoding = @ptrCast(c.ONIG_ENCODING_UTF32_BE);
    pub const utf32_le: *Encoding = @ptrCast(c.ONIG_ENCODING_UTF32_LE);
    pub const euc_jp: *Encoding = @ptrCast(c.ONIG_ENCODING_EUC_JP);
    pub const euc_tw: *Encoding = @ptrCast(c.ONIG_ENCODING_EUC_TW);
    pub const euc_kr: *Encoding = @ptrCast(c.ONIG_ENCODING_EUC_KR);
    pub const euc_cn: *Encoding = @ptrCast(c.ONIG_ENCODING_EUC_CN);
    pub const sjis: *Encoding = @ptrCast(c.ONIG_ENCODING_SJIS);
    pub const koi8: *Encoding = @ptrCast(c.ONIG_ENCODING_KOI8);
    pub const koi8_r: *Encoding = @ptrCast(c.ONIG_ENCODING_KOI8_R);
    pub const cp1251: *Encoding = @ptrCast(c.ONIG_ENCODING_CP1251);
    pub const big5: *Encoding = @ptrCast(c.ONIG_ENCODING_BIG5);
    pub const gb18030: *Encoding = @ptrCast(c.ONIG_ENCODING_GB18030);
};

pub const Syntax = opaque {
    pub const default: *Syntax = @ptrCast(c.ONIG_SYNTAX_ONIGURUMA);
    pub const asis: *Syntax = @ptrCast(c.ONIG_SYNTAX_ASIS);
    pub const posix_basic: *Syntax = @ptrCast(c.ONIG_SYNTAX_POSIX_BASIC);
    pub const posix_extended: *Syntax = @ptrCast(c.ONIG_SYNTAX_POSIX_EXTENDED);
    pub const emacs: *Syntax = @ptrCast(c.ONIG_SYNTAX_EMACS);
    pub const grep: *Syntax = @ptrCast(c.ONIG_SYNTAX_GREP);
    pub const gnu_regex: *Syntax = @ptrCast(c.ONIG_SYNTAX_GNU_REGEX);
    pub const java: *Syntax = @ptrCast(c.ONIG_SYNTAX_JAVA);
    pub const perl: *Syntax = @ptrCast(c.ONIG_SYNTAX_PERL);
    pub const perl_ng: *Syntax = @ptrCast(c.ONIG_SYNTAX_PERL_NG);
    pub const ruby: *Syntax = @ptrCast(c.ONIG_SYNTAX_RUBY);
    pub const oniguruma: *Syntax = @ptrCast(c.ONIG_SYNTAX_ONIGURUMA);
};

pub const Option = packed struct(c_uint) {
    ignorecase: bool = false,
    extend: bool = false,
    multiline: bool = false,
    singleline: bool = false,
    find_longest: bool = false,
    find_not_empty: bool = false,
    negate_singleline: bool = false,
    dont_capture_group: bool = false,
    capture_group: bool = false,
    // search time
    notbol: bool = false,
    noteol: bool = false,
    posix_region: bool = false,
    check_validity_of_string: bool = false,
    // compile time
    ignorecase_is_ascii: bool = false,
    word_is_ascii: bool = false,
    digit_is_ascii: bool = false,
    space_is_ascii: bool = false,
    posix_is_ascii: bool = false,
    text_segment_extended_grapheme_cluster: bool = false,
    text_segment_word: bool = false,
    // search time
    not_begin_string: bool = false,
    not_end_string: bool = false,
    not_begin_position: bool = false,
    callback_each_match: bool = false,
    match_whole_string: bool = false,

    _padding: u7 = 0,

    pub fn int(self: Option) c_uint {
        return @bitCast(self);
    }

    test "order" {
        const testing = std.testing;
        const opt: Option = .{ .extend = true };
        try testing.expectEqual(c.ONIG_OPTION_EXTEND, opt.int());
    }
};

test {}
