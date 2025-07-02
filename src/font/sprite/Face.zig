//! This implements the built-in "sprite face". This font renders
//! the built-in glyphs for the terminal, such as box drawing fonts, as well
//! as specific sprites that are part of our rendering model such as
//! text decorations (underlines).
//!
//! This isn't really a "font face" so much as it is quacks like a font
//! face with regards to how it works with font.Group. We don't use any
//! dynamic dispatch so it isn't truly an interface but the functions
//! and behaviors are close enough to a system face that it makes it easy
//! to integrate with font.Group. This is desirable so that higher level
//! processes such as GroupCache, Shaper, etc. don't need to be aware of
//! special sprite handling and just treat it like a normal font face.
const Face = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const wuffs = @import("wuffs");
const z2d = @import("z2d");
const font = @import("../main.zig");
const Sprite = font.sprite.Sprite;

const special = @import("draw/special.zig");

const log = std.log.scoped(.font_sprite);

/// Grid metrics for rendering sprites.
metrics: font.Metrics,

pub const DrawFnError =
    Allocator.Error ||
    z2d.painter.FillError ||
    z2d.painter.StrokeError ||
    error{
        /// Something went wrong while doing math.
        MathError,
    };

/// A function that draws a glyph on the provided canvas.
pub const DrawFn = fn (
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) DrawFnError!void;

const Range = struct {
    min: u32,
    max: u32,
    draw: DrawFn,
};

/// Automatically collect ranges for functions with names
/// in the format `draw<CP>` or `draw<MIN>_<MAX>`.
const ranges: []const Range = ranges: {
    @setEvalBranchQuota(1_000_000);

    // Structs containing drawing functions for codepoint ranges.
    const structs = [_]type{
        @import("draw/block.zig"),
        @import("draw/box.zig"),
        @import("draw/braille.zig"),
        @import("draw/branch.zig"),
        @import("draw/geometric_shapes.zig"),
        @import("draw/powerline.zig"),
        @import("draw/symbols_for_legacy_computing.zig"),
        @import("draw/symbols_for_legacy_computing_supplement.zig"),
    };

    // Count how many draw fns we have
    var range_count = 0;
    for (structs) |s| {
        for (@typeInfo(s).@"struct".decls) |decl| {
            if (!@hasDecl(s, decl.name)) continue;
            if (!std.mem.startsWith(u8, decl.name, "draw")) continue;
            range_count += 1;
        }
    }

    // Make an array and collect ranges for each function.
    var r: [range_count]Range = undefined;
    var names: [range_count][:0]const u8 = undefined;
    var i = 0;
    for (structs) |s| {
        for (@typeInfo(s).@"struct".decls) |decl| {
            if (!@hasDecl(s, decl.name)) continue;
            if (!std.mem.startsWith(u8, decl.name, "draw")) continue;

            const sep = std.mem.indexOfScalar(u8, decl.name, '_') orelse decl.name.len;

            const min = std.fmt.parseInt(u21, decl.name[4..sep], 16) catch unreachable;

            const max = if (sep == decl.name.len)
                min
            else
                std.fmt.parseInt(u21, decl.name[sep + 1 ..], 16) catch unreachable;

            r[i] = .{
                .min = min,
                .max = max,
                .draw = @field(s, decl.name),
            };
            names[i] = decl.name;
            i += 1;
        }
    }

    // Sort ranges in ascending order
    std.mem.sortUnstableContext(0, r.len, struct {
        r: []Range,
        names: [][:0]const u8,
        pub fn lessThan(self: @This(), a: usize, b: usize) bool {
            return self.r[a].min < self.r[b].min;
        }
        pub fn swap(self: @This(), a: usize, b: usize) void {
            std.mem.swap(Range, &self.r[a], &self.r[b]);
            std.mem.swap([:0]const u8, &self.names[a], &self.names[b]);
        }
    }{
        .r = &r,
        .names = &names,
    });

    // Ensure there's no overlapping ranges
    i = 0;
    for (r, 0..) |n, k| {
        if (n.min <= i) {
            @compileError(
                std.fmt.comptimePrint(
                    "Codepoint range for {s}(...) overlaps range for {s}(...), {X} <= {X} <= {X}",
                    .{ names[k], names[k - 1], r[k - 1].min, n.min, r[k - 1].max },
                ),
            );
        }
        i = n.max;
    }

    // We need to copy in to a const rather than a var in order to take
    // the reference at comptime so that we can break with a slice here.
    const fixed = r;

    break :ranges &fixed;
};

fn getDrawFn(cp: u32) ?*const DrawFn {
    // For special sprites (cursors, underlines, etc.) all sprites are drawn
    // by functions from `Special` that share the name of the enum field.
    if (cp >= Sprite.start) switch (@as(Sprite, @enumFromInt(cp))) {
        inline else => |sprite| {
            return @field(special, @tagName(sprite));
        },
    };

    // Pray that the compiler is smart enough to
    // turn this in to a jump table or something...
    inline for (ranges) |range| {
        if (cp >= range.min and cp <= range.max) return range.draw;
    }
    return null;
}

/// Returns true if the codepoint exists in our sprite font.
pub fn hasCodepoint(self: Face, cp: u32, p: ?font.Presentation) bool {
    // We ignore presentation. No matter what presentation is
    // requested we always provide glyphs for our codepoints.
    _ = p;
    _ = self;
    return getDrawFn(cp) != null;
}

/// Render the glyph.
pub fn renderGlyph(
    self: Face,
    alloc: Allocator,
    atlas: *font.Atlas,
    cp: u32,
    opts: font.face.RenderOptions,
) !font.Glyph {
    if (std.debug.runtime_safety) {
        if (!self.hasCodepoint(cp, null)) {
            log.err("invalid codepoint cp={x}", .{cp});
            unreachable; // crash
        }
    }

    // It should be impossible for this to be null and we assert that
    // in runtime safety modes but in case it is its not worth memory
    // corruption so we return a valid, blank glyph.
    const draw = getDrawFn(cp) orelse return .{
        .width = 0,
        .height = 0,
        .offset_x = 0,
        .offset_y = 0,
        .atlas_x = 0,
        .atlas_y = 0,
        .advance_x = 0,
    };

    const metrics = self.metrics;

    // We adjust our sprite width based on the cell width.
    const width = switch (opts.cell_width orelse 1) {
        0, 1 => metrics.cell_width,
        else => |width| metrics.cell_width * width,
    };

    const height = metrics.cell_height;

    const padding_x = width / 4;
    const padding_y = height / 4;

    // Make a canvas of the desired size
    var canvas = try font.sprite.Canvas.init(alloc, width, height, padding_x, padding_y);
    defer canvas.deinit();

    try draw(cp, &canvas, width, height, metrics);

    // Write the drawing to the atlas
    const region = try canvas.writeAtlas(alloc, atlas);

    return .{
        .width = region.width,
        .height = region.height,
        .offset_x = @as(i32, @intCast(canvas.clip_left)) - @as(i32, @intCast(padding_x)),
        .offset_y = @as(i32, @intCast(region.height +| canvas.clip_bottom)) - @as(i32, @intCast(padding_y)),
        .atlas_x = region.x,
        .atlas_y = region.y,
        .advance_x = @floatFromInt(width),
        .sprite = true,
    };
}

/// Used in `testDrawRanges`, checks for diff between the provided atlas
/// and the reference file for the range, returns true if there is a diff.
fn testDiffAtlas(
    alloc: Allocator,
    atlas: *z2d.Surface,
    path: []const u8,
    i: u32,
    width: u32,
    height: u32,
    thickness: u32,
) !bool {
    // Get the file contents, we compare the PNG data first in
    // order to ensure that no one smuggles arbitrary binary
    // data in to the reference PNGs.
    const test_file = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
    defer test_file.close();
    const test_bytes = try test_file.readToEndAlloc(
        alloc,
        std.math.maxInt(usize),
    );
    defer alloc.free(test_bytes);

    const cwd_absolute = try std.fs.cwd().realpathAlloc(alloc, ".");
    defer alloc.free(cwd_absolute);

    // Get the reference file contents to compare.
    const ref_path = try std.fmt.allocPrint(
        alloc,
        "./src/font/sprite/testdata/U+{X}...U+{X}-{d}x{d}+{d}.png",
        .{ i, i + 0xFF, width, height, thickness },
    );
    defer alloc.free(ref_path);
    const ref_file =
        std.fs.cwd().openFile(ref_path, .{ .mode = .read_only }) catch |err| {
            log.err("Can't open reference file {s}: {}\n", .{
                ref_path,
                err,
            });

            // Copy the test PNG in to the CWD so it isn't
            // cleaned up with the rest of the tmp dir files.
            const test_path = try std.fmt.allocPrint(
                alloc,
                "{s}/sprite_face_test-U+{X}...U+{X}-{d}x{d}+{d}.png",
                .{ cwd_absolute, i, i + 0xFF, width, height, thickness },
            );
            defer alloc.free(test_path);
            try std.fs.copyFileAbsolute(path, test_path, .{});

            return true;
        };
    defer ref_file.close();
    const ref_bytes = try ref_file.readToEndAlloc(
        alloc,
        std.math.maxInt(usize),
    );
    defer alloc.free(ref_bytes);

    // Do our PNG bytes comparison, if it's the same then we can
    // move on, otherwise we'll decode the reference file and do
    // a pixel-for-pixel diff.
    if (std.mem.eql(u8, test_bytes, ref_bytes)) return false;

    // Copy the test PNG in to the CWD so it isn't
    // cleaned up with the rest of the tmp dir files.
    const test_path = try std.fmt.allocPrint(
        alloc,
        "{s}/sprite_face_test-U+{X}...U+{X}-{d}x{d}+{d}.png",
        .{ cwd_absolute, i, i + 0xFF, width, height, thickness },
    );
    defer alloc.free(test_path);
    try std.fs.copyFileAbsolute(path, test_path, .{});

    // Use wuffs to decode the reference PNG to raw pixels.
    // These will be RGBA, so when diffing we can just compare
    // every fourth byte.
    const ref_rgba = try wuffs.png.decode(alloc, ref_bytes);
    defer alloc.free(ref_rgba.data);

    assert(ref_rgba.width == atlas.getWidth());
    assert(ref_rgba.height == atlas.getHeight());

    // We'll make a visual representation of the diff using
    // red for removed pixels and green for added. We make
    // a z2d surface for that here.
    var diff = try z2d.Surface.init(
        .image_surface_rgb,
        alloc,
        atlas.getWidth(),
        atlas.getHeight(),
    );
    defer diff.deinit(alloc);
    const diff_pix = diff.image_surface_rgb.buf;

    const test_gray = std.mem.sliceAsBytes(atlas.image_surface_alpha8.buf);

    var differs: bool = false;
    for (0..test_gray.len) |j| {
        const t = test_gray[j];
        const r = ref_rgba.data[j * 4];
        if (t == r) {
            // If the pixels match, write it as a faded gray.
            diff_pix[j].r = t / 3;
            diff_pix[j].g = t / 3;
            diff_pix[j].b = t / 3;
        } else {
            differs = true;
            // Otherwise put the reference value in the red
            // channel and the new value in the green channel.
            diff_pix[j].r = r;
            diff_pix[j].g = t;
        }
    }

    // If the PNG data differs but not the raw pixels, that's
    // a big red flag, since it could mean someone is trying to
    // smuggle binary data in to the test files.
    if (!differs) {
        log.err(
            "!!! Test PNG data does not match reference, but pixels do match! " ++
                "Either z2d's PNG exporter changed or someone is " ++
                "trying to smuggle binary data in the test files!\n" ++
                "test={s}, reference={s}",
            .{ test_path, ref_path },
        );
        return true;
    }

    // Drop the diff image as a PNG in the cwd.
    const diff_path = try std.fmt.allocPrint(
        alloc,
        "./sprite_face_diff-U+{X}...U+{X}-{d}x{d}+{d}.png",
        .{ i, i + 0xFF, width, height, thickness },
    );
    defer alloc.free(diff_path);
    try z2d.png_exporter.writeToPNGFile(diff, diff_path, .{});
    log.err(
        "One or more glyphs differ from reference file in range U+{X}...U+{X}! " ++
            "test={s}, reference={s}, diff={s}",
        .{ i, i + 0xFF, test_path, ref_path, diff_path },
    );

    return true;
}

/// Draws all ranges in to a set of 16x16 glyph atlases, checks for regressions
/// against reference files, logs errors and exposes a diff for any difference
/// between the reference and test atlas.
///
/// Returns true if there was a diff.
fn testDrawRanges(
    width: u32,
    ascent: u32,
    descent: u32,
    thickness: u32,
) !bool {
    const testing = std.testing;
    const alloc = testing.allocator;

    const metrics: font.Metrics = .calc(.{
        .cell_width = @floatFromInt(width),
        .ascent = @floatFromInt(ascent),
        .descent = -@as(f64, @floatFromInt(descent)),
        .line_gap = 0.0,
        .underline_thickness = @floatFromInt(thickness),
        .strikethrough_thickness = @floatFromInt(thickness),
    });

    const height = ascent + descent;

    const padding_x = width / 4;
    const padding_y = height / 4;

    // Canvas to draw glyphs on, we'll re-use this for all glyphs.
    var canvas = try font.sprite.Canvas.init(
        alloc,
        width,
        height,
        padding_x,
        padding_y,
    );
    defer canvas.deinit();

    // We render glyphs in batches of 256, which we copy (including padding) to
    // a 16 by 16 surface to be compared with the reference file for that range.
    const stride_x = width + 2 * padding_x;
    const stride_y = height + 2 * padding_y;
    var atlas = try z2d.Surface.init(
        .image_surface_alpha8,
        alloc,
        @intCast(stride_x * 16),
        @intCast(stride_y * 16),
    );
    defer atlas.deinit(alloc);

    var i: u32 = std.mem.alignBackward(u32, ranges[0].min, 0x100);

    // Try to make the sprite_face_test folder if it doesn't already exist.
    var dir = testing.tmpDir(.{});
    defer dir.cleanup();
    const tmp_dir = try dir.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_dir);

    // We set this to true if we have any fails so we can
    // return an error after we're done comparing all glyphs.
    var fail: bool = false;

    inline for (ranges) |range| {
        for (range.min..range.max + 1) |cp| {
            // If we've moved to a new batch of 256, check the
            // current one and clear the surface for the next one.
            if (cp - i >= 0x100) {
                // Export to our tmp dir.
                const path = try std.fmt.allocPrint(
                    alloc,
                    "{s}/U+{X}...U+{X}-{d}x{d}+{d}.png",
                    .{ tmp_dir, i, i + 0xFF, width, height, thickness },
                );
                defer alloc.free(path);
                try z2d.png_exporter.writeToPNGFile(atlas, path, .{});

                if (try testDiffAtlas(
                    alloc,
                    &atlas,
                    path,
                    i,
                    width,
                    height,
                    thickness,
                )) fail = true;

                i = std.mem.alignBackward(u32, @intCast(cp), 0x100);
                @memset(std.mem.sliceAsBytes(atlas.image_surface_alpha8.buf), 0);
            }

            try getDrawFn(@intCast(cp)).?(
                @intCast(cp),
                &canvas,
                width,
                height,
                metrics,
            );
            canvas.clearClippingRegions();
            atlas.composite(
                &canvas.sfc,
                .src,
                @intCast(stride_x * ((cp - i) % 16)),
                @intCast(stride_y * ((cp - i) / 16)),
                .{},
            );
            @memset(std.mem.sliceAsBytes(canvas.sfc.image_surface_alpha8.buf), 0);
            canvas.clip_top = 0;
            canvas.clip_left = 0;
            canvas.clip_right = 0;
            canvas.clip_bottom = 0;
        }
    }

    const path = try std.fmt.allocPrint(
        alloc,
        "{s}/U+{X}...U+{X}-{d}x{d}+{d}.png",
        .{ tmp_dir, i, i + 0xFF, width, height, thickness },
    );
    defer alloc.free(path);
    try z2d.png_exporter.writeToPNGFile(atlas, path, .{});
    if (try testDiffAtlas(
        alloc,
        &atlas,
        path,
        i,
        width,
        height,
        thickness,
    )) fail = true;

    return fail;
}

test "sprite face render all sprites" {
    // Renders all sprites to an atlas and compares
    // it to a ground truth for regression testing.

    var diff: bool = false;

    // testDrawRanges(width, ascent, descent, thickness):
    //
    // We compare 4 different sets of metrics;
    // - even cell size / even thickness
    // - even cell size / odd thickness
    // - odd cell size / even thickness
    // - odd cell size / odd thickness
    // (Also a decreasing range of sizes.)
    if (try testDrawRanges(18, 30, 6, 4)) diff = true;
    if (try testDrawRanges(12, 20, 4, 3)) diff = true;
    if (try testDrawRanges(11, 19, 2, 2)) diff = true;
    if (try testDrawRanges(9, 15, 2, 1)) diff = true;

    try std.testing.expect(!diff); // There should be no diffs from reference.
}

// test "sprite face print all sprites" {
//     std.debug.print("\n\n", .{});
//     inline for (ranges) |range| {
//         for (range.min..range.max + 1) |cp| {
//             std.debug.print("{u}", .{ @as(u21, @intCast(cp)) });
//         }
//     }
//     std.debug.print("\n\n", .{});
// }

test {
    std.testing.refAllDecls(@This());
}
