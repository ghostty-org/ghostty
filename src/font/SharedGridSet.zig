//! This structure contains a set of SharedGrid structures keyed by
//! unique font configuration.
//!
//! Most terminals (surfaces) will share the same font configuration.
//! This structure allows expensive font information such as
//! the font atlas, glyph cache, font faces, etc. to be shared.
//!
//! This structure is thread-safe when the operations are documented
//! as thread-safe.
const SharedGridSet = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const font = @import("main.zig");
const CodepointResolver = font.CodepointResolver;
const Collection = font.Collection;
const Discover = font.Discover;
const Style = font.Style;
const Library = font.Library;
const Metrics = font.Metrics;
const CodepointMap = font.CodepointMap;
const DesiredSize = font.face.DesiredSize;
const Face = font.Face;
const SharedGrid = font.SharedGrid;
const discovery = @import("discovery.zig");
const configpkg = @import("../config.zig");
const Config = configpkg.Config;

const log = std.log.scoped(.font_shared_grid_set);

/// The allocator to use for all heap allocations.
alloc: Allocator,

/// The map of font configurations to SharedGrid instances.
map: Map = .{},

/// The font library that is used for all font groups.
font_lib: Library,

/// Font discovery mechanism.
font_discover: ?Discover = null,

/// Lock to protect multi-threaded access to the map.
lock: std.Thread.Mutex = .{},

pub const InitError = Library.InitError;

/// Initialize a new SharedGridSet.
pub fn init(alloc: Allocator) InitError!SharedGridSet {
    var font_lib = try Library.init(alloc);
    errdefer font_lib.deinit();

    return .{
        .alloc = alloc,
        .map = .{},
        .font_lib = font_lib,
    };
}

pub fn deinit(self: *SharedGridSet) void {
    var it = self.map.iterator();
    while (it.next()) |entry| {
        entry.key_ptr.deinit();
        const v = entry.value_ptr.*;
        v.grid.deinit(self.alloc);
        self.alloc.destroy(v.grid);
    }
    self.map.deinit(self.alloc);

    if (comptime Discover != void) {
        if (self.font_discover) |*v| v.deinit();
    }

    self.font_lib.deinit();
}

/// Returns the number of cached grids.
pub fn count(self: *SharedGridSet) usize {
    self.lock.lock();
    defer self.lock.unlock();
    return self.map.count();
}

/// Initialize a SharedGrid for the given font configuration. If the
/// SharedGrid is not present it will be initialized with a ref count of
/// 1. If it is present, the ref count will be incremented.
///
/// This is NOT thread-safe.
///
/// The returned data (key and grid) should never be freed. The memory is
/// owned by the set and will be freed when the ref count reaches zero.
pub fn ref(
    self: *SharedGridSet,
    config: *const DerivedConfig,
    font_size: DesiredSize,
) !struct { Key, *SharedGrid } {
    var key = try Key.init(self.alloc, config, font_size);
    errdefer key.deinit();

    self.lock.lock();
    defer self.lock.unlock();

    const gop = try self.map.getOrPut(self.alloc, key);
    if (gop.found_existing) {
        log.debug("found cached grid for font config", .{});

        // We can deinit the key because we found a cached value.
        key.deinit();

        // Increment our ref count and return the cache
        gop.value_ptr.ref += 1;
        return .{ gop.key_ptr.*, gop.value_ptr.grid };
    }
    errdefer self.map.removeByPtr(gop.key_ptr);

    log.debug("initializing new grid for font config", .{});

    // A new font config, initialize the cache.
    const grid = try self.alloc.create(SharedGrid);
    errdefer self.alloc.destroy(grid);
    gop.value_ptr.* = .{
        .grid = grid,
        .ref = 1,
    };

    grid.* = try .init(self.alloc, resolver: {
        // Build our collection. This is the expensive operation that
        // involves finding fonts, loading them (maybe, some are deferred),
        // etc.
        var c = try self.collection(&key, font_size, config);
        errdefer c.deinit(self.alloc);

        // Setup our enabled/disabled styles
        var styles = CodepointResolver.StyleStatus.initFill(true);
        styles.set(.bold, config.@"font-style-bold" != .false);
        styles.set(.italic, config.@"font-style-italic" != .false);
        styles.set(.bold_italic, config.@"font-style-bold-italic" != .false);

        // Init our resolver which just requires setting fields.
        break :resolver .{
            .collection = c,
            .styles = styles,
            .discover = try self.discover(),
            .codepoint_map = key.codepoint_map,
        };
    });
    errdefer grid.deinit(self.alloc);

    return .{ gop.key_ptr.*, gop.value_ptr.grid };
}

/// Builds the Collection for the given configuration key and
/// initial font size.
fn collection(
    self: *SharedGridSet,
    key: *const Key,
    size: DesiredSize,
    config: *const DerivedConfig,
) !Collection {
    // A quick note on memory management:
    // - font_lib is owned by the SharedGridSet
    // - metric_modifiers is owned by the key which is freed only when
    //   the ref count for this grid reaches zero.
    const load_options: Collection.LoadOptions = .{
        .library = self.font_lib,
        .size = size,
        .freetype_load_flags = key.freetype_load_flags,
    };

    var c = Collection.init();
    errdefer c.deinit(self.alloc);
    c.load_options = load_options;
    c.metric_modifiers = key.metric_modifiers;

    // Search for fonts
    if (Discover != void) discover: {
        const disco = try self.discover() orelse {
            log.warn(
                "font discovery not available, cannot search for fonts",
                .{},
            );
            break :discover;
        };

        // A buffer we use to store the font names for logging.
        var name_buf: [256]u8 = undefined;

        inline for (@typeInfo(Style).@"enum".fields) |field| {
            const style = @field(Style, field.name);
            for (key.descriptorsForStyle(style)) |desc| {
                {
                    var disco_it = try disco.discover(self.alloc, desc);
                    defer disco_it.deinit();
                    if (try disco_it.next()) |face| {
                        log.info("font {s}: {s}", .{
                            field.name,
                            try face.name(&name_buf),
                        });

                        _ = try c.add(
                            self.alloc,
                            style,
                            .{ .deferred = face },
                        );

                        continue;
                    }
                }

                // If there are variation configurations and we didn't find
                // the font, then we retry the discovery with all stylistic
                // bits set to false. This is because some fonts may not
                // set the stylistic bit in their table but still support
                // axes to mimic the style. At the time of writing, Berkeley
                // Mono Variable is like this. See #2140.
                if (style != .regular and desc.variations.len > 0) {
                    var disco_it = try disco.discover(self.alloc, desc: {
                        var copy = desc;
                        copy.bold = false;
                        copy.italic = false;
                        break :desc copy;
                    });
                    defer disco_it.deinit();
                    if (try disco_it.next()) |face| {
                        log.info("font {s}: {s}", .{
                            field.name,
                            try face.name(&name_buf),
                        });

                        _ = try c.add(
                            self.alloc,
                            style,
                            .{ .deferred = face },
                        );

                        continue;
                    }
                }

                log.warn("font-family {s} not found: {s}", .{
                    field.name,
                    desc.family.?,
                });
            }
        }
    }

    // Complete our styles to ensure we have something to satisfy every
    // possible style request. We do this before adding our built-in font
    // because we want to ensure our built-in styles are fallbacks to
    // the configured styles.
    try c.completeStyles(self.alloc, config.@"font-synthetic-style");

    // Our built-in font will be used as a backup
    _ = try c.add(
        self.alloc,
        .regular,
        .{ .fallback_loaded = try .init(
            self.font_lib,
            font.embedded.variable,
            load_options.faceOptions(),
        ) },
    );
    try (try c.getFace(try c.add(
        self.alloc,
        .bold,
        .{ .fallback_loaded = try .init(
            self.font_lib,
            font.embedded.variable,
            load_options.faceOptions(),
        ) },
    ))).setVariations(
        &.{.{ .id = .init("wght"), .value = 700 }},
        load_options.faceOptions(),
    );
    _ = try c.add(
        self.alloc,
        .italic,
        .{ .fallback_loaded = try .init(
            self.font_lib,
            font.embedded.variable_italic,
            load_options.faceOptions(),
        ) },
    );
    try (try c.getFace(try c.add(
        self.alloc,
        .bold_italic,
        .{ .fallback_loaded = try .init(
            self.font_lib,
            font.embedded.variable_italic,
            load_options.faceOptions(),
        ) },
    ))).setVariations(
        &.{.{ .id = .init("wght"), .value = 700 }},
        load_options.faceOptions(),
    );

    // Nerd-font symbols fallback.
    _ = try c.add(
        self.alloc,
        .regular,
        .{ .fallback_loaded = try Face.init(
            self.font_lib,
            font.embedded.symbols_nerd_font,
            load_options.faceOptions(),
        ) },
    );

    // On macOS, always search for and add the Apple Emoji font
    // as our preferred emoji font for fallback. We do this in case
    // people add other emoji fonts to their system, we always want to
    // prefer the official one. Users can override this by explicitly
    // specifying a font-family for emoji.
    if (comptime builtin.target.os.tag.isDarwin() and Discover != void) apple_emoji: {
        const disco = try self.discover() orelse break :apple_emoji;
        var disco_it = try disco.discover(self.alloc, .{
            .family = "Apple Color Emoji",
        });
        defer disco_it.deinit();
        if (try disco_it.next()) |face| {
            _ = try c.add(
                self.alloc,
                .regular,
                .{ .fallback_deferred = face },
            );
        }
    }

    // Emoji fallback. We don't include this on Mac since Mac is expected
    // to always have the Apple Emoji available on the system.
    if (comptime !builtin.target.os.tag.isDarwin() or Discover == void) {
        _ = try c.add(
            self.alloc,
            .regular,
            .{ .fallback_loaded = try .init(
                self.font_lib,
                font.embedded.emoji,
                load_options.faceOptions(),
            ) },
        );
        _ = try c.add(
            self.alloc,
            .regular,
            .{ .fallback_loaded = try .init(
                self.font_lib,
                font.embedded.emoji_text,
                load_options.faceOptions(),
            ) },
        );
    }

    return c;
}

/// Decrement the ref count for the given key. If the ref count is zero,
/// the grid will be deinitialized and removed from the map.j:w
pub fn deref(self: *SharedGridSet, key: Key) void {
    self.lock.lock();
    defer self.lock.unlock();

    const entry = self.map.getEntry(key) orelse return;
    assert(entry.value_ptr.ref >= 1);

    // If we have more than one reference, decrement and return.
    if (entry.value_ptr.ref > 1) {
        entry.value_ptr.ref -= 1;
        return;
    }

    // We are at a zero ref count so deinit the group and remove.
    entry.key_ptr.deinit();
    entry.value_ptr.grid.deinit(self.alloc);
    self.alloc.destroy(entry.value_ptr.grid);
    self.map.removeByPtr(entry.key_ptr);
}

/// Map of font configurations to grid instances. The grid
/// instances are pointers that are heap allocated so that they're
/// stable pointers across hash map resizes.
pub const Map = std.HashMapUnmanaged(
    Key,
    ReffedGrid,
    struct {
        const KeyType = Key;

        pub fn hash(ctx: @This(), k: KeyType) u64 {
            _ = ctx;
            return k.hashcode();
        }

        pub fn eql(ctx: @This(), a: KeyType, b: KeyType) bool {
            return ctx.hash(a) == ctx.hash(b);
        }
    },
    std.hash_map.default_max_load_percentage,
);

/// Initialize once and return the font discovery mechanism. This remains
/// initialized throughout the lifetime of the application because some
/// font discovery mechanisms (i.e. fontconfig) are unsafe to reinit.
fn discover(self: *SharedGridSet) !?*Discover {
    // If we're built without a font discovery mechanism, return null
    if (comptime Discover == void) return null;

    // If we initialized, use it
    if (self.font_discover) |*v| return v;

    self.font_discover = .init();
    return &self.font_discover.?;
}

/// Ref-counted SharedGrid.
const ReffedGrid = struct {
    grid: *SharedGrid,
    ref: u32 = 0,
};

/// This is the configuration required to create a key without having
/// to keep the full Ghostty configuration around.
pub const DerivedConfig = struct {
    arena: ArenaAllocator,

    @"font-family": configpkg.RepeatableString,
    @"font-family-bold": configpkg.RepeatableString,
    @"font-family-italic": configpkg.RepeatableString,
    @"font-family-bold-italic": configpkg.RepeatableString,
    @"font-style": configpkg.FontStyle,
    @"font-style-bold": configpkg.FontStyle,
    @"font-style-italic": configpkg.FontStyle,
    @"font-style-bold-italic": configpkg.FontStyle,
    @"font-variation": configpkg.RepeatableFontVariation,
    @"font-variation-bold": configpkg.RepeatableFontVariation,
    @"font-variation-italic": configpkg.RepeatableFontVariation,
    @"font-variation-bold-italic": configpkg.RepeatableFontVariation,
    @"font-codepoint-map": configpkg.RepeatableCodepointMap,
    @"font-synthetic-style": configpkg.FontSyntheticStyle,
    @"adjust-cell-width": ?Metrics.Modifier,
    @"adjust-cell-height": ?Metrics.Modifier,
    @"adjust-font-baseline": ?Metrics.Modifier,
    @"adjust-underline-position": ?Metrics.Modifier,
    @"adjust-underline-thickness": ?Metrics.Modifier,
    @"adjust-strikethrough-position": ?Metrics.Modifier,
    @"adjust-strikethrough-thickness": ?Metrics.Modifier,
    @"adjust-overline-position": ?Metrics.Modifier,
    @"adjust-overline-thickness": ?Metrics.Modifier,
    @"adjust-cursor-thickness": ?Metrics.Modifier,
    @"adjust-cursor-height": ?Metrics.Modifier,
    @"adjust-box-thickness": ?Metrics.Modifier,
    @"freetype-load-flags": font.face.FreetypeLoadFlags,

    /// Initialize a DerivedConfig. The config should be either a
    /// config.Config or another DerivedConfig to clone from.
    pub fn init(
        alloc_gpa: Allocator,
        config: anytype,
    ) Allocator.Error!DerivedConfig {
        var arena = ArenaAllocator.init(alloc_gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        return .{
            .@"font-family" = try config.@"font-family".clone(alloc),
            .@"font-family-bold" = try config.@"font-family-bold".clone(alloc),
            .@"font-family-italic" = try config.@"font-family-italic".clone(alloc),
            .@"font-family-bold-italic" = try config.@"font-family-bold-italic".clone(alloc),
            .@"font-style" = try config.@"font-style".clone(alloc),
            .@"font-style-bold" = try config.@"font-style-bold".clone(alloc),
            .@"font-style-italic" = try config.@"font-style-italic".clone(alloc),
            .@"font-style-bold-italic" = try config.@"font-style-bold-italic".clone(alloc),
            .@"font-variation" = try config.@"font-variation".clone(alloc),
            .@"font-variation-bold" = try config.@"font-variation-bold".clone(alloc),
            .@"font-variation-italic" = try config.@"font-variation-italic".clone(alloc),
            .@"font-variation-bold-italic" = try config.@"font-variation-bold-italic".clone(alloc),
            .@"font-codepoint-map" = try config.@"font-codepoint-map".clone(alloc),
            .@"font-synthetic-style" = config.@"font-synthetic-style",
            .@"adjust-cell-width" = config.@"adjust-cell-width",
            .@"adjust-cell-height" = config.@"adjust-cell-height",
            .@"adjust-font-baseline" = config.@"adjust-font-baseline",
            .@"adjust-underline-position" = config.@"adjust-underline-position",
            .@"adjust-underline-thickness" = config.@"adjust-underline-thickness",
            .@"adjust-strikethrough-position" = config.@"adjust-strikethrough-position",
            .@"adjust-strikethrough-thickness" = config.@"adjust-strikethrough-thickness",
            .@"adjust-overline-position" = config.@"adjust-overline-position",
            .@"adjust-overline-thickness" = config.@"adjust-overline-thickness",
            .@"adjust-cursor-thickness" = config.@"adjust-cursor-thickness",
            .@"adjust-cursor-height" = config.@"adjust-cursor-height",
            .@"adjust-box-thickness" = config.@"adjust-box-thickness",
            .@"freetype-load-flags" = if (font.face.FreetypeLoadFlags != void) config.@"freetype-load-flags" else {},

            // This must be last so the arena contains all our allocations
            // from above since Zig does assignment in order.
            .arena = arena,
        };
    }

    pub fn deinit(self: *DerivedConfig) void {
        self.arena.deinit();
    }
};

/// The key used to uniquely identify a font configuration.
pub const Key = struct {
    arena: ArenaAllocator,

    /// The descriptors used for all the fonts added to the
    /// initial group, including all styles. This is hashed
    /// in order so the order matters. All users of the struct
    /// should ensure that the order is consistent.
    descriptors: []const discovery.Descriptor = &.{},

    /// These are the offsets into the descriptors array for
    /// each style. For example, bold is from
    /// offsets[@intFromEnum(.bold) - 1] to
    /// offsets[@intFromEnum(.bold)].
    style_offsets: StyleOffsets = @splat(0),

    /// The codepoint map configuration.
    codepoint_map: CodepointMap = .{},

    /// The metric modifier set configuration.
    metric_modifiers: Metrics.ModifierSet = .{},

    /// The configured font size for this key. We don't use this
    /// directly but it is used as part of the hash for the
    /// font grid.
    font_size: DesiredSize = .{ .points = 12 },

    /// The freetype load flags configuration, only non-void if the
    /// freetype backend is enabled.
    freetype_load_flags: font.face.FreetypeLoadFlags = font.face.freetype_load_flags_default,

    const style_offsets_len = std.enums.directEnumArrayLen(Style, 0);
    const StyleOffsets = [style_offsets_len]usize;

    comptime {
        // We assume this throughout this structure. If this changes
        // we may need to change this structure.
        assert(@intFromEnum(Style.regular) == 0);
        assert(@intFromEnum(Style.bold) == 1);
        assert(@intFromEnum(Style.italic) == 2);
        assert(@intFromEnum(Style.bold_italic) == 3);
    }

    pub fn init(
        alloc_gpa: Allocator,
        config_src: *const DerivedConfig,
        font_size: DesiredSize,
    ) Allocator.Error!Key {
        var arena = ArenaAllocator.init(alloc_gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        // Clone our configuration. We need to do this because the lifetime
        // of the derived config is usually shorter than that of a key
        // and we use pointers into the derived config for the key. We
        // can remove this if we wanted by dupe-ing the memory we use
        // from DerivedConfig below.
        var config = try DerivedConfig.init(alloc, config_src);

        var descriptors = std.ArrayList(discovery.Descriptor).init(alloc);
        defer descriptors.deinit();
        for (config.@"font-family".list.items) |family| {
            try descriptors.append(.{
                .family = family,
                .style = config.@"font-style".nameValue(),
                .size = font_size.points,
                .variations = config.@"font-variation".list.items,
            });
        }

        // In all the styled cases below, we prefer to specify an exact
        // style via the `font-style` configuration. If a style is not
        // specified, we use the discovery mechanism to search for a
        // style category such as bold, italic, etc. We can't specify both
        // because the latter will restrict the search to only that. If
        // a user says `font-style = italic` for the bold face for example,
        // no results would be found if we restrict to ALSO searching for
        // italic.
        for (config.@"font-family-bold".list.items) |family| {
            const style = config.@"font-style-bold".nameValue();
            try descriptors.append(.{
                .family = family,
                .style = style,
                .size = font_size.points,
                .bold = style == null,
                .variations = config.@"font-variation-bold".list.items,
            });
        }
        for (config.@"font-family-italic".list.items) |family| {
            const style = config.@"font-style-italic".nameValue();
            try descriptors.append(.{
                .family = family,
                .style = style,
                .size = font_size.points,
                .italic = style == null,
                .variations = config.@"font-variation-italic".list.items,
            });
        }
        for (config.@"font-family-bold-italic".list.items) |family| {
            const style = config.@"font-style-bold-italic".nameValue();
            try descriptors.append(.{
                .family = family,
                .style = style,
                .size = font_size.points,
                .bold = style == null,
                .italic = style == null,
                .variations = config.@"font-variation-bold-italic".list.items,
            });
        }

        // Setup the codepoint map
        const codepoint_map: CodepointMap = map: {
            const map = config.@"font-codepoint-map";
            if (map.map.list.len == 0) break :map .{};
            const clone = try config.@"font-codepoint-map".clone(alloc);
            break :map clone.map;
        };

        // Metric modifiers
        const metric_modifiers: Metrics.ModifierSet = set: {
            var set: Metrics.ModifierSet = .{};
            if (config.@"adjust-cell-width") |m| try set.put(alloc, .cell_width, m);
            if (config.@"adjust-cell-height") |m| try set.put(alloc, .cell_height, m);
            if (config.@"adjust-font-baseline") |m| try set.put(alloc, .cell_baseline, m);
            if (config.@"adjust-underline-position") |m| try set.put(alloc, .underline_position, m);
            if (config.@"adjust-underline-thickness") |m| try set.put(alloc, .underline_thickness, m);
            if (config.@"adjust-strikethrough-position") |m| try set.put(alloc, .strikethrough_position, m);
            if (config.@"adjust-strikethrough-thickness") |m| try set.put(alloc, .strikethrough_thickness, m);
            if (config.@"adjust-overline-position") |m| try set.put(alloc, .overline_position, m);
            if (config.@"adjust-overline-thickness") |m| try set.put(alloc, .overline_thickness, m);
            if (config.@"adjust-cursor-thickness") |m| try set.put(alloc, .cursor_thickness, m);
            if (config.@"adjust-cursor-height") |m| try set.put(alloc, .cursor_height, m);
            if (config.@"adjust-box-thickness") |m| try set.put(alloc, .box_thickness, m);
            break :set set;
        };

        const regular_offset = config.@"font-family".list.items.len;
        const bold_offset = regular_offset + config.@"font-family-bold".list.items.len;
        const italic_offset = bold_offset + config.@"font-family-italic".list.items.len;
        const bold_italic_offset = italic_offset + config.@"font-family-bold-italic".list.items.len;

        return .{
            .arena = arena,
            .descriptors = try descriptors.toOwnedSlice(),
            .style_offsets = .{
                regular_offset,
                bold_offset,
                italic_offset,
                bold_italic_offset,
            },
            .codepoint_map = codepoint_map,
            .metric_modifiers = metric_modifiers,
            .font_size = font_size,
            .freetype_load_flags = if (font.face.FreetypeLoadFlags != void)
                config.@"freetype-load-flags"
            else
                font.face.freetype_load_flags_default,
        };
    }

    pub fn deinit(self: *Key) void {
        self.arena.deinit();
    }

    /// Get the descriptors for the given font style that can be
    /// used with discovery.
    pub fn descriptorsForStyle(
        self: Key,
        style: Style,
    ) []const discovery.Descriptor {
        const idx = @intFromEnum(style);
        const start: usize = if (idx == 0) 0 else self.style_offsets[idx - 1];
        const end = self.style_offsets[idx];
        return self.descriptors[start..end];
    }

    /// Hash the key with the given hasher.
    pub fn hash(self: Key, hasher: anytype) void {
        const autoHash = std.hash.autoHash;
        autoHash(hasher, @as(u32, @bitCast(self.font_size.points)));
        autoHash(hasher, self.font_size.xdpi);
        autoHash(hasher, self.font_size.ydpi);
        autoHash(hasher, self.descriptors.len);
        for (self.descriptors) |d| d.hash(hasher);
        self.codepoint_map.hash(hasher);
        autoHash(hasher, self.metric_modifiers.count());
        autoHash(hasher, self.freetype_load_flags);
        if (self.metric_modifiers.count() > 0) {
            inline for (@typeInfo(Metrics.Key).@"enum".fields) |field| {
                const key = @field(Metrics.Key, field.name);
                if (self.metric_modifiers.get(key)) |value| {
                    autoHash(hasher, key);
                    value.hash(hasher);
                }
            }
        }
    }

    /// Returns a hash code that can be used to uniquely identify this
    /// action.
    pub fn hashcode(self: Key) u64 {
        var hasher = std.hash.Wyhash.init(0);
        self.hash(&hasher);
        return hasher.final();
    }
};

test "Key" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    var keycfg = try DerivedConfig.init(alloc, &cfg);
    defer keycfg.deinit();

    var k = try Key.init(alloc, &keycfg, .{ .points = 12 });
    defer k.deinit();

    var k2 = try Key.init(alloc, &keycfg, .{ .points = 12 });
    defer k2.deinit();

    try testing.expect(k.hashcode() > 0);
    try testing.expectEqual(k.hashcode(), k2.hashcode());
}

test "Key different font points" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    var keycfg = try DerivedConfig.init(alloc, &cfg);
    defer keycfg.deinit();

    var k = try Key.init(alloc, &keycfg, .{ .points = 12 });
    defer k.deinit();

    var k2 = try Key.init(alloc, &keycfg, .{ .points = 16 });
    defer k2.deinit();

    try testing.expect(k.hashcode() != k2.hashcode());
}

test "Key different font DPI" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    var keycfg = try DerivedConfig.init(alloc, &cfg);
    defer keycfg.deinit();

    var k = try Key.init(alloc, &keycfg, .{ .points = 12, .xdpi = 1 });
    defer k.deinit();

    var k2 = try Key.init(alloc, &keycfg, .{ .points = 12, .xdpi = 2 });
    defer k2.deinit();

    try testing.expect(k.hashcode() != k2.hashcode());
}

test SharedGridSet {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set = try SharedGridSet.init(alloc);
    defer set.deinit();

    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    var keycfg = try DerivedConfig.init(alloc, &cfg);
    defer keycfg.deinit();

    // Get a grid for the given config
    const key1, const grid1 = try set.ref(&keycfg, .{ .points = 12 });
    try testing.expectEqual(@as(usize, 1), set.count());

    // Get another
    const key2, const grid2 = try set.ref(&keycfg, .{ .points = 12 });
    try testing.expectEqual(@as(usize, 1), set.count());

    // They should be pointer equivalent
    try testing.expectEqual(@intFromPtr(grid1), @intFromPtr(grid2));

    // If I deref grid2 then we should still have a count of 1
    set.deref(key2);
    try testing.expectEqual(@as(usize, 1), set.count());

    // If I deref grid1 then we should have a count of 0
    set.deref(key1);
    try testing.expectEqual(@as(usize, 0), set.count());
}
