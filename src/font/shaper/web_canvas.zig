const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ziglyph = @import("ziglyph");
const font = @import("../main.zig");
const terminal = @import("../../terminal/main.zig");
const SharedGrid = font.SharedGrid;

const log = std.log.scoped(.font_shaper);

pub const Shaper = struct {
    const RunBuf = std.MultiArrayList(struct {
        /// The codepoint for this cell. This must be used in conjunction
        /// with cluster to find the total set of codepoints for a given
        /// cell. See cluster for more information.
        codepoint: u32,

        /// Cluster is set to the X value of the cell that this codepoint
        /// is part of. Note that a cell can have multiple codepoints
        /// with zero-width joiners (ZWJ) and such. Note that terminals
        /// do NOT handle full extended grapheme clustering well so it
        /// is possible a single grapheme extends multiple clusters.
        /// For example, skin tone emoji thumbs up may show up as two
        /// clusters: one with thumbs up and the ZWJ, and a second
        /// cluster with the tone block. It is up to the shaper to handle
        /// shaping these together into a single glyph, if it wishes.
        cluster: u32,
    });

    /// The allocator used for run_buf.
    alloc: Allocator,

    /// The shared memory used for shaping results.
    cell_buf: std.ArrayListUnmanaged(font.shape.Cell),

    /// The shared memory used for storing information about a run.
    run_buf: RunBuf,

    /// The cell_buf argument is the buffer to use for storing shaped results.
    /// This should be at least the number of columns in the terminal.
    pub fn init(alloc: Allocator, _: font.shape.Options) !Shaper {
        // Note: we do not support opts.font_features

        return Shaper{
            .alloc = alloc,
            .cell_buf = .{},
            .run_buf = .{},
        };
    }

    pub fn deinit(self: *Shaper) void {
        self.run_buf.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn endFrame(self: *const Shaper) void {
        _ = self;
    }

    /// Returns an iterator that returns one text run at a time for the
    /// given terminal row. Note that text runs are are only valid one at a time
    /// for a Shaper struct since they share state.
    pub fn runIterator(
        self: *Shaper,
        grid: *SharedGrid,
        screen: *const terminal.Screen,
        row: terminal.Pin,
        selection: ?terminal.Selection,
        cursor_x: ?usize,
    ) font.shape.RunIterator {
        return .{
            .hooks = .{ .shaper = self },
            .grid = grid,
            .screen = screen,
            .row = row,
            .selection = selection,
            .cursor_x = cursor_x,
        };
    }

    /// Shape the given text run. The text run must be the immediately
    /// previous text run that was iterated since the text run does share
    /// state with the Shaper struct.
    ///
    /// The return value is only valid until the next shape call is called.
    ///
    /// If there is not enough space in the cell buffer, an error is
    /// returned.
    pub fn shape(self: *Shaper, run: font.shape.TextRun) ![]font.shape.Cell {
        // TODO: memory check that cell_buf can fit results

        const codepoints = self.run_buf.items(.codepoint);
        const clusters = self.run_buf.items(.cluster);
        assert(codepoints.len == clusters.len);

        self.cell_buf.clearRetainingCapacity();
        switch (codepoints.len) {
            // Special cases: if we have no codepoints (is this possible?)
            // then our result is also an empty cell run.
            0 => return self.cell_buf.items[0..0],

            // If we have only 1 codepoint, then we assume that it is
            // a single grapheme and just let it through. At this point,
            // we can't have any more information to do anything else.
            1 => {
                try self.cell_buf.append(self.alloc, .{
                    .x = @intCast(clusters[0]),
                    .glyph_index = codepoints[0],
                });

                return self.cell_buf.items[0..1];
            },

            else => {},
        }

        // We know we have at least two codepoints, so we now go through
        // each and perform grapheme clustering.
        //
        // Note that due to limitations of canvas, we can NOT support
        // font ligatures. However, we do support grapheme clustering.
        // This means we can render things like skin tone emoji but
        // we can't render things like single glyph "=>".
        var break_state: u3 = 0;
        var cp1: u21 = @intCast(codepoints[0]);

        var start: usize = 0;
        var i: usize = 1;
        var cur: usize = 0;
        while (i <= codepoints.len) : (i += 1) {
            // We loop to codepoints.len so that we can handle the end
            // case. In the end case, we always assume it is a grapheme
            // break. This isn't strictly true but its how terminals
            // work today.
            const grapheme_break = i == codepoints.len or blk: {
                const cp2: u21 = @intCast(codepoints[i]);
                defer cp1 = cp2;

                break :blk ziglyph.graphemeBreak(
                    cp1,
                    cp2,
                    &break_state,
                );
            };

            // If this is NOT a grapheme break, cp2 is part of a single
            // grapheme cluster and we expect there could be more. We
            // move on to the next codepoint to try again.
            if (!grapheme_break) continue;

            // This IS a grapheme break, meaning that cp2 is NOT part
            // of cp1. So we need to render the prior grapheme.
            const len = i - start;
            assert(len > 0);
            switch (len) {
                // If we have only a single codepoint then just render it
                // as-is.
                1 => try self.cell_buf.append(self.alloc, .{
                    .x = @intCast(clusters[start]),
                    .glyph_index = codepoints[start],
                }),

                // We must have multiple codepoints (see assert above). In
                // this case we UTF-8 encode the codepoints and send them
                // to the face to reserve a private glyph index.
                else => {
                    // UTF-8 encode the codepoints in this cluster.
                    const cluster = cluster: {
                        const cluster_points = codepoints[start..i];
                        assert(cluster_points.len == len);

                        const buf_len = buf_len: {
                            var acc: usize = 0;
                            for (cluster_points) |cp| {
                                acc += try std.unicode.utf8CodepointSequenceLength(
                                    @intCast(cp),
                                );
                            }

                            break :buf_len acc;
                        };

                        var buf = try self.alloc.alloc(u8, buf_len);
                        errdefer self.alloc.free(buf);
                        var buf_i: usize = 0;
                        for (cluster_points) |cp| {
                            buf_i += try std.unicode.utf8Encode(
                                @intCast(cp),
                                buf[buf_i..],
                            );
                        }

                        break :cluster buf;
                    };
                    defer self.alloc.free(cluster);

                    var face = try run.grid.resolver.collection.getFace(run.font_index);
                    const index = try face.graphemeGlyphIndex(cluster);

                    try self.cell_buf.append(self.alloc, .{
                        .x = @intCast(clusters[start]),
                        .glyph_index = index,
                    });
                },
            }

            start = i;
            cur += 1;
        }

        return self.cell_buf.items[0..cur];
    }

    /// The hooks for RunIterator.
    pub const RunIteratorHook = struct {
        shaper: *Shaper,

        pub fn prepare(self: RunIteratorHook) !void {
            // Reset the buffer for our current run
            self.shaper.run_buf.shrinkRetainingCapacity(0);
        }

        pub fn addCodepoint(
            self: RunIteratorHook,
            cp: u32,
            cluster: u32,
        ) !void {
            try self.shaper.run_buf.append(self.shaper.alloc, .{
                .codepoint = cp,
                .cluster = cluster,
            });
        }

        pub fn finalize(self: RunIteratorHook) !void {
            _ = self;
        }
    };
};

/// The wasm-compatible API.
pub const Wasm = struct {
    const wasm = @import("../../os/wasm.zig");
    const alloc = wasm.alloc;

    export fn shaper_new() ?*Shaper {
        return shaper_new_() catch null;
    }

    fn shaper_new_() !*Shaper {
        var shaper = try Shaper.init(alloc, .{});
        errdefer shaper.deinit();

        const result = try alloc.create(Shaper);
        errdefer alloc.destroy(result);
        result.* = shaper;
        return result;
    }

    export fn shaper_free(ptr: ?*Shaper) void {
        if (ptr) |v| {
            v.deinit();
            alloc.destroy(v);
        }
    }

    /// Runs a test to verify shaping works properly.
    export fn shaper_test(
        self: *Shaper,
        grid: *SharedGrid,
        str: [*]const u8,
        len: usize,
    ) void {
        shaper_test_(self, grid, str[0..len]) catch |err| {
            log.warn("error during shaper test err={}", .{err});
        };
    }
    const js = @import("zig-js");

    fn createImageData(self: *font.Atlas) !js.Object {
        // We need to draw pixels so this is format dependent.
        const buf: []u8 = switch (self.format) {
            // RGBA is the native ImageData format
            .rgba => self.data,

            .grayscale => buf: {
                // Convert from A8 to RGBA so every 4th byte is set to a value.
                var buf: []u8 = try alloc.alloc(u8, self.data.len * 4);
                errdefer alloc.free(buf);
                @memset(buf, 0);
                for (self.data, 0..) |value, i| {
                    buf[(i * 4) + 3] = value;
                }
                break :buf buf;
            },

            else => return error.UnsupportedAtlasFormat,
        };
        defer if (buf.ptr != self.data.ptr) alloc.free(buf);

        // Create an ImageData from our buffer and then write it to the canvas
        const image_data: js.Object = data: {
            // Get our runtime memory
            const mem = try js.runtime.get(js.Object, "memory");
            defer mem.deinit();
            const mem_buf = try mem.get(js.Object, "buffer");
            defer mem_buf.deinit();

            // Create an array that points to our buffer
            const arr = arr: {
                const Uint8ClampedArray = try js.global.get(js.Object, "Uint8ClampedArray");
                defer Uint8ClampedArray.deinit();
                const arr = try Uint8ClampedArray.new(.{ mem_buf, buf.ptr, buf.len });
                if (!wasm.shared_mem) break :arr arr;

                // If we're sharing memory then we have to copy the data since
                // we can't set ImageData directly using a SharedArrayBuffer.
                defer arr.deinit();
                break :arr try arr.call(js.Object, "slice", .{});
            };
            defer arr.deinit();

            // Create the image data from our array
            const ImageData = try js.global.get(js.Object, "ImageData");
            defer ImageData.deinit();
            const data = try ImageData.new(.{ arr, self.size, self.size });
            errdefer data.deinit();

            break :data data;
        };

        return image_data;
    }

    fn shaper_test_(self: *Shaper, grid: *SharedGrid, str: []const u8) !void {
        // Make a screen with some data
        var term = try terminal.Terminal.init(alloc, .{ .cols = 20, .rows = 5 });
        defer term.deinit(alloc);
        try term.printString(str);

        // Get our run iterator

        var row_it = term.screen.pages.rowIterator(.right_down, .{ .viewport = .{} }, null);
        var y: usize = 0;
        const Render = struct {
            render: SharedGrid.Render,
            y: usize,
            x: usize,
        };
        var cell_list: std.ArrayListUnmanaged(Render) = .{};
        defer cell_list.deinit(wasm.alloc);
        while (row_it.next()) |row| {
            defer y += 1;
            var it = self.runIterator(grid, &term.screen, row, null, null);
            while (try it.next(alloc)) |run| {
                const cells = try self.shape(run);
                for (cells) |cell| {
                    const render = try grid.renderGlyph(wasm.alloc, run.font_index, cell.glyph_index, .{});
                    try cell_list.append(wasm.alloc, .{ .render = render, .x = cell.x, .y = y });

                    log.info("y={} x={} width={} height={} ax={} ay={} base={}", .{
                        y * grid.metrics.cell_height,
                        cell.x * grid.metrics.cell_width,
                        render.glyph.width,
                        render.glyph.height,
                        render.glyph.atlas_x,
                        render.glyph.atlas_y,
                        grid.metrics.cell_baseline,
                    });
                }
            }
        }
        const colour_data = try createImageData(&grid.atlas_color);
        const gray_data = try createImageData(&grid.atlas_grayscale);

        const doc = try js.global.get(js.Object, "document");
        defer doc.deinit();
        const canvas = try doc.call(js.Object, "getElementById", .{js.string("shaper-canvas")});
        errdefer canvas.deinit();
        const ctx = try canvas.call(js.Object, "getContext", .{js.string("2d")});
        defer ctx.deinit();
        for (cell_list.items) |cell| {
            const x_start = -@as(isize, @intCast(cell.render.glyph.atlas_x));
            const y_start = -@as(isize, @intCast(cell.render.glyph.atlas_y));
            try ctx.call(void, "putImageData", .{
                if (cell.render.presentation == .emoji) colour_data else gray_data,
                x_start + @as(isize, @intCast(cell.x * grid.metrics.cell_width)) + cell.render.glyph.offset_x,
                y_start + @as(isize, @intCast((cell.y + 1) * grid.metrics.cell_height)) - cell.render.glyph.offset_y,
                cell.render.glyph.atlas_x,
                cell.render.glyph.atlas_y,
                cell.render.glyph.width,
                cell.render.glyph.height,
            });
        }
    }
};
