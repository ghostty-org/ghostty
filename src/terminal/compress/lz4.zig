//! An allocation-free implementation of the raw LZ4 block format.
//!
//! LZ4 has two relevant layers: the block format describes the compressed
//! bytes, while the frame format adds headers, sizes, checksums, and support
//! for a stream of blocks. Terminal pages already have their own ownership
//! and metadata, so this implements only blocks. In particular, an encoded
//! block does not contain its decompressed size. The caller must store that
//! separately and provide an exactly sized buffer when decoding.
//!
//! A block is a series of sequences. Each non-final sequence has this shape:
//!
//!     token | literal length extensions | literals | offset | match length extensions
//!
//! The token's high nibble contains the literal length and its low nibble
//! contains the match length minus four. A nibble value of 15 means that the
//! length continues in extension bytes at the corresponding point in the
//! sequence. Each extension byte adds to the length; a value of 255 means
//! another byte follows. The literal bytes are copied directly. The two-byte
//! little-endian offset then points backwards in the already decompressed
//! output to the match bytes.
//!
//! The last sequence is special: it contains literals only and ends directly
//! after them. The reference format also requires the last five input bytes to
//! be literals and the final match to begin at least twelve bytes before the
//! end of the input. The compressor observes these restrictions so its output
//! can be consumed by optimized LZ4 decoders which copy in larger units.
//!
//! Compression uses the fast LZ4 strategy: hash each four-byte input sequence
//! and test recent positions as match candidates. Two 16-bit positions fit in
//! each hash-table entry because the format cannot refer further than 64 KiB
//! backwards. Retaining the displaced position recovers useful matches after
//! hash collisions without increasing the fixed 16 KiB workspace. Long runs
//! without matches gradually skip input positions, while matching runs are
//! extended a machine word at a time. The implementation allocates nothing;
//! all input, output, and scratch memory is supplied by the caller.
//!
//! Format reference:
//! https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

/// Maximum input accepted by the reference LZ4 block API. Keeping the same
/// limit means `compressBound` fits in the integer sizes used by LZ4 callers
/// and gives us the same compatibility boundary as other implementations.
pub const max_input_size: usize = 0x7E000000;

/// Every LZ4 match represents at least four bytes. The token stores the number
/// of bytes beyond this minimum rather than the full match length.
const min_match = 4;

/// Number of bytes at the end of a conforming block which must remain literals.
const last_literals = 5;

/// A match may not begin in the final 12 bytes. This leaves enough room for the
/// minimum match and the required five trailing literals.
const match_find_limit = 12;

/// We retain one input position for each 12-bit hash. LZ4 refers to this as
/// memory usage 14 because the 4096 entries are four bytes each (16 KiB).
const hash_log = 12;

/// Multiplicative hash used by the reference LZ4 fast compressor. The high
/// `hash_log` bits provide the table index.
const hash_multiplier: u32 = 2_654_435_761;

/// Scratch memory used while compressing one block. Each entry packs the low
/// 16 bits of the two most recent input positions for its hash. All-ones marks
/// an empty half; LZ4's 16-bit offset is enough to reconstruct the only useful
/// preceding address from the current position.
/// The table is reset by every call to `compress` and can be reused afterwards.
pub const HashTable = [1 << hash_log]u32;

/// Errors which can occur while encoding a block.
pub const CompressError = error{
    /// The input exceeds the maximum size supported by the block compressor.
    InputTooLarge,

    /// The provided output buffer cannot hold the encoded block.
    OutputTooSmall,
};

/// Errors which can occur while decoding a block.
pub const DecompressError = error{
    /// The encoded block ended in the middle of a sequence.
    TruncatedInput,

    /// A match offset was zero or pointed before the produced output.
    InvalidOffset,

    /// A sequence would write beyond the provided output buffer.
    OutputTooSmall,

    /// The block ended before filling the exact-size output buffer.
    OutputSizeMismatch,
};

/// Return the maximum number of bytes needed to encode `input_len` bytes.
///
/// Incompressible input is represented as one literal run. Every 255 literal
/// bytes can require one extension byte. The additional 16-byte margin covers
/// the token and the format's fixed overhead. Callers can allocate this amount
/// once and reuse it for any block no larger than `input_len`.
pub fn compressBound(input_len: usize) CompressError!usize {
    if (input_len > max_input_size) return error.InputTooLarge;
    return input_len + input_len / 255 + 16;
}

/// Compress `input` into a raw LZ4 block in `output`.
///
/// Returns the initialized length of `output`. The input and output buffers
/// must not overlap. `table` is scratch space and does not need to be
/// initialized by the caller; it is reset before use.
pub fn compress(
    input: []const u8,
    output: []u8,
    table: *HashTable,
) CompressError!usize {
    if (input.len > max_input_size) return error.InputTooLarge;

    // All-ones in either packed half means "no previous position".
    @memset(table, std.math.maxInt(u32));

    // `ip` is the current input position, `anchor` is the first literal not yet
    // emitted, and `op` is the next output position. A successful match emits
    // input[anchor..ip] as literals followed by the match, then moves both input
    // positions to the end of that match.
    var op: usize = 0;
    var anchor: usize = 0;

    // LZ4's format leaves the final five input bytes as literals and starts
    // the final match at least twelve bytes before the end. This is not
    // required by our safe decoder, but makes blocks compatible with fast
    // decoders that rely on the standard format restrictions. Inputs too
    // short for any match are emitted below as one literal-only sequence.
    if (input.len >= match_find_limit) {
        const search_end = input.len - match_find_limit;
        const match_end_limit = input.len - last_literals;
        var ip: usize = 0;
        var search_attempts: usize = 0;

        search: while (ip <= search_end) {
            // Hash the next four bytes and replace the table entry
            // immediately. Hash collisions are expected, so equality is
            // checked below before accepting a saved position as a match.
            const sequence = readU32(input, ip);
            const hash = hashSequence(sequence);
            const candidates = table[hash];
            rememberPosition(table, hash, ip);

            var match_pos = candidatePosition(ip, @truncate(candidates)) orelse
                candidatePosition(ip, @truncate(candidates >> 16)) orelse
                {
                    advanceSearch(&ip, anchor, &search_attempts);
                    continue :search;
                };

            if (readU32(input, match_pos) != sequence) {
                // The nearest candidate collided. Fall back to the older
                // one, which must additionally match one byte beyond the
                // minimum so collision-prone minimum-length matches from
                // the stale half are not emitted.
                match_pos = older: {
                    if (candidatePosition(
                        ip,
                        @truncate(candidates >> 16),
                    )) |older| {
                        if (readU32(input, older) == sequence and
                            input[older + min_match] == input[ip + min_match])
                        {
                            break :older older;
                        }
                    }

                    advanceSearch(&ip, anchor, &search_attempts);
                    continue :search;
                };
            }

            // Pull the match backwards into the current literal run. This is
            // particularly helpful around aligned cell records. As with
            // forward extension, compare words before locating the first
            // differing byte.
            const match_begin = matchBegin(input, ip, match_pos, anchor);
            ip = match_begin.position;
            match_pos = match_begin.candidate;

            // We already compared the first four bytes. Continue up to the
            // point where the required last five literals begin. `matchEnd`
            // compares a machine word at a time before locating the first
            // differing byte.
            const match_end = matchEnd(
                input,
                ip + min_match,
                match_pos + min_match,
                match_end_limit,
            );

            try emitSequence(
                output,
                &op,
                input[anchor..ip],
                @intCast(ip - match_pos),
                match_end - ip,
            );

            // The main loop jumps over the matched bytes rather than hashing
            // every position within them. Seed one position near the end so
            // an adjacent repeated record can still refer back into this
            // match. The next loop iteration will then seed `match_end`
            // normally.
            if (match_end >= 2 and match_end - 2 + min_match <= input.len) {
                const seed = match_end - 2;
                rememberPosition(
                    table,
                    hashSequence(readU32(input, seed)),
                    seed,
                );
            }

            ip = match_end;
            anchor = ip;
            search_attempts = 0;
        }
    }

    // Whatever remains after the last match is the terminal literal-only
    // sequence. For short inputs this is also the only sequence in the block.
    try emitLastLiterals(output, &op, input[anchor..]);
    return op;
}

/// Decompress a raw LZ4 block into an exact-size output buffer.
///
/// Returns `output.len` on success. Both consuming all input and filling all
/// output are required. Raw LZ4 blocks do not carry their decoded size, so this
/// exact-size contract validates the size metadata maintained by the caller.
/// The input and output buffers must not overlap.
pub fn decompress(input: []const u8, output: []u8) DecompressError!usize {
    // `ip` and `op` always identify the next unread input byte and the next
    // unwritten output byte respectively.
    //
    // The decoder is written around one observation: almost every sequence
    // in real blocks has a short literal run and a short match. Both fast
    // paths below copy a fixed number of bytes blindly and let the length
    // arithmetic sort out how many of them were meaningful. Writing past a
    // run's logical end is safe within the output buffer because decoding
    // is strictly in order: every byte past `op` is either rewritten by a
    // later copy before anything can read it, or lies beyond the block's
    // final length and is never part of the result. The margin conditions
    // on the fast paths also subsume the exact bounds checks they replace,
    // which keeps decoding of malformed blocks memory-safe.
    var ip: usize = 0;
    var op: usize = 0;

    while (true) {
        // A normal block ends after the literal bytes of its final sequence.
        // This also accepts the empty block produced by our compressor, which
        // consists of a zero token and no literals.
        if (ip == input.len) {
            if (op != output.len) return error.OutputSizeMismatch;
            return op;
        }

        const token = input[ip];
        ip += 1;

        // The high nibble and any extension bytes describe the literal run.
        // The literals are copied as a side effect of computing the length.
        const literal_len: usize = len: {
            const nibble: usize = token >> 4;
            if (nibble != 15 and
                @min(input.len - ip, output.len - op) >= 16)
            {
                // A run below the extension threshold is at most 14 bytes,
                // so with a 16-byte margin on both buffers one wide copy
                // covers it.
                copyIntAt(u128, output, op, input, ip);
                break :len nibble;
            }

            // Extended or margin-poor runs take the checked path. Bounds are
            // verified before copying so malformed blocks never cause a
            // partial read or write.
            const len = try decodeLength(input, &ip, nibble);
            if (len > input.len - ip) return error.TruncatedInput;
            if (len > output.len - op) return error.OutputTooSmall;
            @memcpy(output[op..][0..len], input[ip..][0..len]);
            break :len len;
        };
        ip += literal_len;
        op += literal_len;

        // Ending immediately after the literals marks the final sequence. Any
        // non-final sequence must continue with an offset and match length.
        if (ip == input.len) {
            if (op != output.len) return error.OutputSizeMismatch;
            return op;
        }

        if (input.len - ip < 2) return error.TruncatedInput;
        const offset = readIntAt(u16, input, ip);
        ip += 2;
        if (offset == 0 or offset > op) return error.InvalidOffset;

        // The token stores the match length minus the four-byte minimum. As
        // with literals, a low nibble of 15 is extended by following bytes.
        const match_nibble: usize = token & 0x0F;

        // A match whose length fits its nibble spans at most 18 bytes, so
        // three blind copies always cover it. They are overlap-safe when the
        // offset is at least a word: each load lies a full word behind the
        // store which could observe it, so repeating patterns propagate
        // correctly.
        if (match_nibble != 15 and offset >= 8 and output.len - op >= 18) {
            const match = op - offset;
            copyIntAt(u64, output, op, output, match);
            copyIntAt(u64, output, op + 8, output, match + 8);
            copyIntAt(u16, output, op + 16, output, match + 16);
            op += match_nibble + min_match;
            continue;
        }

        const encoded_match_len = try decodeLength(input, &ip, match_nibble);
        const match_len = std.math.add(
            usize,
            encoded_match_len,
            min_match,
        ) catch return error.OutputTooSmall;
        if (match_len > output.len - op) return error.OutputTooSmall;

        // Match copies may overlap, so this cannot always be one memcpy.
        // `copyMatch` expands the common small repeating periods into wide
        // stores and uses word copies for larger offsets.
        copyMatch(output, op, offset, match_len);
        op += match_len;
    }
}

/// Emit one non-final sequence.
///
/// A sequence starts with a token, followed by optional literal length bytes,
/// the literals themselves, the two-byte offset, and optional match length
/// bytes. This function computes the complete size first so `OutputTooSmall`
/// is reported without partially writing a sequence.
fn emitSequence(
    output: []u8,
    op: *usize,
    literals: []const u8,
    offset: u16,
    match_len: usize,
) CompressError!void {
    assert(match_len >= min_match);
    assert(offset > 0);

    const encoded_match_len = match_len - min_match;

    // One byte is always needed for the token and two for the offset. Each
    // length may additionally need extension bytes after its token nibble.
    const required = 1 +
        encodedLengthBytes(literals.len) + literals.len +
        2 + encodedLengthBytes(encoded_match_len);
    if (required > output.len - op.*) return error.OutputTooSmall;

    const token_pos = op.*;
    op.* += 1;

    // Lengths below 15 fit directly in their nibble. Larger values put 15 in
    // the nibble and encode the remainder immediately after the token.
    output[token_pos] = (@as(u8, @intCast(@min(literals.len, 15))) << 4) |
        @as(u8, @intCast(@min(encoded_match_len, 15)));

    // Literal length extensions precede the literals they describe.
    if (literals.len >= 15) writeLength(output, op, literals.len - 15);
    @memcpy(output[op.*..][0..literals.len], literals);
    op.* += literals.len;

    // Match length extensions follow the offset because this is where the
    // decoder expects them in an LZ4 sequence.
    writeIntAt(u16, output, op.*, offset);
    op.* += 2;
    if (encoded_match_len >= 15)
        writeLength(output, op, encoded_match_len - 15);
}

/// Emit the literal-only sequence which terminates every block.
///
/// There is no offset or match length after these bytes. As with
/// `emitSequence`, capacity is checked before modifying the output.
fn emitLastLiterals(
    output: []u8,
    op: *usize,
    literals: []const u8,
) CompressError!void {
    const required = 1 + encodedLengthBytes(literals.len) + literals.len;
    if (required > output.len - op.*) return error.OutputTooSmall;

    output[op.*] = @as(u8, @intCast(@min(literals.len, 15))) << 4;
    op.* += 1;
    if (literals.len >= 15) writeLength(output, op, literals.len - 15);
    @memcpy(output[op.*..][0..literals.len], literals);
    op.* += literals.len;
}

/// Return the number of extension bytes needed when a length is represented by
/// a token nibble plus zero or more bytes. An extended length always ends with
/// a byte below 255, so an exact multiple of 255 requires a final zero byte.
fn encodedLengthBytes(encoded_len: usize) usize {
    if (encoded_len < 15) return 0;
    return (encoded_len - 15) / 255 + 1;
}

/// Write the portion of a length which did not fit in the token nibble.
///
/// Each 255 byte means "add 255 and continue". The final byte is always less
/// than 255 and may be zero.
fn writeLength(output: []u8, op: *usize, length_: usize) void {
    var length = length_;
    while (length >= 255) {
        output[op.*] = 255;
        op.* += 1;
        length -= 255;
    }
    output[op.*] = @intCast(length);
    op.* += 1;
}

/// Decode a length from its token nibble and any following extension bytes.
/// `ip` is advanced past every consumed extension byte.
fn decodeLength(
    input: []const u8,
    ip: *usize,
    nibble: usize,
) DecompressError!usize {
    var length: usize = nibble;
    if (nibble != 15) return length;

    while (true) {
        if (ip.* >= input.len) return error.TruncatedInput;
        const value = input[ip.*];
        ip.* += 1;
        length = std.math.add(usize, length, value) catch
            return error.TruncatedInput;
        if (value != 255) return length;
    }
}

/// Read an unaligned little-endian integer at `position`.
inline fn readIntAt(
    comptime Int: type,
    input: []const u8,
    position: usize,
) Int {
    return std.mem.readInt(
        Int,
        input[position..][0..@sizeOf(Int)],
        .little,
    );
}

/// Write an unaligned little-endian integer at `position`.
inline fn writeIntAt(
    comptime Int: type,
    output: []u8,
    position: usize,
    value: Int,
) void {
    std.mem.writeInt(
        Int,
        output[position..][0..@sizeOf(Int)],
        value,
        .little,
    );
}

/// Copy one fixed-size integer between non-overlapping byte ranges.
inline fn copyIntAt(
    comptime Int: type,
    output: []u8,
    output_position: usize,
    input: []const u8,
    input_position: usize,
) void {
    writeIntAt(
        Int,
        output,
        output_position,
        readIntAt(Int, input, input_position),
    );
}

/// Read the four-byte sequence used for match finding. Callers only use this
/// where at least four input bytes remain.
inline fn readU32(input: []const u8, pos: usize) u32 {
    return readIntAt(u32, input, pos);
}

/// Add a position to one hash slot and shift the previous newest position into
/// the fallback half. A position whose low bits are 0xFFFF conflicts with the
/// sentinel and is simply not stored.
inline fn rememberPosition(table: *HashTable, hash: usize, position: usize) void {
    const low: u16 = @truncate(position);
    if (low == std.math.maxInt(u16)) return;
    table[hash] = (@as(u32, @truncate(table[hash])) << 16) | low;
}

/// Recover the nearest preceding position from a stored low half. Modular
/// subtraction directly produces the LZ4 offset within the current window.
inline fn candidatePosition(ip: usize, stored: u16) ?usize {
    if (stored == std.math.maxInt(u16)) return null;
    const distance: u16 = @as(u16, @truncate(ip)) -% stored;
    if (distance == 0) return null;
    return ip - distance;
}

/// Advance through a literal run. The first KiB inspects every byte without
/// maintaining a counter, which keeps ordinary terminal-page searches cheap.
/// Longer runs enable gradually increasing steps for incompressible data.
inline fn advanceSearch(
    ip: *usize,
    anchor: usize,
    attempts: *usize,
) void {
    if (attempts.* == 0) {
        ip.* += 1;
        if (ip.* - anchor == 1024) attempts.* = 1;
        return;
    }

    attempts.* += 1;
    ip.* += 1 + attempts.* / 64;
}

/// Extend a match backwards without crossing the current literal anchor or the
/// beginning of the candidate. The returned positions preserve their offset.
fn matchBegin(
    input: []const u8,
    position_: usize,
    candidate_: usize,
    anchor: usize,
) struct { position: usize, candidate: usize } {
    var position = position_;
    var candidate = candidate_;

    while (@min(position - anchor, candidate) >= @sizeOf(u64)) {
        const position_word = position - @sizeOf(u64);
        const candidate_word = candidate - @sizeOf(u64);
        const difference = readIntAt(u64, input, position_word) ^
            readIntAt(u64, input, candidate_word);
        if (difference != 0) {
            const equal_bytes: usize = @intCast(@clz(difference) / 8);
            position -= equal_bytes;
            candidate -= equal_bytes;
            return .{ .position = position, .candidate = candidate };
        }

        position = position_word;
        candidate = candidate_word;
    }

    while (position > anchor and candidate > 0 and
        input[position - 1] == input[candidate - 1])
    {
        position -= 1;
        candidate -= 1;
    }
    return .{ .position = position, .candidate = candidate };
}

/// Return the first input position where two matching runs differ, or `limit`
/// when they remain equal. Both positions are known to have matched through
/// `min_match` before this is called.
fn matchEnd(
    input: []const u8,
    position_: usize,
    candidate_: usize,
    limit: usize,
) usize {
    var position = position_;
    var candidate = candidate_;

    // Reading as little endian makes the least-significant differing bit map
    // to the earliest byte in memory on every target. Unaligned reads are
    // lowered appropriately by Zig and require no target-specific intrinsics.
    while (limit - position >= @sizeOf(u64)) {
        const difference = readIntAt(u64, input, position) ^
            readIntAt(u64, input, candidate);
        if (difference != 0) {
            const equal_bytes: usize = @intCast(@ctz(difference) / 8);
            return position + equal_bytes;
        }

        position += @sizeOf(u64);
        candidate += @sizeOf(u64);
    }

    while (position < limit and input[position] == input[candidate]) {
        position += 1;
        candidate += 1;
    }
    return position;
}

/// Copy one decoded match from `offset` bytes behind `op`.
///
/// The caller has validated that the match fits: `op + match_len` never
/// exceeds `output.len`. Wide copies may write a few scratch bytes past the
/// match's logical end; as described in `decompress`, that is safe anywhere
/// the write stays inside the output buffer. Every path therefore bounds its
/// wide stores by both the match end and the buffer end, and the bytewise
/// loop at the bottom finishes whatever remains.
fn copyMatch(output: []u8, op_: usize, offset: usize, match_len: usize) void {
    var op = op_;
    const end = op_ + match_len;

    // A source which ends behind the copy can never overlap it. Long
    // distant matches are common in structured pages (repeated rows and
    // whole blank regions), and one exact memcpy moves them in cache-line
    // units. Shorter matches are not worth the call overhead.
    if (offset >= match_len and match_len >= 64) {
        @memcpy(
            output[op..][0..match_len],
            output[op - offset ..][0..match_len],
        );
        return;
    }

    switch (offset) {
        // A period which divides the word size expands into one repeated
        // pattern word. Long runs (blank lines, repeated cells) then become
        // independent stores, with no load waiting on a preceding store.
        // Stores advance by whole words from `op`, which preserves the
        // pattern's phase.
        1, 2, 4, 8 => {
            const pattern: u64 = switch (offset) {
                1 => @as(u64, output[op - 1]) * 0x0101_0101_0101_0101,
                2 => @as(u64, readIntAt(u16, output, op - 2)) *
                    0x0001_0001_0001_0001,
                4 => @as(u64, readIntAt(u32, output, op - 4)) *
                    0x0000_0001_0000_0001,
                8 => readIntAt(u64, output, op - 8),
                else => unreachable,
            };

            const limit = @min(end, output.len -| 7);
            while (op < limit) : (op += 8)
                writeIntAt(u64, output, op, pattern);
        },

        // Wide copies are overlap-safe for the remaining offsets of at
        // least a copy unit: each load lies a full unit behind the store
        // which could observe it. Offsets 3, 5, 6, and 7 fall through to
        // the bytewise loop; they are rare in real data and word tricks
        // for them cost more in complexity than they return.
        else => if (offset >= 16) {
            const limit = @min(end, output.len -| 15);
            while (op < limit) : (op += 16)
                copyIntAt(u128, output, op, output, op - offset);
        } else if (offset >= 8) {
            const limit = @min(end, output.len -| 7);
            while (op < limit) : (op += 8)
                copyIntAt(u64, output, op, output, op - offset);
        },
    }

    while (op < end) : (op += 1) output[op] = output[op - offset];
}

/// Map a four-byte input sequence to its scratch-table slot.
inline fn hashSequence(sequence: u32) usize {
    return @intCast((sequence *% hash_multiplier) >> (32 - hash_log));
}

/// Shared round-trip assertion used by the corpus-style tests below.
fn expectRoundTrip(input: []const u8) !void {
    const bound = try compressBound(input.len);
    const encoded = try testing.allocator.alloc(u8, bound);
    defer testing.allocator.free(encoded);
    const decoded = try testing.allocator.alloc(u8, input.len);
    defer testing.allocator.free(decoded);

    var table: HashTable = undefined;
    const encoded_len = try compress(input, encoded, &table);
    try testing.expectEqual(input.len, try decompress(
        encoded[0..encoded_len],
        decoded,
    ));
    try testing.expectEqualSlices(u8, input, decoded);
}

test "compressBound" {
    try testing.expectEqual(@as(usize, 16), try compressBound(0));
    try testing.expectEqual(@as(usize, 272), try compressBound(255));
    try testing.expectError(error.InputTooLarge, compressBound(max_input_size + 1));
}

test "literal-only compatibility vectors" {
    var empty: [0]u8 = .{};
    try testing.expectEqual(@as(usize, 0), try decompress(&.{0}, &empty));

    var hello: [5]u8 = undefined;
    try testing.expectEqual(@as(usize, 5), try decompress(
        &.{ 0x50, 'h', 'e', 'l', 'l', 'o' },
        &hello,
    ));
    try testing.expectEqualStrings("hello", &hello);

    var fifteen: [15]u8 = undefined;
    var encoded: [17]u8 = undefined;
    encoded[0] = 0xF0;
    encoded[1] = 0;
    @memset(encoded[2..], 'x');
    _ = try decompress(&encoded, &fifteen);
    try testing.expect(std.mem.allEqual(u8, &fifteen, 'x'));
}

test "overlapping match compatibility vector" {
    // One literal 'a', followed by a four-byte match at distance one.
    var output: [5]u8 = undefined;
    try testing.expectEqual(@as(usize, 5), try decompress(
        &.{ 0x10, 'a', 0x01, 0x00 },
        &output,
    ));
    try testing.expectEqualStrings("aaaaa", &output);
}

test "extended overlapping match compatibility vector" {
    // One literal followed by a 274-byte match. The match extension is
    // encoded as 255 + 0 after the low token nibble's initial 15 bytes.
    var output: [275]u8 = undefined;
    try testing.expectEqual(@as(usize, output.len), try decompress(
        &.{ 0x1F, 'a', 0x01, 0x00, 0xFF, 0x00 },
        &output,
    ));
    try testing.expect(std.mem.allEqual(u8, &output, 'a'));
}

test "short offset compatibility vectors" {

    // These blocks end immediately after their match. Besides covering the
    // repeating-pattern paths, they verify that the decoder uses exact copies
    // when the block does not provide the standard trailing-literal margin.
    var offset_two: [6]u8 = undefined;
    _ = try decompress(&.{ 0x20, 'a', 'b', 0x02, 0x00 }, &offset_two);
    try testing.expectEqualStrings("ababab", &offset_two);

    var offset_three: [9]u8 = undefined;
    _ = try decompress(
        &.{ 0x32, 'a', 'b', 'c', 0x03, 0x00 },
        &offset_three,
    );
    try testing.expectEqualStrings("abcabcabc", &offset_three);

    var offset_four: [8]u8 = undefined;
    _ = try decompress(
        &.{ 0x40, 'a', 'b', 'c', 'd', 0x04, 0x00 },
        &offset_four,
    );
    try testing.expectEqualStrings("abcdabcd", &offset_four);
}

test "bounded wild copies are overwritten by final literals" {

    // The first sequence's nine-byte match leaves the five final literals
    // required by the LZ4 block format. Its logical one-byte tail is copied as
    // a word and the following literal sequence overwrites the extra bytes.
    var repeated_byte: [15]u8 = undefined;
    _ = try decompress(
        &.{
            0x15, 'a', 0x01, 0x00,
            0x50, '1', '2',  '3',
            '4',  '5',
        },
        &repeated_byte,
    );
    try testing.expectEqualStrings("aaaaaaaaaa12345", &repeated_byte);

    // Exercise the same bounded tail copy with a non-overlapping offset.
    var word_offset: [22]u8 = undefined;
    _ = try decompress(
        &.{
            0x85, 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 0x08, 0x00,
            0x50, '1', '2', '3', '4', '5',
        },
        &word_offset,
    );
    try testing.expectEqualStrings(
        "abcdefghabcdefgha12345",
        &word_offset,
    );
}

test "maximum match offset compatibility vector" {
    const literal_len = std.math.maxInt(u16);
    const extension_len = (literal_len - 15) / 255 + 1;
    const encoded = try testing.allocator.alloc(
        u8,
        1 + extension_len + literal_len + 2,
    );
    defer testing.allocator.free(encoded);
    const output = try testing.allocator.alloc(u8, literal_len + min_match);
    defer testing.allocator.free(output);

    var op: usize = 0;
    encoded[op] = 0xF0;
    op += 1;
    writeLength(encoded, &op, literal_len - 15);
    for (encoded[op..][0..literal_len], 0..) |*byte, i|
        byte.* = @truncate(i);
    op += literal_len;
    std.mem.writeInt(u16, encoded[op..][0..2], std.math.maxInt(u16), .little);
    op += 2;

    try testing.expectEqual(encoded.len, op);
    try testing.expectEqual(output.len, try decompress(encoded, output));
    try testing.expectEqualSlices(u8, encoded[1 + extension_len ..][0..4], output[literal_len..]);
}

test "round trips boundary-sized inputs" {
    const lengths = [_]usize{
        0,   1,      3,      4,      5,   12,  15,  16,  19,
        20,  254,    255,    256,    269, 270, 271, 510, 511,
        512, 65_535, 65_536, 65_537,
    };

    for (lengths) |len| {
        const buf = try testing.allocator.alloc(u8, len);
        defer testing.allocator.free(buf);
        for (buf, 0..) |*byte, i| byte.* = @truncate(i *% 31);
        try expectRoundTrip(buf);
    }
}

test "round trips compressible page-sized inputs" {
    const page_len = 400 * 1024;

    const zeros = try testing.allocator.alloc(u8, page_len);
    defer testing.allocator.free(zeros);
    @memset(zeros, 0);
    try expectRoundTrip(zeros);

    const structured = try testing.allocator.alloc(u8, page_len);
    defer testing.allocator.free(structured);
    @memset(structured, 0);
    for (0..page_len / 8) |i| {
        structured[i * 8] = @truncate(' ' + i % 95);
        structured[i * 8 + 4] = @truncate((i / 80) % 16);
    }
    try expectRoundTrip(structured);
}

test "round trips deterministic random inputs" {
    var prng = std.Random.DefaultPrng.init(0x4C5A_3401);
    const random = prng.random();

    for (0..256) |_| {
        const len = random.uintLessThan(usize, 32 * 1024);
        const input = try testing.allocator.alloc(u8, len);
        defer testing.allocator.free(input);
        random.bytes(input);
        try expectRoundTrip(input);
    }
}

test "compress reports short output" {
    const input = "a terminal page needs enough output space";
    var table: HashTable = undefined;
    var output: [4]u8 = undefined;
    try testing.expectError(
        error.OutputTooSmall,
        compress(input, &output, &table),
    );
}

test "decompress rejects malformed blocks" {
    var output: [32]u8 = undefined;

    try testing.expectError(error.TruncatedInput, decompress(&.{0xF0}, &output));
    try testing.expectError(error.TruncatedInput, decompress(&.{ 0x10, 'a', 1 }, output[0..5]));
    try testing.expectError(error.InvalidOffset, decompress(&.{ 0x10, 'a', 0, 0 }, output[0..5]));
    try testing.expectError(error.InvalidOffset, decompress(&.{ 0x10, 'a', 2, 0 }, output[0..5]));
    try testing.expectError(error.OutputTooSmall, decompress(
        &.{ 0x10, 'a', 1, 0 },
        output[0..4],
    ));
    try testing.expectError(error.OutputSizeMismatch, decompress(&.{0}, output[0..1]));
}

test {
    _ = @import("lz4_differential.zig");
}
