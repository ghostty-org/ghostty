//! Complete terminal snapshot encoding and restoration.

const std = @import("std");
const build_options = @import("terminal_options");
const Allocator = std.mem.Allocator;
const checkpoint = @import("checkpoint.zig");
const envelope = @import("envelope.zig");
const test_fixture = @import("fixture.zig");
const history = @import("history.zig");
const record = @import("record.zig");
const screen = @import("screen.zig");
const terminal = @import("terminal.zig");
const Terminal = @import("../Terminal.zig");
const terminal_kitty = @import("../kitty.zig");
const TerminalPageList = @import("../PageList.zig");
const TerminalScreen = @import("../Screen.zig");
const TerminalScreenKey = @import("../ScreenSet.zig").Key;

const test_complete_fixture = test_fixture.parse(
    @embedFile("testdata/complete-v1.hex"),
);

/// Errors possible while encoding one complete terminal snapshot.
pub const EncodeError = terminal.EncodeError ||
    screen.EncodeError ||
    history.EncodeError ||
    checkpoint.EncodeError;

/// Encode one complete terminal snapshot.
///
/// Encoding starts at the destination's current position. Only one record
/// payload is buffered at a time; completed records stream immediately. On
/// failure, the destination may contain a snapshot prefix without its required
/// checkpoints, and an output failure may have written part of a record.
pub fn encode(
    alloc: Allocator,
    destination: *std.Io.Writer,
    t: *const Terminal,
) EncodeError!void {
    var stream: record.Writer = .init(alloc, destination);
    defer stream.deinit();

    // 1. Envelope
    try envelope.encode(stream.writer());

    // 2. Terminal
    try terminal.encode(t, &stream);

    // 3. Primary and alt screen
    try screen.encode(
        t.screens.get(.primary).?,
        .primary,
        &stream,
    );
    if (t.screens.get(.alternate)) |alternate| try screen.encode(
        alternate,
        .alternate,
        &stream,
    );

    // 4. Ready checkpoint. In the future we'll put our continuation
    // state before this so pty bytes can also flow.
    try checkpoint.encode(.ready, &stream);

    // 5. History
    try history.encode(
        t.screens.get(.primary).?,
        .primary,
        &stream,
    );
    if (t.screens.get(.alternate)) |alternate| try history.encode(
        alternate,
        .alternate,
        &stream,
    );

    // 6. Finish
    try checkpoint.encode(.finish, &stream);
}

/// Errors possible while restoring one complete terminal snapshot.
pub const DecodeError = envelope.DecodeError ||
    terminal.DecodeError ||
    screen.DecodeError ||
    history.DecodeError ||
    checkpoint.DecodeError ||
    error{
        /// A SCREEN names a key not declared by TERMINAL.
        UnexpectedScreenKey,

        /// More than one SCREEN names the same key.
        DuplicateScreen,

        /// A HISTORY names a key not declared by TERMINAL.
        UnexpectedHistoryKey,

        /// More than one HISTORY names the same key.
        DuplicateHistory,
    };

/// Restore one complete snapshot into a native terminal.
///
/// This consumes one snapshot through FINISH and leaves any following bytes in
/// the reader for the containing transport. Restoration is transactional: the
/// returned terminal is either complete and ready or not (error return).
/// Individual record codecs normalize optional semantic state, while framing,
/// checkpoints, declared sequence counts, and unique cross-record screen
/// routing remain strict.
pub fn decode(
    alloc: Allocator,
    io_: std.Io,
    source: *std.Io.Reader,
) DecodeError!Terminal {
    // StreamReader owns a zero-buffer hashing adapter, making checkpoint
    // boundaries part of its API rather than a caller-maintained invariant.
    var stream: record.StreamReader = .init(source);
    const reader = stream.reader();

    // Read the envelope, which is currently just a verification step.
    try envelope.decode(reader);

    // TERMINAL establishes terminal-wide state and allocates empty screen
    // slots with their final routing. SCREEN values replace those slots in
    // place so ScreenSet pointers, including the active pointer, stay valid.
    var result = try terminal.decode(reader, io_, alloc);
    errdefer result.deinit(alloc);

    // TERMINAL initializes exactly the number of screen slots it declared.
    // Decode that many SCREEN sequences and route each one by its encoded key.
    const screen_count = result.screens.all.count();
    const options: TerminalScreen.Options = options: {
        const primary = result.screens.get(.primary).?;
        const explicit_bytes = primary.pages.limits.bytes.explicit;
        const explicit_lines = primary.pages.limits.lines.explicit;
        break :options .{
            .cols = result.cols,
            .rows = result.rows,
            .max_scrollback_bytes = if (explicit_bytes == std.math.maxInt(usize))
                null
            else
                explicit_bytes,
            .max_scrollback_lines = if (explicit_lines == std.math.maxInt(usize))
                null
            else
                explicit_lines,
        };
    };

    for (0..screen_count) |_| {
        var decoded = try screen.decode(
            reader,
            io_,
            alloc,
            options,
        );
        errdefer decoded.deinit();

        const slot = result.screens.get(decoded.key) orelse
            return error.UnexpectedScreenKey;

        // The fresh ScreenSet starts every declared slot at generation zero.
        // Replacing a slot advances its generation, so a nonzero value means
        // an earlier SCREEN in this snapshot already supplied the same key.
        if (result.screens.generation(decoded.key) != 0) return error.DuplicateScreen;

        slot.deinit();
        slot.* = decoded.screen;
        decoded.screen = undefined;

        // We put an artificial generation in just so we can detect duplicates.
        result.screens.generations.put(
            decoded.key,
            result.screens.generation(decoded.key) +% 1,
        );
    }

    // READY covers the exact envelope-through-SCREEN prefix. Finalizing does
    // not consume the hasher, so the same stream continues toward FINISH.
    try checkpoint.decode(.ready, &stream);

    // HISTORY keys make this sequence order-independent just like SCREEN.
    // Although a decoder may publish recent pages as they validate, any later
    // full-snapshot failure deinitializes the whole result.
    for (0..screen_count) |_| {
        var decoder: history.Decoder = undefined;
        try decoder.init(reader);

        const key = decoder.header.key;
        const restored = result.screens.get(key) orelse
            return error.UnexpectedHistoryKey;

        // SCREEN routing advanced every decoded slot from generation zero to
        // one. A value other than one means this key already received HISTORY.
        if (result.screens.generation(key) != 1) {
            return error.DuplicateHistory;
        }

        try decoder.decode(alloc, restored);
        result.screens.generations.put(key, 2);
    }

    // FINISH authenticates READY and all history. Decode it directly from the
    // underlying reader so the digest does not include FINISH itself.
    try checkpoint.decode(.finish, &stream);

    const keys = [_]TerminalScreenKey{ .primary, .alternate };
    if (comptime build_options.slow_runtime_safety) {
        for (keys) |key| {
            const restored = result.screens.get(key) orelse continue;
            restored.pages.assertIntegrity();
            restored.assertIntegrity();
        }
    }

    // Generations are only scratch state while routing the two keyed sequence
    // groups. The completed terminal has not escaped yet, so reset them to the
    // same initial state as any newly constructed ScreenSet.
    for (keys) |key| result.screens.generations.put(key, 0);
    return result;
}

/// Errors possible while restoring a snapshot that must end at end-of-file.
pub const DecodeExactError = DecodeError || std.Io.Reader.Error || error{
    /// FINISH was followed by additional bytes.
    TrailingData,
};

/// Restore one snapshot and require FINISH to be followed by end-of-file.
///
/// This is intended for bounded snapshot files and buffers. On a live stream,
/// checking for end-of-file may block; use `decode` to stop at FINISH instead.
pub fn decodeExact(
    alloc: Allocator,
    io_: std.Io,
    source: *std.Io.Reader,
) DecodeExactError!Terminal {
    var result = try decode(alloc, io_, source);
    errdefer result.deinit(alloc);

    _ = source.peekByte() catch |err| switch (err) {
        error.EndOfStream => return result,
        else => return err,
    };
    return error.TrailingData;
}

test "complete snapshot round trip with history and alternate screen" {
    const testing = std.testing;

    var t = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 2,
        .rows = 3,
        .max_scrollback_bytes = null,
        .max_scrollback_lines = null,
    });
    defer t.deinit(testing.allocator);

    // Exercise terminal-wide state.
    t.width_px = 800;
    t.height_px = 600;
    t.colors.palette.set(7, .{ .r = 1, .g = 2, .b = 3 });
    t.modes.values.bracketed_paste = true;
    try t.setPwd("file:///tmp/snapshot");
    try t.setTitle("complete snapshot");

    const primary = t.screens.get(.primary).?;

    // Use small exact capacities so this compound golden remains practical to
    // review while still containing two complete history pages and one active
    // page. Replacing the Screen in place preserves ScreenSet routing.
    var replacement: TerminalScreen = replacement: {
        var builder = try TerminalPageList.Builder.init(
            testing.allocator,
            .{
                .cols = t.cols,
                .rows = t.rows,
                .max_size = null,
                .max_lines = null,
            },
        );
        defer builder.deinit();

        const oldest = try builder.allocatePage(.{ .cols = 2, .rows = 2 });
        oldest.size.rows = 2;
        oldest.getRowAndCell(0, 0).cell.* = .init('A');

        const recent = try builder.allocatePage(.{ .cols = 2, .rows = 2 });
        recent.size.rows = 2;
        recent.getRowAndCell(0, 0).cell.* = .init('B');

        const active = try builder.allocatePage(.{ .cols = 2, .rows = 3 });
        active.size.rows = 3;
        active.getRowAndCell(0, 0).cell.* = .init('C');
        active.getRowAndCell(0, 1).cell.* = .init('D');
        active.getRowAndCell(0, 2).cell.* = .init('E');

        var pages = try builder.finish();
        errdefer pages.deinit();

        const cursor_pin = try pages.trackPin(
            pages.pin(.{ .active = .{} }).?,
        );
        const cursor_rac = cursor_pin.rowAndCell();
        break :replacement .{
            .io = testing.io,
            .alloc = testing.allocator,
            .pages = pages,
            .cursor = .{
                .page_pin = cursor_pin,
                .page_row = cursor_rac.row,
                .page_cell = cursor_rac.cell,
            },
        };
    };
    primary.deinit();
    primary.* = replacement;
    replacement = undefined;

    try testing.expect(primary.pages.scrollbar().total > t.rows);

    // Compression is an internal source representation and must remain
    // unchanged while the complete history is inspected for encoding.
    _ = primary.pages.compress(.full);
    const source_memory = primary.pages.memoryStats();

    // The optional alternate screen participates in both phases and remains
    // the active screen after restoration.
    _ = try t.switchScreen(.alternate);
    try t.printString("alternate");

    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t);
    try testing.expectEqualDeep(source_memory, primary.pages.memoryStats());
    try test_fixture.expectEqual(
        .snapshot,
        "src/terminal/snapshot/testdata/complete-v1.hex",
        "snapshot_fixture-complete-v1.hex",
        &test_complete_fixture,
        encoded.written(),
    );

    // A complete snapshot can stream through a non-allocating destination.
    // Independently hash that output so both its length and complete byte
    // sequence are checked without retaining a second snapshot copy.
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var hashing = discard.writer.hashed(
        std.crypto.hash.Blake3.init(.{}),
        &.{},
    );
    try encode(testing.allocator, &hashing.writer, &t);
    try testing.expectEqual(
        @as(u64, test_complete_fixture.len),
        discard.fullCount(),
    );
    var expected_digest: checkpoint.Digest = undefined;
    std.crypto.hash.Blake3.hash(
        &test_complete_fixture,
        &expected_digest,
        .{},
    );
    var actual_digest: checkpoint.Digest = undefined;
    hashing.hasher.final(&actual_digest);
    try testing.expectEqual(expected_digest, actual_digest);

    // Restore the checked-in reference rather than the just-generated bytes.
    var encoded_source: std.Io.Reader = .fixed(&test_complete_fixture);
    var source_buffer: [1]u8 = undefined;
    var limited = encoded_source.limited(.unlimited, &source_buffer);
    var restored = try decode(
        testing.allocator,
        testing.io,
        &limited.interface,
    );
    defer restored.deinit(testing.allocator);

    try testing.expectEqual(TerminalScreenKey.alternate, restored.screens.active_key);
    try testing.expectEqual(
        restored.screens.get(.alternate).?,
        restored.screens.active,
    );
    try testing.expectEqualStrings(
        "file:///tmp/snapshot",
        restored.getPwd().?,
    );
    try testing.expectEqualStrings(
        "complete snapshot",
        restored.getTitle().?,
    );
    try testing.expectEqual(
        primary.pages.scrollbar().total,
        restored.screens.get(.primary).?.pages.scrollbar().total,
    );

    // Re-encoding is a compact semantic equality check over all TERMINAL,
    // SCREEN, PAGE, and HISTORY fields and both checkpoint boundaries.
    var reencoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reencoded.deinit();
    try encode(testing.allocator, &reencoded.writer, &restored);
    try testing.expectEqualStrings(
        &test_complete_fixture,
        reencoded.written(),
    );

    // SCREEN and HISTORY keys make both sequence groups order independent.
    var reversed: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reversed.deinit();
    var reversed_stream: record.Writer = .init(
        testing.allocator,
        &reversed.writer,
    );
    defer reversed_stream.deinit();
    try envelope.encode(reversed_stream.writer());
    try terminal.encode(&t, &reversed_stream);
    try screen.encode(
        t.screens.get(.alternate).?,
        .alternate,
        &reversed_stream,
    );
    try screen.encode(primary, .primary, &reversed_stream);
    try checkpoint.encode(.ready, &reversed_stream);
    try history.encode(
        t.screens.get(.alternate).?,
        .alternate,
        &reversed_stream,
    );
    try history.encode(primary, .primary, &reversed_stream);
    try checkpoint.encode(.finish, &reversed_stream);

    var reversed_source: std.Io.Reader = .fixed(reversed.written());
    var reversed_restored = try decode(
        testing.allocator,
        testing.io,
        &reversed_source,
    );
    defer reversed_restored.deinit(testing.allocator);
    try testing.expectEqual(
        TerminalScreenKey.alternate,
        reversed_restored.screens.active_key,
    );
    try testing.expectEqual(
        @as(usize, 0),
        reversed_restored.screens.generation(.primary),
    );
    try testing.expectEqual(
        @as(usize, 0),
        reversed_restored.screens.generation(.alternate),
    );
}

test "complete snapshot preserves Kitty virtual placeholders" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    const testing = std.testing;
    var t = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 2,
        .rows = 1,
    });
    defer t.deinit(testing.allocator);

    // Register a real virtual placement, then write its grid representation:
    // U+10EEEE followed by row and column diacritics. The image and placement
    // registry is intentionally omitted, but the grid content must remain
    // decodable.
    try t.screens.active.kitty_images.addImage(
        testing.io,
        testing.allocator,
        .{ .id = 1 },
    );
    try t.screens.active.kitty_images.addPlacement(
        testing.io,
        testing.allocator,
        1,
        0,
        .{
            .location = .{ .virtual = {} },
            .columns = 1,
            .rows = 1,
        },
    );
    try t.setAttribute(.{ .@"256_fg" = 1 });
    try t.printString("\u{10EEEE}\u{0305}\u{0305}");
    const source_cell = t.screens.active.pages.getCell(.{
        .screen = .{},
    }).?;
    try testing.expectEqual(
        terminal_kitty.graphics.unicode.placeholder,
        source_cell.cell.codepoint(),
    );
    try testing.expect(source_cell.row.kitty_virtual_placeholder);

    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t);

    var encoded_source: std.Io.Reader = .fixed(encoded.written());
    var restored = try decode(
        testing.allocator,
        testing.io,
        &encoded_source,
    );
    defer restored.deinit(testing.allocator);

    const restored_cell = restored.screens.active.pages.getCell(.{
        .screen = .{},
    }).?;
    try testing.expectEqual(
        terminal_kitty.graphics.unicode.placeholder,
        restored_cell.cell.codepoint(),
    );
    try testing.expect(restored_cell.cell.hasGrapheme());
    try testing.expect(restored_cell.row.kitty_virtual_placeholder);
    try testing.expectEqual(
        @as(usize, 0),
        restored.screens.active.kitty_images.images.count(),
    );
    try testing.expectEqual(
        @as(usize, 0),
        restored.screens.active.kitty_images.placements.count(),
    );
}

test "complete snapshot encoding streams from the current writer position" {
    const testing = std.testing;

    var t = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 2,
        .rows = 1,
    });
    defer t.deinit(testing.allocator);

    // Prefix hashing begins with this call's envelope, independent of bytes
    // that were already present in the destination.
    var nonempty: std.Io.Writer.Allocating = .init(testing.allocator);
    defer nonempty.deinit();
    try nonempty.writer.writeAll("prefix");
    const snapshot_offset = nonempty.written().len;
    try encode(testing.allocator, &nonempty.writer, &t);
    try testing.expectEqualStrings(
        "prefix",
        nonempty.written()[0..snapshot_offset],
    );
    var appended_source: std.Io.Reader = .fixed(
        nonempty.written()[snapshot_offset..],
    );
    var appended = try decode(
        testing.allocator,
        testing.io,
        &appended_source,
    );
    appended.deinit(testing.allocator);

    // Payload validation happens in the record-local scratch allocation. The
    // already-streamed envelope remains, but no partial TERMINAL is emitted.
    t.colors.palette.current[7] = .{ .r = 1, .g = 2, .b = 3 };
    var destination: std.Io.Writer.Allocating = .init(testing.allocator);
    defer destination.deinit();
    try destination.writer.writeAll("prefix");
    try testing.expectError(
        error.InvalidPalette,
        encode(testing.allocator, &destination.writer, &t),
    );
    var expected_envelope: [envelope.encoded_len]u8 = undefined;
    var envelope_writer: std.Io.Writer = .fixed(&expected_envelope);
    try envelope.encode(&envelope_writer);
    try testing.expectEqualStrings(
        &expected_envelope,
        destination.written()["prefix".len..],
    );
}

test "complete snapshot rejects ordering and invalid checkpoints" {
    const testing = std.testing;

    var t = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 2,
        .rows = 1,
    });
    defer t.deinit(testing.allocator);
    const primary = t.screens.get(.primary).?;

    // HISTORY is individually valid here, but the full decoder requires the
    // primary SCREEN before READY.
    var reordered: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reordered.deinit();
    var reordered_stream: record.Writer = .init(
        testing.allocator,
        &reordered.writer,
    );
    defer reordered_stream.deinit();
    try envelope.encode(reordered_stream.writer());
    try terminal.encode(&t, &reordered_stream);
    try history.encode(primary, .primary, &reordered_stream);
    var reordered_source: std.Io.Reader = .fixed(reordered.written());
    try testing.expectError(
        error.UnexpectedRecordTag,
        decode(testing.allocator, testing.io, &reordered_source),
    );

    // Construct a correctly framed READY with an intentionally unrelated
    // digest so the full driver, rather than record CRC validation, rejects it.
    var invalid_ready: std.Io.Writer.Allocating = .init(testing.allocator);
    defer invalid_ready.deinit();
    var invalid_ready_stream: record.Writer = .init(
        testing.allocator,
        &invalid_ready.writer,
    );
    defer invalid_ready_stream.deinit();
    try envelope.encode(invalid_ready_stream.writer());
    try terminal.encode(&t, &invalid_ready_stream);
    try screen.encode(primary, .primary, &invalid_ready_stream);
    const ready_payload = invalid_ready_stream.begin(.ready);
    errdefer invalid_ready_stream.cancel();
    try ready_payload.splatByteAll(
        0,
        @sizeOf(checkpoint.Digest),
    );
    try invalid_ready_stream.finish();
    var invalid_ready_source: std.Io.Reader = .fixed(
        invalid_ready.written(),
    );
    try testing.expectError(
        error.InvalidDigest,
        decode(testing.allocator, testing.io, &invalid_ready_source),
    );

    // A SCREEN key must name one of the slots declared by TERMINAL.
    var undeclared: std.Io.Writer.Allocating = .init(testing.allocator);
    defer undeclared.deinit();
    var undeclared_stream: record.Writer = .init(
        testing.allocator,
        &undeclared.writer,
    );
    defer undeclared_stream.deinit();
    try envelope.encode(undeclared_stream.writer());
    try terminal.encode(&t, &undeclared_stream);
    try screen.encode(primary, .alternate, &undeclared_stream);
    var undeclared_source: std.Io.Reader = .fixed(undeclared.written());
    try testing.expectError(
        error.UnexpectedScreenKey,
        decode(testing.allocator, testing.io, &undeclared_source),
    );

    // HISTORY sequences are also routed by key, which must name a declared
    // screen even when the sequence contains no PAGE records.
    var undeclared_history: std.Io.Writer.Allocating = .init(testing.allocator);
    defer undeclared_history.deinit();
    var undeclared_history_stream: record.Writer = .init(
        testing.allocator,
        &undeclared_history.writer,
    );
    defer undeclared_history_stream.deinit();
    try envelope.encode(undeclared_history_stream.writer());
    try terminal.encode(&t, &undeclared_history_stream);
    try screen.encode(primary, .primary, &undeclared_history_stream);
    try checkpoint.encode(.ready, &undeclared_history_stream);
    try history.encode(primary, .alternate, &undeclared_history_stream);
    var undeclared_history_source: std.Io.Reader = .fixed(
        undeclared_history.written(),
    );
    try testing.expectError(
        error.UnexpectedHistoryKey,
        decode(testing.allocator, testing.io, &undeclared_history_source),
    );

    // The declared count cannot be satisfied by repeating the same key.
    _ = try t.switchScreen(.alternate);
    var duplicate: std.Io.Writer.Allocating = .init(testing.allocator);
    defer duplicate.deinit();
    var duplicate_stream: record.Writer = .init(
        testing.allocator,
        &duplicate.writer,
    );
    defer duplicate_stream.deinit();
    try envelope.encode(duplicate_stream.writer());
    try terminal.encode(&t, &duplicate_stream);
    try screen.encode(primary, .primary, &duplicate_stream);
    try screen.encode(primary, .primary, &duplicate_stream);
    var duplicate_source: std.Io.Reader = .fixed(duplicate.written());
    try testing.expectError(
        error.DuplicateScreen,
        decode(testing.allocator, testing.io, &duplicate_source),
    );

    // The declared count cannot be satisfied by repeating one HISTORY key.
    var duplicate_history: std.Io.Writer.Allocating = .init(testing.allocator);
    defer duplicate_history.deinit();
    var duplicate_history_stream: record.Writer = .init(
        testing.allocator,
        &duplicate_history.writer,
    );
    defer duplicate_history_stream.deinit();
    try envelope.encode(duplicate_history_stream.writer());
    try terminal.encode(&t, &duplicate_history_stream);
    try screen.encode(primary, .primary, &duplicate_history_stream);
    try screen.encode(
        t.screens.get(.alternate).?,
        .alternate,
        &duplicate_history_stream,
    );
    try checkpoint.encode(.ready, &duplicate_history_stream);
    try history.encode(primary, .primary, &duplicate_history_stream);
    try history.encode(primary, .primary, &duplicate_history_stream);
    var duplicate_history_source: std.Io.Reader = .fixed(
        duplicate_history.written(),
    );
    try testing.expectError(
        error.DuplicateHistory,
        decode(testing.allocator, testing.io, &duplicate_history_source),
    );
}

test "complete snapshot leaves continuation bytes unread" {
    const testing = std.testing;

    var t = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 2,
        .rows = 1,
    });
    defer t.deinit(testing.allocator);

    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t);
    const snapshot_len = encoded.written().len;
    try encoded.writer.writeAll("pty");

    var source: std.Io.Reader = .fixed(encoded.written());
    var restored = try decode(testing.allocator, testing.io, &source);
    defer restored.deinit(testing.allocator);

    var continuation: [3]u8 = undefined;
    try source.readSliceAll(&continuation);
    try testing.expectEqualStrings("pty", &continuation);

    var exact_source: std.Io.Reader = .fixed(encoded.written());
    try testing.expectError(
        error.TrailingData,
        decodeExact(testing.allocator, testing.io, &exact_source),
    );

    var bounded_source: std.Io.Reader = .fixed(
        encoded.written()[0..snapshot_len],
    );
    var bounded = try decodeExact(
        testing.allocator,
        testing.io,
        &bounded_source,
    );
    defer bounded.deinit(testing.allocator);
}

test "complete snapshots decode sequentially from one reader" {
    const testing = std.testing;

    var t = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 2,
        .rows = 1,
    });
    defer t.deinit(testing.allocator);

    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t);
    try encode(testing.allocator, &encoded.writer, &t);

    var source: std.Io.Reader = .fixed(encoded.written());
    var first = try decode(testing.allocator, testing.io, &source);
    defer first.deinit(testing.allocator);
    var second = try decode(testing.allocator, testing.io, &source);
    defer second.deinit(testing.allocator);
    try testing.expectError(error.EndOfStream, source.takeByte());
}
