const std = @import("std");
const builtin = @import("builtin");
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");

const framedata = @import("framedata").compressed;

const vxfw = vaxis.vxfw;

pub const Options = struct {
    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables `-h` and `--help` to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// Original frame dimensions (from the website animation)
const orig_frame_width: usize = 100;
const orig_frame_height: usize = 41;

/// Minimum terminal size to show anything meaningful
const min_width: usize = 20;
const min_height: usize = 8;

/// A single grapheme with its style
const StyledGrapheme = struct {
    bytes: []const u8,
    style: vaxis.Style,
};

const Boo = struct {
    gpa: Allocator,
    frame: u8,
    framerate: u32, // 30 fps

    ghostty_style: vaxis.Style,
    outline_style: vaxis.Style,

    // Dynamic buffer - allocated based on terminal size
    buffer: []vaxis.Cell = &.{},
    buffer_size: usize = 0,

    // Current render dimensions (may differ from original)
    render_width: usize = 0,
    render_height: usize = 0,

    // Parsed frame data: array of lines, each line is array of styled graphemes
    parsed_frame: [][]StyledGrapheme = &.{},

    fn init(self: *Boo, gpa: Allocator) void {
        self.gpa = gpa;
        self.frame = 0;
        self.framerate = 1000 / 30;
        self.ghostty_style = .{};
        self.outline_style = .{ .fg = .{ .index = 4 } };
    }

    fn deinit(self: *Boo) void {
        if (self.buffer.len > 0) {
            self.gpa.free(self.buffer);
            self.buffer = &.{};
        }
        self.freeParsedFrame();
    }

    fn freeParsedFrame(self: *Boo) void {
        for (self.parsed_frame) |line| {
            for (line) |g| {
                self.gpa.free(g.bytes);
            }
            self.gpa.free(line);
        }
        self.gpa.free(self.parsed_frame);
        self.parsed_frame = &.{};
    }

    fn widget(self: *Boo) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Boo.typeErasedEventHandler,
            .drawFn = Boo.typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Boo = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init,
            .tick,
            => {
                self.updateFrame();
                ctx.redraw = true;
                return ctx.tick(self.framerate, self.widget());
            },
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true }) or
                    key.matches(vaxis.Key.escape, .{}))
                {
                    ctx.quit = true;
                    return;
                }
            },
            else => {},
        }
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Boo = @ptrCast(@alignCast(ptr));
        const max = ctx.max.size();

        // Check minimum size
        if (max.width < min_width or max.height < min_height) {
            const text: vxfw.Text = .{ .text = "Terminal too small for +boo (min: 20w x 8h)" };
            const center: vxfw.Center = .{ .child = text.widget() };
            return center.draw(ctx);
        }

        // Calculate render dimensions with adaptive scaling
        const render_w = @min(max.width, orig_frame_width);
        const render_h = @min(max.height, orig_frame_height);

        // Resize buffer if needed
        const needed = render_w * render_h;
        if (self.buffer_size != needed) {
            if (self.buffer.len > 0) self.gpa.free(self.buffer);
            self.buffer = try self.gpa.alloc(vaxis.Cell, needed);
            self.buffer_size = needed;
            @memset(self.buffer, .{});
        }

        self.render_width = render_w;
        self.render_height = render_h;

        // Calculate offsets to center the animation
        const offset_y: i32 = @intCast((max.height - render_h) / 2);
        const offset_x: i32 = @intCast((max.width - render_w) / 2);

        // Create the animation surface
        const child: vxfw.Surface = .{
            .size = .{ .width = @intCast(render_w), .height = @intCast(render_h) },
            .widget = self.widget(),
            .buffer = self.buffer,
            .children = &.{},
        };

        // Allocate a slice of child surfaces
        var children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{
            .origin = .{ .row = @intCast(offset_y), .col = @intCast(offset_x) },
            .surface = child,
        };

        return .{
            .size = max,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }

    /// Parse a raw frame string into styled graphemes, handling HTML spans
    fn parseFrame(self: *Boo, frame: []const u8) Allocator.Error!void {
        self.freeParsedFrame();

        // Count lines first
        var line_count: usize = 0;
        {
            var it = std.mem.splitScalar(u8, frame, '\n');
            while (it.next()) |_| line_count += 1;
        }

        self.parsed_frame = try self.gpa.alloc([]StyledGrapheme, line_count);

        var line_iter = std.mem.splitScalar(u8, frame, '\n');
        var line_idx: usize = 0;

        while (line_iter.next()) |line| {
            // Count graphemes first (excluding HTML tags)
            var grapheme_count: usize = 0;
            {
                var state: enum { normal, span, in_tag, in_closing_tag } = .normal;
                var cp_iter: std.unicode.Utf8Iterator = .{ .bytes = line, .i = 0 };
                while (cp_iter.nextCodepointSlice()) |char| {
                    switch (state) {
                        .normal => if (std.mem.eql(u8, "<", char)) {
                            state = .in_tag;
                            continue;
                        },
                        .span => if (std.mem.eql(u8, "<", char)) {
                            state = .in_tag;
                            continue;
                        },
                        .in_tag => {
                            if (std.mem.eql(u8, "/", char))
                                state = .in_closing_tag
                            else if (std.mem.eql(u8, ">", char))
                                state = .span;
                            continue;
                        },
                        .in_closing_tag => {
                            if (std.mem.eql(u8, ">", char)) state = .normal;
                            continue;
                        },
                    }
                    grapheme_count += 1;
                }
            }

            const graphemes = try self.gpa.alloc(StyledGrapheme, grapheme_count);

            // Now actually parse with styles
            var state: enum { normal, span, in_tag, in_closing_tag } = .normal;
            var style = self.ghostty_style;
            var gi: usize = 0;

            var cp_iter: std.unicode.Utf8Iterator = .{ .bytes = line, .i = 0 };
            while (cp_iter.nextCodepointSlice()) |char| {
                switch (state) {
                    .normal => if (std.mem.eql(u8, "<", char)) {
                        state = .in_tag;
                        style = self.outline_style;
                        continue;
                    },
                    .span => if (std.mem.eql(u8, "<", char)) {
                        state = .in_tag;
                        style = self.ghostty_style;
                        continue;
                    },
                    .in_tag => {
                        if (std.mem.eql(u8, "/", char))
                            state = .in_closing_tag
                        else if (std.mem.eql(u8, ">", char))
                            state = .span;
                        continue;
                    },
                    .in_closing_tag => {
                        if (std.mem.eql(u8, ">", char)) state = .normal;
                        continue;
                    },
                }
                // Store a copy of the grapheme bytes
                const copy = try self.gpa.dupe(u8, char);
                graphemes[gi] = .{
                    .bytes = copy,
                    .style = style,
                };
                gi += 1;
            }

            self.parsed_frame[line_idx] = graphemes;
            line_idx += 1;
        }
    }

    /// Updates our internal buffer with the current frame, then advances the frame index
    fn updateFrame(self: *Boo) void {
        const frame = frames[self.frame];

        // Parse frame if not already parsed
        if (self.parsed_frame.len == 0) {
            self.parseFrame(frame) catch return;
        }

        const src_w = orig_frame_width;
        const src_h = self.parsed_frame.len;
        const dst_w = self.render_width;
        const dst_h = self.render_height;

        if (dst_w < src_w or dst_h < src_h) {
            // Scaled render
            self.updateFrameScaled(src_w, src_h, dst_w, dst_h);
        } else {
            // Full size: direct copy
            self.updateFrameFull(dst_w);
        }

        // Lastly, update the frame index
        self.frame += 1;
        if (self.frame == frames.len) self.frame = 0;
    }

    /// Full size render - direct copy from parsed frame
    fn updateFrameFull(self: *Boo, dst_w: usize) void {
        var cell_idx: usize = 0;
        const lines_to_render = @min(self.render_height, self.parsed_frame.len);

        var y: usize = 0;
        while (y < lines_to_render) : (y += 1) {
            const line = self.parsed_frame[y];
            const chars_to_render = @min(line.len, dst_w);

            var x: usize = 0;
            while (x < chars_to_render) : (x += 1) {
                self.buffer[cell_idx] = .{
                    .char = .{
                        .grapheme = line[x].bytes,
                        .width = 1,
                    },
                    .style = line[x].style,
                };
                cell_idx += 1;
            }

            // Pad remaining width
            while (x < dst_w) : (x += 1) {
                self.buffer[cell_idx] = .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = .{},
                };
                cell_idx += 1;
            }
        }

        // Fill remaining rows if render height > parsed lines
        while (cell_idx < self.buffer_size) : (cell_idx += 1) {
            self.buffer[cell_idx] = .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = .{},
            };
        }
    }

    /// Scaled render - sample from source to fit destination
    fn updateFrameScaled(self: *Boo, src_w: usize, src_h: usize, dst_w: usize, dst_h: usize) void {
        var cell_idx: usize = 0;

        const x_scale: f32 = @as(f32, @floatFromInt(src_w)) / @as(f32, @floatFromInt(dst_w));
        const y_scale: f32 = @as(f32, @floatFromInt(src_h)) / @as(f32, @floatFromInt(dst_h));

        var dy: usize = 0;
        while (dy < dst_h) : (dy += 1) {
            const sy: usize = @min(
                @as(usize, @intFromFloat(@floor(@as(f32, @floatFromInt(dy)) * y_scale))),
                src_h -| 1,
            );

            if (sy >= self.parsed_frame.len) {
                var dx: usize = 0;
                while (dx < dst_w) : (dx += 1) {
                    self.buffer[cell_idx] = .{
                        .char = .{ .grapheme = " ", .width = 1 },
                        .style = .{},
                    };
                    cell_idx += 1;
                }
                continue;
            }

            const line = self.parsed_frame[sy];

            var dx: usize = 0;
            while (dx < dst_w) : (dx += 1) {
                if (line.len == 0) {
                    self.buffer[cell_idx] = .{
                        .char = .{ .grapheme = " ", .width = 1 },
                        .style = .{},
                    };
                    cell_idx += 1;
                    continue;
                }

                const sx: usize = @min(
                    @as(usize, @intFromFloat(@floor(@as(f32, @floatFromInt(dx)) * x_scale))),
                    line.len -| 1,
                );

                if (sx < line.len) {
                    self.buffer[cell_idx] = .{
                        .char = .{
                            .grapheme = line[sx].bytes,
                            .width = 1,
                        },
                        .style = line[sx].style,
                    };
                } else {
                    self.buffer[cell_idx] = .{
                        .char = .{ .grapheme = " ", .width = 1 },
                        .style = .{},
                    };
                }
                cell_idx += 1;
            }
        }
    }
};

/// The `boo` command is used to display the animation from the Ghostty website in the terminal
pub fn run(gpa: Allocator) !u8 {
    // Disable on non-desktop systems.
    switch (builtin.os.tag) {
        .windows, .macos, .linux, .freebsd => {},
        else => return 1,
    }

    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(gpa);
        defer iter.deinit();
        try args.parse(Options, gpa, &opts, &iter);
    }

    try decompressFrames(gpa);
    defer {
        gpa.free(frames);
        gpa.free(decompressed_data);
    }

    var app = try vxfw.App.init(gpa);
    defer app.deinit();

    var boo: Boo = undefined;
    boo.init(gpa);
    defer boo.deinit();

    try app.run(boo.widget(), .{});

    return 0;
}

/// We store a global ref to the decompressed data. All of our frames reference into this data
var decompressed_data: []const u8 = undefined;

/// Heap allocated list of frames. The underlying frame data references decompressed_data
var frames: []const []const u8 = undefined;

/// Decompress the frames into a slice of individual frames
fn decompressFrames(gpa: Allocator) !void {
    var src: std.Io.Reader = .fixed(framedata);

    var decompress: std.compress.flate.Decompress = .init(&src, .raw, &.{});

    var out: std.Io.Writer.Allocating = .init(gpa);
    _ = try decompress.reader.streamRemaining(&out.writer);
    decompressed_data = try out.toOwnedSlice();

    var frame_list: std.ArrayList([]const u8) = try .initCapacity(gpa, 235);

    var frame_iter = std.mem.splitScalar(u8, decompressed_data, '\x01');
    while (frame_iter.next()) |frame| {
        try frame_list.append(gpa, frame);
    }
    frames = try frame_list.toOwnedSlice(gpa);
}
