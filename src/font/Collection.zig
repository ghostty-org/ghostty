//! A font collection is a list of faces of different styles. The list is
//! ordered by priority (per style). All fonts in a collection share the same
//! size so they can be used interchangeably in cases a glyph is missing in one
//! and present in another.
//!
//! The purpose of a collection is to store a list of fonts by style
//! and priority order. A collection does not handle searching for font
//! callbacks, rasterization, etc. For this, see CodepointResolver.
//!
//! The collection can contain both loaded and deferred faces. Deferred faces
//! typically use less memory while still providing some necessary information
//! such as codepoint support, presentation, etc. This is useful for looking
//! for fallback fonts as efficiently as possible. For example, when the glyph
//! "X" is not found, we can quickly search through deferred fonts rather
//! than loading the font completely.
const Collection = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const config = @import("../config.zig");
const font = @import("main.zig");
const options = font.options;
const DeferredFace = font.DeferredFace;
const DesiredSize = font.face.DesiredSize;
const Face = font.Face;
const Library = font.Library;
const Metrics = font.Metrics;
const Presentation = font.Presentation;
const Style = font.Style;

const log = std.log.scoped(.font_collection);

/// The available faces we have. This shouldn't be modified manually.
/// Instead, use the functions available on Collection.
faces: StyleArray,

/// The metric modifiers to use for this collection. The memory
/// for this is owned by the user and is not freed by the collection.
///
/// Call `Collection.updateMetrics` to recompute the
/// collection's metrics after making changes to these.
metric_modifiers: Metrics.ModifierSet = .{},

/// Metrics for this collection. Call `Collection.updateMetrics` to (re)compute
/// these after adding a primary font or making changes to `metric_modifiers`.
metrics: ?Metrics = null,

/// The load options for deferred faces in the face list. If this
/// is not set, then deferred faces will not be loaded. Attempting to
/// add a deferred face will result in an error.
load_options: ?LoadOptions = null,

/// Initialize an empty collection.
pub fn init() Collection {
    // Initialize our styles array, preallocating some space that is
    // likely to be used.
    return .{ .faces = .initFill(.{}) };
}

pub fn deinit(self: *Collection, alloc: Allocator) void {
    var it = self.faces.iterator();
    while (it.next()) |array| {
        var entry_it = array.value.iterator(0);
        while (entry_it.next()) |entry_or_alias| {
            if (entry_or_alias.unwrapNoAlias()) |entry| entry.deinit();
        }
        array.value.deinit(alloc);
    }

    if (self.load_options) |*v| v.deinit(alloc);
}

pub const AddError =
    Allocator.Error ||
    AdjustSizeError ||
    error{
        CollectionFull,
        DeferredLoadingUnavailable,
        SetSizeFailed,
    };

/// Add a face to the collection for the given style. This face will be added
/// next in priority if others exist already, i.e. it'll be the _last_ to be
/// searched for a glyph in that list.
///
/// If no error is encountered then the collection takes ownership of the face,
/// in which case face will be deallocated when the collection is deallocated.
///
/// If a loaded face is added to the collection, its size will be changed to
/// match the size specified in load_options, adjusted for harmonization with
/// the primary face.
pub fn add(
    self: *Collection,
    alloc: Allocator,
    style: Style,
    face: Entry,
) AddError!Index {
    const list = self.faces.getPtr(style);

    // We have some special indexes so we must never pass those.
    const idx = list.count();
    if (idx >= Index.Special.start - 1)
        return error.CollectionFull;

    // If this is deferred and we don't have load options, we can't.
    if (face.isDeferred() and self.load_options == null)
        return error.DeferredLoadingUnavailable;

    try list.append(alloc, .{ .entry = face });

    const owned: *Entry = list.at(idx).unwrapNoAlias().?;

    // If we have load options, we update the size to ensure it's matches and is
    // normalized to the primary if possible. If the face is not loaded, this is
    // a no-op and sizing/scaling will happen whenever we do load it.
    if (self.load_options) |opts| {
        const primary_entry = self.getEntry(.{ .idx = 0 }) catch null;
        try owned.setSize(opts.faceOptions(), primary_entry);
    }

    return .{ .style = style, .idx = @intCast(idx) };
}

/// Return the Face represented by a given Index. The returned pointer
/// is only valid as long as this collection is not modified.
///
/// This will initialize the face if it is deferred and not yet loaded,
/// which can fail.
pub fn getFace(self: *Collection, index: Index) !*Face {
    return try self.getFaceFromEntry(try self.getEntry(index));
}

/// Get the unaliased entry from an index
pub fn getEntry(self: *Collection, index: Index) !*Entry {
    if (index.special() != null) return error.SpecialHasNoFace;
    const list = self.faces.getPtr(index.style);
    return list.at(index.idx).unwrap();
}

/// Get the face from an entry.
///
/// This entry must not be an alias.
fn getFaceFromEntry(
    self: *Collection,
    entry: *Entry,
) !*Face {
    return switch (entry.face) {
        inline .deferred, .fallback_deferred => |*d, tag| deferred: {
            const opts = self.load_options orelse
                return error.DeferredLoadingUnavailable;
            const face_opts = opts.faceOptions();
            const face = try d.load(opts.library, face_opts);
            d.deinit();

            entry.face = switch (tag) {
                .deferred => .{ .loaded = face },
                .fallback_deferred => .{ .fallback_loaded = face },
                else => unreachable,
            };

            // Adjust the size if we have access to the primary font for
            // scaling. Otherwise, nothing to do, calling setSize would
            // be redundant as the same face_opts were used when loading.
            if (self.getEntry(.{ .idx = 0 })) |primary_entry| {
                try entry.setSize(face_opts, primary_entry);
            } else |_| {}

            break :deferred switch (tag) {
                .deferred => &entry.face.loaded,
                .fallback_deferred => &entry.face.fallback_loaded,
                else => unreachable,
            };
        },

        .loaded, .fallback_loaded => |*f| f,
    };
}

/// Return the index of the font in this collection that contains
/// the given codepoint, style, and presentation. If no font is found,
/// null is returned.
///
/// This does not trigger font loading; deferred fonts can be
/// searched for codepoints.
pub fn getIndex(
    self: *const Collection,
    cp: u32,
    style: Style,
    p_mode: PresentationMode,
) ?Index {
    var i: usize = 0;
    var it = self.faces.get(style).constIterator(0);
    while (it.next()) |entry_or_alias| {
        if (entry_or_alias.unwrapConst().hasCodepoint(cp, p_mode)) {
            return .{
                .style = style,
                .idx = @intCast(i),
            };
        }

        i += 1;
    }

    // Not found
    return null;
}

/// Check if a specific font index has a specific codepoint. This does not
/// necessarily force the font to load. The presentation value "p" will
/// verify the Emoji representation matches if it is non-null. If "p" is
/// null then any presentation will be accepted.
pub fn hasCodepoint(
    self: *const Collection,
    index: Index,
    cp: u32,
    p_mode: PresentationMode,
) bool {
    const list = self.faces.get(index.style);
    if (index.idx >= list.count()) return false;
    return list.at(index.idx).unwrapConst().hasCodepoint(cp, p_mode);
}

pub const CompleteError = Allocator.Error || error{
    DefaultUnavailable,
};

/// Ensure we have an option for all styles in the collection, such
/// as italic and bold by synthesizing them if necessary from the
/// first regular face that has text glyphs.
///
/// If there is no regular face that has text glyphs, then this
/// does nothing.
pub fn completeStyles(
    self: *Collection,
    alloc: Allocator,
    synthetic_config: config.FontSyntheticStyle,
) CompleteError!void {
    // If every style has at least one entry then we're done!
    // This is the most common case.
    empty: {
        var it = self.faces.iterator();
        while (it.next()) |entry| {
            if (entry.value.count() == 0) break :empty;
        }

        return;
    }

    // Find the first regular face that has non-colorized text glyphs.
    // This is the font we want to fallback to. This may not be index zero
    // if a user configures something like an Emoji font first.
    const regular_entry: *Entry = entry: {
        const list = self.faces.getPtr(.regular);
        if (list.count() == 0) return;

        // Find our first regular face that has text glyphs.
        var it = list.iterator(0);
        while (it.next()) |entry_or_alias| {
            // Load our face. If we fail to load it, we just skip it and
            // continue on to try the next one.
            const entry = entry_or_alias.unwrap();
            const face = self.getFaceFromEntry(entry) catch |err| {
                log.warn("error loading regular entry={d} err={}", .{
                    it.index - 1,
                    err,
                });

                continue;
            };

            // We have two conditionals here. The color check is obvious:
            // we want to auto-italicize a normal text font. The second
            // check is less obvious... for mixed color/non-color fonts, we
            // accept the regular font if it has basic ASCII. This may not
            // be strictly correct (especially with international fonts) but
            // it's a reasonable heuristic and the first case will match 99%
            // of the time.
            if (!face.hasColor() or face.glyphIndex('A') != null) {
                break :entry entry;
            }
        }

        // No regular text face found. We can't provide any fallback.
        return error.DefaultUnavailable;
    };

    // If we don't have italic, attempt to create a synthetic italic face.
    // If we can't create a synthetic italic face, we'll just use the regular
    // face for italic.
    const italic_list = self.faces.getPtr(.italic);
    const have_italic = italic_list.count() > 0;
    if (!have_italic) italic: {
        if (!synthetic_config.italic) {
            log.info("italic style not available and synthetic italic disabled", .{});
            try italic_list.append(alloc, .{ .alias = regular_entry });
            break :italic;
        }

        const synthetic = self.syntheticItalic(regular_entry) catch |err| {
            log.warn("failed to create synthetic italic, italic style will not be available err={}", .{err});
            try italic_list.append(alloc, .{ .alias = regular_entry });
            break :italic;
        };

        const synthetic_entry = regular_entry.initCopy(.{ .loaded = synthetic });
        log.info("synthetic italic face created", .{});
        try italic_list.append(alloc, .{ .entry = synthetic_entry });
    }

    // If we don't have bold, use the regular font.
    const bold_list = self.faces.getPtr(.bold);
    const have_bold = bold_list.count() > 0;
    if (!have_bold) bold: {
        if (!synthetic_config.bold) {
            log.info("bold style not available and synthetic bold disabled", .{});
            try bold_list.append(alloc, .{ .alias = regular_entry });
            break :bold;
        }

        const synthetic = self.syntheticBold(regular_entry) catch |err| {
            log.warn("failed to create synthetic bold, bold style will not be available err={}", .{err});
            try bold_list.append(alloc, .{ .alias = regular_entry });
            break :bold;
        };

        const synthetic_entry = regular_entry.initCopy(.{ .loaded = synthetic });
        log.info("synthetic bold face created", .{});
        try bold_list.append(alloc, .{ .entry = synthetic_entry });
    }

    // If we don't have bold italic, we attempt to synthesize a bold variant
    // of the italic font. If we can't do that, we'll use the italic font.
    const bold_italic_list = self.faces.getPtr(.bold_italic);
    if (bold_italic_list.count() == 0) bold_italic: {
        if (!synthetic_config.@"bold-italic") {
            log.info("bold italic style not available and synthetic bold italic disabled", .{});
            try bold_italic_list.append(alloc, .{ .alias = regular_entry });
            break :bold_italic;
        }

        // Prefer to synthesize on top of the face we already had. If we
        // have bold then we try to synthesize italic on top of bold.
        if (have_bold) {
            const base_entry: *Entry = bold_list.at(0).unwrap();
            if (self.syntheticItalic(base_entry)) |synthetic| {
                log.info("synthetic bold italic face created from bold", .{});
                const synthetic_entry = base_entry.initCopy(.{ .loaded = synthetic });
                try bold_italic_list.append(alloc, .{ .entry = synthetic_entry });
                break :bold_italic;
            } else |_| {}

            // If synthesizing italic failed, then we try to synthesize
            // bold on whatever italic font we have.
        }

        const base_entry: *Entry = italic_list.at(0).unwrap();
        if (self.syntheticBold(base_entry)) |synthetic| {
            log.info("synthetic bold italic face created from italic", .{});
            const synthetic_entry = base_entry.initCopy(.{ .loaded = synthetic });
            try bold_italic_list.append(alloc, .{ .entry = synthetic_entry });
            break :bold_italic;
        } else |_| {}

        log.warn("bold italic style not available, using italic font", .{});
        try bold_italic_list.append(alloc, .{ .alias = base_entry });
    }
}

// Create a synthetic bold font face from the given entry and return it.
fn syntheticBold(self: *Collection, entry: *Entry) !Face {
    // Not all font backends support synthetic bold.
    if (comptime !@hasDecl(Face, "syntheticBold")) return error.SyntheticBoldUnavailable;

    // We require loading options to create a synthetic bold face.
    const opts = self.load_options orelse return error.DeferredLoadingUnavailable;

    // Try to bold it.
    const regular = try self.getFaceFromEntry(entry);

    // Inherit size from regular; it may be different than opts.size
    // due to scaling adjustments
    var face_opts = opts.faceOptions();
    face_opts.size = regular.size;
    const face = try regular.syntheticBold(opts.faceOptions());

    var buf: [256]u8 = undefined;
    if (face.name(&buf)) |name| {
        log.info("font synthetic bold created family={s}", .{name});
    } else |_| {}

    return face;
}

// Create a synthetic italic font face from the given entry and return it.
fn syntheticItalic(self: *Collection, entry: *Entry) !Face {
    // Not all font backends support synthetic italicization.
    if (comptime !@hasDecl(Face, "syntheticItalic")) return error.SyntheticItalicUnavailable;

    // We require loading options to create a synthetic italic face.
    const opts = self.load_options orelse return error.DeferredLoadingUnavailable;

    // Try to italicize it.
    const regular = try self.getFaceFromEntry(entry);

    // Inherit size from regular; it may be different than opts.size
    // due to scaling adjustments
    var face_opts = opts.faceOptions();
    face_opts.size = regular.size;
    const face = try regular.syntheticItalic(opts.faceOptions());

    var buf: [256]u8 = undefined;
    if (face.name(&buf)) |name| {
        log.info("font synthetic italic created family={s}", .{name});
    } else |_| {}

    return face;
}

/// Update the size of all faces in the collection. This will
/// also update the size in the load options for future deferred
/// face loading.
///
/// This requires load options to be set.
pub fn setSize(self: *Collection, size: DesiredSize) !void {
    // Get a pointer to our options so we can modify the size.
    const opts = if (self.load_options) |*v|
        v
    else
        return error.DeferredLoadingUnavailable;
    opts.size = size;
    const face_opts = opts.faceOptions();

    // Get the primary face if we can, for size normalization. No need
    // to jump through hoops to make sure this is resized first, as
    // Entry.setSize will get it right regardless. (That said, it's
    // likely the first iterate and hence resized first anyway.)
    const primary_entry = self.getEntry(.{ .idx = 0 }) catch null;

    // Resize all our faces that are loaded
    var it = self.faces.iterator();
    while (it.next()) |array| {
        var entry_it = array.value.iterator(0);
        while (entry_it.next()) |entry_or_alias| {
            if (entry_or_alias.unwrapNoAlias()) |entry| {
                try entry.setSize(face_opts, primary_entry);
            }
        }
    }

    try self.updateMetrics();
}

/// Update the scale reference metric associated with a face. This will
/// also rescale the face's size accordingly.
pub fn setScaleReference(self: *Collection, entry: *Entry, scale_reference: ReferenceMetric) !void {
    entry.scale_reference = scale_reference;
    if (self.load_options) |opts| {
        const primary_entry = self.getEntry(.{ .idx = 0 }) catch null;
        try entry.setSize(opts.faceOptions(), primary_entry);
    }
}

const UpdateMetricsError = font.Face.GetMetricsError || error{
    CannotLoadPrimaryFont,
};

/// Update the cell metrics for this collection, based on
/// the primary font and the modifiers in `metric_modifiers`.
///
/// This requires a primary font (index `0`) to be present.
pub fn updateMetrics(self: *Collection) UpdateMetricsError!void {
    const primary_face = self.getFace(.{ .idx = 0 }) catch return error.CannotLoadPrimaryFont;

    const face_metrics = try primary_face.getMetrics();

    var metrics = Metrics.calc(face_metrics);

    metrics.apply(self.metric_modifiers);

    self.metrics = metrics;
}

/// Packed array of all Style enum cases mapped to a growable list of faces.
///
/// We use this data structure because there aren't many styles and all
/// styles are typically loaded for a terminal session. The overhead per
/// style even if it is not used or barely used is minimal given the
/// small style count.
///
/// We use a segmented list because the entry values must be pointer-stable
/// to support the "alias" field in Entry.
///
/// WARNING: We cannot use any prealloc yet for the segmented list because
/// the collection is copied around by value and pointers aren't stable.
const StyleArray = std.EnumArray(Style, std.SegmentedList(EntryOrAlias, 0));

/// Load options are used to configure all the details a Collection
/// needs to load deferred faces.
pub const LoadOptions = struct {
    /// The library to use for loading faces. This is not owned by
    /// the collection and can be used by multiple collections. When
    /// deinitializing the collection, the library is not deinitialized.
    library: Library,

    /// The desired font size for all loaded faces.
    size: DesiredSize = .{ .points = 12 },

    /// Freetype Load Flags to use when loading glyphs. This is a list of
    /// bitfield constants that controls operations to perform during glyph
    /// loading. Only a subset is exposed for configuration, for the whole set
    /// of flags see `pkg.freetype.face.LoadFlags`.
    freetype_load_flags: font.face.FreetypeLoadFlags = font.face.freetype_load_flags_default,

    pub fn deinit(self: *LoadOptions, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }

    /// The options to use for loading faces.
    pub fn faceOptions(self: *const LoadOptions) font.face.Options {
        return .{
            .size = self.size,
            .freetype_load_flags = self.freetype_load_flags,
        };
    }
};

/// A entry in a collection can be deferred or loaded. A deferred face
/// is not yet fully loaded and only represents the font descriptor
/// and usually uses less resources. A loaded face is fully parsed,
/// ready to rasterize, and usually uses more resources than a
/// deferred version.
///
/// A face can also be a "fallback" variant that is still either
/// deferred or loaded. Today, there is only one difference between
/// fallback and non-fallback (or "explicit") faces: the handling
/// of emoji presentation.
///
/// For explicit faces, when an explicit emoji presentation is
/// not requested, we will use any glyph for that codepoint found
/// even if the font presentation does not match the UCD
/// (Unicode Character Database) value. When an explicit presentation
/// is requested (via either VS15/V16), that is always honored.
/// The reason we do this is because we assume that if a user
/// explicitly chosen a font face (hence it is "explicit" and
/// not "fallback"), they want to use any glyphs possible within that
/// font face. Fallback fonts on the other hand are picked as a
/// last resort, so we should prefer exactness if possible.
pub const Entry = struct {
    const AnyFace = union(enum) {
        deferred: DeferredFace, // Not loaded
        loaded: Face, // Loaded, explicit use

        // The same as deferred/loaded but fallback font semantics (see large
        // comment above Entry).
        fallback_deferred: DeferredFace,
        fallback_loaded: Face,
    };

    face: AnyFace,

    // Metric by which to normalize the font's size to the primary font.
    // Default to ic_width to ensure appropriate normalization of CJK
    // font sizes when mixed with latin fonts. See scaleFactor()
    // implementation for fallback rules when the font does not define
    // the specified metric.
    //
    // NOTE: In the future, if additional modifiers are needed for the
    // translation of global collection options to individual font
    // options, this should be promoted to a new FontModifiers type.
    scale_reference: ReferenceMetric = .ic_width,

    /// Convenience initializer so that users won't have to write nested
    /// expressions depending on internals, like .{ .face = .{ .loaded = face } }
    pub fn init(face: AnyFace) Entry {
        return .{ .face = face };
    }

    /// Convenience initializer that also takes a scale reference
    pub fn initWithScaleReference(face: AnyFace, scale_reference: ReferenceMetric) Entry {
        return .{ .face = face, .scale_reference = scale_reference };
    }

    /// Initialize a new entry with the same scale reference as an existing entry
    pub fn initCopy(self: Entry, face: AnyFace) Entry {
        return .{ .face = face, .scale_reference = self.scale_reference };
    }

    pub fn deinit(self: *Entry) void {
        switch (self.face) {
            inline .deferred,
            .loaded,
            .fallback_deferred,
            .fallback_loaded,
            => |*v| v.deinit(),
        }
    }

    /// If this face is loaded, then this returns the `Face`,
    /// otherwise returns null.
    pub fn getLoaded(self: *Entry) ?*Face {
        return switch (self.face) {
            .deferred, .fallback_deferred => null,
            .loaded, .fallback_loaded => |*face| face,
        };
    }

    /// True if the entry is deferred.
    fn isDeferred(self: Entry) bool {
        return switch (self.face) {
            .deferred, .fallback_deferred => true,
            .loaded, .fallback_loaded => false,
        };
    }

    /// True if this face satisfies the given codepoint and presentation.
    pub fn hasCodepoint(
        self: Entry,
        cp: u32,
        p_mode: PresentationMode,
    ) bool {
        return switch (self.face) {
            // Non-fallback fonts require explicit presentation matching but
            // otherwise don't care about presentation
            .deferred => |v| switch (p_mode) {
                .explicit => |p| v.hasCodepoint(cp, p),
                .default, .any => v.hasCodepoint(cp, null),
            },

            .loaded => |face| switch (p_mode) {
                .explicit => |p| explicit: {
                    const index = face.glyphIndex(cp) orelse break :explicit false;
                    break :explicit switch (p) {
                        .text => !face.isColorGlyph(index),
                        .emoji => face.isColorGlyph(index),
                    };
                },
                .default, .any => face.glyphIndex(cp) != null,
            },

            // Fallback fonts require exact presentation matching.
            .fallback_deferred => |v| switch (p_mode) {
                .explicit, .default => |p| v.hasCodepoint(cp, p),
                .any => v.hasCodepoint(cp, null),
            },

            .fallback_loaded => |face| switch (p_mode) {
                .explicit,
                .default,
                => |p| explicit: {
                    const index = face.glyphIndex(cp) orelse break :explicit false;
                    break :explicit switch (p) {
                        .text => !face.isColorGlyph(index),
                        .emoji => face.isColorGlyph(index),
                    };
                },
                .any => face.glyphIndex(cp) != null,
            },
        };
    }

    // Set the size of the face, rescaling to match the primary if given
    pub fn setSize(self: *Entry, opts: font.face.Options, primary_entry: ?*Entry) !void {
        // If not loaded, nothing to do
        var face = self.getLoaded() orelse return;

        var modified_opts = opts;

        // If we have a primary we rescale
        if (primary_entry) |p| {
            modified_opts.size = try self.scaledSize(modified_opts.size, p);
        }

        // Before going through with the resize, we check whether the requested
        // size after scaling is actually different from the existing size.
        if (!std.meta.eql(modified_opts.size, face.size)) {
            face.setSize(modified_opts) catch return error.SetSizeFailed;
        }
    }

    // Calculate a size for the face that will match it with the primary font,
    // metrically, to improve consistency with fallback fonts.
    //
    // This returns a scaled copy of the nominal_size, where the points size has
    // been scaled by the font metric ratio specified by self.scale_reference.
    // If either this or the primary face are not yet loaded, or the primary
    // face is the same as this, nominal_size is returned unchanged.
    //
    // This is very much like the `font-size-adjust` CSS property in how it works.
    // ref: https://developer.mozilla.org/en-US/docs/Web/CSS/font-size-adjust
    //
    // TODO: In the future, provide config options that allow the user to select
    //       which metric should be matched for fallback fonts, instead of hard
    //       coding at the point where a face is added to the collection.
    pub fn scaledSize(self: *Entry, nominal_size: DesiredSize, primary_entry: *Entry) !DesiredSize {
        // If the scale reference is the em size, no scaling
        if (self.scale_reference == .em_size) return nominal_size;

        // If the primary is us, no scaling
        if (@intFromPtr(self) == @intFromPtr(primary_entry)) return nominal_size;

        // If we or the primary face aren't loaded, we don't know our metrics,
        // so unable to scale
        const primary_face = primary_entry.getLoaded() orelse return nominal_size;
        const face = self.getLoaded() orelse return nominal_size;

        const primary_metrics = try primary_face.getMetrics();
        const face_metrics = try face.getMetrics();

        // The face metrics are in pixel units, and both point sizes and dpis
        // may differ. The following factors are used to convert ratios of face
        // metrics to scaling factors that are size- and dpi-independent and can
        // be used to scale point sizes directly.
        const primary_y_px_per_72em = primary_face.size.points * @as(f32, @floatFromInt(primary_face.size.ydpi));
        const primary_x_px_per_72em = primary_face.size.points * @as(f32, @floatFromInt(primary_face.size.xdpi));

        const face_y_px_per_72em = face.size.points * @as(f32, @floatFromInt(face.size.ydpi));
        const face_x_px_per_72em = face.size.points * @as(f32, @floatFromInt(face.size.xdpi));

        const y_ratio: f64 = face_y_px_per_72em / primary_y_px_per_72em;
        const x_ratio: f64 = face_x_px_per_72em / primary_x_px_per_72em;

        // The preferred metric to normalize by is self.scale_reference,
        // however we don't want to use a metric not explicitly defined
        // in `self`, so if needed we fall back through other metrics in
        // the order shown in the switch statement below. If the metric
        // is not defined in `primary`, that's OK, we'll use the estimate.
        const line_height_ratio = y_ratio * primary_metrics.lineHeight() / face_metrics.lineHeight();
        const scale = normalize_by: switch (self.scale_reference) {
            // Even if a metric is non-null, it may be invalid (e.g., negative),
            // so we check for equality with the estimator before using it
            .ic_width => {
                if (face_metrics.ic_width) |value| if (value == face_metrics.icWidth()) {
                    break :normalize_by x_ratio * (primary_metrics.icWidth() / value);
                };
                continue :normalize_by .ex_height;
            },
            .ex_height => {
                if (face_metrics.ex_height) |value| if (value == face_metrics.exHeight()) {
                    break :normalize_by y_ratio * primary_metrics.exHeight() / value;
                };
                continue :normalize_by .cap_height;
            },
            .cap_height => {
                if (face_metrics.cap_height) |value| if (value == face_metrics.capHeight()) {
                    break :normalize_by y_ratio * primary_metrics.capHeight() / value;
                };
                continue :normalize_by .line_height;
            },
            .line_height => line_height_ratio,
            .em_size => unreachable,
        };

        // If the line height of the scaled font would be larger than
        // the line height of the primary font, we don't want that, so
        // we take the minimum between matching the reference metric
        // and keeping the line heights within some margin.
        //
        // NOTE: We actually allow the line height to be up to 1.2
        //       times the primary line height because empirically
        //       this is usually fine and is better for CJK.
        const capped_scale = @min(scale, 1.2 * line_height_ratio);

        // Scale the target size by the final scaling factor and return.
        var scaled_size = nominal_size;
        scaled_size.points *= @floatCast(capped_scale);

        return scaled_size;
    }
};

pub const EntryOrAlias = union(enum) {
    entry: Entry,

    // An alias to another entry. This is used to share the same face,
    // avoid memory duplication. An alias must point to a non-alias entry.
    alias: *Entry,

    pub fn unwrap(self: *EntryOrAlias) *Entry {
        return switch (self.*) {
            .entry => |*v| v,
            .alias => |v| v,
        };
    }

    pub fn unwrapConst(self: *const EntryOrAlias) *const Entry {
        return switch (self.*) {
            .entry => |*v| v,
            .alias => |v| v,
        };
    }

    pub fn unwrapNoAlias(self: *EntryOrAlias) ?*Entry {
        return switch (self.*) {
            .entry => |*v| v,
            .alias => null,
        };
    }
};

pub const AdjustSizeError = font.Face.GetMetricsError;

pub const ReferenceMetric = enum {
    // The font's ideograph width
    ic_width,
    // The font's ex height
    ex_height,
    // The font's cap height
    cap_height,
    // The font's line height
    line_height,
    // The font's em size
    // Conventionally equivalent to line height, but the semantics
    // differ: using em_size directly sets the point sizes to the same
    // value, while using line_height calculates the scaling ratio for
    // matching line heights even if it differs from 1 em for one or
    // both fonts
    em_size,
};

/// The requested presentation for a codepoint.
pub const PresentationMode = union(enum) {
    /// The codepoint has an explicit presentation that is required,
    /// i.e. VS15/V16.
    explicit: Presentation,

    /// The codepoint has no explicit presentation and we should use
    /// the presentation from the UCD.
    default: Presentation,

    /// The codepoint can be any presentation.
    any: void,
};

/// This represents a specific font in the collection.
///
/// The backing size of this packed struct represents the total number
/// of possible usable fonts in a collection. And the number of bits
/// used for the index and not the style represents the total number
/// of possible usable fonts for a given style.
///
/// The goal is to keep the size of this struct as small as practical. We
/// accept the limitations that this imposes so long as they're reasonable.
/// At the time of writing this comment, this is a 16-bit struct with 13
/// bits used for the index, supporting up to 8192 fonts per style. This
/// seems more than reasonable. There are synthetic scenarios where this
/// could be a limitation but I can't think of any that are practical.
///
/// If you somehow need more fonts per style, you can increase the size of
/// the Backing type and everything should just work fine.
pub const Index = packed struct(Index.Backing) {
    const Backing = u16;
    const backing_bits = @typeInfo(Backing).int.bits;

    /// The number of bits we use for the index.
    const idx_bits = backing_bits - @typeInfo(@typeInfo(Style).@"enum".tag_type).int.bits;
    pub const IndexInt = @Type(.{ .int = .{ .signedness = .unsigned, .bits = idx_bits } });

    /// The special-case fonts that we support.
    pub const Special = enum(IndexInt) {
        // We start all special fonts at this index so they can be detected.
        pub const start = std.math.maxInt(IndexInt);

        /// Sprite drawing, this is rendered JIT using 2D graphics APIs.
        sprite = start,
    };

    style: Style = .regular,
    idx: IndexInt = 0,

    /// Initialize a special font index.
    pub fn initSpecial(v: Special) Index {
        return .{ .style = .regular, .idx = @intFromEnum(v) };
    }

    /// Convert to int
    pub fn int(self: Index) Backing {
        return @bitCast(self);
    }

    /// Returns true if this is a "special" index which doesn't map to
    /// a real font face. We can still render it but there is no face for
    /// this font.
    pub fn special(self: Index) ?Special {
        if (self.idx < Special.start) return null;
        return @enumFromInt(self.idx);
    }

    test {
        // We never want to take up more than a byte since font indexes are
        // everywhere so if we increase the size of this we'll dramatically
        // increase our memory usage.
        try std.testing.expectEqual(@sizeOf(Backing), @sizeOf(Index));

        // Just so we're aware when this changes. The current maximum number
        // of fonts for a style is 13 bits or 8192 fonts.
        try std.testing.expectEqual(13, idx_bits);
    }
};

test init {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c = init();
    defer c.deinit(alloc);
}

test "add full" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.regular;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var c = init();
    defer c.deinit(alloc);

    for (0..Index.Special.start - 1) |_| {
        _ = try c.add(alloc, .regular, .init(.{ .loaded = try .init(
            lib,
            testFont,
            .{ .size = .{ .points = 12 } },
        ) }));
    }

    var face = try Face.init(
        lib,
        testFont,
        .{ .size = .{ .points = 12 } },
    );
    // We have to deinit it manually since the
    // collection doesn't do it if adding fails.
    defer face.deinit();
    try testing.expectError(
        error.CollectionFull,
        c.add(alloc, .regular, .init(.{ .loaded = face })),
    );
}

test "add deferred without loading options" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c = init();
    defer c.deinit(alloc);

    try testing.expectError(error.DeferredLoadingUnavailable, c.add(
        alloc,
        .regular,

        // This can be undefined because it should never be accessed.
        .init(.{ .deferred = undefined }),
    ));
}

test getFace {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.regular;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var c = init();
    defer c.deinit(alloc);

    const idx = try c.add(alloc, .regular, .init(.{ .loaded = try .init(
        lib,
        testFont,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    ) }));

    {
        const face1 = try c.getFace(idx);
        const face2 = try c.getFace(idx);
        try testing.expectEqual(@intFromPtr(face1), @intFromPtr(face2));
    }
}

test getIndex {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.regular;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var c = init();
    defer c.deinit(alloc);

    _ = try c.add(alloc, .regular, .init(.{ .loaded = try .init(
        lib,
        testFont,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    ) }));

    // Should find all visible ASCII
    var i: u32 = 32;
    while (i < 127) : (i += 1) {
        const idx = c.getIndex(i, .regular, .{ .any = {} });
        try testing.expect(idx != null);
    }

    // Should not find emoji
    {
        const idx = c.getIndex('🥸', .regular, .{ .any = {} });
        try testing.expect(idx == null);
    }
}

test completeStyles {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.regular;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var c = init();
    defer c.deinit(alloc);
    c.load_options = .{ .library = lib };

    _ = try c.add(alloc, .regular, .init(.{ .loaded = try .init(
        lib,
        testFont,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    ) }));

    try testing.expect(c.getIndex('A', .bold, .{ .any = {} }) == null);
    try testing.expect(c.getIndex('A', .italic, .{ .any = {} }) == null);
    try testing.expect(c.getIndex('A', .bold_italic, .{ .any = {} }) == null);
    try c.completeStyles(alloc, .{});
    try testing.expect(c.getIndex('A', .bold, .{ .any = {} }) != null);
    try testing.expect(c.getIndex('A', .italic, .{ .any = {} }) != null);
    try testing.expect(c.getIndex('A', .bold_italic, .{ .any = {} }) != null);
}

test setSize {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.regular;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var c = init();
    defer c.deinit(alloc);
    c.load_options = .{ .library = lib };

    _ = try c.add(alloc, .regular, .init(.{ .loaded = try .init(
        lib,
        testFont,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    ) }));

    try testing.expectEqual(@as(u32, 12), c.load_options.?.size.points);
    try c.setSize(.{ .points = 24 });
    try testing.expectEqual(@as(u32, 24), c.load_options.?.size.points);
}

test hasCodepoint {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.regular;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var c = init();
    defer c.deinit(alloc);
    c.load_options = .{ .library = lib };

    const idx = try c.add(alloc, .regular, .init(.{ .loaded = try .init(
        lib,
        testFont,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    ) }));

    try testing.expect(c.hasCodepoint(idx, 'A', .{ .any = {} }));
    try testing.expect(!c.hasCodepoint(idx, '🥸', .{ .any = {} }));
}

test "hasCodepoint emoji default graphical" {
    if (options.backend != .fontconfig_freetype) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const testEmoji = font.embedded.emoji;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var c = init();
    defer c.deinit(alloc);
    c.load_options = .{ .library = lib };

    const idx = try c.add(alloc, .regular, .init(.{ .loaded = try .init(
        lib,
        testEmoji,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    ) }));

    try testing.expect(!c.hasCodepoint(idx, 'A', .{ .any = {} }));
    try testing.expect(c.hasCodepoint(idx, '🥸', .{ .any = {} }));
    // TODO(fontmem): test explicit/implicit
}

test "metrics" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.inconsolata;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var c = init();
    defer c.deinit(alloc);
    const size: DesiredSize = .{ .points = 12, .xdpi = 96, .ydpi = 96 };
    c.load_options = .{ .library = lib, .size = size };

    _ = try c.add(alloc, .regular, .init(.{ .loaded = try .init(
        lib,
        testFont,
        .{ .size = size },
    ) }));

    try c.updateMetrics();

    try std.testing.expectEqual(font.Metrics{
        .cell_width = 8,
        // The cell height is 17 px because the calculation is
        //
        //  ascender - descender + gap
        //
        // which, for inconsolata is
        //
        //  859 - -190 + 0
        //
        // font units, at 1000 units per em that works out to 1.049 em,
        // and 1em should be the point size * dpi scale, so 12 * (96/72)
        // which is 16, and 16 * 1.049 = 16.784, which finally is rounded
        // to 17.
        .cell_height = 17,
        .cell_baseline = 3,
        .underline_position = 17,
        .underline_thickness = 1,
        .strikethrough_position = 10,
        .strikethrough_thickness = 1,
        .overline_position = 0,
        .overline_thickness = 1,
        .box_thickness = 1,
        .cursor_height = 17,
        .icon_height = 11,
    }, c.metrics);

    // Resize should change metrics
    try c.setSize(.{ .points = 24, .xdpi = 96, .ydpi = 96 });
    try std.testing.expectEqual(font.Metrics{
        .cell_width = 16,
        .cell_height = 34,
        .cell_baseline = 6,
        .underline_position = 34,
        .underline_thickness = 2,
        .strikethrough_position = 19,
        .strikethrough_thickness = 2,
        .overline_position = 0,
        .overline_thickness = 2,
        .box_thickness = 2,
        .cursor_height = 34,
        .icon_height = 23,
    }, c.metrics);
}

// TODO: Also test CJK fallback sizing, we don't currently have a CJK test font.
test "adjusted sizes" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.inconsolata;
    const fallback = font.embedded.monaspace_neon;
    const symbol = font.embedded.symbols_nerd_font;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var c = init();
    defer c.deinit(alloc);
    const size: DesiredSize = .{ .points = 12, .xdpi = 96, .ydpi = 96 };
    c.load_options = .{ .library = lib, .size = size };

    // Add our primary face.
    _ = try c.add(alloc, .regular, .init(.{ .loaded = try .init(
        lib,
        testFont,
        .{ .size = size },
    ) }));

    try c.updateMetrics();

    // Add the fallback face.
    const fallback_idx = try c.add(alloc, .regular, .init(.{ .loaded = try .init(
        lib,
        fallback,
        .{ .size = size },
    ) }));

    inline for ([_][]const u8{ "ex_height", "cap_height" }) |metric| {
        try c.setScaleReference(try c.getEntry(fallback_idx), @field(ReferenceMetric, metric));

        // The chosen metric should match.
        {
            const primary_metrics = try (try c.getFace(.{ .idx = 0 })).getMetrics();
            const fallback_metrics = try (try c.getFace(fallback_idx)).getMetrics();

            try std.testing.expectApproxEqRel(
                @field(primary_metrics, metric).?,
                @field(fallback_metrics, metric).?,
                // We accept anything within 5 %.
                0.05,
            );
        }

        // Resize should keep that relationship.
        try c.setSize(.{ .points = 37, .xdpi = 96, .ydpi = 96 });
        {
            const primary_metrics = try (try c.getFace(.{ .idx = 0 })).getMetrics();
            const fallback_metrics = try (try c.getFace(fallback_idx)).getMetrics();

            try std.testing.expectApproxEqRel(
                @field(primary_metrics, metric).?,
                @field(fallback_metrics, metric).?,
                // We accept anything within 5 %.
                0.05,
            );
        }
        // Reset size for the next iteration
        try c.setSize(size);
    }

    // Add the symbol face.
    const symbol_idx = try c.add(alloc, .regular, .initWithScaleReference(.{ .loaded = try .init(
        lib,
        symbol,
        .{ .size = size },
    ) }, .ex_height));

    // Test fallback to lineHeight() (ex_height and cap_height not defined in symbols font).
    {
        const primary_metrics = try (try c.getFace(.{ .idx = 0 })).getMetrics();
        const symbol_metrics = try (try c.getFace(symbol_idx)).getMetrics();

        try std.testing.expectApproxEqRel(
            primary_metrics.lineHeight(),
            symbol_metrics.lineHeight(),
            // We accept anything within 5 %.
            0.05,
        );
    }

    // Test em_size giving exact font size equality
    try c.setScaleReference(try c.getEntry(symbol_idx), .em_size);

    try std.testing.expectEqual(
        (try c.getFace(.{ .idx = 0 })).size.points,
        (try c.getFace(symbol_idx)).size.points,
    );
}
