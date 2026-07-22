const std = @import("std");
const snapshot = @import("main.zig");

test "version 0 envelope and PAGE header" {
    const envelope = snapshot.envelope;
    const page = snapshot.page;
    const record = snapshot.record;

    const page_header: page.Header = .{
        .columns = 80,
        .rows = 24,
        .style_count = 0,
        .hyperlink_count = 0,
        .style_capacity = 0,
        .hyperlink_capacity_bytes = 0,
        .grapheme_capacity_bytes = 0,
        .string_capacity_bytes = 0,
    };

    var checksum: record.Checksum = .init(.page, page.Header.len);
    try page_header.encode(checksum.writer());
    const record_header: record.Header = .{
        .tag = .page,
        .payload_len = page.Header.len,
        .crc32c = checksum.final(),
    };

    var buf: [
        envelope.encoded_len +
            record.Header.len +
            page.Header.len
    ]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try envelope.encode(&writer);
    try record_header.encode(&writer);
    try page_header.encode(&writer);

    const fixture =
        "BOOSNAP\x00\x00\x00" ++
        "\x03\x00\x14\x00\x00\x00\xf0\x90\x39\xdb" ++
        "\x50\x00\x18\x00\x00\x00\x00\x00" ++
        "\x00\x00\x00\x00\x00\x00\x00\x00" ++
        "\x00\x00\x00\x00";
    try std.testing.expectEqualStrings(fixture, writer.buffered());

    var reader: std.Io.Reader = .fixed(writer.buffered());
    try envelope.decode(&reader);
    const decoded_record = try record.Header.decode(&reader);
    var payload_reader: record.PayloadReader = undefined;
    var limited_buf: [1]u8 = undefined;
    var hashing_buf: [1]u8 = undefined;
    payload_reader.init(&reader, decoded_record, .{
        .limited = &limited_buf,
        .hashing = &hashing_buf,
    });
    const decoded_page = try page.Header.decode(payload_reader.reader());
    try payload_reader.finish();

    try std.testing.expectEqual(record_header, decoded_record);
    try std.testing.expectEqual(page_header, decoded_page);
    try std.testing.expectError(error.EndOfStream, reader.takeByte());
}
