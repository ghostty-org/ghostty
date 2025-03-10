const std = @import("std");
const Config = @import("Config.zig");

const Template = struct {
    const header =
        \\%YAML 1.2
        \\---
        \\# See http://www.sublimetext.com/docs/syntax.html
        \\name: Ghostty Config
        \\file_extensions:
        \\  - ghostty
        \\scope: source.ghostty
        \\
        \\contexts:
        \\  main:
        \\    # Comments
        \\    - match: '^\s*#.*$'
        \\      scope: comment.line.number-sign.ghostty
        \\
        \\    # Keywords
        \\    - match: '\b(
    ;
    const footer =
        \\)\b'
        \\      scope: keyword.other.ghostty
        \\
    ;
};

/// Check if a field is internal (starts with underscore)
fn isInternal(name: []const u8) bool {
    return name.len > 0 and name[0] == '_';
}

/// Generate keywords from Config fields
fn generateKeywords() []const u8 {
    @setEvalBranchQuota(5000);
    var keywords: []const u8 = "";
    const config_fields = @typeInfo(Config).@"struct".fields;

    for (config_fields) |field| {
        if (isInternal(field.name)) continue;
        if (keywords.len > 0) keywords = keywords ++ "|";
        keywords = keywords ++ field.name;
    }

    return keywords;
}

/// Complete Sublime syntax file content
pub const syntax = Template.header ++ generateKeywords() ++ Template.footer;
