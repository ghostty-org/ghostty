const std = @import("std");
const Allocator = std.mem.Allocator;
const wuffs = @import("wuffs");
const z2d = @import("z2d");
const compat_file = @import("../lib/compat/file.zig");

const glyf_rasterize = @import("glyf_rasterize.zig");
const glyf = @import("opentype/glyf.zig");

const log = std.log.scoped(.glyf_rasterize);

const test_glyf_payloads = [_][]const u8{
    // Nerd Font branch, folder, home, heart, and Rust cog outlines from:
    // https://github.com/raphamorim/glyph-protocol-examples/blob/main/bubbletea/main.go
    "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",
};

/// Return deterministic font metrics for the PNG reference test.
///
/// These are intentionally minimal: the rasterizer only needs cell geometry,
/// face geometry, and icon heights for constraint calculations.
fn testMetrics(width: u32, height: u32) @import("Metrics.zig") {
    return .{
        .cell_width = width,
        .cell_height = height,
        .cell_baseline = 0,
        .underline_position = height,
        .underline_thickness = 1,
        .strikethrough_position = height / 2,
        .strikethrough_thickness = 1,
        .overline_position = 0,
        .overline_thickness = 1,
        .box_thickness = 1,
        .cursor_thickness = 1,
        .cursor_height = height,
        .icon_height = @floatFromInt(height),
        .icon_height_single = @floatFromInt(height),
        .face_width = @floatFromInt(width),
        .face_height = @floatFromInt(height),
        .face_y = 0,
    };
}

/// Decode a base64-encoded glyf protocol payload into an owned outline.
///
/// The payload is a complete simple-glyph `glyf` table entry. The returned
/// outline owns decoded point and contour storage and must be deinitialized by
/// the caller.
fn decodeGlyfPayload(alloc: Allocator, payload: []const u8) !glyf.Glyf.Outline {
    const decoder = std.base64.standard.Decoder;
    const size = try decoder.calcSizeForSlice(payload);
    const data = try alloc.alloc(u8, size);
    defer alloc.free(data);

    try decoder.decode(data, payload);
    const entry = try glyf.Glyf.Entry.init(data);
    return try entry.decode(alloc);
}

/// Copy a tightly packed alpha bitmap into the alpha atlas at `dst_x`, `dst_y`.
///
/// The destination rectangle must fit inside the atlas. This is a test helper,
/// so it trusts the hardcoded atlas layout rather than clipping.
fn blitBitmap(atlas: *z2d.Surface, bm: glyf_rasterize.Bitmap, dst_x: usize, dst_y: usize) void {
    const dst_width: usize = @intCast(atlas.getWidth());
    const dst = std.mem.sliceAsBytes(atlas.image_surface_alpha8.buf);
    for (0..bm.height) |y| {
        const src_start = y * bm.width;
        const src_end = src_start + bm.width;
        const dst_start = (dst_y + y) * dst_width + dst_x;
        @memcpy(dst[dst_start .. dst_start + bm.width], bm.data[src_start..src_end]);
    }
}

/// Draw faint terminal-cell outlines into one row of the alpha atlas.
///
/// The boxes make cell advance and placement behavior visible in the reference
/// PNG without overpowering the rendered glyph coverage.
fn drawCellBoxes(atlas: *z2d.Surface, y: usize, cell_width: usize, cell_height: usize) void {
    const width: usize = @intCast(atlas.getWidth());
    const dst = std.mem.sliceAsBytes(atlas.image_surface_alpha8.buf);
    const alpha = 64;

    var x: usize = 0;
    while (x < width) : (x += cell_width) {
        const right = @min(x + cell_width - 1, width - 1);
        const bottom = y + cell_height - 1;

        for (x..right + 1) |px| {
            dst[y * width + px] = @max(dst[y * width + px], alpha);
            dst[bottom * width + px] = @max(dst[bottom * width + px], alpha);
        }
        for (y..bottom + 1) |py| {
            dst[py * width + x] = @max(dst[py * width + x], alpha);
            dst[py * width + right] = @max(dst[py * width + right], alpha);
        }
    }
}

/// Compare a generated atlas PNG against the checked-in reference image.
///
/// On missing reference or mismatch, copy the generated PNG into the workspace
/// as `glyf_rasterize_test.png`. On pixel mismatch, also write
/// `glyf_rasterize_diff.png`, where red is reference-only coverage and green is
/// newly generated coverage. Returns true when a difference was found.
fn diffAtlas(
    io: std.Io,
    alloc: Allocator,
    atlas: *z2d.Surface,
    generated_path: []const u8,
) !bool {
    const ref_path = "src/font/testdata/glyf_rasterize.png";

    const generated_file = try std.Io.Dir.openFileAbsolute(io, generated_path, .{ .mode = .read_only });
    defer generated_file.close(io);
    const generated_bytes = try compat_file.readToEndAlloc(generated_file, alloc, std.math.maxInt(usize));
    defer alloc.free(generated_bytes);

    const cwd_absolute = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", alloc);
    defer alloc.free(cwd_absolute);

    const ref_file = std.Io.Dir.cwd().openFile(io, ref_path, .{ .mode = .read_only }) catch |err| {
        log.err("Can't open reference file {s}: {}", .{ ref_path, err });

        const test_path = try std.fmt.allocPrint(alloc, "{s}/glyf_rasterize_test.png", .{cwd_absolute});
        defer alloc.free(test_path);
        try std.Io.Dir.copyFileAbsolute(generated_path, test_path, io, .{});
        return true;
    };
    defer ref_file.close(io);
    const ref_bytes = try compat_file.readToEndAlloc(ref_file, alloc, std.math.maxInt(usize));
    defer alloc.free(ref_bytes);

    if (std.mem.eql(u8, generated_bytes, ref_bytes)) return false;

    const test_path = try std.fmt.allocPrint(alloc, "{s}/glyf_rasterize_test.png", .{cwd_absolute});
    defer alloc.free(test_path);
    try std.Io.Dir.copyFileAbsolute(generated_path, test_path, io, .{});

    const ref_rgba = try wuffs.png.decode(alloc, ref_bytes);
    defer alloc.free(ref_rgba.data);

    if (ref_rgba.width != atlas.getWidth() or ref_rgba.height != atlas.getHeight()) {
        log.err(
            "glyf rasterize visual output dimensions differ from reference: " ++
                "test={s} ({d}x{d}), reference={s} ({d}x{d})",
            .{ test_path, atlas.getWidth(), atlas.getHeight(), ref_path, ref_rgba.width, ref_rgba.height },
        );
        return true;
    }

    var diff = try z2d.Surface.init(
        .image_surface_rgb,
        alloc,
        atlas.getWidth(),
        atlas.getHeight(),
    );
    defer diff.deinit(alloc);

    const test_gray = std.mem.sliceAsBytes(atlas.image_surface_alpha8.buf);
    const diff_pix = diff.image_surface_rgb.buf;
    var differs = false;
    for (test_gray, 0..) |t, i| {
        const r = ref_rgba.data[i * 4];
        if (t == r) {
            diff_pix[i].r = t / 3;
            diff_pix[i].g = t / 3;
            diff_pix[i].b = t / 3;
        } else {
            differs = true;
            diff_pix[i].r = r;
            diff_pix[i].g = t;
        }
    }

    if (!differs) {
        log.err(
            "generated glyf rasterize PNG bytes differ from reference but pixels match; " ++
                "test={s}, reference={s}",
            .{ test_path, ref_path },
        );
        return true;
    }

    const diff_path = "./glyf_rasterize_diff.png";
    try z2d.png_exporter.writeToPNGFile(io, diff, diff_path, .{});
    log.err(
        "glyf rasterize visual output differs from reference: test={s}, reference={s}, diff={s}",
        .{ test_path, ref_path, diff_path },
    );

    return true;
}

test "glyf_rasterize: bubbletea glyph protocol examples match reference image" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // The generated PNG is a visual atlas for reading placement behavior.
    // Each column below is one terminal cell. The five payloads are rendered in
    // order: branch, folder, home, heart, rust.
    //
    // ```text
    // columns: 0 1 2 3 4 5 6 7 8 9
    //          ┌─┬─┬─┬─┬─┬─┬─┬─┬─┬─┐
    // row 0    │B│F│H│♥│R│ │ │ │ │ │  narrow/default: one-cell bitmap stride
    //          ├─┼─┼─┼─┼─┼─┼─┼─┼─┼─┤
    // row 1    │B  │F  │H  │♥  │R  │  width=2: same glyphs, two-cell bitmaps
    //          ├─┼─┼─┼─┼─┼─┼─┼─┼─┼─┤
    // row 2    │  B│  F│  H│  ♥│  R│  width=2 + horizontal center alignment
    //          ├─┼─┼─┼─┼─┼─┼─┼─┼─┼─┤
    // row 3    │B  │F  │H  │♥  │R  │  advance_width=2000: wider design box
    //          └─┴─┴─┴─┴─┴─┴─┴─┴─┴─┘
    // ```
    //
    // The faint grid lines in the PNG are these cell boundaries. Rows 2 and 3
    // are the design-metric/placement regression checks: row 2 centers a
    // one-cell-wide design box inside two cells, while row 3 centers a two-cell
    // design box so the visible glyph returns to the start of each span.
    const cell_width = 20;
    const cell_height = 20;
    const columns = test_glyf_payloads.len;
    const narrow_stride_x = cell_width;
    const wide_stride_x = cell_width * 2;
    const row_count = 4;

    var atlas = try z2d.Surface.init(
        .image_surface_alpha8,
        alloc,
        @intCast(wide_stride_x * columns),
        cell_height * row_count,
    );
    defer atlas.deinit(alloc);

    for (test_glyf_payloads, 0..) |payload, i| {
        var outline = try decodeGlyfPayload(alloc, payload);
        defer outline.deinit(alloc);

        var narrow = try glyf_rasterize.rasterize(alloc, outline, .{
            .units_per_em = 1000,
            .advance_width = 1000,
            .line_height = 1000,
        }, .{
            .grid_metrics = testMetrics(cell_width, cell_height),
        });
        defer narrow.deinit(alloc);
        blitBitmap(&atlas, narrow, i * narrow_stride_x, 0);

        var wide = try glyf_rasterize.rasterize(alloc, outline, .{
            .units_per_em = 1000,
            .advance_width = 1000,
            .line_height = 1000,
        }, .{
            .grid_metrics = testMetrics(cell_width, cell_height),
            .cell_width = 2,
        });
        defer wide.deinit(alloc);
        blitBitmap(&atlas, wide, i * wide_stride_x, cell_height);

        var centered = try glyf_rasterize.rasterize(alloc, outline, .{
            .units_per_em = 1000,
            .advance_width = 1000,
            .line_height = 1000,
        }, .{
            .grid_metrics = testMetrics(cell_width, cell_height),
            .cell_width = 2,
            .constraint_width = 2,
            .constraint = .{ .align_horizontal = .center },
        });
        defer centered.deinit(alloc);
        blitBitmap(&atlas, centered, i * wide_stride_x, cell_height * 2);

        var designed_wide = try glyf_rasterize.rasterize(alloc, outline, .{
            .units_per_em = 1000,
            .advance_width = 2000,
            .line_height = 1000,
        }, .{
            .grid_metrics = testMetrics(cell_width, cell_height),
            .cell_width = 2,
            .constraint_width = 2,
            .constraint = .{ .align_horizontal = .center },
        });
        defer designed_wide.deinit(alloc);
        blitBitmap(&atlas, designed_wide, i * wide_stride_x, cell_height * 3);
    }

    for (0..row_count) |row| drawCellBoxes(&atlas, row * cell_height, cell_width, cell_height);

    var dir = testing.tmpDir(.{});
    defer dir.cleanup();
    const tmp_dir = try dir.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(tmp_dir);

    const generated_path = try std.fmt.allocPrint(alloc, "{s}/glyf_rasterize.png", .{tmp_dir});
    defer alloc.free(generated_path);
    try z2d.png_exporter.writeToPNGFile(testing.io, atlas, generated_path, .{});

    try testing.expect(!try diffAtlas(testing.io, alloc, &atlas, generated_path));
}
