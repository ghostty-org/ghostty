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

/// The face metrics for the primary face in the collection.
///
/// We keep this around so we don't need to re-compute it when calculating
/// the scale factor for additional fonts added to the collection.
primary_face_metrics: ?Metrics.FaceMetrics = null,

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
        // Deinit all entries, aliases can be ignored.
        while (entry_it.next()) |entry_or_alias|
            switch (entry_or_alias.*) {
                .entry => |*entry| entry.deinit(),
                .alias => {},
            };
        array.value.deinit(alloc);
    }

    if (self.load_options) |*v| v.deinit(alloc);
}

/// Options for adding a face to the collection.
pub const AddOptions = struct {
    /// What style this face is.
    style: Style,
    /// What size adjustment to use.
    size_adjustment: SizeAdjustment,
    /// Whether this is a fallback face.
    fallback: bool,
};

pub const AddError =
    Allocator.Error ||
    error{
        /// There's no more room in the collection.
        CollectionFull,
        /// The call to `face.setSize` failed.
        SetSizeFailed,
    };

/// Add a face to the collection. This face will be added next in priority if
/// others exist already, i.e. it'll be the _last_ to be searched for a glyph
/// in that list.
///
/// If no error is encountered then the collection takes ownership of the face,
/// in which case face will be deallocated when the collection is deallocated.
///
/// When added, the size of the face will be adjusted to match `load_options`.
///
/// Returns the index for the added face.
pub fn add(
    self: *Collection,
    alloc: Allocator,
    face: Face,
    opts: AddOptions,
) AddError!Index {
    const list = self.faces.getPtr(opts.style);

    // We have some special indexes so we must never pass those.
    const idx = list.count();
    if (idx >= Index.Special.start - 1)
        return error.CollectionFull;

    var owned_face = face;

    // Scale factor to adjust the size of the added face.
    const scale_factor = self.scaleFactor(
        owned_face.getMetrics(),
        opts.size_adjustment,
    );

    // If we have load options, we update the size to ensure
    // it's matches and is normalized to the primary if possible.
    if (self.load_options) |load_opts| {
        var new_opts = load_opts;
        new_opts.size.points *= @floatCast(scale_factor);
        owned_face.setSize(new_opts.faceOptions()) catch return error.SetSizeFailed;
    }

    try list.append(alloc, .{
        .entry = .{
            .face = .{ .loaded = owned_face },
            .fallback = opts.fallback,
            .scale_factor = .{ .scale = scale_factor },
        },
    });

    return .{ .style = opts.style, .idx = @intCast(idx) };
}

pub const AddDeferredError =
    Allocator.Error ||
    error{
        /// There's no more room in the collection.
        CollectionFull,
        /// `load_options` is null, can't do deferred loading.
        DeferredLoadingUnavailable,
    };

/// Add a deferred face to the collection.
///
/// Returns the index for the added face.
pub fn addDeferred(
    self: *Collection,
    alloc: Allocator,
    face: DeferredFace,
    opts: AddOptions,
) AddDeferredError!Index {
    const list = self.faces.getPtr(opts.style);

    if (self.load_options == null) return error.DeferredLoadingUnavailable;

    // We have some special indexes so we must never pass those.
    const idx = list.count();
    if (idx >= Index.Special.start - 1)
        return error.CollectionFull;

    try list.append(alloc, .{
        .entry = .{
            .face = .{ .deferred = face },
            .fallback = opts.fallback,
            .scale_factor = .{ .adjustment = opts.size_adjustment },
        },
    });

    return .{ .style = opts.style, .idx = @intCast(idx) };
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
    if (index.idx >= list.len) return error.IndexOutOfBounds;
    return list.at(index.idx).getEntry();
}

/// Get the face from an entry.
///
/// This entry must not be an alias.
fn getFaceFromEntry(
    self: *Collection,
    entry: *Entry,
) !*Face {
    return switch (entry.face) {
        .deferred => |*d| deferred: {
            var opts = self.load_options orelse
                return error.DeferredLoadingUnavailable;

            // Load the face.
            var face = try d.load(opts.library, opts.faceOptions());
            errdefer face.deinit();

            // Calculate the scale factor for this
            // entry now that we have a loaded face.
            entry.scale_factor = .{
                .scale = self.scaleFactor(
                    face.getMetrics(),
                    entry.scale_factor.adjustment,
                ),
            };

            // If our scale factor is something other
            // than 1.0 then we need to resize the face.
            if (entry.scale_factor.scale != 1.0) {
                opts.size.points *= @floatCast(entry.scale_factor.scale);
                try face.setSize(opts.faceOptions());
            }

            // Deinit the deferred face now that we have
            // loaded it and are past any possible errors.
            errdefer comptime unreachable;
            d.deinit();

            // Set the loaded face on the entry.
            entry.face = .{ .loaded = face };

            // Return the pointer to it.
            break :deferred &entry.face.loaded;
        },

        .loaded => |*f| f,
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
        if (entry_or_alias.getConstEntry().hasCodepoint(cp, p_mode)) {
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
    return list.at(index.idx).getConstEntry().hasCodepoint(cp, p_mode);
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
            const entry = entry_or_alias.getEntry();
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

        const synthetic_entry: Entry = .{
            .face = .{ .loaded = synthetic },
            .fallback = false,
        };
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

        const synthetic_entry: Entry = .{
            .face = .{ .loaded = synthetic },
            .fallback = false,
        };
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
            const base_entry: *Entry = bold_list.at(0).getEntry();
            if (self.syntheticItalic(base_entry)) |synthetic| {
                log.info("synthetic bold italic face created from bold", .{});
                const synthetic_entry: Entry = .{
                    .face = .{ .loaded = synthetic },
                    .fallback = false,
                };
                try bold_italic_list.append(alloc, .{ .entry = synthetic_entry });
                break :bold_italic;
            } else |_| {}

            // If synthesizing italic failed, then we try to synthesize
            // bold on whatever italic font we have.
        }

        const base_entry: *Entry = italic_list.at(0).getEntry();
        if (self.syntheticBold(base_entry)) |synthetic| {
            log.info("synthetic bold italic face created from italic", .{});
            const synthetic_entry: Entry = .{
                .face = .{ .loaded = synthetic },
                .fallback = false,
            };
            try bold_italic_list.append(alloc, .{ .entry = synthetic_entry });
            break :bold_italic;
        } else |_| {}

        log.warn("bold italic style not available, using italic font", .{});
        try bold_italic_list.append(alloc, .{ .alias = base_entry });
    }
}

/// Create a synthetic bold font face from the given entry and return it.
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

/// Create a synthetic italic font face from the given entry and return it.
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

pub const SetSizeError =
    UpdateMetricsError ||
    error{
        /// `self.load_options` is `null`.
        DeferredLoadingUnavailable,
        /// The call to `face.setSize` failed.
        SetSizeFailed,
    };

/// Update the size of all faces in the collection. This will
/// also update the size in the load options for future deferred
/// face loading.
///
/// This requires load options to be set.
pub fn setSize(
    self: *Collection,
    size: DesiredSize,
) SetSizeError!void {
    // Get a pointer to our options so we can modify the size.
    const opts = &(self.load_options orelse return error.DeferredLoadingUnavailable);
    opts.size = size;

    const primary_entry = self.getEntry(.{ .idx = 0 }) catch null;

    // Resize all our faces that are loaded
    var it = self.faces.iterator();
    while (it.next()) |array| {
        var entry_it = array.value.iterator(0);
        // Resize all faces. We skip entries that are aliases, since
        // the underlying face will have a non-alias entry somewhere.
        while (entry_it.next()) |entry_or_alias| {
            if (entry_or_alias.* == .alias) continue;

            const entry = entry_or_alias.getEntry();

            if (entry.getLoaded()) |face| {
                // If this isn't our primary face, we scale
                // the size appropriately before setting it.
                //
                // If we don't have a primary face we also don't.
                var new_opts = opts.*;
                if (primary_entry != null and entry != primary_entry) {
                    new_opts.size.points *= @floatCast(entry.scale_factor.scale);
                }
                face.setSize(new_opts.faceOptions()) catch return error.SetSizeFailed;
            }
        }
    }

    try self.updateMetrics();
}

/// Options for adjusting the size of a face relative to the primary face.
pub const SizeAdjustment = enum {
    /// Don't adjust the size for this face, use the original point size.
    none,
    /// Match ideograph character width with the primary face.
    ic_width,
    /// Match ex height with the primary face.
    ex_height,
    /// Match cap height with the primary face.
    cap_height,
    /// Match line height with the primary face.
    line_height,
};

/// Calculate a factor by which to scale the provided face to match
/// it with the primary face, depending on the specified adjustment.
///
/// If this encounters any problems loading the primary face or its
/// metrics then it just returns `1.0`.
///
/// This functions very much like the `font-size-adjust` CSS property.
/// ref: https://developer.mozilla.org/en-US/docs/Web/CSS/font-size-adjust
fn scaleFactor(
    self: *Collection,
    face_metrics: Metrics.FaceMetrics,
    adjustment: SizeAdjustment,
) f64 {
    // If there's no adjustment, the scale is 1.0
    if (adjustment == .none) return 1.0;

    // If we haven't calculated our primary face metrics yet, do so now.
    if (self.primary_face_metrics == null) {
        @branchHint(.unlikely);
        // If we can't load the primary face, just use 1.0 as the scale factor.
        const primary_face = self.getFace(.{ .idx = 0 }) catch return 1.0;
        self.primary_face_metrics = primary_face.getMetrics();
    }

    const primary_metrics = self.primary_face_metrics.?;

    // We normalize the metrics values which are expressed in px to instead
    // be in ems, so that it doesn't matter what size the faces actually are.
    const primary_scale = 1 / primary_metrics.px_per_em;
    const face_scale = 1 / face_metrics.px_per_em;

    // We get the target metrics from the primary face and this face depending
    // on the specified `adjustment`. If this face doesn't explicitly define a
    // metric, or if the value it defines is invalid, we fall through to other
    // options in the order below.
    //
    // In order to make sure the value is valid, we compare it with the result
    // of the estimator function, which rules out both null and invalid values.
    const primary_metric: f64, const face_metric: f64 =
        normalize_by: switch (adjustment) {
            .ic_width => {
                if (face_metrics.ic_width != face_metrics.icWidth())
                    continue :normalize_by .ex_height;

                break :normalize_by .{
                    primary_metrics.icWidth() * primary_scale,
                    face_metrics.icWidth() * face_scale,
                };
            },

            .ex_height => {
                if (face_metrics.ex_height != face_metrics.exHeight())
                    continue :normalize_by .cap_height;

                break :normalize_by .{
                    primary_metrics.exHeight() * primary_scale,
                    face_metrics.exHeight() * face_scale,
                };
            },

            .cap_height => {
                if (face_metrics.cap_height != face_metrics.capHeight())
                    continue :normalize_by .line_height;

                break :normalize_by .{
                    primary_metrics.capHeight() * primary_scale,
                    face_metrics.capHeight() * face_scale,
                };
            },

            .line_height => .{
                primary_metrics.lineHeight() * primary_scale,
                face_metrics.lineHeight() * face_scale,
            },

            .none => unreachable,
        };

    return primary_metric / face_metric;
}

const UpdateMetricsError = error{
    CannotLoadPrimaryFont,
};

/// Update the cell metrics for this collection, based on
/// the primary font and the modifiers in `metric_modifiers`.
///
/// This requires a primary font (index `0`) to be present.
pub fn updateMetrics(self: *Collection) UpdateMetricsError!void {
    const primary_face = self.getFace(.{ .idx = 0 }) catch return error.CannotLoadPrimaryFont;

    self.primary_face_metrics = primary_face.getMetrics();

    var metrics = Metrics.calc(self.primary_face_metrics.?);

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
/// to support aliases.
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
        /// Not yet loaded.
        deferred: DeferredFace,

        /// Loaded.
        loaded: Face,
    };

    face: AnyFace,

    /// Whether this face is a fallback face, see
    /// main doc comment on Entry for more info.
    fallback: bool,

    /// Factor to multiply the collection size by for this face, or
    /// else the size adjustment that should be used to calculate
    /// once the face is loaded.
    ///
    /// This is computed when the face is loaded, based on a scale
    /// factor computed for an adjustment from the primary face to
    /// this one, which allows fallback fonts to be harmonized with
    /// the primary font by matching one of the metrics between them.
    scale_factor: union(enum) {
        adjustment: SizeAdjustment,
        scale: f64,
    } = .{ .scale = 1.0 },

    pub fn deinit(self: *Entry) void {
        switch (self.face) {
            inline .deferred, .loaded => |*v| v.deinit(),
        }
    }

    /// If this face is loaded, then this returns the `Face`,
    /// otherwise returns null.
    pub fn getLoaded(self: *Entry) ?*Face {
        return switch (self.face) {
            .deferred => null,
            .loaded => |*face| face,
        };
    }

    /// True if the entry is deferred.
    fn isDeferred(self: Entry) bool {
        return switch (self.face) {
            .deferred => true,
            .loaded => false,
        };
    }

    /// True if this face satisfies the given codepoint and presentation.
    pub fn hasCodepoint(
        self: Entry,
        cp: u32,
        p_mode: PresentationMode,
    ) bool {
        return mode: switch (p_mode) {
            .default => |p| if (self.fallback)
                // Fallback fonts require explicit presentation matching.
                continue :mode .{ .explicit = p }
            else
                // Non-fallback fonts do not.
                continue :mode .any,

            .explicit => |p| switch (self.face) {
                .deferred => |v| v.hasCodepoint(cp, p),

                .loaded => |face| explicit: {
                    const index = face.glyphIndex(cp) orelse break :explicit false;
                    break :explicit switch (p) {
                        .text => !face.isColorGlyph(index),
                        .emoji => face.isColorGlyph(index),
                    };
                },
            },

            .any => switch (self.face) {
                .deferred => |v| v.hasCodepoint(cp, null),

                .loaded => |face| face.glyphIndex(cp) != null,
            },
        };
    }
};

pub const EntryOrAlias = union(enum) {
    entry: Entry,

    /// An alias to another entry. This is used to share the same face,
    /// avoid memory duplication. An alias must point to a non-alias entry.
    alias: *Entry,

    /// Get a pointer to the underlying entry.
    pub fn getEntry(self: *EntryOrAlias) *Entry {
        return switch (self.*) {
            .entry => |*v| v,
            .alias => |v| v,
        };
    }

    /// Get a const pointer to the underlying entry.
    pub fn getConstEntry(self: *const EntryOrAlias) *const Entry {
        return switch (self.*) {
            .entry => |*v| v,
            .alias => |v| v,
        };
    }
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
    // This test is way too slow to run under Valgrind, unfortunately.
    if (std.valgrind.runningOnValgrind() > 0) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.regular;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var c = init();
    defer c.deinit(alloc);

    for (0..Index.Special.start - 1) |_| {
        _ = try c.add(alloc, try .init(
            lib,
            testFont,
            .{ .size = .{ .points = 12 } },
        ), .{
            .style = .regular,
            .fallback = false,
            .size_adjustment = .none,
        });
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
        c.add(alloc, face, .{
            .style = .regular,
            .fallback = false,
            .size_adjustment = .none,
        }),
    );
}

test "add deferred without loading options" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c = init();
    defer c.deinit(alloc);

    try testing.expectError(error.DeferredLoadingUnavailable, c.addDeferred(
        alloc,
        // This can be undefined because it should never be accessed.
        undefined,
        .{
            .style = .regular,
            .fallback = false,
            .size_adjustment = .none,
        },
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

    const idx = try c.add(alloc, try .init(
        lib,
        testFont,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    ), .{
        .style = .regular,
        .fallback = false,
        .size_adjustment = .none,
    });

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

    _ = try c.add(alloc, try .init(
        lib,
        testFont,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    ), .{
        .style = .regular,
        .fallback = false,
        .size_adjustment = .none,
    });

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

    _ = try c.add(alloc, try .init(
        lib,
        testFont,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    ), .{
        .style = .regular,
        .fallback = false,
        .size_adjustment = .none,
    });

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

    _ = try c.add(alloc, try .init(
        lib,
        testFont,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    ), .{
        .style = .regular,
        .fallback = false,
        .size_adjustment = .none,
    });

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

    const idx = try c.add(alloc, try .init(
        lib,
        testFont,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    ), .{
        .style = .regular,
        .fallback = false,
        .size_adjustment = .none,
    });

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

    const idx = try c.add(alloc, try .init(
        lib,
        testEmoji,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    ), .{
        .style = .regular,
        .fallback = false,
        .size_adjustment = .none,
    });

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

    _ = try c.add(alloc, try .init(
        lib,
        testFont,
        .{ .size = size },
    ), .{
        .style = .regular,
        .fallback = false,
        .size_adjustment = .none,
    });

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
    _ = try c.add(alloc, try .init(
        lib,
        testFont,
        .{ .size = size },
    ), .{
        .style = .regular,
        .fallback = false,
        .size_adjustment = .none,
    });

    try c.updateMetrics();

    inline for ([_][]const u8{ "ex_height", "cap_height" }) |metric| {
        // Add the fallback face with the chosen adjustment metric.
        const fallback_idx = try c.add(alloc, try .init(
            lib,
            fallback,
            .{ .size = size },
        ), .{
            .style = .regular,
            .fallback = false,
            .size_adjustment = @field(SizeAdjustment, metric),
        });

        // The chosen metric should match.
        {
            const primary_metrics = (try c.getFace(.{ .idx = 0 })).getMetrics();
            const fallback_metrics = (try c.getFace(fallback_idx)).getMetrics();

            try std.testing.expectApproxEqAbs(
                @field(primary_metrics, metric).?,
                @field(fallback_metrics, metric).?,
                // We accept anything within half a pixel.
                0.5,
            );
        }

        // Resize should keep that relationship.
        try c.setSize(.{ .points = 37, .xdpi = 96, .ydpi = 96 });
        {
            const primary_metrics = (try c.getFace(.{ .idx = 0 })).getMetrics();
            const fallback_metrics = (try c.getFace(fallback_idx)).getMetrics();

            try std.testing.expectApproxEqAbs(
                @field(primary_metrics, metric).?,
                @field(fallback_metrics, metric).?,
                // We accept anything within half a pixel.
                0.5,
            );
        }

        // Reset size for the next iteration
        try c.setSize(size);
    }

    {
        // A reference metric of "none" should leave the size unchanged.
        const fallback_idx = try c.add(alloc, try .init(
            lib,
            fallback,
            .{ .size = size },
        ), .{
            .style = .regular,
            .fallback = false,
            .size_adjustment = .none,
        });

        try std.testing.expectEqual(
            (try c.getFace(.{ .idx = 0 })).size.points,
            (try c.getFace(fallback_idx)).size.points,
        );

        // Resize should keep that.
        try c.setSize(.{ .points = 37, .xdpi = 96, .ydpi = 96 });

        try std.testing.expectEqual(
            (try c.getFace(.{ .idx = 0 })).size.points,
            (try c.getFace(fallback_idx)).size.points,
        );

        // Reset collection size
        try c.setSize(size);
    }

    // Add the symbol face.
    const symbol_idx = try c.add(alloc, try .init(
        lib,
        symbol,
        .{ .size = size },
    ), .{
        .style = .regular,
        .fallback = false,
        .size_adjustment = .ex_height,
    });

    // Test fallback to lineHeight() (ex_height and cap_height not defined in symbols font).
    {
        const primary_metrics = (try c.getFace(.{ .idx = 0 })).getMetrics();
        const symbol_metrics = (try c.getFace(symbol_idx)).getMetrics();

        try std.testing.expectApproxEqAbs(
            primary_metrics.lineHeight(),
            symbol_metrics.lineHeight(),
            // We accept anything within half a pixel.
            0.5,
        );
    }
}
