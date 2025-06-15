const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const simd = @import("../../simd/main.zig");

const log = std.log.scoped(.kitty_gfx);

/// The key-value pairs for the control information for a command. The
/// keys are always single characters and the values are either single
/// characters or 32-bit unsigned integers.
///
/// For the value of this: if the value is a single printable ASCII character
/// it is the ASCII code. Otherwise, it is parsed as a 32-bit unsigned integer.
const KV = std.AutoHashMapUnmanaged(u8, u32);

/// Command parser parses the Kitty graphics protocol escape sequence.
pub const Parser = struct {
    /// The memory used by the parser is stored in an arena because it is
    /// all freed at the end of the command.
    arena: ArenaAllocator,

    /// This is the list of KV pairs that we're building up.
    kv: KV = .{},

    /// This is used as a buffer to store the key/value of a KV pair. The value
    /// of a KV pair is at most a 32-bit integer which at most is 10 characters
    /// (4294967295), plus one character for the sign bit on signed ints.
    kv_temp: [11]u8 = undefined,
    kv_temp_len: u4 = 0,
    kv_current: u8 = 0, // Current kv key

    /// This is the list we use to collect the bytes from the data payload.
    /// The Kitty Graphics protocol specification seems to imply that the
    /// payload content of a single command should never exceed 4096 bytes,
    /// but Kitty itself supports larger payloads, so we use an ArrayList
    /// here instead of a fixed buffer so that we can too.
    data: std.ArrayList(u8),

    /// Internal state for parsing.
    state: State = .control_key,

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
    pub fn init(alloc: Allocator) Parser {
        var arena = ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        return .{
            .arena = arena,
            .data = std.ArrayList(u8).init(alloc),
        };
    }

    pub fn deinit(self: *Parser) void {
        // We don't free the hash map because its in the arena
        self.arena.deinit();
        self.data.deinit();
    }

    /// Parse a complete command string.
    pub fn parseString(alloc: Allocator, data: []const u8) !Command {
        var parser = init(alloc);
        defer parser.deinit();
        for (data) |c| try parser.feed(c);
        return try parser.complete();
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

            .data => try self.data.append(c),
        }
    }

    /// Complete the parsing. This must be called after all the
    /// bytes have been fed to the parser.
    ///
    /// The allocator given will be used for the long-lived data
    /// of the final command.
    pub fn complete(self: *Parser) !Command {
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
            'a' => .{ .control_animation = try .parse(self.kv) },
            'c' => .{ .compose_animation = try .parse(self.kv) },
            else => return error.InvalidFormat,
        };

        // Determine our quiet value
        const quiet: Command.Quiet = if (self.kv.get('q')) |v| quiet: {
            break :quiet switch (v) {
                0 => .no,
                1 => .ok,
                2 => .failures,
                else => return error.InvalidFormat,
            };
        } else .no;

        return .{
            .control = control,
            .quiet = quiet,
            .data = try self.decodeData(),
        };
    }

    /// Decodes the payload data from base64 and returns it as a slice.
    /// This function will destroy the contents of self.data, it should
    /// only be used once we are done collecting payload bytes.
    fn decodeData(self: *Parser) ![]const u8 {
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

        return try self.data.toOwnedSlice();
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
        const alloc = self.arena.allocator();

        // We can move states right away, we don't use it.
        self.state = next_state;

        // Check for ASCII chars first
        if (self.kv_temp_len == 1) {
            const c = self.kv_temp[0];
            if (c < '0' or c > '9') {
                try self.kv.put(alloc, self.kv_current, @intCast(c));
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
        try self.kv.put(alloc, self.kv_current, v);

        // Clear our temp buffer
        self.kv_temp_len = 0;
    }
};

/// Represents a possible response to a command.
pub const Response = struct {
    id: u32 = 0,
    image_number: u32 = 0,
    placement_id: u32 = 0,
    message: []const u8 = "OK",

    pub fn encode(self: Response, writer: anytype) !void {
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

    pub const Format = enum {
        rgb, // 24
        rgba, // 32
        png, // 100

        // The following are not supported directly via the protocol
        // but they are formats that a png may decode to that we
        // support.
        gray_alpha,
        gray,

        pub fn bpp(self: Format) u8 {
            return switch (self) {
                .gray => 1,
                .gray_alpha => 2,
                .rgb => 3,
                .rgba => 4,
                .png => unreachable, // Must be validated before
            };
        }
    };

    pub const Medium = enum {
        direct, // d
        file, // f
        temporary_file, // t
        shared_memory, // s
    };

    pub const Compression = enum {
        none,
        zlib_deflate, // z
    };

    fn parse(kv: KV) !Transmission {
        var result: Transmission = .{};
        if (kv.get('f')) |v| {
            result.format = switch (v) {
                24 => .rgb,
                32 => .rgba,
                100 => .png,
                else => return error.InvalidFormat,
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
            result.cursor_movement = switch (v) {
                0 => .after,
                1 => .none,
                else => return error.InvalidFormat,
            };
        }

        if (kv.get('U')) |v| {
            result.virtual_placement = switch (v) {
                0 => false,
                1 => true,
                else => return error.InvalidFormat,
            };
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
    x: u32 = 0, // x
    y: u32 = 0, // y
    create_frame: u32 = 0, // c
    edit_frame: u32 = 0, // r
    gap_ms: u32 = 0, // z
    composition_mode: CompositionMode = .alpha_blend, // X
    background: Background = .{}, // Y

    pub const Background = packed struct(u32) {
        r: u8 = 0,
        g: u8 = 0,
        b: u8 = 0,
        a: u8 = 0,
    };

    fn parse(kv: KV) !AnimationFrameLoading {
        var result: AnimationFrameLoading = .{};

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
            result.gap_ms = v;
        }

        if (kv.get('X')) |v| {
            result.composition_mode = switch (v) {
                0 => .alpha_blend,
                1 => .overwrite,
                else => return error.InvalidFormat,
            };
        }

        if (kv.get('Y')) |v| {
            result.background = @bitCast(v);
        }

        return result;
    }
};

pub const AnimationFrameComposition = struct {
    frame: u32 = 0, // c
    edit_frame: u32 = 0, // r
    x: u32 = 0, // x
    y: u32 = 0, // y
    width: u32 = 0, // w
    height: u32 = 0, // h
    left_edge: u32 = 0, // X
    top_edge: u32 = 0, // Y
    composition_mode: CompositionMode = .alpha_blend, // C

    fn parse(kv: KV) !AnimationFrameComposition {
        var result: AnimationFrameComposition = .{};

        if (kv.get('c')) |v| {
            result.frame = v;
        }

        if (kv.get('r')) |v| {
            result.edit_frame = v;
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
            result.composition_mode = switch (v) {
                0 => .alpha_blend,
                1 => .overwrite,
                else => return error.InvalidFormat,
            };
        }

        return result;
    }
};

pub const AnimationControl = struct {
    action: AnimationAction = .invalid, // s
    frame: u32 = 0, // r
    gap_ms: u32 = 0, // z
    current_frame: u32 = 0, // c
    loops: u32 = 0, // v

    pub const AnimationAction = enum {
        invalid, // 0
        stop, // 1
        run_wait, // 2
        run, // 3
    };

    fn parse(kv: KV) !AnimationControl {
        var result: AnimationControl = .{};

        if (kv.get('s')) |v| {
            result.action = switch (v) {
                0 => .invalid,
                1 => .stop,
                2 => .run_wait,
                3 => .run,
                else => return error.InvalidFormat,
            };
        }

        if (kv.get('r')) |v| {
            result.frame = v;
        }

        if (kv.get('z')) |v| {
            result.gap_ms = v;
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

pub const Delete = union(enum) {
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
    animation_frames: bool,

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

    fn parse(kv: KV) !Delete {
        const what: u8 = what: {
            const value = kv.get('d') orelse break :what 'a';
            const c = std.math.cast(u8, value) orelse return error.InvalidFormat;
            break :what c;
        };

        return switch (what) {
            'a', 'A' => .{ .all = what == 'A' },

            'i', 'I' => blk: {
                var result: Delete = .{ .id = .{ .delete = what == 'I' } };
                if (kv.get('i')) |v| {
                    result.id.image_id = v;
                }
                if (kv.get('p')) |v| {
                    result.id.placement_id = v;
                }

                break :blk result;
            },

            'n', 'N' => blk: {
                var result: Delete = .{ .newest = .{ .delete = what == 'N' } };
                if (kv.get('I')) |v| {
                    result.newest.image_number = v;
                }
                if (kv.get('p')) |v| {
                    result.newest.placement_id = v;
                }

                break :blk result;
            },

            'c', 'C' => .{ .intersect_cursor = what == 'C' },

            'f', 'F' => .{ .animation_frames = what == 'F' },

            'p', 'P' => blk: {
                var result: Delete = .{ .intersect_cell = .{ .delete = what == 'P' } };
                if (kv.get('x')) |v| {
                    result.intersect_cell.x = v;
                }
                if (kv.get('y')) |v| {
                    result.intersect_cell.y = v;
                }

                break :blk result;
            },

            'q', 'Q' => blk: {
                var result: Delete = .{ .intersect_cell_z = .{ .delete = what == 'Q' } };
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
                const x = kv.get('x') orelse return error.InvalidFormat;
                const y = kv.get('y') orelse return error.InvalidFormat;
                if (x > y) return error.InvalidFormat;
                break :blk .{
                    .range = .{
                        .delete = what == 'R',
                        .first = x,
                        .last = y,
                    },
                };
            },

            'x', 'X' => blk: {
                var result: Delete = .{ .column = .{ .delete = what == 'X' } };
                if (kv.get('x')) |v| {
                    result.column.x = v;
                }

                break :blk result;
            },

            'y', 'Y' => blk: {
                var result: Delete = .{ .row = .{ .delete = what == 'Y' } };
                if (kv.get('y')) |v| {
                    result.row.y = v;
                }

                break :blk result;
            },

            'z', 'Z' => blk: {
                var result: Delete = .{ .z = .{ .delete = what == 'Z' } };
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

pub const CompositionMode = enum {
    alpha_blend, // 0
    overwrite, // 1
};

test "transmission command" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc);
    defer p.deinit();

    const input = "f=24,s=10,v=20";
    for (input) |c| try p.feed(c);
    const command = try p.complete();
    defer command.deinit(alloc);

    try testing.expect(command.control == .transmit);
    const v = command.control.transmit;
    try testing.expectEqual(Transmission.Format.rgb, v.format);
    try testing.expectEqual(@as(u32, 10), v.width);
    try testing.expectEqual(@as(u32, 20), v.height);
}

test "transmission ignores 'm' if medium is not direct" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc);
    defer p.deinit();

    const input = "a=t,t=t,m=1";
    for (input) |c| try p.feed(c);
    const command = try p.complete();
    defer command.deinit(alloc);

    try testing.expect(command.control == .transmit);
    const v = command.control.transmit;
    try testing.expectEqual(Transmission.Medium.temporary_file, v.medium);
    try testing.expect(!v.more_chunks);
}

test "transmission respects 'm' if medium is direct" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc);
    defer p.deinit();

    const input = "a=t,t=d,m=1";
    for (input) |c| try p.feed(c);
    const command = try p.complete();
    defer command.deinit(alloc);

    try testing.expect(command.control == .transmit);
    const v = command.control.transmit;
    try testing.expectEqual(Transmission.Medium.direct, v.medium);
    try testing.expect(v.more_chunks);
}

test "query command" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc);
    defer p.deinit();

    const input = "i=31,s=1,v=1,a=q,t=d,f=24;QUFBQQ";
    for (input) |c| try p.feed(c);
    const command = try p.complete();
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
    var p = Parser.init(alloc);
    defer p.deinit();

    const input = "a=p,U=1,i=31,c=80,r=120";
    for (input) |c| try p.feed(c);
    const command = try p.complete();
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
    var p = Parser.init(alloc);
    defer p.deinit();

    const input = "a=d,d=p,x=3,y=4";
    for (input) |c| try p.feed(c);
    const command = try p.complete();
    defer command.deinit(alloc);

    try testing.expect(command.control == .delete);
    const v = command.control.delete;
    try testing.expect(v == .intersect_cell);
    const dv = v.intersect_cell;
    try testing.expect(!dv.delete);
    try testing.expectEqual(@as(u32, 3), dv.x);
    try testing.expectEqual(@as(u32, 4), dv.y);
}

test "no control data" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc);
    defer p.deinit();

    const input = ";QUFBQQ";
    for (input) |c| try p.feed(c);
    const command = try p.complete();
    defer command.deinit(alloc);

    try testing.expect(command.control == .transmit);
    try testing.expectEqualStrings("AAAA", command.data);
}

test "ignore unknown keys (long)" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc);
    defer p.deinit();

    const input = "f=24,s=10,v=20,hello=world";
    for (input) |c| try p.feed(c);
    const command = try p.complete();
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
    var p = Parser.init(alloc);
    defer p.deinit();

    const input = "f=24,s=10,v=2000000000000000000000000000000000000000";
    for (input) |c| try p.feed(c);
    const command = try p.complete();
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
    var p = Parser.init(alloc);
    defer p.deinit();

    const input = "a=p,i=1,z=-2000000000";
    for (input) |c| try p.feed(c);
    const command = try p.complete();
    defer command.deinit(alloc);

    try testing.expect(command.control == .display);
    const v = command.control.display;
    try testing.expectEqual(1, v.image_id);
    try testing.expectEqual(-2000000000, v.z);
}

test "ensure proper overflow error for u32" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc);
    defer p.deinit();

    const input = "a=p,i=10000000000";
    for (input) |c| try p.feed(c);
    try testing.expectError(error.Overflow, p.complete());
}

test "ensure proper overflow error for i32" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc);
    defer p.deinit();

    const input = "a=p,i=1,z=-9999999999";
    for (input) |c| try p.feed(c);
    try testing.expectError(error.Overflow, p.complete());
}

test "all i32 values" {
    const testing = std.testing;
    const alloc = testing.allocator;

    {
        // 'z' (usually z-axis values)
        var p = Parser.init(alloc);
        defer p.deinit();
        const input = "a=p,i=1,z=-1";
        for (input) |c| try p.feed(c);
        const command = try p.complete();
        defer command.deinit(alloc);

        try testing.expect(command.control == .display);
        const v = command.control.display;
        try testing.expectEqual(1, v.image_id);
        try testing.expectEqual(-1, v.z);
    }

    {
        // 'H' (relative placement, horizontal offset)
        var p = Parser.init(alloc);
        defer p.deinit();
        const input = "a=p,i=1,H=-1";
        for (input) |c| try p.feed(c);
        const command = try p.complete();
        defer command.deinit(alloc);

        try testing.expect(command.control == .display);
        const v = command.control.display;
        try testing.expectEqual(1, v.image_id);
        try testing.expectEqual(-1, v.horizontal_offset);
    }

    {
        // 'V' (relative placement, vertical offset)
        var p = Parser.init(alloc);
        defer p.deinit();
        const input = "a=p,i=1,V=-1";
        for (input) |c| try p.feed(c);
        const command = try p.complete();
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
    var fbs = std.io.fixedBufferStream(&buf);

    var r: Response = .{};
    try r.encode(fbs.writer());
    try testing.expectEqualStrings("", fbs.getWritten());
}

test "response: encode with only image id" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var r: Response = .{ .id = 4 };
    try r.encode(fbs.writer());
    try testing.expectEqualStrings("\x1b_Gi=4;OK\x1b\\", fbs.getWritten());
}

test "response: encode with only image number" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var r: Response = .{ .image_number = 4 };
    try r.encode(fbs.writer());
    try testing.expectEqualStrings("\x1b_GI=4;OK\x1b\\", fbs.getWritten());
}

test "response: encode with image ID and number" {
    const testing = std.testing;
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var r: Response = .{ .id = 12, .image_number = 4 };
    try r.encode(fbs.writer());
    try testing.expectEqualStrings("\x1b_Gi=12,I=4;OK\x1b\\", fbs.getWritten());
}

test "delete range command 1" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc);
    defer p.deinit();

    const input = "a=d,d=r,x=3,y=4";
    for (input) |c| try p.feed(c);
    const command = try p.complete();
    defer command.deinit(alloc);

    try testing.expect(command.control == .delete);
    const v = command.control.delete;
    try testing.expect(v == .range);
    const range = v.range;
    try testing.expect(!range.delete);
    try testing.expectEqual(@as(u32, 3), range.first);
    try testing.expectEqual(@as(u32, 4), range.last);
}

test "delete range command 2" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc);
    defer p.deinit();

    const input = "a=d,d=R,x=5,y=11";
    for (input) |c| try p.feed(c);
    const command = try p.complete();
    defer command.deinit(alloc);

    try testing.expect(command.control == .delete);
    const v = command.control.delete;
    try testing.expect(v == .range);
    const range = v.range;
    try testing.expect(range.delete);
    try testing.expectEqual(@as(u32, 5), range.first);
    try testing.expectEqual(@as(u32, 11), range.last);
}

test "delete range command 3" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc);
    defer p.deinit();

    const input = "a=d,d=R,x=5,y=4";
    for (input) |c| try p.feed(c);
    try testing.expectError(error.InvalidFormat, p.complete());
}

test "delete range command 4" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc);
    defer p.deinit();

    const input = "a=d,d=R,x=5";
    for (input) |c| try p.feed(c);
    try testing.expectError(error.InvalidFormat, p.complete());
}

test "delete range command 5" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var p = Parser.init(alloc);
    defer p.deinit();

    const input = "a=d,d=R,y=5";
    for (input) |c| try p.feed(c);
    try testing.expectError(error.InvalidFormat, p.complete());
}
