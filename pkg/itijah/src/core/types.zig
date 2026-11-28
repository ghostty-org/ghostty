const std = @import("std");
const level = @import("level.zig");
const Allocator = std.mem.Allocator;

pub const BidiLevel = level.BidiLevel;

pub const ParDirection = enum {
    ltr,
    rtl,
    auto_ltr,
    auto_rtl,

    pub fn toLevel(self: ParDirection) BidiLevel {
        return switch (self) {
            .ltr, .auto_ltr => level.ltr_level,
            .rtl, .auto_rtl => level.rtl_level,
        };
    }

    pub fn isAuto(self: ParDirection) bool {
        return self == .auto_ltr or self == .auto_rtl;
    }
};

pub const ReorderFlags = struct {
    reorder_nsm: bool = false, // L3 (Phase 2)
};

pub const ShapeFlags = struct {
    mirror: bool = false, // L4
    arab_pres: bool = false,
    arab_liga: bool = false,
    arab_console: bool = false,
};

pub const EmbeddingResult = struct {
    levels: []BidiLevel,
    resolved_par_dir: ParDirection,

    pub fn deinit(self: *EmbeddingResult, allocator: Allocator) void {
        allocator.free(self.levels);
        self.* = undefined;
    }
};

pub const EmbeddingScratchView = struct {
    // Slice is owned by the scratch object passed to getParEmbeddingLevelsScratchView.
    // It remains valid until the next mutation of that scratch.
    levels: []const BidiLevel,
    resolved_par_dir: ParDirection,
};

pub const ReorderResult = struct {
    visual: []u21,
    l_to_v: []u32,
    v_to_l: []u32,
    max_level: BidiLevel,

    pub fn deinit(self: *ReorderResult, allocator: Allocator) void {
        allocator.free(self.visual);
        allocator.free(self.l_to_v);
        allocator.free(self.v_to_l);
        self.* = undefined;
    }
};

pub const ReorderResultScratchView = struct {
    // Slices are owned by the scratch object passed to reorderLineScratch.
    // They remain valid until the next mutation of that scratch.
    visual: []const u21,
    l_to_v: []const u32,
    v_to_l: []const u32,
    max_level: BidiLevel,
};

pub const VisualRun = struct {
    // Start index in visual order for this run.
    visual_start: u32,
    // Start index in logical order for a contiguous logical slice.
    logical_start: u32,
    // Number of codepoints in this run.
    len: u32,
    // Run direction for shaping/layout.
    is_rtl: bool,

    pub fn visualEnd(self: VisualRun) u32 {
        return self.visual_start + self.len;
    }

    pub fn logicalEnd(self: VisualRun) u32 {
        return self.logical_start + self.len;
    }

    pub fn logicalIndexForVisual(self: VisualRun, visual_index: u32) u32 {
        std.debug.assert(visual_index >= self.visual_start and visual_index < self.visualEnd());
        const offset = visual_index - self.visual_start;
        return if (self.is_rtl) self.logical_start + (self.len - 1 - offset) else self.logical_start + offset;
    }

    pub fn visualIndexForLogical(self: VisualRun, logical_index: u32) u32 {
        std.debug.assert(logical_index >= self.logical_start and logical_index < self.logicalEnd());
        const offset = logical_index - self.logical_start;
        return if (self.is_rtl) self.visual_start + (self.len - 1 - offset) else self.visual_start + offset;
    }

    pub fn logicalRangeForVisualSlice(
        self: VisualRun,
        visual_start: u32,
        visual_end: u32,
    ) LogicalRange {
        std.debug.assert(visual_start >= self.visual_start);
        std.debug.assert(visual_end <= self.visualEnd());
        std.debug.assert(visual_start <= visual_end);
        if (visual_start == visual_end) {
            const cursor_logical = if (visual_start == self.visualEnd())
                self.logicalEnd()
            else
                self.logicalIndexForVisual(visual_start);
            return .{ .start = cursor_logical, .end = cursor_logical };
        }

        return if (!self.is_rtl)
            .{
                .start = self.logicalIndexForVisual(visual_start),
                .end = self.logicalIndexForVisual(visual_end - 1) + 1,
            }
        else
            .{
                .start = self.logicalIndexForVisual(visual_end - 1),
                .end = self.logicalIndexForVisual(visual_start) + 1,
            };
    }

    pub fn clusterForLogical(self: VisualRun, logical_index: u32) u32 {
        return self.visualIndexForLogical(logical_index) - self.visual_start;
    }
};

pub const RemoveBidiMarksResult = struct {
    result: []u21,
    new_len: u32,
};

pub const LogicalRange = struct {
    start: u32,
    end: u32,
};

pub fn logicalIndexForVisual(run: VisualRun, visual_index: u32) u32 {
    return run.logicalIndexForVisual(visual_index);
}

pub fn visualIndexForLogical(run: VisualRun, logical_index: u32) u32 {
    return run.visualIndexForLogical(logical_index);
}

pub fn logicalRangeForVisualSlice(
    run: VisualRun,
    visual_start: u32,
    visual_end: u32,
) LogicalRange {
    return run.logicalRangeForVisualSlice(visual_start, visual_end);
}

pub fn clusterForLogical(run: VisualRun, logical_index: u32) u32 {
    return run.clusterForLogical(logical_index);
}

pub const VisualLayout = struct {
    levels: []BidiLevel,
    runs: []VisualRun,
    l_to_v: []u32,
    v_to_l: []u32,
    base_level: BidiLevel,

    pub fn deinit(self: *VisualLayout, allocator: Allocator) void {
        allocator.free(self.levels);
        allocator.free(self.runs);
        allocator.free(self.l_to_v);
        allocator.free(self.v_to_l);
        self.* = undefined;
    }
};

pub const VisualLayoutScratchView = struct {
    // Slices are owned by the scratch object passed to resolveVisualLayoutScratch.
    // They remain valid until the next mutation of that scratch.
    levels: []const BidiLevel,
    runs: []const VisualRun,
    l_to_v: []const u32,
    v_to_l: []const u32,
    base_level: BidiLevel,
};

pub const LayoutOptions = struct {
    base_dir: ParDirection = .ltr,
};
