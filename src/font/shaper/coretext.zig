const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const macos = @import("macos");
const itijah = @import("itijah");
const bidi_helpers = @import("bidi_helpers.zig");
const font = @import("../main.zig");
const os = @import("../../os/main.zig");
const terminal = @import("../../terminal/main.zig");
const unicode = @import("../../unicode/main.zig");
const Feature = font.shape.Feature;
const FeatureList = font.shape.FeatureList;
const default_features = font.shape.default_features;
const Face = font.Face;
const Collection = font.Collection;
const DeferredFace = font.DeferredFace;
const Group = font.Group;
const GroupCache = font.GroupCache;
const Library = font.Library;
const SharedGrid = font.SharedGrid;
const Style = font.Style;
const Presentation = font.Presentation;
const CFReleaseThread = os.CFReleaseThread;

const log = std.log.scoped(.font_shaper);

/// Shaper that uses CoreText.
///
/// CoreText shaping differs in subtle ways from HarfBuzz so it may result
/// in inconsistent rendering across platforms. But it also fixes many
/// issues (some macOS specific):
///
///   - Theta hat offset is incorrect in HarfBuzz but correct by default
///     on macOS applications using CoreText. (See:
///     https://github.com/harfbuzz/harfbuzz/discussions/4525)
///
///   - Hyphens (U+2010) can be synthesized by CoreText but not by HarfBuzz.
///     See: https://github.com/mitchellh/ghostty/issues/1643
///
pub const Shaper = struct {
    /// The allocated used for the feature list, font cache, and cell buf.
    alloc: Allocator,

    /// The string used for shaping the current run.
    run_state: RunState,

    /// CoreFoundation Dictionary which represents our font feature settings.
    features: *macos.foundation.Dictionary,
    /// A version of the features dictionary with the default features excluded.
    features_no_default: *macos.foundation.Dictionary,

    /// The shared memory used for shaping results.
    cell_buf: CellBuf,
    /// Per-cluster x anchors captured when a cluster first establishes its
    /// cell offset. This lets out-of-order combining marks re-anchor to the
    /// correct base cluster.
    cluster_anchor_x: std.ArrayListUnmanaged(f64),

    /// Cached attributes dict for creating CTTypesetter objects.
    /// The values in this never change so we can avoid overhead
    /// by just creating it once and saving it for reuse.
    typesetter_attr_dict: *macos.foundation.Dictionary,
    /// Same as above but with embedding level 1 (RTL).
    typesetter_attr_dict_rtl: *macos.foundation.Dictionary,

    /// List where we cache fonts, so we don't have to remake them for
    /// every single shaping operation.
    ///
    /// Fonts are cached as attribute dictionaries to be applied directly to
    /// attributed strings.
    cached_fonts: std.ArrayListUnmanaged(?*macos.foundation.Dictionary),

    /// The grid that our cached fonts correspond to.
    /// If the grid changes then we need to reset our cache.
    cached_font_grid: usize,

    /// The list of CoreFoundation objects to release on the dedicated
    /// release thread. This is built up over the course of shaping and
    /// sent to the release thread when endFrame is called.
    cf_release_pool: std.ArrayListUnmanaged(*anyopaque),

    /// Dedicated thread for releasing CoreFoundation objects. Some objects,
    /// such as those produced by CoreText, have excessively slow release
    /// callback logic.
    cf_release_thread: *CFReleaseThread,
    cf_release_thr: std.Thread,

    /// Scratch reused for terminal bidi layout resolution.
    bidi_layout_scratch: itijah.VisualLayoutScratch = .{},

    const CellBuf = std.ArrayListUnmanaged(font.shape.Cell);
    const CodepointList = std.ArrayListUnmanaged(Codepoint);
    const Codepoint = struct {
        codepoint: u32,
        cluster: u32,
    };

    const RunState = struct {
        codepoints: CodepointList,
        unichars: std.ArrayListUnmanaged(u16),

        fn init() RunState {
            return .{ .codepoints = .{}, .unichars = .{} };
        }

        fn deinit(self: *RunState, alloc: Allocator) void {
            self.codepoints.deinit(alloc);
            self.unichars.deinit(alloc);
        }

        fn reset(self: *RunState) void {
            self.codepoints.clearRetainingCapacity();
            self.unichars.clearRetainingCapacity();
        }
    };

    const Offset = struct {
        cluster: u32 = 0,
        x: f64 = 0,
    };

    /// Create a CoreFoundation Dictionary suitable for
    /// settings the font features of a CoreText font.
    fn makeFeaturesDict(feats: []const Feature) !*macos.foundation.Dictionary {
        const list = try macos.foundation.MutableArray.create();
        // The list will be retained by the dict once we add it to it.
        defer list.release();

        for (feats) |feat| {
            const value_num: c_int = @intCast(feat.value);

            // Keys can only be ASCII.
            var key = try macos.foundation.String.createWithBytes(&feat.tag, .ascii, false);
            defer key.release();
            var value = try macos.foundation.Number.create(.int, &value_num);
            defer value.release();

            const dict = try macos.foundation.Dictionary.create(
                &[_]?*const anyopaque{
                    macos.text.c.kCTFontOpenTypeFeatureTag,
                    macos.text.c.kCTFontOpenTypeFeatureValue,
                },
                &[_]?*const anyopaque{ key, value },
            );
            defer dict.release();

            list.appendValue(macos.foundation.Dictionary, dict);
        }

        var dict = try macos.foundation.Dictionary.create(
            &[_]?*const anyopaque{macos.text.c.kCTFontFeatureSettingsAttribute},
            &[_]?*const anyopaque{list},
        );
        errdefer dict.release();

        return dict;
    }

    /// The cell_buf argument is the buffer to use for storing shaped results.
    /// This should be at least the number of columns in the terminal.
    pub fn init(alloc: Allocator, opts: font.shape.Options) !Shaper {
        var feature_list: FeatureList = .{};
        defer feature_list.deinit(alloc);
        for (opts.features) |feature_str| {
            try feature_list.appendFromString(alloc, feature_str);
        }

        // We need to construct two attrs dictionaries for font features;
        // one without the default features included, and one with them.
        const feats = feature_list.features.items;
        const feats_df = try alloc.alloc(Feature, feats.len + default_features.len);
        defer alloc.free(feats_df);

        @memcpy(feats_df[0..default_features.len], &default_features);
        @memcpy(feats_df[default_features.len..], feats);

        const features = try makeFeaturesDict(feats_df);
        errdefer features.release();
        const features_no_default = try makeFeaturesDict(feats);
        errdefer features_no_default.release();

        var run_state = RunState.init();
        errdefer run_state.deinit(alloc);

        // Use kCTTypesetterOptionForcedEmbeddingLevel to control BiDi
        // embedding. We force embedding level 0 (LTR) for LTR runs and
        // embedding level 1 (RTL) for RTL runs. Our run iterator already
        // splits runs at direction boundaries, so each run is guaranteed
        // to be single-direction.
        //
        // See: https://github.com/mitchellh/ghostty/issues/1737
        // See: https://github.com/mitchellh/ghostty/issues/1442
        const typesetter_attr_dict = dict: {
            const num = try macos.foundation.Number.create(.int, &@as(c_int, 0));
            defer num.release();
            break :dict try macos.foundation.Dictionary.create(
                &.{macos.c.kCTTypesetterOptionForcedEmbeddingLevel},
                &.{num},
            );
        };
        errdefer typesetter_attr_dict.release();

        const typesetter_attr_dict_rtl = dict: {
            const num = try macos.foundation.Number.create(.int, &@as(c_int, 1));
            defer num.release();
            break :dict try macos.foundation.Dictionary.create(
                &.{macos.c.kCTTypesetterOptionForcedEmbeddingLevel},
                &.{num},
            );
        };
        errdefer typesetter_attr_dict_rtl.release();

        // Create the CF release thread.
        var cf_release_thread = try alloc.create(CFReleaseThread);
        errdefer alloc.destroy(cf_release_thread);
        cf_release_thread.* = try .init(alloc);
        errdefer cf_release_thread.deinit();

        // Start the CF release thread.
        var cf_release_thr = try std.Thread.spawn(
            .{},
            CFReleaseThread.threadMain,
            .{cf_release_thread},
        );
        cf_release_thr.setName("cf_release") catch {};

        return .{
            .alloc = alloc,
            .cell_buf = .{},
            .cluster_anchor_x = .{},
            .run_state = run_state,
            .features = features,
            .features_no_default = features_no_default,
            .typesetter_attr_dict = typesetter_attr_dict,
            .typesetter_attr_dict_rtl = typesetter_attr_dict_rtl,
            .cached_fonts = .{},
            .cached_font_grid = 0,
            .cf_release_pool = .{},
            .cf_release_thread = cf_release_thread,
            .cf_release_thr = cf_release_thr,
        };
    }

    pub fn deinit(self: *Shaper) void {
        self.cell_buf.deinit(self.alloc);
        self.cluster_anchor_x.deinit(self.alloc);
        self.run_state.deinit(self.alloc);
        self.features.release();
        self.features_no_default.release();
        self.typesetter_attr_dict.release();
        self.typesetter_attr_dict_rtl.release();
        self.bidi_layout_scratch.deinit(self.alloc);

        {
            for (self.cached_fonts.items) |ft| {
                if (ft) |f| f.release();
            }
            self.cached_fonts.deinit(self.alloc);
        }

        if (self.cf_release_pool.items.len > 0) {
            for (self.cf_release_pool.items) |ref| macos.foundation.CFRelease(ref);

            // For tests this logic is normal because we don't want to
            // wait for a release thread. But in production this is a bug
            // and we should warn.
            if (comptime !builtin.is_test) log.warn(
                "BUG: CFRelease pool was not empty, releasing remaining objects",
                .{},
            );
        }
        self.cf_release_pool.deinit(self.alloc);

        // Stop the CF release thread
        {
            self.cf_release_thread.stop.notify() catch |err|
                log.err("error notifying cf release thread to stop, may stall err={}", .{err});
            self.cf_release_thr.join();
        }
        self.cf_release_thread.deinit();
        self.alloc.destroy(self.cf_release_thread);
    }

    pub fn endFrame(self: *Shaper) void {
        if (self.cf_release_pool.items.len == 0) return;

        // Get all the items in the pool as an owned slice so we can
        // send it to the dedicated release thread.
        const items = self.cf_release_pool.toOwnedSlice(self.alloc) catch |err| {
            log.warn("error converting release pool to owned slice, slow release err={}", .{err});
            for (self.cf_release_pool.items) |ref| macos.foundation.CFRelease(ref);
            self.cf_release_pool.clearRetainingCapacity();
            return;
        };

        // Send the items. If the send succeeds then we wake up the
        // thread to process the items. If the send fails then do a manual
        // cleanup.
        if (self.cf_release_thread.mailbox.push(.{ .release = .{
            .refs = items,
            .alloc = self.alloc,
        } }, .{ .forever = {} }) != 0) {
            self.cf_release_thread.wakeup.notify() catch |err| {
                log.warn(
                    "error notifying cf release thread to wake up, may stall err={}",
                    .{err},
                );
            };
            return;
        }

        for (items) |ref| macos.foundation.CFRelease(ref);
        self.alloc.free(items);
    }

    pub fn runIterator(
        self: *Shaper,
        opts: font.shape.RunOptions,
    ) font.shape.RunIterator {
        return .{
            .hooks = .{ .shaper = self },
            .opts = opts,
        };
    }

    /// Note that this will accumulate garbage in the release pool. The
    /// caller must ensure you're properly calling endFrame to release
    /// all the objects.
    pub fn shape(
        self: *Shaper,
        run: font.shape.TextRun,
    ) ![]const font.shape.Cell {
        const state = &self.run_state;

        // {
        //     log.debug("shape -----------------------------------", .{});
        //     for (state.codepoints.items) |entry| {
        //         log.debug("cp={X} cluster={}", .{ entry.codepoint, entry.cluster });
        //     }
        //     log.debug("shape end -------------------------------", .{});
        // }

        // Special fonts aren't shaped and their codepoint == glyph so we
        // can just return the codepoints as-is.
        if (run.font_index.special() != null) {
            self.cell_buf.clearRetainingCapacity();
            try self.cell_buf.ensureTotalCapacity(self.alloc, state.codepoints.items.len);
            for (state.codepoints.items) |entry| {
                // We use null codepoints to pad out our list so indices match
                // the UTF-16 string we constructed for CoreText. We don't want
                // to emit these if this is a special font, since they're not
                // part of the original run.
                if (entry.codepoint == 0) continue;

                self.cell_buf.appendAssumeCapacity(.{
                    .x = @intCast(entry.cluster),
                    .glyph_index = @intCast(entry.codepoint),
                });
            }

            return self.cell_buf.items;
        }

        // Create an arena for any Zig-based allocations we do
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();

        const attr_dict: *macos.foundation.Dictionary = try self.getFont(
            run.grid,
            run.font_index,
        );

        // Make room for the attributed string, CTTypesetter, and CTLine.
        try self.cf_release_pool.ensureUnusedCapacity(self.alloc, 4);

        const str = macos.foundation.String.createWithCharactersNoCopy(state.unichars.items);
        self.cf_release_pool.appendAssumeCapacity(str);

        // Create an attributed string from our string
        const attr_str = try macos.foundation.AttributedString.create(
            str,
            attr_dict,
        );
        self.cf_release_pool.appendAssumeCapacity(attr_str);

        // Create a typesetter from the attributed string. Use the RTL
        // embedding level dict for RTL runs so CoreText shapes correctly.
        const ts_dict = if (run.rtl)
            self.typesetter_attr_dict_rtl
        else
            self.typesetter_attr_dict;
        const typesetter =
            try macos.text.Typesetter.createWithAttributedStringAndOptions(
                attr_str,
                ts_dict,
            );
        self.cf_release_pool.appendAssumeCapacity(typesetter);

        // Create a line from the typesetter
        const line = typesetter.createLine(.{ .location = 0, .length = 0 });
        self.cf_release_pool.appendAssumeCapacity(line);

        // This keeps track of the current x offset (sum of advance.width) and
        // the furthest cluster we've seen so far (max).
        var run_offset: Offset = .{};

        // This keeps track of the cell starting x and cluster.
        var cell_offset: Offset = .{};
        const anchor_sentinel = std.math.nan(f64);
        self.cluster_anchor_x.clearRetainingCapacity();
        try self.cluster_anchor_x.ensureUnusedCapacity(self.alloc, run.cells);
        self.cluster_anchor_x.appendNTimesAssumeCapacity(anchor_sentinel, run.cells);

        // For debugging positions, turn this on:
        //var run_offset_y: f64 = 0.0;
        //var cell_offset_y: f64 = 0.0;

        // Clear our cell buf and make sure we have enough room for the whole
        // line of glyphs, so that we can just assume capacity when appending
        // instead of maybe allocating.
        self.cell_buf.clearRetainingCapacity();
        try self.cell_buf.ensureTotalCapacity(self.alloc, line.getGlyphCount());

        // CoreText, despite our insistence with an enforced embedding level,
        // may sometimes output runs that are non-monotonic. In order to fix
        // this, we check the run status for each run and if any aren't ltr
        // we set this to true, which indicates that we must sort our buffer.
        var non_ltr: bool = false;

        // CoreText may generate multiple runs even though our input to
        // CoreText is already split into runs by our own run iterator.
        // The runs as far as I can tell are always sequential to each
        // other so we can iterate over them and just append to our
        // cell buffer.
        const runs = line.getGlyphRuns();
        for (0..runs.getCount()) |run_i| {
            const ctrun = runs.getValueAtIndex(macos.text.Run, run_i);

            const status = ctrun.getStatus();
            if (status.non_monotonic or status.right_to_left) non_ltr = true;

            // Get our glyphs and positions
            const glyphs = ctrun.getGlyphsPtr() orelse try ctrun.getGlyphs(alloc);
            const advances = ctrun.getAdvancesPtr() orelse try ctrun.getAdvances(alloc);
            const positions = ctrun.getPositionsPtr() orelse try ctrun.getPositions(alloc);
            const indices = ctrun.getStringIndicesPtr() orelse try ctrun.getStringIndices(alloc);
            assert(glyphs.len == advances.len);
            assert(glyphs.len == positions.len);
            assert(glyphs.len == indices.len);

            for (
                glyphs,
                advances,
                positions,
                indices,
            ) |glyph, advance, position, index| {
                // Our cluster is also our cell X position. If the cluster changes
                // then we need to reset our current cell offsets.
                const cluster = state.codepoints.items[index].cluster;
                const source_codepoint = state.codepoints.items[index].codepoint;
                const is_combining_mark = source_codepoint != 0 and
                    unicode.table.get(@intCast(source_codepoint)).width_zero_in_grapheme;
                if (cell_offset.cluster != cluster) {
                    // We previously asserted that the new cluster is greater
                    // than cell_offset.cluster, but this isn't always true.
                    // See e.g. the "shape Chakma vowel sign with ligature
                    // (vowel sign renders first)" test.

                    const is_after_glyph_from_current_or_next_clusters =
                        cluster <= run_offset.cluster;

                    const is_first_codepoint_in_cluster = blk: {
                        var i = index;
                        while (i > 0) {
                            i -= 1;
                            const codepoint = state.codepoints.items[i];

                            // Skip surrogate pair padding
                            if (codepoint.codepoint == 0) continue;
                            break :blk codepoint.cluster != cluster;
                        } else break :blk true;
                    };

                    // We need to reset the `cell_offset` at the start of a new
                    // cluster, but we do that conditionally if the codepoint
                    // `is_first_codepoint_in_cluster` and the cluster is not
                    // `is_after_glyph_from_current_or_next_clusters`, which is
                    // a heuristic to detect ligatures and avoid positioning
                    // glyphs that mark ligatures incorrectly. The idea is that
                    // if the first codepoint in a cluster doesn't appear in
                    // the stream, it's very likely that it combined with
                    // codepoints from a previous cluster into a ligature.
                    // Then, the subsequent codepoints are very likely marking
                    // glyphs that are placed relative to that ligature, so if
                    // we were to reset the `cell_offset` to align it with the
                    // grid, the positions would be off. The
                    // `!is_after_glyph_from_current_or_next_clusters` check is
                    // needed in case these marking glyphs come from a later
                    // cluster but are rendered first (see the Chakma and
                    // Bengali tests). In that case when we get to the
                    // codepoint that `is_first_codepoint_in_cluster`, but in a
                    // cluster that
                    // `is_after_glyph_from_current_or_next_clusters`, we don't
                    // want to reset to the grid and cause the positions to be
                    // off. (Note that we could go back and align the cells to
                    // the grid starting from the one from the cluster that
                    // rendered out of order, but that is more complicated so
                    // we don't do that for now. Also, it's TBD if there are
                    // exceptions to this heuristic for detecting ligatures,
                    // but using the logging below seems to show it works
                    // well.)
                    if (is_first_codepoint_in_cluster) {
                        const should_reset = (run.rtl and !is_combining_mark) or
                            !is_after_glyph_from_current_or_next_clusters;
                        if (should_reset) {
                            const reset_x = if (run.rtl) position.x else run_offset.x;
                            cell_offset = .{
                                .cluster = cluster,
                                .x = reset_x,
                            };

                            const cluster_i: usize = @intCast(cluster);
                            if (cluster_i < self.cluster_anchor_x.items.len) {
                                self.cluster_anchor_x.items[cluster_i] = reset_x;
                            }
                        }
                    } else if (!run.rtl and !is_combining_mark) {
                        // In LTR scripts, a cluster's first codepoint can be
                        // absent from the glyph stream (due to ligature
                        // composition). If this is the first glyph we see for
                        // that cluster, establish an anchor now.
                        const cluster_i: usize = @intCast(cluster);
                        if (cluster_i < self.cluster_anchor_x.items.len and
                            std.math.isNan(self.cluster_anchor_x.items[cluster_i]))
                        {
                            cell_offset = .{
                                .cluster = cluster,
                                .x = run_offset.x,
                            };
                            self.cluster_anchor_x.items[cluster_i] = run_offset.x;
                        }
                    } else if (run.rtl and is_combining_mark) {
                        const cluster_i: usize = @intCast(cluster);
                        if (cluster_i < self.cluster_anchor_x.items.len) {
                            const anchor_x = self.cluster_anchor_x.items[cluster_i];
                            // Keep this scoped to Arabic RTL marks only:
                            // broadening this fallback regresses scripts with
                            // out-of-order vowels/marks (e.g.
                            // Chakma/Bengali tests).
                            const allow_non_first_fallback =
                                bidi_helpers.isArabicCombiningMark(source_codepoint);
                            if (!std.math.isNan(anchor_x)) {
                                cell_offset = .{
                                    .cluster = cluster,
                                    .x = anchor_x,
                                };
                            } else if (allow_non_first_fallback) {
                                // A non-first combining mark can still be
                                // emitted before its base glyph in visual
                                // stream order. If we don't have a prior
                                // anchor yet, establish one at the current
                                // run offset.
                                cell_offset = .{
                                    .cluster = cluster,
                                    .x = position.x,
                                };
                                self.cluster_anchor_x.items[cluster_i] = position.x;
                            }
                        }
                    }
                } else if (run.rtl and source_codepoint != 0 and !is_combining_mark) {
                    const is_first_codepoint_in_cluster = blk: {
                        var i = index;
                        while (i > 0) {
                            i -= 1;
                            const codepoint = state.codepoints.items[i];

                            // Skip surrogate pair padding
                            if (codepoint.codepoint == 0) continue;
                            break :blk codepoint.cluster != cluster;
                        } else break :blk true;
                    };

                    // In RTL runs, a combining mark can establish a cluster
                    // anchor before the base glyph arrives. Re-anchor to the
                    // base glyph position once the first logical codepoint in
                    // the cluster is seen.
                    if (is_first_codepoint_in_cluster) {
                        const cluster_i: usize = @intCast(cluster);
                        cell_offset.x = position.x;
                        if (cluster_i < self.cluster_anchor_x.items.len) {
                            self.cluster_anchor_x.items[cluster_i] = position.x;
                        }
                    }
                }

                // For debugging positions, turn this on:
                //try self.debugPositions(alloc, run_offset, run_offset_y, cell_offset, cell_offset_y, position, index);

                const x_offset = position.x - cell_offset.x;

                self.cell_buf.appendAssumeCapacity(.{
                    .x = @intCast(cell_offset.cluster),
                    .x_offset = @intFromFloat(@round(x_offset)),
                    .y_offset = @intFromFloat(@round(position.y)),
                    .glyph_index = glyph,
                });

                // Add our advances to keep track of our run offsets.
                // Advances apply to the NEXT cell.
                run_offset.x += advance.width;
                run_offset.cluster = @max(run_offset.cluster, cluster);

                // For debugging positions, turn this on:
                //run_offset_y += advance.height;
            }
        }

        // If our buffer contains some non-ltr sections we need to sort it :/
        if (non_ltr or run.rtl) {
            // This is EXCEPTIONALLY rare. Only happens for languages with
            // complex shaping which we don't even really support properly
            // right now, so are very unlikely to be used heavily by users
            // of Ghostty.
            @branchHint(.cold);
            std.mem.sort(
                font.shape.Cell,
                self.cell_buf.items,
                {},
                struct {
                    fn lt(_: void, a: font.shape.Cell, b: font.shape.Cell) bool {
                        return a.x < b.x;
                    }
                }.lt,
            );
        }

        return self.cell_buf.items;
    }

    /// Get an attr dict for a font from a specific index.
    /// These items are cached, do not retain or release them.
    fn getFont(
        self: *Shaper,
        grid: *font.SharedGrid,
        index: font.Collection.Index,
    ) !*macos.foundation.Dictionary {
        // If this grid doesn't match the one we've cached fonts for,
        // then we reset the cache list since it's no longer valid.
        // We use an intFromPtr rather than direct pointer comparison
        // because we don't want anyone to inadvertently use the pointer.
        const grid_id: usize = @intFromPtr(grid);
        if (grid_id != self.cached_font_grid) {
            if (self.cached_font_grid > 0) {
                // Put all the currently cached fonts in to
                // the release pool before clearing the list.
                try self.cf_release_pool.ensureUnusedCapacity(
                    self.alloc,
                    self.cached_fonts.items.len,
                );
                for (self.cached_fonts.items) |ft| {
                    if (ft) |f| {
                        self.cf_release_pool.appendAssumeCapacity(f);
                    }
                }
                self.cached_fonts.clearRetainingCapacity();
            }

            self.cached_font_grid = grid_id;
        }

        const index_int = index.int();

        // The cached fonts are indexed directly by the font index, since
        // this number is usually low. Therefore, we set any index we haven't
        // seen to null.
        if (self.cached_fonts.items.len <= index_int) {
            try self.cached_fonts.ensureTotalCapacity(self.alloc, index_int + 1);
            while (self.cached_fonts.items.len <= index_int) {
                self.cached_fonts.appendAssumeCapacity(null);
            }
        }

        // If we have it, return the cached attr dict.
        if (self.cached_fonts.items[index_int]) |cached| return cached;

        // Font descriptor, font
        try self.cf_release_pool.ensureUnusedCapacity(self.alloc, 2);

        const run_font = font: {
            // The CoreText shaper relies on CoreText and CoreText claims
            // that CTFonts are threadsafe. See:
            // https://developer.apple.com/documentation/coretext/
            //
            // Quote:
            // All individual functions in Core Text are thread-safe. Font
            // objects (CTFont, CTFontDescriptor, and associated objects) can
            // be used simultaneously by multiple operations, work queues, or
            // threads. However, the layout objects (CTTypesetter,
            // CTFramesetter, CTRun, CTLine, CTFrame, and associated objects)
            // should be used in a single operation, work queue, or thread.
            //
            // Because of this, we only acquire the read lock to grab the
            // face and set it up, then release it.
            grid.lock.lockShared();
            defer grid.lock.unlockShared();

            const face = try grid.resolver.collection.getFace(index);
            const original = face.font;

            const attrs = if (face.quirks_disable_default_font_features)
                self.features_no_default
            else
                self.features;

            const desc = try macos.text.FontDescriptor.createWithAttributes(attrs);
            self.cf_release_pool.appendAssumeCapacity(desc);

            const copied = try original.copyWithAttributes(0, null, desc);
            errdefer copied.release();

            break :font copied;
        };
        self.cf_release_pool.appendAssumeCapacity(run_font);

        // Get our font and use that get the attributes to set for the
        // attributed string so the whole string uses the same font.
        const attr_dict = dict: {
            break :dict try macos.foundation.Dictionary.create(
                &.{macos.text.StringAttribute.font.key()},
                &.{run_font},
            );
        };

        self.cached_fonts.items[index_int] = attr_dict;
        return attr_dict;
    }

    /// The hooks for RunIterator.
    pub const RunIteratorHook = struct {
        shaper: *Shaper,

        pub fn prepare(self: *RunIteratorHook) void {
            self.shaper.run_state.reset();
            // log.warn("----------- run reset -------------", .{});
        }

        pub fn addCodepoint(self: RunIteratorHook, cp: u32, cluster: u32) !void {
            const state = &self.shaper.run_state;

            // Build our UTF-16 string for CoreText
            try state.unichars.ensureUnusedCapacity(self.shaper.alloc, 2);

            state.unichars.appendNTimesAssumeCapacity(0, 2);

            const pair = macos.foundation.stringGetSurrogatePairForLongCharacter(
                cp,
                state.unichars.items[state.unichars.items.len - 2 ..][0..2],
            );
            if (!pair) {
                state.unichars.items.len -= 1;
            }

            // Build our reverse lookup table for codepoints to clusters
            try state.codepoints.append(self.shaper.alloc, .{
                .codepoint = cp,
                .cluster = cluster,
            });
            // log.warn("run cp={X}", .{cp});

            // If the UTF-16 codepoint is a pair then we need to insert
            // a dummy entry so that the CTRunGetStringIndices() function
            // maps correctly.
            if (pair) try state.codepoints.append(self.shaper.alloc, .{
                .codepoint = 0,
                .cluster = cluster,
            });
        }

        pub fn finalize(self: RunIteratorHook) void {
            _ = self;
        }

        pub fn bidiLayoutScratch(self: RunIteratorHook) *itijah.VisualLayoutScratch {
            return &self.shaper.bidi_layout_scratch;
        }
    };

    fn debugPositions(
        self: *Shaper,
        alloc: Allocator,
        run_offset: Offset,
        run_offset_y: f64,
        cell_offset: Offset,
        cell_offset_y: f64,
        position: macos.graphics.Point,
        index: usize,
    ) !void {
        const state = &self.run_state;
        const x_offset = position.x - cell_offset.x;
        const advance_x_offset = run_offset.x - cell_offset.x;
        const advance_y_offset = run_offset_y - cell_offset_y;
        const x_offset_diff = x_offset - advance_x_offset;
        const y_offset_diff = position.y - advance_y_offset;
        const positions_differ = @abs(x_offset_diff) > 0.0001 or @abs(y_offset_diff) > 0.0001;
        const old_offset_y = position.y - cell_offset_y;
        const position_y_differs = @abs(cell_offset_y) > 0.0001;
        const cluster = state.codepoints.items[index].cluster;
        const cluster_differs = cluster != cell_offset.cluster;

        // To debug every loop, flip this to true:
        const extra_debugging = false;

        const is_previous_codepoint_prepend = if (cluster_differs or
            extra_debugging)
        blk: {
            var i = index;
            while (i > 0) {
                i -= 1;
                const codepoint = state.codepoints.items[i];

                // Skip surrogate pair padding
                if (codepoint.codepoint == 0) continue;

                break :blk unicode.table.get(@intCast(codepoint.codepoint)).grapheme_boundary_class == .prepend;
            }
            break :blk false;
        } else false;

        const formatted_cps = if (positions_differ or
            position_y_differs or
            cluster_differs or
            extra_debugging)
        blk: {
            var allocating = std.Io.Writer.Allocating.init(alloc);
            const writer = &allocating.writer;
            const codepoints = state.codepoints.items;
            var last_cluster: ?u32 = null;
            for (codepoints, 0..) |cp, i| {
                if ((@as(i32, @intCast(cp.cluster)) >= @as(i32, @intCast(cell_offset.cluster)) - 1 and
                    cp.cluster <= cluster + 1) and
                    cp.codepoint != 0 // Skip surrogate pair padding
                ) {
                    if (last_cluster) |last| {
                        if (cp.cluster != last) {
                            try writer.writeAll(" ");
                        }
                    }
                    if (i == index) {
                        try writer.writeAll("▸");
                    }
                    // Using Python syntax for easier debugging
                    if (cp.codepoint > 0xFFFF) {
                        try writer.print("\\U{x:0>8}", .{cp.codepoint});
                    } else {
                        try writer.print("\\u{x:0>4}", .{cp.codepoint});
                    }
                    last_cluster = cp.cluster;
                }
            }
            try writer.writeAll(" → ");
            for (codepoints) |cp| {
                if ((@as(i32, @intCast(cp.cluster)) >= @as(i32, @intCast(cell_offset.cluster)) - 1 and
                    cp.cluster <= cluster + 1) and
                    cp.codepoint != 0 // Skip surrogate pair padding
                ) {
                    try writer.print("{u}", .{@as(u21, @intCast(cp.codepoint))});
                }
            }
            break :blk try allocating.toOwnedSlice();
        } else "";

        if (extra_debugging) {
            log.warn("extra debugging of positions index={d} cell_offset.cluster={d} cluster={d} run_offset.cluster={d} diff={d} pos=({d:.2},{d:.2}) run_offset=({d:.2},{d:.2}) cell_offset=({d:.2},{d:.2}) is_prev_prepend={} cps = {s}", .{
                index,
                cell_offset.cluster,
                cluster,
                run_offset.cluster,
                @as(isize, @intCast(cluster)) - @as(isize, @intCast(cell_offset.cluster)),
                x_offset,
                position.y,
                run_offset.x,
                run_offset_y,
                cell_offset.x,
                cell_offset_y,
                is_previous_codepoint_prepend,
                formatted_cps,
            });
        }

        if (positions_differ) {
            log.warn("position differs from advance: cluster={d} pos=({d:.2},{d:.2}) adv=({d:.2},{d:.2}) diff=({d:.2},{d:.2}) cps = {s}", .{
                cluster,
                x_offset,
                position.y,
                advance_x_offset,
                advance_y_offset,
                x_offset_diff,
                y_offset_diff,
                formatted_cps,
            });
        }

        if (position_y_differs) {
            log.warn("position.y differs from old offset.y: cluster={d} pos=({d:.2},{d:.2}) run_offset=({d:.2},{d:.2}) cell_offset=({d:.2},{d:.2}) old offset.y={d:.2} cps = {s}", .{
                cluster,
                x_offset,
                position.y,
                run_offset.x,
                run_offset_y,
                cell_offset.x,
                cell_offset_y,
                old_offset_y,
                formatted_cps,
            });
        }

        if (cluster_differs) {
            log.warn("cell_offset.cluster differs from cluster (potential ligature detected) cell_offset.cluster={d} cluster={d} run_offset.cluster={d} diff={d} pos=({d:.2},{d:.2}) run_offset=({d:.2},{d:.2}) cell_offset=({d:.2},{d:.2}) is_prev_prepend={} cps = {s}", .{
                cell_offset.cluster,
                cluster,
                run_offset.cluster,
                @as(isize, @intCast(cluster)) - @as(isize, @intCast(cell_offset.cluster)),
                x_offset,
                position.y,
                run_offset.x,
                run_offset_y,
                cell_offset.x,
                cell_offset_y,
                is_previous_codepoint_prepend,
                formatted_cps,
            });
        }
    }
};

test "run iterator" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    {
        var t: terminal.Terminal = try .init(alloc, .{
            .cols = 5,
            .rows = 3,
        });
        defer t.deinit(alloc);

        var s = t.vtStream();
        defer s.deinit();
        try s.nextSlice("ABCD");

        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |_| count += 1;
        try testing.expectEqual(@as(usize, 1), count);
    }

    // Spaces should be part of a run
    {
        var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 3 });
        defer t.deinit(alloc);

        var s = t.vtStream();
        defer s.deinit();
        try s.nextSlice("ABCD   EFG");

        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |_| count += 1;
        try testing.expectEqual(@as(usize, 1), count);
    }

    {
        // Make a screen with some data
        var t = try terminal.Terminal.init(alloc, .{ .cols = 5, .rows = 3 });
        defer t.deinit(alloc);

        var s = t.vtStream();
        defer s.deinit();
        try s.nextSlice("A😃D");

        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |_| count += 1;
        try testing.expectEqual(@as(usize, 3), count);
    }

    // Bad ligatures
    for (&[_][]const u8{ "fl", "fi", "st" }) |bad| {
        // Make a screen with some data
        var t = try terminal.Terminal.init(alloc, .{ .cols = 5, .rows = 3 });
        defer t.deinit(alloc);

        var s = t.vtStream();
        defer s.deinit();
        try s.nextSlice(bad);

        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |_| count += 1;
        try testing.expectEqual(@as(usize, 2), count);
    }
}

test "run iterator: empty cells with background set" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    {
        // Make a screen with some data
        var t = try terminal.Terminal.init(alloc, .{ .cols = 5, .rows = 3 });
        defer t.deinit(alloc);

        var s = t.vtStream();
        defer s.deinit();
        // Set red background
        try s.nextSlice("\x1b[48;2;255;0;0m");
        try s.nextSlice("A");

        // Get our first row
        {
            const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 1 } }).?;
            const cell = list_cell.cell;
            cell.* = .{
                .content_tag = .bg_color_rgb,
                .content = .{ .color_rgb = .{ .r = 0xFF, .g = 0, .b = 0 } },
            };
        }
        {
            const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 2 } }).?;
            const cell = list_cell.cell;
            cell.* = .{
                .content_tag = .bg_color_rgb,
                .content = .{ .color_rgb = .{ .r = 0xFF, .g = 0, .b = 0 } },
            };
        }

        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        {
            const run = (try it.next(alloc)).?;
            const cells = try shaper.shape(run);
            try testing.expectEqual(@as(usize, 3), cells.len);
        }
        try testing.expect(try it.next(alloc) == null);
    }
}

test "shape" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x1F44D, buf[buf_idx..]); // Thumbs up plain
    buf_idx += try std.unicode.utf8Encode(0x1F44D, buf[buf_idx..]); // Thumbs up plain
    buf_idx += try std.unicode.utf8Encode(0x1F3FD, buf[buf_idx..]); // Medium skin tone

    // Make a screen with some data
    var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice(buf[0..buf_idx]);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        _ = try shaper.shape(run);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "shape nerd fonts" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaperWithFont(alloc, .nerd_font);
    defer testdata.deinit();

    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(' ', buf[buf_idx..]); // space
    buf_idx += try std.unicode.utf8Encode(0xF024B, buf[buf_idx..]); // nf-md-folder
    buf_idx += try std.unicode.utf8Encode(' ', buf[buf_idx..]); // space

    // Make a screen with some data
    var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice(buf[0..buf_idx]);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        _ = try shaper.shape(run);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "shape inconsolata ligs" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    {
        var t = try terminal.Terminal.init(alloc, .{ .cols = 5, .rows = 3 });
        defer t.deinit(alloc);

        var s = t.vtStream();
        defer s.deinit();
        try s.nextSlice(">=");

        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;

            try testing.expectEqual(@as(usize, 2), run.cells);

            const cells = try shaper.shape(run);
            try testing.expectEqual(@as(usize, 1), cells.len);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }

    {
        var t = try terminal.Terminal.init(alloc, .{ .cols = 5, .rows = 3 });
        defer t.deinit(alloc);

        var s = t.vtStream();
        defer s.deinit();
        try s.nextSlice("===");

        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;

            try testing.expectEqual(@as(usize, 3), run.cells);

            const cells = try shaper.shape(run);
            try testing.expectEqual(@as(usize, 1), cells.len);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
}

test "shape monaspace ligs" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaperWithFont(alloc, .monaspace_neon);
    defer testdata.deinit();

    {
        var t = try terminal.Terminal.init(alloc, .{ .cols = 5, .rows = 3 });
        defer t.deinit(alloc);

        var s = t.vtStream();
        defer s.deinit();
        try s.nextSlice("===");

        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;

            try testing.expectEqual(@as(usize, 3), run.cells);

            const cells = try shaper.shape(run);
            try testing.expectEqual(@as(usize, 1), cells.len);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
}

// https://github.com/mitchellh/ghostty/issues/1708
test "shape left-replaced lig in last run" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaperWithFont(alloc, .geist_mono);
    defer testdata.deinit();

    {
        var t = try terminal.Terminal.init(alloc, .{ .cols = 5, .rows = 3 });
        defer t.deinit(alloc);

        var s = t.vtStream();
        defer s.deinit();
        try s.nextSlice("!==");

        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;

            try testing.expectEqual(@as(usize, 3), run.cells);

            const cells = try shaper.shape(run);
            try testing.expectEqual(@as(usize, 1), cells.len);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
}

// https://github.com/mitchellh/ghostty/issues/1708
test "shape left-replaced lig in early run" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaperWithFont(alloc, .geist_mono);
    defer testdata.deinit();

    {
        var t = try terminal.Terminal.init(alloc, .{ .cols = 5, .rows = 3 });
        defer t.deinit(alloc);

        var s = t.vtStream();
        defer s.deinit();
        try s.nextSlice("!==X");

        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });

        const run = (try it.next(alloc)).?;

        try testing.expectEqual(@as(usize, 4), run.cells);

        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 2), cells.len);
    }
}

// https://github.com/mitchellh/ghostty/issues/1664
test "shape U+3C9 with JB Mono" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaperWithFont(alloc, .jetbrains_mono);
    defer testdata.deinit();

    {
        var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 3 });
        defer t.deinit(alloc);

        var s = t.vtStream();
        defer s.deinit();
        try s.nextSlice("\u{03C9} foo");

        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });

        var run_count: usize = 0;
        var cell_count: usize = 0;
        while (try it.next(alloc)) |run| {
            run_count += 1;
            const cells = try shaper.shape(run);
            cell_count += cells.len;
        }
        try testing.expectEqual(@as(usize, 1), run_count);
        try testing.expectEqual(@as(usize, 5), cell_count);
    }
}

test "shape emoji width" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    {
        var t = try terminal.Terminal.init(alloc, .{ .cols = 5, .rows = 3 });
        defer t.deinit(alloc);

        var s = t.vtStream();
        defer s.deinit();
        try s.nextSlice("👍");

        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;

            const cells = try shaper.shape(run);
            try testing.expectEqual(@as(usize, 1), cells.len);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
}

test "shape emoji width long" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    // Make a screen and add a long emoji sequence to it.
    var t = try terminal.Terminal.init(alloc, .{ .cols = 30, .rows = 3 });
    defer t.deinit(alloc);

    var page = t.screens.active.pages.pages.first.?.data;
    var row = page.getRow(1);
    const cell = &row.cells.ptr(page.memory)[0];
    cell.* = .{
        .content_tag = .codepoint,
        .content = .{ .codepoint = 0x1F9D4 }, // Person with beard
    };
    var graphemes = [_]u21{
        0x1F3FB, // Light skin tone (Fitz 1-2)
        0x200D, // ZWJ
        0x2642, // Male sign
        0xFE0F, // Emoji presentation selector
    };
    try page.setGraphemes(
        row,
        cell,
        graphemes[0..],
    );

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(1).cells.slice(),
    });
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        const cells = try shaper.shape(run);

        try testing.expectEqual(@as(usize, 1), cells.len);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "shape variation selector VS15" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x270C, buf[buf_idx..]); // Victory sign (default text)
    buf_idx += try std.unicode.utf8Encode(0xFE0E, buf[buf_idx..]); // ZWJ to force text

    // Make a screen with some data
    var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice(buf[0..buf_idx]);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 1), cells.len);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "shape variation selector VS16" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x270C, buf[buf_idx..]); // Victory sign (default text)
    buf_idx += try std.unicode.utf8Encode(0xFE0F, buf[buf_idx..]); // ZWJ to force color

    // Make a screen with some data
    var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice(buf[0..buf_idx]);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 1), cells.len);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "shape with empty cells in between" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    // Make a screen with some data
    var t = try terminal.Terminal.init(alloc, .{ .cols = 30, .rows = 3 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("A");
    try s.nextSlice("\x1b[5C"); // 5 spaces forward
    try s.nextSlice("B");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;

        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 1), count);
        try testing.expectEqual(@as(usize, 7), cells.len);
    }
}

test "shape Combining characters" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode('n', buf[buf_idx..]); // Combining
    buf_idx += try std.unicode.utf8Encode(0x0308, buf[buf_idx..]); // Combining
    buf_idx += try std.unicode.utf8Encode(0x0308, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode('a', buf[buf_idx..]);

    // Make a screen with some data
    var t = try terminal.Terminal.init(alloc, .{ .cols = 30, .rows = 3 });
    defer t.deinit(alloc);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice(buf[0..buf_idx]);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;

        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 4), cells.len);
        try testing.expectEqual(@as(u16, 0), cells[0].x);
        try testing.expectEqual(@as(u16, 0), cells[1].x);
        try testing.expectEqual(@as(u16, 0), cells[2].x);
        try testing.expectEqual(@as(u16, 1), cells[3].x);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

// This test exists because the string it uses causes CoreText to output a
// non-monotonic run, which we need to handle by sorting the resulting buffer.
test "shape Devanagari string" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // We need a font that supports devanagari for this to work, if we can't
    // find Arial Unicode MS, which is a system font on macOS, we just skip
    // the test.
    var testdata = testShaperWithDiscoveredFont(
        alloc,
        "Arial Unicode MS",
    ) catch return error.SkipZigTest;
    defer testdata.deinit();

    // Make a screen with some data
    var t = try terminal.Terminal.init(alloc, .{ .cols = 30, .rows = 3 });
    defer t.deinit(alloc);

    // Disable grapheme clustering
    t.modes.set(.grapheme_cluster, false);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("अपार्टमेंट");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });

    const run = try it.next(alloc);
    try testing.expect(run != null);
    const cells = try shaper.shape(run.?);

    // To understand the `x`/`cluster` assertions here, run with the "For
    // debugging positions" code turned on and `extra_debugging` set to true.
    try testing.expectEqual(@as(usize, 8), cells.len);
    try testing.expectEqual(@as(u16, 0), cells[0].x);
    try testing.expectEqual(@as(u16, 1), cells[1].x);
    try testing.expectEqual(@as(u16, 2), cells[2].x);
    try testing.expectEqual(@as(u16, 4), cells[3].x);
    try testing.expectEqual(@as(u16, 4), cells[4].x);
    try testing.expectEqual(@as(u16, 5), cells[5].x);
    try testing.expectEqual(@as(u16, 5), cells[6].x);
    try testing.expectEqual(@as(u16, 6), cells[7].x);

    try testing.expect(try it.next(alloc) == null);
}

test "shape Tai Tham vowels (position differs from advance)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // We need a font that supports Tai Tham for this to work, if we can't find
    // Noto Sans Tai Tham, which is a system font on macOS, we just skip the
    // test.
    var testdata = testShaperWithDiscoveredFont(
        alloc,
        "Noto Sans Tai Tham",
    ) catch return error.SkipZigTest;
    defer testdata.deinit();

    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x1a2F, buf[buf_idx..]); // ᨯ
    buf_idx += try std.unicode.utf8Encode(0x1a70, buf[buf_idx..]); //  ᩰ

    // Make a screen with some data
    var t = try terminal.Terminal.init(alloc, .{ .cols = 30, .rows = 3 });
    defer t.deinit(alloc);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice(buf[0..buf_idx]);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;

        const cells = try shaper.shape(run);
        const cell_width = run.grid.metrics.cell_width;
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u16, 0), cells[0].x);
        try testing.expectEqual(@as(u16, 0), cells[1].x);

        // The first glyph renders in the next cell
        try testing.expectEqual(@as(i16, @intCast(cell_width)), cells[0].x_offset);
        try testing.expectEqual(@as(i16, 0), cells[1].x_offset);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "shape Tai Tham letters (position.y differs from advance)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // We need a font that supports Tai Tham for this to work, if we can't find
    // Noto Sans Tai Tham, which is a system font on macOS, we just skip the
    // test.
    var testdata = testShaperWithDiscoveredFont(
        alloc,
        "Noto Sans Tai Tham",
    ) catch return error.SkipZigTest;
    defer testdata.deinit();

    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;

    // First grapheme cluster:
    buf_idx += try std.unicode.utf8Encode(0x1a49, buf[buf_idx..]); // HA
    buf_idx += try std.unicode.utf8Encode(0x1a60, buf[buf_idx..]); // SAKOT
    // Second grapheme cluster, combining with the first in a ligature:
    buf_idx += try std.unicode.utf8Encode(0x1a3f, buf[buf_idx..]); // YA
    buf_idx += try std.unicode.utf8Encode(0x1a69, buf[buf_idx..]); // U

    // Make a screen with some data
    var t = try terminal.Terminal.init(alloc, .{ .cols = 30, .rows = 3 });
    defer t.deinit(alloc);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice(buf[0..buf_idx]);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;

        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 3), cells.len);
        try testing.expectEqual(@as(u16, 0), cells[0].x);
        try testing.expectEqual(@as(u16, 0), cells[1].x);
        try testing.expectEqual(@as(u16, 0), cells[2].x); // U from second grapheme

        // The U glyph renders at a y below zero
        try testing.expectEqual(@as(i16, -3), cells[2].y_offset);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "shape Javanese ligatures" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // We need a font that supports Javanese for this to work, if we can't find
    // Noto Sans Javanese Regular, which is a system font on macOS, we just
    // skip the test.
    var testdata = testShaperWithDiscoveredFont(
        alloc,
        "Noto Sans Javanese",
    ) catch return error.SkipZigTest;
    defer testdata.deinit();

    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;

    // First grapheme cluster:
    buf_idx += try std.unicode.utf8Encode(0xa9a4, buf[buf_idx..]); // NA
    buf_idx += try std.unicode.utf8Encode(0xa9c0, buf[buf_idx..]); // PANGKON
    // Second grapheme cluster, combining with the first in a ligature:
    buf_idx += try std.unicode.utf8Encode(0xa9b2, buf[buf_idx..]); // HA
    buf_idx += try std.unicode.utf8Encode(0xa9b8, buf[buf_idx..]); // Vowel sign SUKU

    // Make a screen with some data
    var t = try terminal.Terminal.init(alloc, .{ .cols = 30, .rows = 3 });
    defer t.deinit(alloc);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice(buf[0..buf_idx]);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;

        const cells = try shaper.shape(run);
        const cell_width = run.grid.metrics.cell_width;
        try testing.expectEqual(@as(usize, 3), cells.len);
        try testing.expectEqual(@as(u16, 0), cells[0].x);
        try testing.expectEqual(@as(u16, 0), cells[1].x);
        try testing.expectEqual(@as(u16, 0), cells[2].x);

        // The vowel sign SUKU renders with correct x_offset
        try testing.expect(cells[2].x_offset > 3 * cell_width);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "shape Chakma vowel sign with ligature (vowel sign renders first)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // We need a font that supports Chakma for this to work, if we can't find
    // Noto Sans Chakma Regular, which is a system font on macOS, we just skip
    // the test.
    var testdata = testShaperWithDiscoveredFont(
        alloc,
        "Noto Sans Chakma",
    ) catch return error.SkipZigTest;
    defer testdata.deinit();

    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;

    // First grapheme cluster:
    buf_idx += try std.unicode.utf8Encode(0x1111d, buf[buf_idx..]); // BAA
    // Second grapheme cluster:
    buf_idx += try std.unicode.utf8Encode(0x11116, buf[buf_idx..]); // TAA
    buf_idx += try std.unicode.utf8Encode(0x11133, buf[buf_idx..]); // Virama
    // Third grapheme cluster, combining with the second in a ligature:
    buf_idx += try std.unicode.utf8Encode(0x11120, buf[buf_idx..]); // YYAA
    buf_idx += try std.unicode.utf8Encode(0x1112c, buf[buf_idx..]); // Vowel Sign U

    // Make a screen with some data
    var t = try terminal.Terminal.init(alloc, .{ .cols = 30, .rows = 3 });
    defer t.deinit(alloc);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice(buf[0..buf_idx]);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;

        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 4), cells.len);
        try testing.expectEqual(@as(u16, 0), cells[0].x);
        for (cells) |cell| try testing.expect(cell.x < run.cells);
        for (cells[1..], 0..) |cell, i| try testing.expect(cell.x >= cells[i].x);

        // The vowel sign U renders before the TAA:
        try testing.expect(cells[1].x_offset < cells[2].x_offset);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "shape Bengali ligatures with out of order vowels" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // We need a font that supports Bengali for this to work, if we can't find
    // Arial Unicode MS, which is a system font on macOS, we just skip the
    // test.
    var testdata = testShaperWithDiscoveredFont(
        alloc,
        "Arial Unicode MS",
    ) catch return error.SkipZigTest;
    defer testdata.deinit();

    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;

    // First grapheme cluster:
    buf_idx += try std.unicode.utf8Encode(0x09b0, buf[buf_idx..]); // RA
    buf_idx += try std.unicode.utf8Encode(0x09be, buf[buf_idx..]); // Vowel sign AA
    // Second grapheme cluster:
    buf_idx += try std.unicode.utf8Encode(0x09b7, buf[buf_idx..]); // SSA
    buf_idx += try std.unicode.utf8Encode(0x09cd, buf[buf_idx..]); // Virama
    // Third grapheme cluster, combining with the second in a ligature:
    buf_idx += try std.unicode.utf8Encode(0x099f, buf[buf_idx..]); // TTA
    buf_idx += try std.unicode.utf8Encode(0x09cd, buf[buf_idx..]); // Virama
    // Fourth grapheme cluster, combining with the previous two in a ligature:
    buf_idx += try std.unicode.utf8Encode(0x09b0, buf[buf_idx..]); // RA
    buf_idx += try std.unicode.utf8Encode(0x09c7, buf[buf_idx..]); // Vowel sign E

    // Make a screen with some data
    var t = try terminal.Terminal.init(alloc, .{ .cols = 30, .rows = 3 });
    defer t.deinit(alloc);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice(buf[0..buf_idx]);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;

        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 8), cells.len);
        for (cells) |cell| try testing.expect(cell.x < run.cells);
        for (cells[1..], 0..) |cell, i| try testing.expect(cell.x >= cells[i].x);

        var distinct: usize = 1;
        var prev_x = cells[0].x;
        for (cells[1..]) |cell| {
            if (cell.x != prev_x) {
                distinct += 1;
                prev_x = cell.x;
            }
        }
        try testing.expect(distinct >= 2);

        // The vowel sign E renders before the SSA:
        try testing.expect(cells[2].x_offset < cells[3].x_offset);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "shape Bengali sentence keeps base clusters anchored" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = testShaperWithDiscoveredFont(
        alloc,
        "Arial Unicode MS",
    ) catch return error.SkipZigTest;
    defer testdata.deinit();

    var t = try terminal.Terminal.init(alloc, .{ .cols = 200, .rows = 3 });
    defer t.deinit(alloc);

    t.modes.set(.grapheme_cluster, true);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("পছন্দের ভাষা টাইপ করা আরো সহজ করে তোলে৷ আরো জানুন");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });

    var saw_run = false;
    while (try it.next(alloc)) |run| {
        saw_run = true;

        var expected = try alloc.alloc(bool, run.cells);
        defer alloc.free(expected);
        @memset(expected, false);

        for (shaper.run_state.codepoints.items) |entry| {
            if (entry.codepoint == 0) continue;
            if (unicode.table.get(@intCast(entry.codepoint)).width_zero_in_grapheme) continue;
            const cluster_i: usize = @intCast(entry.cluster);
            if (cluster_i < expected.len) expected[cluster_i] = true;
        }

        const cells = try shaper.shape(run);
        var actual = try alloc.alloc(bool, run.cells);
        defer alloc.free(actual);
        @memset(actual, false);

        for (cells) |cell| {
            if (cell.x < actual.len) actual[cell.x] = true;
        }
        for (expected, 0..) |need, i| {
            if (need) try testing.expect(actual[i]);
        }
    }
    try testing.expect(saw_run);
}

test "shape Bengali sentence in mixed-direction line keeps base clusters anchored" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = testShaperWithDiscoveredFont(
        alloc,
        "Arial Unicode MS",
    ) catch return error.SkipZigTest;
    defer testdata.deinit();

    var t = try terminal.Terminal.init(alloc, .{ .cols = 220, .rows = 3 });
    defer t.deinit(alloc);

    t.modes.set(.grapheme_cluster, true);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("ABC পছন্দের ভাষা টাইপ করা আরো সহজ করে তোলে৷ আরো জানুন مرحبا");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });

    var saw_bengali = false;
    while (try it.next(alloc)) |run| {
        var expected = try alloc.alloc(bool, run.cells);
        defer alloc.free(expected);
        @memset(expected, false);

        var has_bengali = false;
        for (shaper.run_state.codepoints.items) |entry| {
            if (entry.codepoint == 0) continue;
            if (entry.codepoint >= 0x0980 and entry.codepoint <= 0x09FF) has_bengali = true;
            if (unicode.table.get(@intCast(entry.codepoint)).width_zero_in_grapheme) continue;
            const cluster_i: usize = @intCast(entry.cluster);
            if (cluster_i < expected.len) expected[cluster_i] = true;
        }
        if (!has_bengali) continue;
        saw_bengali = true;

        const cells = try shaper.shape(run);
        var actual = try alloc.alloc(bool, run.cells);
        defer alloc.free(actual);
        @memset(actual, false);

        for (cells) |cell| {
            if (cell.x < actual.len) actual[cell.x] = true;
        }
        for (expected, 0..) |need, i| {
            if (need) try testing.expect(actual[i]);
        }
    }
    try testing.expect(saw_bengali);
}

test "shape box glyphs" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x2500, buf[buf_idx..]); // horiz line
    buf_idx += try std.unicode.utf8Encode(0x2501, buf[buf_idx..]); //

    // Make a screen with some data
    var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice(buf[0..buf_idx]);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u32, 0x2500), cells[0].glyph_index);
        try testing.expectEqual(@as(u16, 0), cells[0].x);
        try testing.expectEqual(@as(u32, 0x2501), cells[1].glyph_index);
        try testing.expectEqual(@as(u16, 1), cells[1].x);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "shape selection boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    // Make a screen with some data
    var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("a1b2c3d4e5");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Full line selection
    {
        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
            .selection = .{ 0, @intCast(t.cols - 1) },
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }

    // Offset x, goes to end of line selection
    {
        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
            .selection = .{ 2, @intCast(t.cols - 1) },
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 2), count);
    }

    // Offset x, starts at beginning of line
    {
        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
            .selection = .{ 0, 3 },
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 2), count);
    }

    // Selection only subset of line
    {
        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
            .selection = .{ 1, 3 },
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 3), count);
    }

    // Selection only one character
    {
        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
            .selection = .{ 1, 1 },
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 3), count);
    }
}

test "shape cursor boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    // Make a screen with some data
    var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("a1b2c3d4e5");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // No cursor is full line
    {
        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }

    {
        // Cursor at index 0 is two runs
        {
            // Get our run iterator
            var shaper = &testdata.shaper;
            var it = shaper.runIterator(.{
                .grid = testdata.grid,
                .cells = state.row_data.get(0).cells.slice(),
                .cursor_x = 0,
            });
            var count: usize = 0;
            while (try it.next(alloc)) |run| {
                count += 1;
                _ = try shaper.shape(run);
            }
            try testing.expectEqual(@as(usize, 2), count);
        }
        // And without cursor splitting remains one
        {
            // Get our run iterator
            var shaper = &testdata.shaper;
            var it = shaper.runIterator(.{
                .grid = testdata.grid,
                .cells = state.row_data.get(0).cells.slice(),
            });
            var count: usize = 0;
            while (try it.next(alloc)) |run| {
                count += 1;
                _ = try shaper.shape(run);
            }
            try testing.expectEqual(@as(usize, 1), count);
        }
    }

    {
        // Cursor at index 1 is three runs
        {
            // Get our run iterator
            var shaper = &testdata.shaper;
            var it = shaper.runIterator(.{
                .grid = testdata.grid,
                .cells = state.row_data.get(0).cells.slice(),
                .cursor_x = 1,
            });
            var count: usize = 0;
            while (try it.next(alloc)) |run| {
                count += 1;
                _ = try shaper.shape(run);
            }
            try testing.expectEqual(@as(usize, 3), count);
        }
        // And without cursor splitting remains one
        {
            // Get our run iterator
            var shaper = &testdata.shaper;
            var it = shaper.runIterator(.{
                .grid = testdata.grid,
                .cells = state.row_data.get(0).cells.slice(),
            });
            var count: usize = 0;
            while (try it.next(alloc)) |run| {
                count += 1;
                _ = try shaper.shape(run);
            }
            try testing.expectEqual(@as(usize, 1), count);
        }
    }
    {
        // Cursor at last col is two runs
        {
            // Get our run iterator
            var shaper = &testdata.shaper;
            var it = shaper.runIterator(.{
                .grid = testdata.grid,
                .cells = state.row_data.get(0).cells.slice(),
                .cursor_x = 9,
            });
            var count: usize = 0;
            while (try it.next(alloc)) |run| {
                count += 1;
                _ = try shaper.shape(run);
            }
            try testing.expectEqual(@as(usize, 2), count);
        }
        // And without cursor splitting remains one
        {
            // Get our run iterator
            var shaper = &testdata.shaper;
            var it = shaper.runIterator(.{
                .grid = testdata.grid,
                .cells = state.row_data.get(0).cells.slice(),
            });
            var count: usize = 0;
            while (try it.next(alloc)) |run| {
                count += 1;
                _ = try shaper.shape(run);
            }
            try testing.expectEqual(@as(usize, 1), count);
        }
    }
}

test "shape cursor boundary and colored emoji" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    // Make a screen with some data
    var t = try terminal.Terminal.init(alloc, .{ .cols = 3, .rows = 10 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("👍🏼");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // No cursor is full line
    {
        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }

    // Cursor on emoji does not split it
    {
        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
            .cursor_x = 0,
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
    {
        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
    {
        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
            .cursor_x = 1,
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
    {
        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
}

test "shape cell attribute change" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    // Plain >= should shape into 1 run
    {
        var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 3 });
        defer t.deinit(alloc);

        var s = t.vtStream();
        defer s.deinit();
        try s.nextSlice(">=");

        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }

    // Bold vs regular should split
    {
        var t = try terminal.Terminal.init(alloc, .{ .cols = 3, .rows = 10 });
        defer t.deinit(alloc);

        var s = t.vtStream();
        defer s.deinit();
        try s.nextSlice(">");
        try s.nextSlice("\x1b[1m"); // Bold
        try s.nextSlice("=");

        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 2), count);
    }

    // Changing fg color should split
    {
        var t = try terminal.Terminal.init(alloc, .{ .cols = 3, .rows = 10 });
        defer t.deinit(alloc);

        var s = t.vtStream();
        defer s.deinit();
        // RGB 1, 2, 3
        try s.nextSlice("\x1b[38;2;1;2;3m");
        try s.nextSlice(">");
        // RGB 3, 2, 1
        try s.nextSlice("\x1b[38;2;3;2;1m");
        try s.nextSlice("=");

        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 2), count);
    }

    // Changing bg color should NOT split
    {
        var t = try terminal.Terminal.init(alloc, .{ .cols = 3, .rows = 10 });
        defer t.deinit(alloc);

        var s = t.vtStream();
        defer s.deinit();
        // RGB 1, 2, 3 bg
        try s.nextSlice("\x1b[48;2;1;2;3m");
        try s.nextSlice(">");
        // RGB 3, 2, 1 bg
        try s.nextSlice("\x1b[48;2;3;2;1m");
        try s.nextSlice("=");

        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }

    // Same bg color should not split
    {
        var t = try terminal.Terminal.init(alloc, .{ .cols = 3, .rows = 10 });
        defer t.deinit(alloc);

        var s = t.vtStream();
        defer s.deinit();
        // RGB 1, 2, 3 bg
        try s.nextSlice("\x1b[48;2;1;2;3m");
        try s.nextSlice(">");
        try s.nextSlice("=");

        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
}

test "shape high plane sprite font codepoint" {
    // While creating runs, the CoreText shaper uses `0` codepoints to
    // pad its codepoint list to account for high plane characters which
    // use two UTF-16 code units. This is so that, after shaping, the string
    // indices can be used to find the originating codepoint / cluster.
    //
    // This is a problem for special (sprite) fonts, which need to be "shaped"
    // by simply returning the input codepoints verbatim. We include logic to
    // skip `0` codepoints when constructing the shaped run for sprite fonts,
    // this test verifies that it works correctly.

    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    // U+1FB70: Vertical One Eighth Block-2
    try s.nextSlice("\u{1FB70}");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });
    // We should get one run
    const run = (try it.next(alloc)).?;
    // The run state should have the UTF-16 encoding of the character.
    try testing.expectEqualSlices(
        u16,
        &.{ 0xD83E, 0xDF70 },
        shaper.run_state.unichars.items,
    );
    // The codepoint list should be padded.
    try testing.expectEqualSlices(
        Shaper.Codepoint,
        &.{
            .{ .codepoint = 0x1FB70, .cluster = 0 },
            .{ .codepoint = 0, .cluster = 0 },
        },
        shaper.run_state.codepoints.items,
    );
    // And when shape it
    const cells = try shaper.shape(run);
    // we should have
    // - 1 cell
    try testing.expectEqual(1, run.cells);
    // - at position 0
    try testing.expectEqual(0, run.offset);
    // - with 1 glyph in it
    try testing.expectEqual(1, cells.len);
    // - at position 0
    try testing.expectEqual(0, cells[0].x);
    // - the glyph index should be equal to the codepoint
    try testing.expectEqual(0x1FB70, cells[0].glyph_index);
    // - it should be a sprite font
    try testing.expect(run.font_index.special() != null);
    // And we should get a null run after that
    try testing.expectEqual(null, try it.next(alloc));
}

test "shape LTR neutral RTL splits and sets direction" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaperWithFont(alloc, .arabic);
    defer testdata.deinit();

    // "Hello مرحبا" — LTR "Hello" then neutral space then RTL Arabic.
    var t = try terminal.Terminal.init(alloc, .{ .cols = 30, .rows = 3 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("Hello مرحبا");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });

    var runs: [10]font.shape.TextRun = undefined;
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        if (count < runs.len) runs[count] = run;
        count += 1;
    }

    try testing.expectEqual(@as(usize, 2), count);
    try testing.expect(!runs[0].rtl);
    try testing.expectEqual(@as(u16, 0), runs[0].offset);
    try testing.expect(runs[1].rtl);
    try testing.expect(runs[1].offset > 0);
}

test "shape arabic with tashkeel at EOL" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaperWithFont(alloc, .arabic);
    defer testdata.deinit();

    var t = try terminal.Terminal.init(alloc, .{ .cols = 30, .rows = 3 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("مرحباً");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });

    const run = (try it.next(alloc)).?;
    try testing.expect(run.rtl);
    try testing.expectEqual(@as(u16, 5), run.cells);
    const cells = try shaper.shape(run);
    try testing.expect(cells.len > 1);

    var prev_x: u16 = cells[0].x;
    for (cells[1..]) |cell| {
        try testing.expect(cell.x >= prev_x);
        prev_x = cell.x;
    }
    for (cells) |cell| {
        try testing.expect(cell.x < run.cells);
    }

    try testing.expectEqual(try it.next(alloc), null);
}

test "shape arabic with tashkeel on middle letters" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaperWithFont(alloc, .arabic);
    defer testdata.deinit();

    var t = try terminal.Terminal.init(alloc, .{ .cols = 30, .rows = 3 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("وفُكَّ");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });

    const run = (try it.next(alloc)).?;
    try testing.expect(run.rtl);
    try testing.expectEqual(@as(u16, 3), run.cells);

    const cells = try shaper.shape(run);
    try testing.expect(cells.len > 0);

    var seen = [_]bool{ false, false, false };
    for (cells) |cell| {
        try testing.expect(cell.x < run.cells);
        seen[cell.x] = true;
    }
    try testing.expect(seen[0]);
    try testing.expect(seen[1]);
    try testing.expect(seen[2]);

    try testing.expectEqual(@as(?font.shape.TextRun, null), try it.next(alloc));
}

test "shape arabic tanween stays on hamza before space" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaperWithFont(alloc, .arabic);
    defer testdata.deinit();

    var t = try terminal.Terminal.init(alloc, .{ .cols = 30, .rows = 3 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("شيءٍ جميل");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });

    const run = (try it.next(alloc)).?;
    try testing.expect(run.rtl);
    try testing.expectEqual(@as(u16, 8), run.cells);

    var hamza_cluster: ?u32 = null;
    var tanween_cluster: ?u32 = null;
    for (shaper.run_state.codepoints.items) |entry| {
        if (entry.codepoint == 0x0621 and hamza_cluster == null) hamza_cluster = entry.cluster;
        if (entry.codepoint == 0x064D and tanween_cluster == null) tanween_cluster = entry.cluster;
    }
    try testing.expect(hamza_cluster != null);
    try testing.expect(tanween_cluster != null);
    try testing.expectEqual(hamza_cluster.?, tanween_cluster.?);

    const cells = try shaper.shape(run);
    try testing.expect(cells.len > 0);

    var hamza_cell_glyphs: usize = 0;
    for (cells) |cell| {
        if (cell.x == hamza_cluster.?) hamza_cell_glyphs += 1;
    }
    try testing.expect(hamza_cell_glyphs >= 2);

    try testing.expectEqual(@as(?font.shape.TextRun, null), try it.next(alloc));
}

test "shape arabic end tashkeel no overlap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaperWithFont(alloc, .arabic);
    defer testdata.deinit();

    var t = try terminal.Terminal.init(alloc, .{ .cols = 30, .rows = 3 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("بحقِّ");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });

    const run = (try it.next(alloc)).?;
    try testing.expect(run.rtl);
    try testing.expectEqual(@as(u16, 3), run.cells);

    var qaf_cluster: ?u32 = null;
    var kasra_cluster: ?u32 = null;
    var shadda_cluster: ?u32 = null;
    var ha_cluster: ?u32 = null;
    for (shaper.run_state.codepoints.items) |entry| {
        if (entry.codepoint == 0) continue;
        if (entry.codepoint == 0x0642 and qaf_cluster == null) qaf_cluster = entry.cluster;
        if (entry.codepoint == 0x0650 and kasra_cluster == null) kasra_cluster = entry.cluster;
        if (entry.codepoint == 0x0651 and shadda_cluster == null) shadda_cluster = entry.cluster;
        if (entry.codepoint == 0x062D and ha_cluster == null) ha_cluster = entry.cluster;
    }
    try testing.expect(qaf_cluster != null);
    try testing.expect(kasra_cluster != null);
    try testing.expect(shadda_cluster != null);
    try testing.expect(ha_cluster != null);
    try testing.expectEqual(qaf_cluster.?, kasra_cluster.?);
    try testing.expectEqual(qaf_cluster.?, shadda_cluster.?);
    try testing.expect(qaf_cluster.? != ha_cluster.?);

    const cells = try shaper.shape(run);
    try testing.expect(cells.len > 0);

    var prev_x: u16 = cells[0].x;
    for (cells[1..]) |cell| {
        try testing.expect(cell.x >= prev_x);
        prev_x = cell.x;
    }

    var seen = [_]bool{ false, false, false };
    var qaf_cell_glyphs: usize = 0;
    for (cells) |cell| {
        try testing.expect(cell.x < run.cells);
        seen[cell.x] = true;
        if (cell.x == qaf_cluster.?) qaf_cell_glyphs += 1;

        // Base glyphs after the tashkeel cluster must not carry a
        // spurious x_offset from position.x/run_offset.x divergence.
        if (cell.x != qaf_cluster.?) {
            try testing.expectEqual(@as(i32, 0), cell.x_offset);
        }
    }
    try testing.expect(seen[0]);
    try testing.expect(seen[1]);
    try testing.expect(seen[2]);
    try testing.expect(qaf_cell_glyphs >= 2);

    try testing.expectEqual(@as(?font.shape.TextRun, null), try it.next(alloc));
}

test "shape arabic end tanween no overlap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaperWithFont(alloc, .arabic);
    defer testdata.deinit();

    var t = try terminal.Terminal.init(alloc, .{ .cols = 30, .rows = 3 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("عينٍ");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });

    const run = (try it.next(alloc)).?;
    try testing.expect(run.rtl);
    try testing.expectEqual(@as(u16, 3), run.cells);

    var nun_cluster: ?u32 = null;
    var tanween_cluster: ?u32 = null;
    var ya_cluster: ?u32 = null;
    for (shaper.run_state.codepoints.items) |entry| {
        if (entry.codepoint == 0) continue;
        if (entry.codepoint == 0x0646 and nun_cluster == null) nun_cluster = entry.cluster;
        if (entry.codepoint == 0x064D and tanween_cluster == null) tanween_cluster = entry.cluster;
        if (entry.codepoint == 0x064A and ya_cluster == null) ya_cluster = entry.cluster;
    }
    try testing.expect(nun_cluster != null);
    try testing.expect(tanween_cluster != null);
    try testing.expect(ya_cluster != null);
    try testing.expectEqual(nun_cluster.?, tanween_cluster.?);
    try testing.expect(nun_cluster.? != ya_cluster.?);

    const cells = try shaper.shape(run);
    try testing.expect(cells.len > 0);

    var prev_x: u16 = cells[0].x;
    for (cells[1..]) |cell| {
        try testing.expect(cell.x >= prev_x);
        prev_x = cell.x;
    }

    var seen = [_]bool{ false, false, false };
    var nun_cell_glyphs: usize = 0;
    for (cells) |cell| {
        try testing.expect(cell.x < run.cells);
        seen[cell.x] = true;
        if (cell.x == nun_cluster.?) nun_cell_glyphs += 1;

        // Base glyphs after the tanween cluster must not carry a
        // spurious x_offset from position.x/run_offset.x divergence.
        if (cell.x != nun_cluster.?) {
            try testing.expectEqual(@as(i32, 0), cell.x_offset);
        }
    }
    try testing.expect(seen[0]);
    try testing.expect(seen[1]);
    try testing.expect(seen[2]);
    try testing.expect(nun_cell_glyphs >= 2);

    try testing.expectEqual(@as(?font.shape.TextRun, null), try it.next(alloc));
}

test "shape arabic multiword end tashkeel stays anchored" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaperWithFont(alloc, .arabic);
    defer testdata.deinit();

    var t = try terminal.Terminal.init(alloc, .{ .cols = 30, .rows = 3 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("الحيِّ الذي");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });

    const run = (try it.next(alloc)).?;
    try testing.expect(run.rtl);

    var kasra_cluster: ?u32 = null;
    var shadda_cluster: ?u32 = null;
    for (shaper.run_state.codepoints.items) |entry| {
        if (entry.codepoint == 0) continue;
        if (entry.codepoint == 0x0650 and kasra_cluster == null) kasra_cluster = entry.cluster;
        if (entry.codepoint == 0x0651 and shadda_cluster == null) shadda_cluster = entry.cluster;
    }
    try testing.expect(kasra_cluster != null);
    try testing.expect(shadda_cluster != null);
    try testing.expectEqual(kasra_cluster.?, shadda_cluster.?);
    const ya_cluster = kasra_cluster.?;

    var ha_cluster: ?u32 = null;
    for (shaper.run_state.codepoints.items) |entry| {
        if (entry.codepoint == 0) continue;
        if (entry.codepoint == 0x062D and ha_cluster == null) ha_cluster = entry.cluster;
    }
    try testing.expect(ha_cluster != null);
    try testing.expect(ha_cluster.? != ya_cluster);

    const cells = try shaper.shape(run);
    try testing.expect(cells.len > 0);

    var prev_x: u16 = cells[0].x;
    var saw_ha = false;
    var saw_ya = false;
    var ya_base_near_zero = false;
    for (cells) |cell| {
        try testing.expect(cell.x < run.cells);
        try testing.expect(cell.x >= prev_x);
        prev_x = cell.x;

        const xoff: i32 = cell.x_offset;
        try testing.expect(@abs(xoff) < 200);
        if (cell.x == ha_cluster.?) saw_ha = true;
        if (cell.x == ya_cluster) {
            saw_ya = true;
            if (@abs(xoff) <= 5 and @abs(@as(i32, cell.y_offset)) <= 5) {
                ya_base_near_zero = true;
            }
        }
    }
    try testing.expect(saw_ha);
    try testing.expect(saw_ya);
    try testing.expect(ya_base_near_zero);

    try testing.expectEqual(@as(?font.shape.TextRun, null), try it.next(alloc));
}

const TestShaper = struct {
    alloc: Allocator,
    shaper: Shaper,
    grid: *SharedGrid,
    lib: Library,

    pub fn deinit(self: *TestShaper) void {
        self.shaper.deinit();
        self.grid.deinit(self.alloc);
        self.alloc.destroy(self.grid);
        self.lib.deinit();
    }
};

const TestFont = enum {
    arabic,
    code_new_roman,
    geist_mono,
    inconsolata,
    jetbrains_mono,
    monaspace_neon,
    nerd_font,
};

/// Helper to return a fully initialized shaper.
fn testShaper(alloc: Allocator) !TestShaper {
    return try testShaperWithFont(alloc, .inconsolata);
}

fn testShaperWithFont(alloc: Allocator, font_req: TestFont) !TestShaper {
    const testEmoji = font.embedded.emoji;
    const testEmojiText = font.embedded.emoji_text;
    const testFont = switch (font_req) {
        .arabic => font.embedded.arabic,
        .code_new_roman => font.embedded.code_new_roman,
        .inconsolata => font.embedded.inconsolata,
        .geist_mono => font.embedded.geist_mono,
        .jetbrains_mono => font.embedded.jetbrains_mono,
        .monaspace_neon => font.embedded.monaspace_neon,
        .nerd_font => font.embedded.test_nerd_font,
    };

    var lib = try Library.init(alloc);
    errdefer lib.deinit();

    var c = Collection.init();
    c.load_options = .{ .library = lib };

    // Setup group
    _ = try c.add(alloc, try .init(
        lib,
        testFont,
        .{ .size = .{ .points = 12 } },
    ), .{
        .style = .regular,
        .fallback = false,
        .size_adjustment = .none,
    });

    if (font.options.backend != .coretext) {
        // Coretext doesn't support Noto's format
        _ = try c.add(alloc, try .init(
            lib,
            testEmoji,
            .{ .size = .{ .points = 12 } },
        ), .{
            .style = .regular,
            .fallback = false,
            .size_adjustment = .none,
        });
    } else {
        // On CoreText we want to load Apple Emoji, we should have it.
        var disco = font.Discover.init();
        defer disco.deinit();
        var disco_it = try disco.discover(alloc, .{
            .family = "Apple Color Emoji",
            .size = 12,
            .monospace = false,
        });
        defer disco_it.deinit();
        var face = (try disco_it.next()).?;
        errdefer face.deinit();
        _ = try c.addDeferred(alloc, face, .{
            .style = .regular,
            .fallback = false,
            .size_adjustment = .none,
        });
    }
    _ = try c.add(alloc, try .init(
        lib,
        testEmojiText,
        .{ .size = .{ .points = 12 } },
    ), .{
        .style = .regular,
        .fallback = false,
        .size_adjustment = .none,
    });

    const grid_ptr = try alloc.create(SharedGrid);
    errdefer alloc.destroy(grid_ptr);
    grid_ptr.* = try .init(alloc, .{ .collection = c });
    errdefer grid_ptr.*.deinit(alloc);

    var shaper = try Shaper.init(alloc, .{
        // Some of our tests rely on dlig being enabled by default
        .features = &.{"dlig"},
    });
    errdefer shaper.deinit();

    return TestShaper{
        .alloc = alloc,
        .shaper = shaper,
        .grid = grid_ptr,
        .lib = lib,
    };
}

/// Return a fully initialized shaper by discovering a named font on the system.
fn testShaperWithDiscoveredFont(alloc: Allocator, font_req: [:0]const u8) !TestShaper {
    var lib = try Library.init(alloc);
    errdefer lib.deinit();

    var c = Collection.init();
    c.load_options = .{ .library = lib };

    // Discover and add our font to the collection.
    {
        var disco = font.Discover.init();
        defer disco.deinit();
        var disco_it = try disco.discover(alloc, .{
            .family = font_req,
            .size = 12,
            .monospace = false,
        });
        defer disco_it.deinit();
        var face: font.DeferredFace = (try disco_it.next()) orelse return error.FontNotFound;
        errdefer face.deinit();
        _ = try c.add(
            alloc,
            try face.load(lib, .{ .size = .{ .points = 12 } }),
            .{
                .style = .regular,
                .fallback = false,
                .size_adjustment = .none,
            },
        );
    }

    const grid_ptr = try alloc.create(SharedGrid);
    errdefer alloc.destroy(grid_ptr);
    grid_ptr.* = try .init(alloc, .{ .collection = c });
    errdefer grid_ptr.*.deinit(alloc);

    var shaper = try Shaper.init(alloc, .{});
    errdefer shaper.deinit();

    return TestShaper{
        .alloc = alloc,
        .shaper = shaper,
        .grid = grid_ptr,
        .lib = lib,
    };
}
