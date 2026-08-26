const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const simd = @import("../../simd/main.zig");
const lib = @import("../lib.zig");

const log = std.log.scoped(.kitty_gfx);

/// The key-value pairs for the control information for a command. The
/// recognized keys are always single ASCII letters and the values are either
/// single characters or 32-bit unsigned integers. Unknown non-letter keys are
/// ignored, matching how unknown letter keys are ignored when building a
/// command.
///
/// This is deliberately a dense value table plus a presence bitmap. There are
/// only 52 possible keys(technically KIP has fever than 52 possible .. at the moment of writing), so a lookup is one machine-word bit test followed by
/// an indexed load. The values are undefined until their presence bit is set.
///
/// Other alternatives were considered and should probably be revisited in the
/// future. Some of them were:
/// A `[52]?u32` table is 416 bytes versus 216 bytes for this layout, and
/// its larger copies erased the smaller lookup code.
/// `std.EnumMap` added optional-return lowering,
/// `std.StaticBitSet(52)` kept the same size but generated larger code
/// for the packed mask. Passing the table by pointer removed the copies
/// but did not improve end-to-end throughput. Keep this representation
/// unless a new benchmark shows an improvement in the zig compilers codegen.
///
/// For the value itself: if it is a single printable ASCII character it is the
/// ASCII code. Otherwise, it is parsed as a 32-bit unsigned integer.
const KV = struct {
    values: [52]u32 = undefined,
    present: u64 = 0,

    fn index(key: u8) ?u6 {
        return switch (key) {
            'a'...'z' => @intCast(key - 'a'),
            'A'...'Z' => @intCast(26 + key - 'A'),
            else => null,
        };
    }

    fn get(self: *const KV, key: u8) ?u32 {
        const idx = index(key) orelse return null;
        if (self.present & (@as(u64, 1) << idx) == 0) return null;
        return self.values[idx];
    }

    fn put(self: *KV, key: u8, value: u32) void {
        const idx = index(key) orelse return;
        self.values[idx] = value;
        self.present |= @as(u64, 1) << idx;
    }
};

/// Command parser parses the Kitty graphics protocol escape sequence.
pub const Parser = struct {
    alloc: Allocator,

    /// This is the list of KV pairs that we're building up.
    kv: KV,

    /// This is used as a buffer to store the key/value of a KV pair. The value
    /// of a KV pair is at most a 32-bit integer which at most is 10 characters
    /// (4294967295), plus one character for the sign bit on signed ints.
    kv_temp: [11]u8,
    kv_temp_len: u4,
    kv_current: u8, // Current kv key

    /// This is the list we use to collect the bytes from the data payload.
    /// The Kitty Graphics protocol specification seems to imply that the
    /// payload content of a single command should never exceed 4096 bytes,
    /// but Kitty itself supports larger payloads, so we use an ArrayList
    /// here instead of a fixed buffer so that we can too.
    data: std.ArrayList(u8),

    /// Maximum bytes the data payload can take. This is to prevent
    /// malicious input from causing us to allocate too much memory.
    max_bytes: usize,

    /// Internal state for parsing.
    state: State,

    const State = enum {
        /// Parsing k/v pairs. The "ignore" variants are in that state
        /// but ignore any data because we know they're invalid.
        control_key,
        control_key_ignore,
        control_value,
        control_value_ignore,

        /// Collecting the data payload blob.
        data,
    };

    /// Initialize the parser. The allocator given will be used for both
    /// temporary data and long-lived values such as the final image blob.
    pub fn init(alloc: Allocator, max_bytes: usize) Parser {
        var result: Parser = .{
            .alloc = alloc,
            .data = .empty,
            .kv = .{},
            .kv_temp_len = 0,
            .kv_current = 0,
            .max_bytes = max_bytes,
            .state = .control_key,

            .kv_temp = undefined,
        };
        if (std.valgrind.runningOnValgrind() > 0) {
            // Initialize our undefined fields so Valgrind can catch it.
            // https://github.com/ziglang/zig/issues/19148
            result.kv_temp = undefined;
        }
        return result;
    }

    pub fn deinit(self: *Parser) void {
        self.data.deinit(self.alloc);
    }

    /// Parse a complete command string.
    pub fn parseString(alloc: Allocator, data: []const u8) !Command {
        var parser = init(alloc, 1024 * 1024);
        defer parser.deinit();
        for (data) |c| try parser.feed(c);
        return try parser.complete(alloc);
    }

    /// Feed a single byte to the parser.
    ///
    /// The first byte to start parsing should be the byte immediately following
    /// the "G" in the APC sequence, i.e. "\x1b_G123" the first byte should
    /// be "1".
    pub fn feed(self: *Parser, c: u8) !void {
        switch (self.state) {
            .control_key => switch (c) {
                // '=' means the key is complete and we're moving to the value.
                '=' => if (self.kv_temp_len != 1) {
                    // All control keys are a single character right now so
                    // if we're not a single character just ignore follow-up
                    // data.
                    self.state = .control_value_ignore;
                    self.kv_temp_len = 0;
                } else {
                    self.kv_current = self.kv_temp[0];
                    self.kv_temp_len = 0;
                    self.state = .control_value;
                },

                // This can be encountered if we have a sequence with no
                // control data, only payload data (i.e. "\x1b_G;<data>").
                //
                // Kitty treats this as valid so we do as well.
                ';' => self.state = .data,

                else => try self.accumulateValue(c, .control_key_ignore),
            },

            .control_key_ignore => switch (c) {
                '=' => self.state = .control_value_ignore,
                else => {},
            },

            .control_value => switch (c) {
                ',' => try self.finishValue(.control_key), // move to next key
                ';' => try self.finishValue(.data), // move to data
                else => try self.accumulateValue(c, .control_value_ignore),
            },

            .control_value_ignore => switch (c) {
                ',' => self.state = .control_key_ignore,
                ';' => self.state = .data,
                else => {},
            },

            .data => {
                if (self.data.items.len >= self.max_bytes) return error.OutOfMemory;
                try self.data.append(self.alloc, c);
            },
        }
    }

    /// Feed a slice of bytes to the parser. This is equivalent to
    /// calling feed for each byte in order, but once we're in the data
    /// state the remainder of the slice is appended in bulk, avoiding
    /// per-byte overhead for large payloads.
    pub fn feedSlice(self: *Parser, bytes: []const u8) !void {
        var rem = bytes;
        while (rem.len > 0) {
            if (self.state == .data) {
                if (self.data.items.len + rem.len > self.max_bytes) {
                    return error.OutOfMemory;
                }
                try self.data.appendSlice(self.alloc, rem);
                return;
            }

            try self.feed(rem[0]);
            rem = rem[1..];
        }
    }

    /// Complete the parsing. This must be called after all the
    /// bytes have been fed to the parser.
    ///
    /// The allocator given will be used for the long-lived data
    /// of the final command.
    pub fn complete(self: *Parser, alloc: Allocator) !Command {
        switch (self.state) {
            // We can't ever end in the control key state and be valid.
            // This means the command looked something like "a=1,b"
            .control_key, .control_key_ignore => return error.InvalidFormat,

            // Some commands (i.e. placements) end without extra data so
            // we end in the value state. i.e. "a=1,b=2"
            .control_value => try self.finishValue(.data),
            .control_value_ignore => {},

            // Most commands end in data, i.e. "a=1,b=2;1234"
            .data => {},
        }

        // Determine our action, which is always a single character.
        const action: u8 = action: {
            const value = self.kv.get('a') orelse break :action 't';
            const c = std.math.cast(u8, value) orelse return error.InvalidFormat;
            break :action c;
        };
        const control: Command.Control = switch (action) {
            'q' => .{ .query = try .parse(self.kv) },
            't' => .{ .transmit = try .parse(self.kv) },
            'T' => .{ .transmit_and_display = .{
                .transmission = try .parse(self.kv),
                .display = try .parse(self.kv),
            } },
            'p' => .{ .display = try .parse(self.kv) },
            'd' => .{ .delete = try .parse(self.kv) },
            'f' => .{ .transmit_animation_frame = try .parse(self.kv) },
            'a' => .{ .control_animation = .parse(self.kv) },
            'c' => .{ .compose_animation = .parse(self.kv) },
            else => return error.InvalidFormat,
        };

        // Determine our quiet value. The spec specifies 0 and 1 but Kitty
        // allows anything greater than 1 to suppress.
        const quiet: Command.Quiet = if (self.kv.get('q')) |v| quiet: {
            break :quiet switch (v) {
                0 => .no,
                1 => .ok,
                else => .failures,
            };
        } else .no;

        return .{
            .control = control,
            .quiet = quiet,
            .data = try self.decodeData(alloc),
        };
    }

    /// Decodes the payload data from base64 and returns it as a slice.
    /// This function will destroy the contents of self.data, it should
    /// only be used once we are done collecting payload bytes.
    fn decodeData(self: *Parser, alloc: Allocator) ![]const u8 {
        if (self.data.items.len == 0) {
            return "";
        }

        const max_len = simd.base64.maxLen(self.data.items);
        assert(max_len <= self.data.items.len);

        // This is kinda cursed, but we can decode the base64 on top of
        // itself, since it's guaranteed that the encoded size is larger,
        // and any bytes in areas that are written to will have already
        // been used (assuming scalar decoding).
        const decoded = simd.base64.decode(
            self.data.items,
            self.data.items[0..max_len],
        ) catch |err| {
            log.warn("failed to decode base64 payload data: {}", .{err});
            return error.InvalidData;
        };
        assert(decoded.len <= max_len);

        // Remove the extra bytes.
        self.data.items.len = decoded.len;

        return try self.data.toOwnedSlice(alloc);
    }

    fn accumulateValue(self: *Parser, c: u8, overflow_state: State) !void {
        const idx = self.kv_temp_len;
        self.kv_temp_len += 1;
        if (self.kv_temp_len > self.kv_temp.len) {
            self.state = overflow_state;
            self.kv_temp_len = 0;
            return;
        }
        self.kv_temp[idx] = c;
    }

    fn finishValue(self: *Parser, next_state: State) !void {
        // We can move states right away, we don't use it.
        self.state = next_state;

        // Check for ASCII chars first
        if (self.kv_temp_len == 1) {
            const c = self.kv_temp[0];
            if (c < '0' or c > '9') {
                self.kv.put(self.kv_current, @intCast(c));
                self.kv_temp_len = 0;
                return;
            }
        }

        // Handle integer fields, parsing signed fields accordingly. We still
        // store the fields as u32 as they can be bitcast back later during
        // building of the higher-level command tree.
        const v: u32 = switch (self.kv_current) {
            'z', 'H', 'V' => @bitCast(try std.fmt.parseInt(i32, self.kv_temp[0..self.kv_temp_len], 10)),
            else => try std.fmt.parseInt(u32, self.kv_temp[0..self.kv_temp_len], 10),
        };
        self.kv.put(self.kv_current, v);

        // Clear our temp buffer
        self.kv_temp_len = 0;
    }
};

/// Represents a possible response to a command.
pub const Response = struct {
    id: u32 = 0,
    image_number: u32 = 0,
    placement_id: u32 = 0,
    /// The 1-based animation frame number, echoed as "r=" for the
    /// animation frame actions. This is how clients learn the frame
    /// number assigned to a newly created frame.
    frame: u32 = 0,
    message: []const u8 = "OK",

    pub fn encode(self: Response, writer: *std.Io.Writer) !void {
        // We only encode a result if we have either an id or an image number.
        if (self.id == 0 and self.image_number == 0) return;

        // Used to cheaply keep track if we need to add a comma before
        // the next key-value pair.
        var prior: bool = false;

        try writer.writeAll("\x1b_G");
        if (self.id > 0) {
            prior = true;
            try writer.print("i={}", .{self.id});
        }
        if (self.image_number > 0) {
            if (prior) try writer.writeByte(',') else prior = true;
            try writer.print("I={}", .{self.image_number});
        }
        if (self.placement_id > 0) {
            if (prior) try writer.writeByte(',') else prior = true;
            try writer.print("p={}", .{self.placement_id});
        }
        if (self.frame > 0) {
            if (prior) try writer.writeByte(',') else prior = true;
            try writer.print("r={}", .{self.frame});
        }
        try writer.writeByte(';');
        try writer.writeAll(self.message);
        try writer.writeAll("\x1b\\");
    }

    /// Returns true if this response is not an error.
    pub fn ok(self: Response) bool {
        return std.mem.eql(u8, self.message, "OK");
    }

    /// Empty response
    pub fn empty(self: Response) bool {
        return self.id == 0 and self.image_number == 0;
    }
};

pub const Command = struct {
    control: Control,
    quiet: Quiet = .no,
    data: []const u8 = "",

    pub const Action = enum {
        query, // q
        transmit, // t
        transmit_and_display, // T
        display, // p
        delete, // d
        transmit_animation_frame, // f
        control_animation, // a
        compose_animation, // c
    };

    pub const Quiet = enum {
        no, // 0
        ok, // 1
        failures, // 2
    };

    pub const Control = union(Action) {
        query: Transmission,
        transmit: Transmission,
        transmit_and_display: struct {
            transmission: Transmission,
            display: Display,
        },
        display: Display,
        delete: Delete,
        transmit_animation_frame: AnimationFrameLoading,
        control_animation: AnimationControl,
        compose_animation: AnimationFrameComposition,

        pub const Identifiers = struct {
            image_id: u32 = 0,
            image_number: u32 = 0,
            placement_id: u32 = 0,
        };

        /// Returns the image and placement identifiers for any action.
        pub fn identifiers(self: Control) Identifiers {
            return switch (self) {
                .query, .transmit => |t| .{
                    .image_id = t.image_id,
                    .image_number = t.image_number,
                    .placement_id = t.placement_id,
                },
                .transmit_and_display => |t| .{
                    .image_id = t.transmission.image_id,
                    .image_number = t.transmission.image_number,
                    .placement_id = t.transmission.placement_id,
                },
                .display => |d| .{
                    .image_id = d.image_id,
                    .image_number = d.image_number,
                    .placement_id = d.placement_id,
                },
                .delete => |d| .{
                    .image_id = d.image_id,
                    .image_number = d.image_number,
                    .placement_id = d.placement_id,
                },
                .transmit_animation_frame => |f| .{
                    .image_id = f.transmission.image_id,
                    .image_number = f.transmission.image_number,
                    .placement_id = f.transmission.placement_id,
                },
                .control_animation => |a| .{
                    .image_id = a.image_id,
                    .image_number = a.image_number,
                    .placement_id = a.placement_id,
                },
                .compose_animation => |c| .{
                    .image_id = c.image_id,
                    .image_number = c.image_number,
                    .placement_id = c.placement_id,
                },
            };
        }
    };

    /// Take ownership over the data in this command. If the returned value
    /// has a length of zero, then the data was empty and need not be freed.
    pub fn toOwnedData(self: *Command) []const u8 {
        const result = self.data;
        self.data = "";
        return result;
    }

    /// Returns the transmission data if it has any.
    pub fn transmission(self: Command) ?Transmission {
        return switch (self.control) {
            .query => |t| t,
            .transmit => |t| t,
            .transmit_and_display => |t| t.transmission,
            .transmit_animation_frame => |f| f.transmission,
            else => null,
        };
    }

    /// Returns the display data if it has any.
    pub fn display(self: Command) ?Display {
        return switch (self.control) {
            .display => |d| d,
            .transmit_and_display => |t| t.display,
            else => null,
        };
    }

    pub fn deinit(self: Command, alloc: Allocator) void {
        if (self.data.len > 0) alloc.free(self.data);
    }
};

pub const Transmission = struct {
    format: Format = .rgba, // f
    /// Set when "f" carried a value we don't recognize. Kitty rejects these
    /// while handling the command so the EINVAL response can carry the image
    /// id, so we defer to `LoadingImage.init`. `format` is meaningless when
    /// this is set.
    format_unknown: bool = false,
    medium: Medium = .direct, // t
    width: u32 = 0, // s
    height: u32 = 0, // v
    size: u32 = 0, // S
    offset: u32 = 0, // O
    image_id: u32 = 0, // i
    image_number: u32 = 0, // I
    placement_id: u32 = 0, // p
    compression: Compression = .none, // o
    more_chunks: bool = false, // m
    usage: Usage = .default, // N

    pub const Format = lib.Enum(lib.target, &.{
        "rgb", // 24
        "rgba", // 32
        "png", // 100
        // The following are not supported directly via the protocol
        // but they are formats that a png may decode to that we
        // support.
        "gray_alpha",
        "gray",
    });

    pub const Medium = lib.Enum(lib.target, &.{
        "direct", // d
        "file", // f
        "temporary_file", // t
        "shared_memory", // s
    });

    pub const Compression = lib.Enum(lib.target, &.{
        "none",
        "zlib_deflate", // z
    });

    /// Usage hints allow for optimising resource consumption strategies.
    ///
    /// https://sw.kovidgoyal.net/kitty/graphics-protocol/#usage-hints
    pub const Usage = packed struct(u32) {
        /// Image with this usage hint is assumed to be used for only a short
        /// time, so may be evicted before other images if memory pressure is
        /// encountered.
        transient: bool = false,
        _padding: u31 = 0,

        pub const default: Usage = .{};
    };

    pub fn formatBpp(format: Format) u8 {
        return switch (format) {
            .gray => 1,
            .gray_alpha => 2,
            .rgb => 3,
            .rgba => 4,
            .png => unreachable, // Must be validated before
        };
    }

    fn parse(kv: KV) !Transmission {
        var result: Transmission = .{};
        if (kv.get('f')) |v| {
            result.format = switch (v) {
                24 => .rgb,
                0, 32 => .rgba,
                100 => .png,
                else => unknown: {
                    // Defer returning an error until the image is processed.
                    result.format_unknown = true;
                    break :unknown .rgba;
                },
            };
        }

        if (kv.get('t')) |v| {
            const c = std.math.cast(u8, v) orelse return error.InvalidFormat;
            result.medium = switch (c) {
                'd' => .direct,
                'f' => .file,
                't' => .temporary_file,
                's' => .shared_memory,
                else => return error.InvalidFormat,
            };
        }

        if (kv.get('s')) |v| {
            result.width = v;
        }

        if (kv.get('v')) |v| {
            result.height = v;
        }

        if (kv.get('S')) |v| {
            result.size = v;
        }

        if (kv.get('O')) |v| {
            result.offset = v;
        }

        if (kv.get('i')) |v| {
            result.image_id = v;
        }

        if (kv.get('I')) |v| {
            result.image_number = v;
        }

        if (kv.get('p')) |v| {
            result.placement_id = v;
        }

        if (kv.get('o')) |v| {
            const c = std.math.cast(u8, v) orelse return error.InvalidFormat;
            result.compression = switch (c) {
                'z' => .zlib_deflate,
                else => return error.InvalidFormat,
            };
        }

        // If the transmission medium is a local-only medium, ignore the "m"
        // key. The Kitty graphics protocol specification does not explicitly
        // call out this behavior (although the "m" key is only mentioned in
        // connection with remote clients) but that's how it's implemented in
        // Kitty and at least one client (mpv) relies on this behavior when
        // using the shared memory transmission medium.
        //
        // https://sw.kovidgoyal.net/kitty/graphics-protocol/#the-transmission-medium
        // https://github.com/kovidgoyal/kitty/blob/ccc3bee9af794f332b4e9adcd714a649f639c397/kitty/graphics.c#L547-L592
        if (result.medium == .direct) {
            if (kv.get('m')) |v| {
                result.more_chunks = v > 0;
            }
        }

        if (kv.get('N')) |v| {
            result.usage = @bitCast(v);
        }

        return result;
    }
};

pub const Display = struct {
    image_id: u32 = 0, // i
    image_number: u32 = 0, // I
    placement_id: u32 = 0, // p
    x: u32 = 0, // x
    y: u32 = 0, // y
    width: u32 = 0, // w
    height: u32 = 0, // h
    x_offset: u32 = 0, // X
    y_offset: u32 = 0, // Y
    columns: u32 = 0, // c
    rows: u32 = 0, // r
    cursor_movement: CursorMovement = .after, // C
    virtual_placement: bool = false, // U
    parent_id: u32 = 0, // P
    parent_placement_id: u32 = 0, // Q
    horizontal_offset: i32 = 0, // H
    vertical_offset: i32 = 0, // V
    z: i32 = 0, // z

    pub const CursorMovement = enum {
        after, // 0
        none, // 1
    };

    fn parse(kv: KV) !Display {
        var result: Display = .{};

        if (kv.get('i')) |v| {
            result.image_id = v;
        }

        if (kv.get('I')) |v| {
            result.image_number = v;
        }

        if (kv.get('p')) |v| {
            result.placement_id = v;
        }

        if (kv.get('x')) |v| {
            result.x = v;
        }

        if (kv.get('y')) |v| {
            result.y = v;
        }

        if (kv.get('w')) |v| {
            result.width = v;
        }

        if (kv.get('h')) |v| {
            result.height = v;
        }

        if (kv.get('X')) |v| {
            result.x_offset = v;
        }

        if (kv.get('Y')) |v| {
            result.y_offset = v;
        }

        if (kv.get('c')) |v| {
            result.columns = v;
        }

        if (kv.get('r')) |v| {
            result.rows = v;
        }

        if (kv.get('C')) |v| {
            // Kitty only tests this against 1 so any other value moves the cursor.
            result.cursor_movement = if (v == 1) .none else .after;
        }

        if (kv.get('U')) |v| {
            // Kitty stores this in a bool, so any non-zero value is virtual.
            result.virtual_placement = v != 0;
        }

        if (kv.get('z')) |v| {
            // We can bitcast here because of how we parse it earlier.
            result.z = @bitCast(v);
        }

        if (kv.get('P')) |v| {
            result.parent_id = v;
        }

        if (kv.get('Q')) |v| {
            result.parent_placement_id = v;
        }

        if (kv.get('H')) |v| {
            // We can bitcast here because of how we parse it earlier.
            result.horizontal_offset = @bitCast(v);
        }

        if (kv.get('V')) |v| {
            // We can bitcast here because of how we parse it earlier.
            result.vertical_offset = @bitCast(v);
        }

        return result;
    }
};

pub const AnimationFrameLoading = struct {
    /// Frame data is transmitted exactly like image data, so an a=f
    /// command carries a full set of transmission keys: medium (t),
    /// format (f), the frame rectangle size (s/v), chunking (m), etc.
    /// The image id/number here identify the (existing) image the
    /// frame belongs to.
    transmission: Transmission = .{},

    /// The left/top edge (pixels) of the rectangle within the frame
    /// that the transmitted data updates.
    x: u32 = 0, // x
    y: u32 = 0, // y

    /// The 1-based frame number whose pixels serve as the base canvas
    /// for a newly created frame. Zero means no base frame: the
    /// canvas is filled with `background` instead.
    create_frame: u32 = 0, // c

    /// The 1-based frame number of an existing frame to edit. Zero
    /// (or any value past the next frame number) creates a new frame.
    edit_frame: u32 = 0, // r

    /// The gap in milliseconds before the next frame is shown. For
    /// new frames, zero selects the default gap and a negative value
    /// creates a gapless (never displayed) frame. For edits, zero
    /// leaves the gap unchanged.
    gap_ms: i32 = 0, // z

    composition_mode: CompositionMode = .alpha_blend, // X
    background: Background = .{}, // Y

    /// The canvas background color as a 32-bit RGBA value where R is
    /// the most significant byte (0xRRGGBBAA), e.g. Y=4278190335
    /// (0xff0000ff) is opaque red. Bit-cast from the little-endian
    /// u32 value, so the field order is reversed from the byte order.
    pub const Background = packed struct(u32) {
        a: u8 = 0,
        b: u8 = 0,
        g: u8 = 0,
        r: u8 = 0,
    };

    fn parse(kv: KV) error{InvalidFormat}!AnimationFrameLoading {
        var result: AnimationFrameLoading = .{
            .transmission = try .parse(kv),
        };

        if (kv.get('x')) |v| {
            result.x = v;
        }

        if (kv.get('y')) |v| {
            result.y = v;
        }

        if (kv.get('c')) |v| {
            result.create_frame = v;
        }

        if (kv.get('r')) |v| {
            result.edit_frame = v;
        }

        if (kv.get('z')) |v| {
            // 'z' is one of the keys Parser.finishValue parses as an
            // i32, so the u32 in the KV table is the bit pattern of
            // that i32 and this reconstructs it exactly.
            result.gap_ms = @bitCast(v);
        }

        // Tested only against 1 like Kitty.
        if (kv.get('X')) |v| {
            result.composition_mode = if (v == 1) .overwrite else .alpha_blend;
        }

        if (kv.get('Y')) |v| {
            result.background = @bitCast(v);
        }

        return result;
    }
};

pub const AnimationFrameComposition = struct {
    image_id: u32 = 0, // i
    image_number: u32 = 0, // I
    placement_id: u32 = 0, // p

    /// The 1-based frame number being edited (the destination).
    dest_frame: u32 = 0, // c

    /// The 1-based frame number whose pixels are composed onto the
    /// destination (the source).
    source_frame: u32 = 0, // r

    /// The left/top edge (pixels) of the destination rectangle.
    x: u32 = 0, // x
    y: u32 = 0, // y

    /// The size of the rectangle to compose. Zero selects the full
    /// image width/height.
    width: u32 = 0, // w
    height: u32 = 0, // h

    /// The left/top edge (pixels) of the source rectangle.
    left_edge: u32 = 0, // X
    top_edge: u32 = 0, // Y

    composition_mode: CompositionMode = .alpha_blend, // C

    // Cannot fail: every key is stored as parsed, with no range
    // validation (Kitty range-checks these while handling the
    // command; see the comment above the execution-deferral tests).
    fn parse(kv: KV) AnimationFrameComposition {
        var result: AnimationFrameComposition = .{};

        if (kv.get('i')) |v| {
            result.image_id = v;
        }

        if (kv.get('I')) |v| {
            result.image_number = v;
        }

        if (kv.get('p')) |v| {
            result.placement_id = v;
        }

        if (kv.get('c')) |v| {
            result.dest_frame = v;
        }

        if (kv.get('r')) |v| {
            result.source_frame = v;
        }

        if (kv.get('x')) |v| {
            result.x = v;
        }

        if (kv.get('y')) |v| {
            result.y = v;
        }

        if (kv.get('w')) |v| {
            result.width = v;
        }

        if (kv.get('h')) |v| {
            result.height = v;
        }

        if (kv.get('X')) |v| {
            result.left_edge = v;
        }

        if (kv.get('Y')) |v| {
            result.top_edge = v;
        }

        if (kv.get('C')) |v| {
            // Kitty tests this against zero for compose so any non-zero overwrites
            result.composition_mode = if (v == 0) .alpha_blend else .overwrite;
        }

        return result;
    }
};

pub const AnimationControl = struct {
    image_id: u32 = 0, // i
    image_number: u32 = 0, // I
    placement_id: u32 = 0, // p
    action: AnimationAction = .invalid, // s

    /// The 1-based frame number whose gap is set from gap_ms.
    frame: u32 = 0, // r

    /// The new gap for `frame` in milliseconds. Zero is ignored and a
    /// negative value makes the frame gapless.
    gap_ms: i32 = 0, // z

    /// The 1-based frame number to make current (client-driven
    /// animation). Zero is ignored.
    current_frame: u32 = 0, // c

    /// The loop count: zero is ignored, 1 loops forever, and any
    /// larger value plays that many minus one loops.
    loops: u32 = 0, // v

    pub const AnimationAction = enum {
        invalid, // 0
        stop, // 1
        run_wait, // 2
        run, // 3
    };

    // Cannot fail: every key is stored as parsed. Out-of-range values
    // (frame numbers, states) are silently ignored during execution,
    // matching Kitty.
    fn parse(kv: KV) AnimationControl {
        var result: AnimationControl = .{};

        if (kv.get('i')) |v| {
            result.image_id = v;
        }

        if (kv.get('I')) |v| {
            result.image_number = v;
        }

        if (kv.get('p')) |v| {
            result.placement_id = v;
        }

        if (kv.get('s')) |v| {
            // Kitty ignores values it doesn't know, leaving the animation
            // state untouched, which is what `.invalid` means here.
            result.action = switch (v) {
                1 => .stop,
                2 => .run_wait,
                3 => .run,
                else => .invalid,
            };
        }

        if (kv.get('r')) |v| {
            result.frame = v;
        }

        if (kv.get('z')) |v| {
            // 'z' is one of the keys Parser.finishValue parses as an
            // i32, so the u32 in the KV table is the bit pattern of
            // that i32 and this reconstructs it exactly.
            result.gap_ms = @bitCast(v);
        }

        if (kv.get('c')) |v| {
            result.current_frame = v;
        }

        if (kv.get('v')) |v| {
            result.loops = v;
        }

        return result;
    }
};

pub const Delete = struct {
    image_id: u32 = 0, // i
    image_number: u32 = 0, // I
    placement_id: u32 = 0, // p
    action: Action,

    fn parse(kv: KV) !Delete {
        return .{
            .image_id = kv.get('i') orelse 0,
            .image_number = kv.get('I') orelse 0,
            .placement_id = kv.get('p') orelse 0,
            .action = try .parse(kv),
        };
    }

    pub const Action = union(enum) {
        // a/A
        all: bool,

        // i/I
        id: struct {
            delete: bool = false, // uppercase
            image_id: u32 = 0, // i
            placement_id: u32 = 0, // p
        },

        // n/N
        newest: struct {
            delete: bool = false, // uppercase
            image_number: u32 = 0, // I
            placement_id: u32 = 0, // p
        },

        // c/C,
        intersect_cursor: bool,

        // f/F
        animation_frames: AnimationFrames,

        // p/P
        intersect_cell: struct {
            delete: bool = false, // uppercase
            x: u32 = 0, // x
            y: u32 = 0, // y
        },

        // q/Q
        intersect_cell_z: struct {
            delete: bool = false, // uppercase
            x: u32 = 0, // x
            y: u32 = 0, // y
            z: i32 = 0, // z
        },

        // r/R
        range: struct {
            delete: bool = false, // uppercase
            first: u32 = 0, // x
            last: u32 = 0, // y
        },

        // x/X
        column: struct {
            delete: bool = false, // uppercase
            x: u32 = 0, // x
        },

        // y/Y
        row: struct {
            delete: bool = false, // uppercase
            y: u32 = 0, // y
        },

        // z/Z
        z: struct {
            delete: bool = false, // uppercase
            z: i32 = 0, // z
        },

        pub const AnimationFrames = struct {
            delete: bool = false, // uppercase
            image_id: u32 = 0, // i
            image_number: u32 = 0, // I
            frame: u32 = 0, // r
        };

        fn parse(kv: KV) error{InvalidFormat}!Action {
            const what: u8 = what: {
                const value = kv.get('d') orelse break :what 'a';
                const c = std.math.cast(u8, value) orelse return error.InvalidFormat;
                break :what c;
            };

            return switch (what) {
                'a', 'A' => .{ .all = what == 'A' },

                'i', 'I' => blk: {
                    var result: Action = .{ .id = .{ .delete = what == 'I' } };
                    if (kv.get('i')) |v| {
                        result.id.image_id = v;
                    }
                    if (kv.get('p')) |v| {
                        result.id.placement_id = v;
                    }

                    break :blk result;
                },

                'n', 'N' => blk: {
                    var result: Action = .{ .newest = .{ .delete = what == 'N' } };
                    if (kv.get('I')) |v| {
                        result.newest.image_number = v;
                    }
                    if (kv.get('p')) |v| {
                        result.newest.placement_id = v;
                    }

                    break :blk result;
                },

                'c', 'C' => .{ .intersect_cursor = what == 'C' },

                'f', 'F' => blk: {
                    var result: Action = .{ .animation_frames = .{ .delete = what == 'F' } };
                    if (kv.get('i')) |v| {
                        result.animation_frames.image_id = v;
                    }
                    if (kv.get('I')) |v| {
                        result.animation_frames.image_number = v;
                    }
                    if (kv.get('r')) |v| {
                        result.animation_frames.frame = v;
                    }

                    break :blk result;
                },

                'p', 'P' => blk: {
                    var result: Action = .{ .intersect_cell = .{ .delete = what == 'P' } };
                    if (kv.get('x')) |v| {
                        result.intersect_cell.x = v;
                    }
                    if (kv.get('y')) |v| {
                        result.intersect_cell.y = v;
                    }

                    break :blk result;
                },

                'q', 'Q' => blk: {
                    var result: Action = .{ .intersect_cell_z = .{ .delete = what == 'Q' } };
                    if (kv.get('x')) |v| {
                        result.intersect_cell_z.x = v;
                    }
                    if (kv.get('y')) |v| {
                        result.intersect_cell_z.y = v;
                    }
                    if (kv.get('z')) |v| {
                        // We can bitcast here because of how we parse it earlier.
                        result.intersect_cell_z.z = @bitCast(v);
                    }

                    break :blk result;
                },

                'r', 'R' => blk: {
                    // Both bounds default to zero when omitted and no
                    // validation is performed; an inverted or zero range
                    // simply matches no images.
                    var result: Action = .{ .range = .{ .delete = what == 'R' } };
                    if (kv.get('x')) |v| {
                        result.range.first = v;
                    }
                    if (kv.get('y')) |v| {
                        result.range.last = v;
                    }

                    break :blk result;
                },

                'x', 'X' => blk: {
                    var result: Action = .{ .column = .{ .delete = what == 'X' } };
                    if (kv.get('x')) |v| {
                        result.column.x = v;
                    }

                    break :blk result;
                },

                'y', 'Y' => blk: {
                    var result: Action = .{ .row = .{ .delete = what == 'Y' } };
                    if (kv.get('y')) |v| {
                        result.row.y = v;
                    }

                    break :blk result;
                },

                'z', 'Z' => blk: {
                    var result: Action = .{ .z = .{ .delete = what == 'Z' } };
                    if (kv.get('z')) |v| {
                        // We can bitcast here because of how we parse it earlier.
                        result.z.z = @bitCast(v);
                    }

                    break :blk result;
                },

                else => return error.InvalidFormat,
            };
        }
    };
};

pub const CompositionMode = enum {
    alpha_blend, // 0
    overwrite, // 1
};

test "transmission command" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();

    const input = "f=24,s=10,v=20";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);

    try testing.expect(command.control == .transmit);
    const v = command.control.transmit;
    try testing.expectEqual(Transmission.Format.rgb, v.format);
    try testing.expectEqual(@as(u32, 10), v.width);
    try testing.expectEqual(@as(u32, 20), v.height);
    try testing.expectEqual(false, v.usage.transient);
}

test "transmission command with transient hint" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();

    const input = "f=24,s=10,v=20,N=1";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);

    try testing.expect(command.control == .transmit);
    const v = command.control.transmit;
    try testing.expectEqual(Transmission.Format.rgb, v.format);
    try testing.expectEqual(@as(u32, 10), v.width);
    try testing.expectEqual(@as(u32, 20), v.height);
    try testing.expectEqual(true, v.usage.transient);
}

test "feedSlice matches per-byte feed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const input = "f=24,s=10,v=20;aGVsbG8gd29ybGQ=";

    var p1 = Parser.init(alloc, 1024 * 1024);
    defer p1.deinit();
    for (input) |c| try p1.feed(c);
    const c1 = try p1.complete(alloc);
    defer c1.deinit(alloc);

    var p2 = Parser.init(alloc, 1024 * 1024);
    defer p2.deinit();
    try p2.feedSlice(input);
    const c2 = try p2.complete(alloc);
    defer c2.deinit(alloc);

    try testing.expect(c1.control == .transmit);
    try testing.expect(c2.control == .transmit);
    try testing.expectEqualStrings(c1.data, c2.data);
}

test "feedSlice across slice boundaries" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();

    try p.feedSlice("f=24,s=10");
    try p.feedSlice(",v=20;aGVsbG8g");
    try p.feedSlice("d29ybGQ=");
    const command = try p.complete(alloc);
    defer command.deinit(alloc);

    try testing.expect(command.control == .transmit);

    // The payload is base64-decoded on completion.
    try testing.expectEqualStrings("hello world", command.data);
}

test "feedSlice respects max_bytes" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 4);
    defer p.deinit();

    try p.feedSlice("f=24;ab");
    try testing.expectError(error.OutOfMemory, p.feedSlice("cde"));
}

test "transmission ignores 'm' if medium is not direct" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();

    const input = "a=t,t=t,m=1";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);

    try testing.expect(command.control == .transmit);
    const v = command.control.transmit;
    try testing.expectEqual(Transmission.Medium.temporary_file, v.medium);
    try testing.expect(!v.more_chunks);
}

test "transmission respects 'm' if medium is direct" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();

    const input = "a=t,t=d,m=1";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);

    try testing.expect(command.control == .transmit);
    const v = command.control.transmit;
    try testing.expectEqual(Transmission.Medium.direct, v.medium);
    try testing.expect(v.more_chunks);
}

test "query command" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();

    const input = "i=31,s=1,v=1,a=q,t=d,f=24;QUFBQQ";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);

    try testing.expect(command.control == .query);
    const v = command.control.query;
    try testing.expectEqual(Transmission.Medium.direct, v.medium);
    try testing.expectEqual(@as(u32, 1), v.width);
    try testing.expectEqual(@as(u32, 1), v.height);
    try testing.expectEqual(@as(u32, 31), v.image_id);
    try testing.expectEqualStrings("AAAA", command.data);
}

test "display command" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();

    const input = "a=p,U=1,i=31,c=80,r=120";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);

    try testing.expect(command.control == .display);
    const v = command.control.display;
    try testing.expectEqual(@as(u32, 80), v.columns);
    try testing.expectEqual(@as(u32, 120), v.rows);
    try testing.expectEqual(@as(u32, 31), v.image_id);
}

test "delete command" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();

    const input = "a=d,d=p,x=3,y=4";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);

    try testing.expect(command.control == .delete);
    const v = command.control.delete.action;
    try testing.expect(v == .intersect_cell);
    const dv = v.intersect_cell;
    try testing.expect(!dv.delete);
    try testing.expectEqual(@as(u32, 3), dv.x);
    try testing.expectEqual(@as(u32, 4), dv.y);
}

test "no control data" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();

    const input = ";QUFBQQ";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);

    try testing.expect(command.control == .transmit);
    try testing.expectEqualStrings("AAAA", command.data);
}

test "ignore unknown keys (long)" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();

    const input = "f=24,s=10,v=20,hello=world";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);

    try testing.expect(command.control == .transmit);
    const v = command.control.transmit;
    try testing.expectEqual(Transmission.Format.rgb, v.format);
    try testing.expectEqual(@as(u32, 10), v.width);
    try testing.expectEqual(@as(u32, 20), v.height);
}

test "ignore unknown keys (non-letter)" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();

    const input = "f=24,s=10,v=20,!=1";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);

    try testing.expect(command.control == .transmit);
    const v = command.control.transmit;
    try testing.expectEqual(Transmission.Format.rgb, v.format);
    try testing.expectEqual(@as(u32, 10), v.width);
    try testing.expectEqual(@as(u32, 20), v.height);
}

test "ignore very long values" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();

    const input = "f=24,s=10,v=2000000000000000000000000000000000000000";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);

    try testing.expect(command.control == .transmit);
    const v = command.control.transmit;
    try testing.expectEqual(Transmission.Format.rgb, v.format);
    try testing.expectEqual(@as(u32, 10), v.width);
    try testing.expectEqual(@as(u32, 0), v.height);
}

test "ensure very large negative values don't get skipped" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();

    const input = "a=p,i=1,z=-2000000000";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);

    try testing.expect(command.control == .display);
    const v = command.control.display;
    try testing.expectEqual(1, v.image_id);
    try testing.expectEqual(-2000000000, v.z);
}

test "ensure proper overflow error for u32" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();

    const input = "a=p,i=10000000000";
    for (input) |c| try p.feed(c);
    try testing.expectError(error.Overflow, p.complete(alloc));
}

test "ensure proper overflow error for i32" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();

    const input = "a=p,i=1,z=-9999999999";
    for (input) |c| try p.feed(c);
    try testing.expectError(error.Overflow, p.complete(alloc));
}

test "all i32 values" {
    const testing = std.testing;
    const alloc = testing.allocator;

    {
        // 'z' (usually z-axis values)
        var p = Parser.init(alloc, 1024 * 1024);
        defer p.deinit();
        const input = "a=p,i=1,z=-1";
        for (input) |c| try p.feed(c);
        const command = try p.complete(alloc);
        defer command.deinit(alloc);

        try testing.expect(command.control == .display);
        const v = command.control.display;
        try testing.expectEqual(1, v.image_id);
        try testing.expectEqual(-1, v.z);
    }

    {
        // 'H' (relative placement, horizontal offset)
        var p = Parser.init(alloc, 1024 * 1024);
        defer p.deinit();
        const input = "a=p,i=1,H=-1";
        for (input) |c| try p.feed(c);
        const command = try p.complete(alloc);
        defer command.deinit(alloc);

        try testing.expect(command.control == .display);
        const v = command.control.display;
        try testing.expectEqual(1, v.image_id);
        try testing.expectEqual(-1, v.horizontal_offset);
    }

    {
        // 'V' (relative placement, vertical offset)
        var p = Parser.init(alloc, 1024 * 1024);
        defer p.deinit();
        const input = "a=p,i=1,V=-1";
        for (input) |c| try p.feed(c);
        const command = try p.complete(alloc);
        defer command.deinit(alloc);

        try testing.expect(command.control == .display);
        const v = command.control.display;
        try testing.expectEqual(1, v.image_id);
        try testing.expectEqual(-1, v.vertical_offset);
    }
}

test "response: encode nothing without ID or image number" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    var r: Response = .{};
    try r.encode(&writer);
    try testing.expectEqualStrings("", writer.buffered());
}

test "response: encode with only image id" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    var r: Response = .{ .id = 4 };
    try r.encode(&writer);
    try testing.expectEqualStrings("\x1b_Gi=4;OK\x1b\\", writer.buffered());
}

test "response: encode with only image number" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    var r: Response = .{ .image_number = 4 };
    try r.encode(&writer);
    try testing.expectEqualStrings("\x1b_GI=4;OK\x1b\\", writer.buffered());
}

test "response: encode with image ID and number" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    var r: Response = .{ .id = 12, .image_number = 4 };
    try r.encode(&writer);
    try testing.expectEqualStrings("\x1b_Gi=12,I=4;OK\x1b\\", writer.buffered());
}

test "delete range command 1" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();

    const input = "a=d,d=r,x=3,y=4";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);

    try testing.expect(command.control == .delete);
    const v = command.control.delete.action;
    try testing.expect(v == .range);
    const range = v.range;
    try testing.expect(!range.delete);
    try testing.expectEqual(@as(u32, 3), range.first);
    try testing.expectEqual(@as(u32, 4), range.last);
}

test "delete range command 2" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();

    const input = "a=d,d=R,x=5,y=11";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);

    try testing.expect(command.control == .delete);
    const v = command.control.delete.action;
    try testing.expect(v == .range);
    const range = v.range;
    try testing.expect(range.delete);
    try testing.expectEqual(@as(u32, 5), range.first);
    try testing.expectEqual(@as(u32, 11), range.last);
}

test "delete range command 3" {
    // An inverted range is accepted; it simply matches no images. This
    // matches kitty, which does no validation and filters with
    // `x <= image_id <= y`.
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();

    const input = "a=d,d=R,x=5,y=4";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);

    try testing.expect(command.control == .delete);
    const v = command.control.delete.action;
    try testing.expect(v == .range);
    const range = v.range;
    try testing.expect(range.delete);
    try testing.expectEqual(@as(u32, 5), range.first);
    try testing.expectEqual(@as(u32, 4), range.last);
}

test "delete range command 4" {
    // An omitted upper bound defaults to zero, which matches no images
    // since image IDs are always non-zero.
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();

    const input = "a=d,d=R,x=5";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);

    try testing.expect(command.control == .delete);
    const v = command.control.delete.action;
    try testing.expect(v == .range);
    const range = v.range;
    try testing.expect(range.delete);
    try testing.expectEqual(@as(u32, 5), range.first);
    try testing.expectEqual(@as(u32, 0), range.last);
}

test "delete range command 5" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();

    const input = "a=d,d=R,y=5";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);

    try testing.expect(command.control == .delete);
    const v = command.control.delete.action;
    try testing.expect(v == .range);
    const range = v.range;
    try testing.expect(range.delete);
    try testing.expectEqual(@as(u32, 0), range.first);
    try testing.expectEqual(@as(u32, 5), range.last);
}

test "delete range command 6" {
    // Both bounds omitted defaults to the empty range [0, 0].
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc, 1024 * 1024);
    defer p.deinit();

    const input = "a=d,d=r";
    for (input) |c| try p.feed(c);
    const command = try p.complete(alloc);
    defer command.deinit(alloc);

    try testing.expect(command.control == .delete);
    const v = command.control.delete.action;
    try testing.expect(v == .range);
    const range = v.range;
    try testing.expect(!range.delete);
    try testing.expectEqual(@as(u32, 0), range.first);
    try testing.expectEqual(@as(u32, 0), range.last);
}

// Kitty range-checks non-flag keys while handling the command, not while
// parsing, so a bad value never drops the command (which would make a
// response impossible even when the client gave an id). The flag keys
// "a", "d", "t" and "o" are the exception.

test "unknown format value is deferred to execution" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const command = try Parser.parseString(alloc, "a=t,f=42,i=31,s=1,v=1");
    defer command.deinit(alloc);

    try testing.expect(command.control == .transmit);
    try testing.expect(command.control.transmit.format_unknown);
    try testing.expectEqual(@as(u32, 31), command.control.transmit.image_id);
}

test "zero format value is rgba" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const command = try Parser.parseString(alloc, "a=t,f=0,i=31,s=1,v=1");
    defer command.deinit(alloc);

    try testing.expect(command.control == .transmit);
    const v = command.control.transmit;
    try testing.expect(!v.format_unknown);
    try testing.expectEqual(Transmission.Format.rgba, v.format);
}

test "known format values are not unknown" {
    const testing = std.testing;
    const alloc = testing.allocator;

    for ([_]struct { []const u8, Transmission.Format }{
        .{ "f=24", .rgb },
        .{ "f=32", .rgba },
        .{ "f=100", .png },
    }) |entry| {
        const command = try Parser.parseString(alloc, entry[0]);
        defer command.deinit(alloc);

        const v = command.control.transmit;
        try testing.expect(!v.format_unknown);
        try testing.expectEqual(entry[1], v.format);
    }
}

test "quiet value above two suppresses all responses" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const command = try Parser.parseString(alloc, "a=t,q=3,i=31,s=1,v=1");
    defer command.deinit(alloc);

    try testing.expectEqual(Command.Quiet.failures, command.quiet);
}

test "cursor movement value above one moves the cursor" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const command = try Parser.parseString(alloc, "a=p,i=31,C=2");
    defer command.deinit(alloc);

    try testing.expect(command.control == .display);
    try testing.expectEqual(
        Display.CursorMovement.after,
        command.control.display.cursor_movement,
    );
}

test "virtual placement value above one is virtual" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const command = try Parser.parseString(alloc, "a=p,i=31,U=2");
    defer command.deinit(alloc);

    try testing.expect(command.control == .display);
    try testing.expect(command.control.display.virtual_placement);
}

test "animation frame composition value above one alpha blends" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const command = try Parser.parseString(alloc, "a=f,i=31,X=2");
    defer command.deinit(alloc);

    try testing.expect(command.control == .transmit_animation_frame);
    try testing.expectEqual(
        CompositionMode.alpha_blend,
        command.control.transmit_animation_frame.composition_mode,
    );
}

test "animation compose value above one overwrites" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const command = try Parser.parseString(alloc, "a=c,i=31,C=2");
    defer command.deinit(alloc);

    try testing.expect(command.control == .compose_animation);
    try testing.expectEqual(
        CompositionMode.overwrite,
        command.control.compose_animation.composition_mode,
    );
}

test "animation control action above three is ignored" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const command = try Parser.parseString(alloc, "a=a,i=31,s=4");
    defer command.deinit(alloc);

    try testing.expect(command.control == .control_animation);
    try testing.expectEqual(
        AnimationControl.AnimationAction.invalid,
        command.control.control_animation.action,
    );
}

test "unknown flag key values still fail parsing" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Kitty rejects these while parsing too. See gen/apc_parsers.py.
    for ([_][]const u8{
        "a=z,i=31", // action
        "a=d,d=w,i=31", // delete action
        "a=t,t=q,i=31", // transmission medium
        "a=t,o=q,i=31", // compression
    }) |input| {
        try testing.expectError(
            error.InvalidFormat,
            Parser.parseString(alloc, input),
        );
    }
}
