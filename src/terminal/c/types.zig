//! Comptime-generated ABI metadata for the public libghostty-vt C types.
//!
//! The manifest is embedded in the library and returned by
//! `ghostty_type_json`. It is intended for FFI consumers that cannot use the
//! C headers directly, most notably WebAssembly hosts. Its format is defined
//! by `types.schema.json`.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("terminal_options");
const lib = @import("../lib.zig");
const c_abi = @import("../../lib/c_abi.zig");

const color = @import("../color.zig");
const clipboard = @import("../clipboard.zig");
const cursor = @import("../cursor.zig");
const device_status = @import("../device_status.zig");
const focus_pkg = @import("../focus.zig");
const formatter_pkg = @import("../formatter.zig");
const modes_pkg = @import("../modes.zig");
const mouse_pkg = @import("../mouse.zig");
const page = @import("../page.zig");
const point = @import("../point.zig");
const Selection = @import("../Selection.zig");
const sgr = @import("../sgr.zig");

const input_config = @import("../../input/config.zig");
const input_key = @import("../../input/key.zig");
const input_mouse = @import("../../input/mouse.zig");

const build_info = @import("build_info.zig");
const cell = @import("cell.zig");
const color_c = @import("color.zig");
const formatter = @import("formatter.zig");
const grid_ref = @import("grid_ref.zig");
const io = @import("io.zig");
const key_encode = @import("key_encode.zig");
const kitty_graphics = @import("kitty_graphics.zig");
const mouse_encode = @import("mouse_encode.zig");
const mouse_event = @import("mouse_event.zig");
const osc = @import("osc.zig");
const paste = @import("paste.zig");
const render = @import("render.zig");
const result = @import("result.zig");
const row = @import("row.zig");
const search = @import("search.zig");
const selection = @import("selection.zig");
const selection_gesture = @import("selection_gesture.zig");
const size_report = @import("size_report.zig");
const snapshot = @import("snapshot.zig");
const style = @import("style.zig");
const sys = @import("sys.zig");
const terminal = @import("terminal.zig");

/// C: GhosttySurfacePosition
pub const SurfacePosition = extern struct {
    x: f64,
    y: f64,
};

/// C: GhosttyCursorStyle
///
/// The cursor shape in the C API. The terminal option
/// GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE reads it as input, and the
/// render state reports it as output. Both convert to and from the core
/// `cursor.Style`.
pub const CursorStyle = enum(c_int) {
    bar = 0,
    block = 1,
    underline = 2,
    block_hollow = 3,
    _,

    /// Convert a core cursor style. Every core style has a C value.
    pub fn fromZig(s: cursor.Style) CursorStyle {
        return switch (s) {
            .bar => .bar,
            .block => .block,
            .underline => .underline,
            .block_hollow => .block_hollow,
        };
    }

    /// Convert a value from C. Returns null for a value this version of
    /// the library doesn't know, which callers report as
    /// GHOSTTY_INVALID_VALUE.
    pub fn toZig(self: CursorStyle) ?cursor.Style {
        return switch (self) {
            .bar => .bar,
            .block => .block,
            .underline => .underline,
            .block_hollow => .block_hollow,
            _ => null,
        };
    }
};

/// C: GhosttyCodepoints
pub const Codepoints = extern struct {
    ptr: ?[*]const u32 = null,
    len: usize = 0,
};

/// C: GhosttyCodepointBuffer
///
/// A caller-provided buffer of codepoints. The caller sets ptr and cap
/// (in u32 elements). The library writes up to cap codepoints and sets
/// len to the total count, returning out_of_space when len > cap.
/// Frozen layout.
pub const CodepointBuffer = extern struct {
    ptr: ?[*]u32 = null,
    cap: usize = 0,
    len: usize = 0,
};

pub const TypeDecl = struct {
    name: []const u8,
    T: type,
    kind: Kind,
    prefix: []const u8 = "",
    sentinel_suffix: []const u8 = "MAX_VALUE",
    alias_type: []const u8 = "",
    tagged_union: ?TaggedUnion = null,
    union_field_names_T: ?type = null,

    pub const Kind = enum {
        @"struct",
        @"union",
        @"enum",
        @"packed",
        alias,
        @"opaque",
        callback,
    };

    const TaggedUnion = struct {
        tag_field: []const u8,
        value_field: []const u8,
        arm_source: ArmSource,

        /// The enum that names the arms when the tag field is a plain
        /// integer instead of the enum, such as a `uint8_t tag`. When
        /// null, the tag field's own type is used.
        tag_enum: ?type = null,

        const ArmSource = enum {
            fields,
            generated,
        };
    };

    fn initStruct(comptime name: []const u8, comptime T: type) TypeDecl {
        return .{ .name = name, .T = T, .kind = .@"struct" };
    }

    fn initTaggedStruct(
        comptime name: []const u8,
        comptime T: type,
        comptime tag_field: []const u8,
        comptime value_field: []const u8,
        comptime arm_source: TaggedUnion.ArmSource,
    ) TypeDecl {
        return .{
            .name = name,
            .T = T,
            .kind = .@"struct",
            .tagged_union = .{
                .tag_field = tag_field,
                .value_field = value_field,
                .arm_source = arm_source,
            },
        };
    }

    /// Like `initTaggedStruct` with `.fields` arms, for a struct whose
    /// tag field is a plain integer (such as `uint8_t tag`) instead of
    /// the enum. `tag_enum` is the enum whose values the tag holds. The
    /// arms are named after its fields.
    fn initTaggedStructByteTag(
        comptime name: []const u8,
        comptime T: type,
        comptime tag_field: []const u8,
        comptime value_field: []const u8,
        comptime tag_enum: type,
    ) TypeDecl {
        var decl = initTaggedStruct(name, T, tag_field, value_field, .fields);
        decl.tagged_union.?.tag_enum = tag_enum;
        return decl;
    }

    fn initUnion(
        comptime name: []const u8,
        comptime T: type,
        comptime field_names_T: ?type,
    ) TypeDecl {
        return .{
            .name = name,
            .T = T,
            .kind = .@"union",
            .union_field_names_T = field_names_T,
        };
    }

    fn initEnum(
        comptime name: []const u8,
        comptime T: type,
        comptime prefix: []const u8,
    ) TypeDecl {
        return .{ .name = name, .T = T, .kind = .@"enum", .prefix = prefix };
    }

    fn initEnumSentinel(
        comptime name: []const u8,
        comptime T: type,
        comptime prefix: []const u8,
        comptime sentinel_suffix: []const u8,
    ) TypeDecl {
        return .{
            .name = name,
            .T = T,
            .kind = .@"enum",
            .prefix = prefix,
            .sentinel_suffix = sentinel_suffix,
        };
    }

    fn initPacked(comptime name: []const u8, comptime T: type) TypeDecl {
        return .{ .name = name, .T = T, .kind = .@"packed" };
    }

    fn initAlias(
        comptime name: []const u8,
        comptime T: type,
        comptime alias_type: []const u8,
    ) TypeDecl {
        return .{ .name = name, .T = T, .kind = .alias, .alias_type = alias_type };
    }

    fn initOpaque(comptime name: []const u8) TypeDecl {
        return .{ .name = name, .T = *anyopaque, .kind = .@"opaque" };
    }

    /// An opaque handle whose Zig type is known, so that key values and
    /// callback parameters of that type can name it. `T` is the Zig handle
    /// type itself, such as `?*TerminalWrapper`, and must be distinct from
    /// every other registered type and from `anyopaque` pointers.
    fn initHandle(comptime name: []const u8, comptime T: type) TypeDecl {
        return .{ .name = name, .T = T, .kind = .@"opaque" };
    }

    /// A callback typedef. `T` is the Zig function pointer type, such as
    /// `*const fn (Terminal, ?*anyopaque) callconv(.c) void`.
    fn initCallback(comptime name: []const u8, comptime T: type) TypeDecl {
        return .{ .name = name, .T = T, .kind = .callback };
    }

    /// A struct or union field as the C header declares it.
    pub const Field = struct {
        /// The C field name.
        name: []const u8,

        /// The Zig type of the field.
        T: type,

        /// The byte offset from the start of the type. Always 0 for unions.
        offset: usize,
    };

    /// The fields of a struct or union, in the order the C header declares
    /// them. Only valid for `.struct` and `.union`.
    ///
    /// Most fields keep their Zig names. The exception is unions built by
    /// `lib.TaggedUnion`, whose fields take their C names from
    /// `union_field_names_T`. For example, the Zig field `@"8_fg"` of
    /// `GhosttySgrAttributeValue` is `fg_8` in C, since a C name cannot start
    /// with a digit.
    pub fn fields(comptime self: TypeDecl) []const Field {
        comptime {
            if (self.union_field_names_T) |FieldNames| {
                const Tag = @FieldType(FieldNames, "tag");
                const tag_fields = @typeInfo(Tag).@"enum".field_names;
                var out: []const Field = &.{};
                for (tag_fields, 0..) |field, i| {
                    const name = FieldNames.cFieldRename(@field(Tag, field)) orelse continue;
                    if (mappedUnionFieldIsDuplicate(self, i, name)) continue;
                    out = out ++ [_]Field{.{
                        .name = name,
                        .T = @FieldType(self.T, field),
                        .offset = 0,
                    }};
                }
                if (@hasField(self.T, "_padding")) out = out ++ [_]Field{.{
                    .name = "_padding",
                    .T = @FieldType(self.T, "_padding"),
                    .offset = 0,
                }};
                return out;
            }

            const info = switch (self.kind) {
                .@"struct" => @typeInfo(self.T).@"struct",
                .@"union" => @typeInfo(self.T).@"union",
                else => unreachable,
            };
            var out: [info.field_names.len]Field = undefined;
            for (&out, info.field_names, info.field_types) |*field, name, ty| field.* = .{
                .name = name,
                .T = ty,
                .offset = if (self.kind == .@"union") 0 else @offsetOf(self.T, name),
            };
            const final = out;
            return &final;
        }
    }

    fn mappedUnionFieldIsDuplicate(
        comptime decl: TypeDecl,
        comptime index: usize,
        comptime name: []const u8,
    ) bool {
        const FieldNames = decl.union_field_names_T.?;
        const Tag = @FieldType(FieldNames, "tag");
        const tag_fields = @typeInfo(Tag).@"enum".field_names;
        const T = @FieldType(decl.T, tag_fields[index]);

        inline for (tag_fields[0..index]) |previous| {
            const previous_name = FieldNames.cFieldRename(@field(Tag, previous)) orelse continue;
            if (std.mem.eql(u8, previous_name, name)) {
                if (@FieldType(decl.T, previous) != T)
                    @compileError("tagged union metadata maps different field types to " ++ name);
                return true;
            }
        }

        return false;
    }

    /// The C name of a Zig enum value, without the enum's prefix.
    ///
    /// Most values are the Zig name in upper case. A few are renamed because
    /// the plain upper case name would be awkward or invalid in C:
    ///
    /// | Enum                     | Zig value                 | Result                  |
    /// | ------------------------ | ------------------------- | ----------------------- |
    /// | `GhosttyCellWide`        | `.spacer_tail`            | `"SPACER_TAIL"`         |
    /// | `GhosttyKey`             | `.key_a`                  | `"A"`                   |
    /// | `GhosttySgrAttributeTag` | `.@"256_underline_color"` | `"UNDERLINE_COLOR_256"` |
    /// | `GhosttyTerminalOption`  | `.size_cb`                | `"SIZE"`                |
    ///
    /// Add the prefix to get the full C enumerator, such as
    /// `GHOSTTY_CELL_WIDE_SPACER_TAIL`.
    pub fn enumValueName(
        comptime enum_name: []const u8,
        comptime zig_name: []const u8,
    ) []const u8 {
        if (std.mem.eql(u8, enum_name, "GhosttyKey") and std.mem.startsWith(u8, zig_name, "key_"))
            return upper(zig_name["key_".len..]);
        if (std.mem.eql(u8, enum_name, "GhosttySgrAttributeTag")) {
            if (std.mem.eql(u8, zig_name, "256_underline_color")) return "UNDERLINE_COLOR_256";
            if (std.mem.eql(u8, zig_name, "8_bg")) return "BG_8";
            if (std.mem.eql(u8, zig_name, "8_fg")) return "FG_8";
            if (std.mem.eql(u8, zig_name, "8_bright_bg")) return "BRIGHT_BG_8";
            if (std.mem.eql(u8, zig_name, "8_bright_fg")) return "BRIGHT_FG_8";
            if (std.mem.eql(u8, zig_name, "256_bg")) return "BG_256";
            if (std.mem.eql(u8, zig_name, "256_fg")) return "FG_256";
        }
        if (std.mem.eql(u8, enum_name, "GhosttyTerminalOption") and std.mem.eql(u8, zig_name, "size_cb"))
            return "SIZE";
        return upper(zig_name);
    }

    fn upper(comptime name: []const u8) []const u8 {
        comptime {
            var buf: [name.len]u8 = undefined;
            for (&buf, name) |*d, c| d.* = std.ascii.toUpper(c);
            const final = buf;
            return &final;
        }
    }
};

/// Public C types. Names and enum prefixes are intentionally explicit because
/// Zig identifiers are not the C API contract.
pub const type_decls = [_]TypeDecl{
    .initStruct("GhosttyAllocator", lib.alloc.Allocator),
    .initStruct("GhosttyAllocatorVtable", lib.alloc.VTable),
    .initStruct("GhosttyBuffer", lib.Buffer),
    .initStruct("GhosttyCellsView", cell.CellsView),
    .initStruct("GhosttyClipboardContent", terminal.ClipboardContent),
    .initStruct("GhosttyClipboardRead", terminal.ClipboardRead),
    .initStruct("GhosttyClipboardReadReply", terminal.ClipboardReadReply),
    .initStruct("GhosttyClipboardWrite", terminal.ClipboardWrite),
    .initStruct("GhosttyClipboardWriteReply", terminal.ClipboardWriteReply),
    .initStruct("GhosttyCodepointBuffer", CodepointBuffer),
    .initStruct("GhosttyCodepoints", Codepoints),
    .initStruct("GhosttyColorPaletteMask", color_c.PaletteMask),
    .initStruct("GhosttyColorRgb", color.RGB.C),
    .initStruct("GhosttyColorX11Entry", color_c.X11Entry),
    .initStruct("GhosttyDeviceAttributes", terminal.DeviceAttributes),
    .initStruct("GhosttyDeviceAttributesPrimary", terminal.DeviceAttributes.Primary),
    .initStruct("GhosttyDeviceAttributesSecondary", terminal.DeviceAttributes.Secondary),
    .initStruct("GhosttyDeviceAttributesTertiary", terminal.DeviceAttributes.Tertiary),
    .initStruct("GhosttyGridRef", grid_ref.CGridRef),
    .initStruct("GhosttyKittyGraphicsPlacementRenderInfo", kitty_graphics.PlacementRenderInfo),
    .initStruct("GhosttyMimeReader", io.MimeReader),
    .initStruct("GhosttyMouseEncoderSize", mouse_encode.Size),
    .initStruct("GhosttyMousePosition", mouse_event.Position),
    .initStruct("GhosttyPaste", paste.Request),
    .initTaggedStruct("GhosttyPoint", point.Point.C, "tag", "value", .generated),
    .initStruct("GhosttyPointCoordinate", point.Coordinate),
    .initUnion("GhosttyPointValue", point.Point.CValue, point.Point.C),
    .initStruct("GhosttyReader", io.Reader),
    .initStruct("GhosttyRenderStateColors", render.Colors),
    .initStruct("GhosttyRenderStateCursor", render.Cursor),
    .initStruct("GhosttyRenderStateOverscan", render.Overscan),
    .initStruct("GhosttyRenderStateRowId", render.RowId),
    .initStruct("GhosttyRenderStateRowSelection", render.RowSelection),
    .initStruct("GhosttySelection", selection.CSelection),
    .initStruct("GhosttySelectionBuffer", selection.CSelectionBuffer),
    .initStruct("GhosttySelectionGestureBehaviors", selection_gesture.Behaviors),
    .initStruct("GhosttySelectionGestureGeometry", selection_gesture.Geometry),
    .initTaggedStruct("GhosttySgrAttribute", sgr.Attribute.C, "tag", "value", .generated),
    .initStruct("GhosttySgrUnknown", sgr.Attribute.Unknown.C),
    .initUnion("GhosttySgrAttributeValue", sgr.Attribute.CValue, sgr.Attribute.C),
    .initStruct("GhosttySizeReportSize", size_report.Size),
    .initStruct("GhosttyString", lib.String),
    .initStruct("GhosttySurfacePosition", SurfacePosition),
    .initStruct("GhosttyStyle", style.Style),
    .initTaggedStructByteTag("GhosttyStyleColor", style.Color, "tag", "value", style.ColorTag),
    .initUnion("GhosttyStyleColorValue", style.ColorValue, null),
    .initStruct("GhosttySysImage", sys.Image),
    .initStruct("GhosttyTerminalDesktopNotification", terminal.DesktopNotification),
    .initStruct("GhosttyTerminalMemoryUsage", terminal.TerminalMemoryUsage),
    .initStruct("GhosttyTerminalModeConfig", terminal.ModeConfig),
    .initStruct("GhosttyTerminalProgramStatus", terminal.ProgramStatus),
    .initStruct("GhosttyTerminalProgressReport", terminal.ProgressReport),
    .initTaggedStruct("GhosttyTerminalResizeWindow", terminal.ResizeWindow.C, "tag", "value", .generated),
    .initStruct("GhosttyTerminalResizeWindowGrid", terminal.ResizeWindowGrid),
    .initUnion(
        "GhosttyTerminalResizeWindowValue",
        terminal.ResizeWindow.CValue,
        terminal.ResizeWindow.C,
    ),
    .initStruct("GhosttyTerminalScrollbar", terminal.TerminalScrollbar),
    .initStruct("GhosttyTerminalSemanticPrompt", terminal.SemanticPrompt),
    .initTaggedStruct("GhosttyTerminalScrollViewport", terminal.ScrollViewport, "tag", "value", .generated),
    .initUnion(
        "GhosttyTerminalScrollViewportValue",
        terminal.ZigTerminal.ScrollViewport.CValue,
        terminal.ZigTerminal.ScrollViewport.C,
    ),
    .initStruct("GhosttyTerminalSelectLineOptions", selection.SelectLineOptions),
    .initStruct("GhosttyTerminalSelectWordBetweenOptions", selection.SelectWordBetweenOptions),
    .initStruct("GhosttyTerminalSelectWordOptions", selection.SelectWordOptions),
    .initTaggedStruct("GhosttyTerminalUnknownSequence", terminal.UnknownSequence.C, "tag", "value", .generated),
    .initStruct("GhosttyTerminalUnknownOscSequence", terminal.UnknownOscSequence),
    .initStruct("GhosttyTerminalUnknownStringSequence", terminal.UnknownStringSequence),
    .initStruct("GhosttyTerminalWriteStop", terminal.WriteStop),
    .initUnion(
        "GhosttyTerminalUnknownSequenceValue",
        terminal.UnknownSequence.CValue,
        terminal.UnknownSequence.C,
    ),
    .initStruct("GhosttyWriter", io.Writer),

    .initEnumSentinel("GhosttyResult", result.Result, "GHOSTTY_", "RESULT_MAX_VALUE"),
    .initEnum("GhosttyBuildInfo", build_info.BuildInfo, "GHOSTTY_BUILD_INFO_"),
    .initEnumSentinel("GhosttyOptimizeMode", build_info.OptimizeMode, "GHOSTTY_OPTIMIZE_", "MODE_MAX_VALUE"),
    .initEnumSentinel("GhosttyCellContentTag", cell.ContentTag, "GHOSTTY_CELL_CONTENT_", "TAG_MAX_VALUE"),
    .initEnum("GhosttyCellData", cell.CellData, "GHOSTTY_CELL_DATA_"),
    .initEnum("GhosttyCellSemanticContent", cell.SemanticContent, "GHOSTTY_CELL_SEMANTIC_"),
    .initEnum("GhosttyCellWide", cell.Wide, "GHOSTTY_CELL_WIDE_"),
    .initEnum("GhosttyClipboardLocation", clipboard.Location, "GHOSTTY_CLIPBOARD_LOCATION_"),
    .initEnum("GhosttyClipboardReadResult", clipboard.Read.Status, "GHOSTTY_CLIPBOARD_READ_RESULT_"),
    .initEnum("GhosttyClipboardWriteResult", clipboard.Write.Status, "GHOSTTY_CLIPBOARD_WRITE_RESULT_"),
    .initEnum("GhosttyCursorStyle", CursorStyle, "GHOSTTY_CURSOR_STYLE_"),
    .initEnum("GhosttyColorScheme", device_status.ColorScheme, "GHOSTTY_COLOR_SCHEME_"),
    .initEnum("GhosttyFocusEvent", focus_pkg.Event, "GHOSTTY_FOCUS_"),
    .initEnum("GhosttyFormatterFormat", formatter_pkg.Format, "GHOSTTY_FORMATTER_FORMAT_"),
    .initEnum("GhosttyFormatterOption", formatter.Option, "GHOSTTY_FORMATTER_OPT_"),
    .initEnum("GhosttyImageLayer", render.ImageLayer, "GHOSTTY_IMAGE_LAYER_"),
    .initEnum("GhosttyImageProtocol", render.ImageProtocol, "GHOSTTY_IMAGE_PROTOCOL_"),
    .initEnum("GhosttyKey", input_key.Key, "GHOSTTY_KEY_"),
    .initEnum("GhosttyKeyAction", input_key.Action, "GHOSTTY_KEY_ACTION_"),
    .initEnum("GhosttyKeyEncoderOption", key_encode.Option, "GHOSTTY_KEY_ENCODER_OPT_"),
    .initEnum("GhosttyKittyGraphicsData", kitty_graphics.Data, "GHOSTTY_KITTY_GRAPHICS_DATA_"),
    .initEnum("GhosttyKittyGraphicsImageData", kitty_graphics.ImageData, "GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_"),
    .initEnum("GhosttyKittyGraphicsPlacementData", kitty_graphics.PlacementData, "GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_"),
    .initEnum("GhosttyKittyGraphicsPlacementIteratorOption", kitty_graphics.PlacementIteratorOption, "GHOSTTY_KITTY_GRAPHICS_PLACEMENT_ITERATOR_OPT_"),
    .initEnum("GhosttyKittyImageCompression", kitty_graphics.ImageCompression, "GHOSTTY_KITTY_IMAGE_COMPRESSION_"),
    .initEnum("GhosttyKittyImageFormat", kitty_graphics.ImageFormat, "GHOSTTY_KITTY_IMAGE_FORMAT_"),
    .initEnum("GhosttyModeReportState", modes_pkg.Report.State, "GHOSTTY_MODE_REPORT_"),
    .initEnum("GhosttyMouseAction", input_mouse.Action, "GHOSTTY_MOUSE_ACTION_"),
    .initEnum("GhosttyMouseButton", input_mouse.Button, "GHOSTTY_MOUSE_BUTTON_"),
    .initEnum("GhosttyMouseEncoderOption", mouse_encode.Option, "GHOSTTY_MOUSE_ENCODER_OPT_"),
    .initEnum("GhosttyMouseFormat", mouse_pkg.Format, "GHOSTTY_MOUSE_FORMAT_"),
    .initEnum("GhosttyMouseShape", mouse_pkg.Shape, "GHOSTTY_MOUSE_SHAPE_"),
    .initEnum("GhosttyMouseTrackingMode", mouse_pkg.Event, "GHOSTTY_MOUSE_TRACKING_"),
    .initEnum("GhosttyOptionAsAlt", input_config.OptionAsAlt, "GHOSTTY_OPTION_AS_ALT_"),
    .initEnum("GhosttyOscCommandData", osc.CommandData, "GHOSTTY_OSC_DATA_"),
    .initEnum("GhosttyOscOption", osc.Option, "GHOSTTY_OSC_OPT_"),
    .initEnum("GhosttyOscTerminator", osc.Terminator, "GHOSTTY_OSC_TERMINATOR_"),
    .initEnumSentinel(
        "GhosttyOscCommandType",
        osc.CommandType,
        "GHOSTTY_OSC_COMMAND_",
        "TYPE_MAX_VALUE",
    ),
    .initEnum("GhosttyPasteSource", paste.Source, "GHOSTTY_PASTE_SOURCE_"),
    .initEnum("GhosttyPointTag", point.Tag, "GHOSTTY_POINT_TAG_"),
    .initEnum("GhosttyProgramStatusKind", terminal.ProgramStatusKind, "GHOSTTY_PROGRAM_STATUS_KIND_"),
    .initEnum("GhosttyProgramStatusState", terminal.ProgramStatusState, "GHOSTTY_PROGRAM_STATUS_STATE_"),
    .initEnum("GhosttyRenderStateData", render.Data, "GHOSTTY_RENDER_STATE_DATA_"),
    .initEnum("GhosttyRenderStateDirty", render.Dirty, "GHOSTTY_RENDER_STATE_DIRTY_"),
    .initEnum("GhosttyRenderStateImageData", render.ImageData, "GHOSTTY_RENDER_STATE_IMAGE_DATA_"),
    .initEnum("GhosttyRenderStateKittyPlacementKind", render.KittyPlacementKind, "GHOSTTY_RENDER_STATE_KITTY_PLACEMENT_KIND_"),
    .initEnum("GhosttyRenderStateOption", render.SetOption, "GHOSTTY_RENDER_STATE_OPT_"),
    .initEnum("GhosttyRenderStateRowCellsData", render.RowCellsData, "GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_"),
    .initEnum("GhosttyRenderStateRowData", render.RowData, "GHOSTTY_RENDER_STATE_ROW_DATA_"),
    .initEnum("GhosttyRenderStateRowOption", render.RowOption, "GHOSTTY_RENDER_STATE_ROW_OPT_"),
    .initEnum("GhosttyRowData", row.RowData, "GHOSTTY_ROW_DATA_"),
    .initEnum("GhosttyRowSemanticPrompt", row.SemanticPrompt, "GHOSTTY_ROW_SEMANTIC_"),
    .initEnum("GhosttySearchData", search.Data, "GHOSTTY_SEARCH_DATA_"),
    .initEnum("GhosttySearchOption", search.Option, "GHOSTTY_SEARCH_OPT_"),
    .initEnum("GhosttySearchScroll", search.Scroll, "GHOSTTY_SEARCH_SCROLL_"),
    .initEnum("GhosttySearchStatus", search.Status, "GHOSTTY_SEARCH_STATUS_"),
    .initEnum("GhosttySelectionAdjust", Selection.Adjustment, "GHOSTTY_SELECTION_ADJUST_"),
    .initEnum("GhosttySelectionGestureAutoscroll", selection_gesture.Autoscroll, "GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_"),
    .initEnum("GhosttySelectionGestureBehavior", selection_gesture.Behavior, "GHOSTTY_SELECTION_GESTURE_BEHAVIOR_"),
    .initEnum("GhosttySelectionGestureData", selection_gesture.Data, "GHOSTTY_SELECTION_GESTURE_DATA_"),
    .initEnum("GhosttySelectionGestureEventOption", selection_gesture.EventOption, "GHOSTTY_SELECTION_GESTURE_EVENT_OPT_"),
    .initEnum("GhosttySelectionGestureEventType", selection_gesture.EventType, "GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_"),
    .initEnum("GhosttySelectionOrder", Selection.Order, "GHOSTTY_SELECTION_ORDER_"),
    .initEnum("GhosttySemanticPromptKind", terminal.SemanticPromptKind, "GHOSTTY_SEMANTIC_PROMPT_"),
    .initEnum("GhosttySemanticPromptPromptKind", terminal.SemanticPromptPromptKind, "GHOSTTY_SEMANTIC_PROMPT_PROMPT_"),
    .initEnum("GhosttySgrAttributeTag", sgr.Attribute.Tag, "GHOSTTY_SGR_ATTR_"),
    .initEnum("GhosttySgrUnderline", sgr.Attribute.Underline, "GHOSTTY_SGR_UNDERLINE_"),
    .initEnumSentinel("GhosttySizeReportStyle", size_report.Style, "GHOSTTY_SIZE_REPORT_", "STYLE_MAX_VALUE"),
    .initEnum("GhosttySnapshotDecoderData", snapshot.DecoderData, "GHOSTTY_SNAPSHOT_DECODER_DATA_"),
    .initEnum("GhosttySnapshotDecoderOption", snapshot.DecoderOption, "GHOSTTY_SNAPSHOT_DECODER_OPT_"),
    .initEnum("GhosttySnapshotDecoderProgressKind", snapshot.DecoderProgressKind, "GHOSTTY_SNAPSHOT_DECODER_PROGRESS_KIND_"),
    .initEnumSentinel("GhosttyStyleColorTag", style.ColorTag, "GHOSTTY_STYLE_COLOR_", "TAG_MAX_VALUE"),
    .initEnum("GhosttySysLogLevel", sys.LogLevel, "GHOSTTY_SYS_LOG_LEVEL_"),
    .initEnum("GhosttySysOption", sys.Option, "GHOSTTY_SYS_OPT_"),
    .initEnum("GhosttyTerminalBoundary", terminal.Boundary, "GHOSTTY_TERMINAL_BOUNDARY_"),
    .initEnum("GhosttyTerminalCompressionMode", terminal.CompressionMode, "GHOSTTY_TERMINAL_COMPRESSION_MODE_"),
    .initEnum("GhosttyTerminalCompressionResult", terminal.CompressionResult, "GHOSTTY_TERMINAL_COMPRESSION_RESULT_"),
    .initEnum("GhosttyTerminalData", terminal.TerminalData, "GHOSTTY_TERMINAL_DATA_"),
    .initEnum("GhosttyTerminalOption", terminal.Option, "GHOSTTY_TERMINAL_OPT_"),
    .initEnum("GhosttyTerminalProgressState", terminal.ProgressState, "GHOSTTY_TERMINAL_PROGRESS_STATE_"),
    .initEnum("GhosttyTerminalScreen", terminal.TerminalScreen, "GHOSTTY_TERMINAL_SCREEN_"),
    .initEnum("GhosttyTerminalResizeWindowTag", terminal.ResizeWindow.Tag, "GHOSTTY_TERMINAL_RESIZE_WINDOW_"),
    .initEnum("GhosttyTerminalScrollViewportTag", terminal.ZigTerminal.ScrollViewport.Tag, "GHOSTTY_TERMINAL_SCROLL_VIEWPORT_"),
    .initEnum("GhosttyTerminalStringEnd", terminal.StringEnd, "GHOSTTY_TERMINAL_STRING_END_"),
    .initEnum("GhosttyTerminalStringIntroducer", terminal.StringIntroducer, "GHOSTTY_TERMINAL_STRING_INTRODUCER_"),
    .initEnum("GhosttyTerminalStringKind", terminal.StringKind, "GHOSTTY_TERMINAL_STRING_KIND_"),
    .initEnum("GhosttyTerminalUnknownSequenceTag", terminal.UnknownSequence.Tag, "GHOSTTY_TERMINAL_UNKNOWN_SEQUENCE_"),

    .initPacked("GhosttyCell", page.Cell.CLayout),
    .initPacked("GhosttyStyleFlags", style.FlagsLayout),
    .initAlias("GhosttyColorPaletteIndex", u8, "u8"),
    .initAlias("GhosttyFormatterExtras", formatter.Extras, "u32"),
    .initAlias("GhosttyKittyKeyFlags", u8, "u8"),
    .initAlias("GhosttyMode", u16, "u16"),
    .initAlias("GhosttyMods", u16, "u16"),
    .initAlias("GhosttyRow", u64, "u64"),
    .initAlias("GhosttyStyleId", u16, "u16"),

    .initOpaque("GhosttyFormatter"),
    .initOpaque("GhosttyKeyEncoder"),
    .initOpaque("GhosttyKeyEvent"),
    .initHandle("GhosttyKittyGraphics", kitty_graphics.KittyGraphics),
    .initOpaque("GhosttyKittyGraphicsImage"),
    .initHandle("GhosttyKittyGraphicsPlacementIterator", kitty_graphics.PlacementIterator),
    .initOpaque("GhosttyMouseEncoder"),
    .initOpaque("GhosttyMouseEvent"),
    .initOpaque("GhosttyOscCommand"),
    .initOpaque("GhosttyOscParser"),
    .initOpaque("GhosttyRenderState"),
    .initHandle("GhosttyRenderStateImageIterator", render.ImageIterator),
    .initHandle("GhosttyRenderStateRowCells", render.RowCells),
    .initHandle("GhosttyRenderStateRowIterator", render.RowIterator),
    .initOpaque("GhosttySearch"),
    .initOpaque("GhosttySelectionGesture"),
    .initOpaque("GhosttySelectionGestureEvent"),
    .initOpaque("GhosttySgrParser"),
    .initOpaque("GhosttySnapshotDecoder"),
    .initHandle("GhosttyTerminal", terminal.Terminal),
    .initOpaque("GhosttyTrackedGridRef"),

    .initCallback("GhosttyAllocatorAllocFn", lib.alloc.AllocFn),
    .initCallback("GhosttyAllocatorFreeFn", lib.alloc.FreeFn),
    .initCallback("GhosttyAllocatorRemapFn", lib.alloc.RemapFn),
    .initCallback("GhosttyAllocatorResizeFn", lib.alloc.ResizeFn),
    .initCallback("GhosttyClipboardReadReplyFn", terminal.ClipboardReadReplyFn),
    .initCallback("GhosttyClipboardWriteReplyFn", terminal.ClipboardWriteReplyFn),
    .initCallback("GhosttyMimeReaderFn", io.MimeReaderFn),
    .initCallback("GhosttyReaderFn", io.ReaderFn),
    .initCallback("GhosttySysDecodePngFn", sys.DecodePngFn),
    .initCallback("GhosttySysLogFn", sys.LogFn),
    .initCallback("GhosttySysRandomSecureFn", sys.RandomSecureFn),
    .initCallback("GhosttyTerminalBellFn", terminal.Effects.BellFn),
    .initCallback("GhosttyTerminalClipboardReadFn", terminal.Effects.ClipboardReadFn),
    .initCallback("GhosttyTerminalClipboardWriteFn", terminal.Effects.ClipboardWriteFn),
    .initCallback("GhosttyTerminalColorSchemeFn", terminal.Effects.ColorSchemeFn),
    .initCallback("GhosttyTerminalDesktopNotificationFn", terminal.Effects.DesktopNotificationFn),
    .initCallback("GhosttyTerminalDeviceAttributesFn", terminal.Effects.DeviceAttributesFn),
    .initCallback("GhosttyTerminalEnquiryFn", terminal.Effects.EnquiryFn),
    .initCallback("GhosttyTerminalProgramStatusFn", terminal.Effects.ProgramStatusFn),
    .initCallback("GhosttyTerminalProgressReportFn", terminal.Effects.ProgressReportFn),
    .initCallback("GhosttyTerminalPwdChangedFn", terminal.Effects.PwdChangedFn),
    .initCallback("GhosttyTerminalRenderHoldFn", terminal.Effects.RenderHoldFn),
    .initCallback("GhosttyTerminalResetFn", terminal.Effects.ResetFn),
    .initCallback("GhosttyTerminalResizeWindowFn", terminal.Effects.ResizeWindowFn),
    .initCallback("GhosttyTerminalSemanticPromptFn", terminal.Effects.SemanticPromptFn),
    .initCallback("GhosttyTerminalSizeFn", terminal.Effects.SizeFn),
    .initCallback("GhosttyTerminalTitleChangedFn", terminal.Effects.TitleChangedFn),
    .initCallback("GhosttyTerminalUnknownSequenceFn", terminal.Effects.UnknownSequenceFn),
    .initCallback("GhosttyTerminalWritePtyFn", terminal.Effects.WritePtyFn),
    .initCallback("GhosttyTerminalXtversionFn", terminal.Effects.XtversionFn),
    .initCallback("GhosttyWriterFn", io.WriterFn),
};

comptime {
    @setEvalBranchQuota(100_000);
    for (type_decls, 0..) |decl, i| {
        for (type_decls[0..i]) |previous| {
            if (std.mem.eql(u8, decl.name, previous.name))
                @compileError("duplicate public ABI type: " ++ decl.name);
        }

        switch (decl.kind) {
            .@"opaque" => if (decl.T != *anyopaque) {
                if (@sizeOf(decl.T) != @sizeOf(*anyopaque) or !isPointer(decl.T))
                    @compileError(decl.name ++ ": a handle type must be a pointer");
                if (isAnyopaquePointer(decl.T))
                    @compileError(decl.name ++ ": a handle type cannot be an anyopaque pointer");
            },
            .callback => if (@typeInfo(decl.T) != .pointer or
                @typeInfo(@typeInfo(decl.T).pointer.child) != .@"fn")
                @compileError(decl.name ++ ": a callback type must be a function pointer"),
            else => {},
        }

        // Key values and callback parameters find their registered name by
        // Zig type, so two names for one Zig type would be ambiguous.
        // Callbacks are exempt. Zig function pointer types are equal when
        // their signatures are, so GhosttyTerminalBellFn and
        // GhosttyTerminalResetFn are one Zig type. Keys find their callback
        // by name instead, in `Json.keyCallbackName`.
        if (!isTypeLookupKind(decl)) continue;
        for (type_decls[0..i]) |previous| {
            if (!isTypeLookupKind(previous)) continue;
            if (previous.T == decl.T)
                @compileError(decl.name ++ " and " ++ previous.name ++ " have the same Zig type");
        }
    }
}

/// Whether `registeredName` finds this declaration by its Zig type.
fn isTypeLookupKind(comptime decl: TypeDecl) bool {
    return switch (decl.kind) {
        .@"struct", .@"union", .@"enum" => true,
        .@"opaque" => decl.T != *anyopaque,
        .@"packed", .alias, .callback => false,
    };
}

fn isPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .optional => |info| @typeInfo(info.child) == .pointer,
        else => false,
    };
}

fn isAnyopaquePointer(comptime T: type) bool {
    const P = switch (@typeInfo(T)) {
        .optional => |info| info.child,
        else => T,
    };
    return @typeInfo(P) == .pointer and @typeInfo(P).pointer.child == anyopaque;
}

pub const json: [:0]const u8 = json: {
    @setEvalBranchQuota(10_000_000);
    var counter: std.Io.Writer.Discarding = .init(&.{});
    Json.writeAll(&counter.writer) catch unreachable;

    var buf: [counter.count:0]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    Json.writeAll(&writer) catch unreachable;
    const final = buf;
    break :json final[0..writer.end :0];
};

pub fn get_json() callconv(lib.calling_conv) [*:0]const u8 {
    return json.ptr;
}

/// Initialize a sized struct for callers that cannot use the
/// GHOSTTY_INIT_SIZED macro. Sets `size` bytes at `ptr` to zero, then
/// stores `size` in the leading `size_t`. Does nothing if `ptr` is NULL or
/// `size` is too small to hold the `size` field itself.
pub fn sized_init(ptr: ?*anyopaque, size: usize) callconv(lib.calling_conv) void {
    const bytes: [*]u8 = @ptrCast(ptr orelse return);
    if (size < @sizeOf(usize)) return;
    @memset(bytes[0..size], 0);
    std.mem.writeInt(usize, bytes[0..@sizeOf(usize)], size, builtin.target.cpu.arch.endian());
}

test "sized_init" {
    const Sized = extern struct {
        size: usize,
        a: u32,
        b: bool,
    };

    var value: Sized = .{ .size = 1, .a = 7, .b = true };
    sized_init(&value, @sizeOf(Sized));
    try std.testing.expectEqual(Sized{ .size = @sizeOf(Sized), .a = 0, .b = false }, value);

    // A struct too small for the size field and a NULL pointer are left alone.
    var tiny: [@sizeOf(usize)]u8 = @splat(0xaa);
    sized_init(&tiny, tiny.len - 1);
    for (tiny) |b| try std.testing.expectEqual(@as(u8, 0xaa), b);
    sized_init(null, 16);
}

const Json = struct {
    fn writeAll(writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var jws: std.json.Stringify = .{ .writer = writer };
        try jws.beginObject();
        try jws.objectField("schema");
        try jws.write(1);

        try jws.objectField("abi");
        try jws.beginObject();
        try jws.objectField("target");
        try jws.write(@tagName(builtin.target.cpu.arch));
        try jws.objectField("os");
        try jws.write(@tagName(builtin.target.os.tag));
        try jws.objectField("environment");
        try jws.write(@tagName(builtin.target.abi));
        try jws.objectField("pointer_size");
        try jws.write(@sizeOf(*anyopaque));
        try jws.objectField("usize_size");
        try jws.write(@sizeOf(usize));
        try jws.objectField("max_alignment");
        try jws.write(c_abi.max_alignment);
        try jws.objectField("endian");
        try jws.write(@tagName(builtin.target.cpu.arch.endian()));
        try jws.endObject();

        try jws.objectField("library_version");
        try jws.write(build_options.version_string);
        try jws.objectField("commit");
        if (build_options.version_build) |commit| try jws.write(commit) else try jws.write(null);
        try jws.objectField("dirty");
        try jws.write(null);

        try jws.objectField("types");
        try jws.beginObject();
        inline for (type_decls) |decl| {
            try jws.objectField(decl.name);
            try writeType(decl, &jws);
        }
        try jws.endObject();
        try jws.endObject();
    }

    fn writeType(comptime decl: TypeDecl, jws: *std.json.Stringify) std.Io.Writer.Error!void {
        try jws.beginObject();
        try jws.objectField("kind");
        try jws.write(@tagName(decl.kind));

        switch (decl.kind) {
            .@"struct", .@"union" => {
                try writeSizeAlign(decl.T, jws);
                try jws.objectField("fields");
                try jws.beginObject();
                inline for (comptime decl.fields()) |field|
                    try writeField(decl, field.name, field.T, field.offset, jws);
                try jws.endObject();
            },
            .@"enum" => {
                try writeSizeAlign(c_int, jws);
                try jws.objectField("underlying");
                try jws.write("i32");
                try jws.objectField("prefix");
                try jws.write(decl.prefix);
                try jws.objectField("values");
                try jws.beginObject();
                const info = @typeInfo(decl.T).@"enum";
                inline for (info.field_names, info.field_values) |field, value| {
                    try writeEnumObjectField(decl.name, field, jws);
                    try jws.write(value);
                }
                try jws.objectField(decl.sentinel_suffix);
                try jws.write(std.math.maxInt(c_int));
                try jws.endObject();
                try writeKeys(decl, jws);
            },
            .@"packed" => try writePackedType(decl.T, jws),
            .alias => {
                try writeSizeAlign(decl.T, jws);
                try jws.objectField("type");
                try jws.write(decl.alias_type);
            },
            .@"opaque" => try writeSizeAlign(*anyopaque, jws),
            .callback => try writeCallback(decl, jws),
        }
        try jws.endObject();
    }

    /// The direction a key enum's values travel, found from the enum's
    /// `InType` or `OutType` declaration, or null if it has neither.
    fn keyDirection(comptime decl: TypeDecl) ?KeyDirection {
        const in = @hasDecl(decl.T, "InType");
        const out = @hasDecl(decl.T, "OutType");
        if (in and out) @compileError(decl.name ++ " declares both InType and OutType");
        if (in) return .in;
        if (out) return .out;
        return null;
    }

    const KeyDirection = enum { in, out };

    /// Write the `keys` object of a key enum, such as
    /// `GhosttyTerminalOption`. Each key gets its direction and the type
    /// its `void *` value points at. An input key's value is a
    /// `const T *` and an output key's value is a `T *`. A key whose type
    /// is a callback takes the function pointer itself as its value.
    fn writeKeys(comptime decl: TypeDecl, jws: *std.json.Stringify) std.Io.Writer.Error!void {
        const direction = comptime keyDirection(decl) orelse return;
        try jws.objectField("keys");
        try jws.beginObject();
        const info = @typeInfo(decl.T).@"enum";
        inline for (info.field_names) |field| {
            if (comptime std.mem.eql(u8, field, "invalid")) continue;
            const key_name = comptime TypeDecl.enumValueName(decl.name, field);
            const context = decl.prefix ++ key_name;
            const T = comptime keyValueType(decl.T, @field(decl.T, field), direction);
            if (T == void) @compileError(context ++ ": a key's value type cannot be void");

            try jws.objectField(key_name);
            try jws.beginObject();
            try jws.objectField("direction");
            try jws.write(@tagName(direction));
            if (comptime keyTypeOverride(decl.name, field)) |name| {
                comptime checkKeyTypeOverride(context, name, T);
                try jws.objectField("type");
                try jws.write(name);
            } else if (comptime isCallbackPointer(T)) {
                try jws.objectField("type");
                try jws.write(comptime keyCallbackName(context, key_name, T));
            } else {
                try writeValueType(context, T, jws);
            }
            try jws.endObject();
        }
        try jws.endObject();
    }

    /// The type a key's value points at. Most key enums return that type
    /// from `InType` or `OutType` directly. The terminal and sys options
    /// instead return the type of the value pointer itself, such as
    /// `?*const usize`, or the callback, such as `?BellFn`, and those are
    /// unwrapped here.
    fn keyValueType(comptime Key: type, comptime key: Key, comptime direction: KeyDirection) type {
        const T = switch (direction) {
            .in => key.InType(),
            .out => key.OutType(),
        };
        if (direction == .out) return T;
        return switch (@typeInfo(T)) {
            .optional => |info| switch (@typeInfo(info.child)) {
                .pointer => |ptr| if (@typeInfo(ptr.child) == .@"fn") info.child else ptr.child,
                else => T,
            },
            else => T,
        };
    }

    /// The header type of a key whose value is an integer typedef. The Zig
    /// value type is the plain integer, so the typedef's name cannot be
    /// found from it. For example, GHOSTTY_CELL_DATA_STYLE_ID writes a
    /// `u16`, which the header calls `GhosttyStyleId`.
    fn keyTypeOverride(comptime enum_name: []const u8, comptime key: []const u8) ?[]const u8 {
        const overrides = [_]struct { []const u8, []const u8, []const u8 }{
            .{ "GhosttyCellData", "color_palette", "GhosttyColorPaletteIndex" },
            .{ "GhosttyCellData", "style_id", "GhosttyStyleId" },
            .{ "GhosttyFormatterOption", "extras", "GhosttyFormatterExtras" },
            .{ "GhosttyKeyEncoderOption", "kitty_flags", "GhosttyKittyKeyFlags" },
            .{ "GhosttyRenderStateRowCellsData", "raw", "GhosttyCell" },
            .{ "GhosttyRenderStateRowData", "raw", "GhosttyRow" },
            .{ "GhosttyTerminalData", "kitty_keyboard_flags", "GhosttyKittyKeyFlags" },
        };
        for (overrides) |entry| {
            const owner, const field, const name = entry;
            if (std.mem.eql(u8, owner, enum_name) and std.mem.eql(u8, field, key)) return name;
        }
        return null;
    }

    /// Check that an override names a registered integer typedef with the
    /// key's Zig type, so the table cannot drift from the code.
    fn checkKeyTypeOverride(comptime context: []const u8, comptime name: []const u8, comptime T: type) void {
        for (type_decls) |decl| {
            if (!std.mem.eql(u8, decl.name, name)) continue;
            const Int = switch (decl.kind) {
                .alias => decl.T,
                .@"packed" => decl.T.Backing,
                else => @compileError(context ++ ": " ++ name ++ " is not an integer typedef"),
            };
            if (Int != T) @compileError(context ++ ": " ++ name ++ " is not " ++ @typeName(T));
            return;
        }
        @compileError(context ++ ": " ++ name ++ " is not registered");
    }

    fn isCallbackPointer(comptime T: type) bool {
        return @typeInfo(T) == .pointer and @typeInfo(@typeInfo(T).pointer.child) == .@"fn";
    }

    /// The callback that a callback key takes. The Zig type alone cannot
    /// pick it, so the key's name does. For example, the key `WRITE_PTY`
    /// takes the registered callback whose name ends in `WritePtyFn`, and
    /// that callback must have the key's Zig type.
    fn keyCallbackName(
        comptime context: []const u8,
        comptime key_name: []const u8,
        comptime T: type,
    ) []const u8 {
        const suffix = pascal(key_name) ++ "Fn";
        var found: ?[]const u8 = null;
        for (type_decls) |decl| {
            if (decl.kind != .callback or !std.mem.endsWith(u8, decl.name, suffix)) continue;
            if (decl.T != T) continue;
            if (found != null) @compileError(context ++ ": more than one callback ends in " ++ suffix);
            found = decl.name;
        }
        return found orelse @compileError(context ++ ": no registered callback ending in " ++
            suffix ++ " has its type");
    }

    /// `WRITE_PTY` to `WritePty`.
    fn pascal(comptime name: []const u8) []const u8 {
        comptime {
            var out: []const u8 = "";
            var upper_next = true;
            for (name) |ch| {
                if (ch == '_') {
                    upper_next = true;
                    continue;
                }
                out = out ++ [_]u8{if (upper_next) ch else std.ascii.toLower(ch)};
                upper_next = false;
            }
            return out;
        }
    }

    /// Write a callback descriptor: the function pointer's size and
    /// alignment, its parameter types and its return type.
    fn writeCallback(comptime decl: TypeDecl, jws: *std.json.Stringify) std.Io.Writer.Error!void {
        const info = @typeInfo(@typeInfo(decl.T).pointer.child).@"fn";
        try writeSizeAlign(decl.T, jws);
        try jws.objectField("params");
        try jws.beginArray();
        inline for (info.param_types, 0..) |param, i| {
            const context = std.fmt.comptimePrint("{s} parameter {d}", .{ decl.name, i });
            const P = param orelse @compileError(context ++ " is generic");
            if (P == void) @compileError(context ++ " is void");
            try jws.beginObject();
            try writeValueType(context, P, jws);
            try jws.endObject();
        }
        try jws.endArray();
        try jws.objectField("return");
        try jws.beginObject();
        const R = info.return_type.?;
        if (R == void) {
            try jws.objectField("type");
            try jws.write("void");
        } else try writeValueType(decl.name ++ " return", R, jws);
        try jws.endObject();
    }

    /// Write a type reference for a key value or a callback parameter, in
    /// the same form struct fields use. Unlike fields, handles resolve to
    /// their registered names. A type the registry cannot name is a compile
    /// error, rather than a vague "struct" or "opaque".
    fn writeValueType(
        comptime context: []const u8,
        comptime T: type,
        jws: *std.json.Stringify,
    ) std.Io.Writer.Error!void {
        if (comptime registeredName(T)) |name| {
            try jws.objectField("type");
            try jws.write(name);
            return;
        }

        switch (@typeInfo(T)) {
            .array => |info| {
                try jws.objectField("type");
                try jws.write("array");
                try jws.objectField("elem");
                try jws.write(comptime valueName(context, info.child));
                try jws.objectField("count");
                try jws.write(info.len);
            },
            .optional => |info| try writeValuePointer(context, info.child, true, jws),
            .pointer => try writeValuePointer(context, T, false, jws),
            else => {
                try jws.objectField("type");
                try jws.write(comptime valueName(context, T));
            },
        }
    }

    fn writeValuePointer(
        comptime context: []const u8,
        comptime P: type,
        comptime nullable: bool,
        jws: *std.json.Stringify,
    ) std.Io.Writer.Error!void {
        const info = switch (@typeInfo(P)) {
            .pointer => |info| info,
            else => @compileError(context ++ ": an optional must hold a pointer, not " ++ @typeName(P)),
        };
        if (info.size == .slice) @compileError(context ++ ": slices have no C type");
        try jws.objectField("type");
        try jws.write("pointer");
        try jws.objectField("elem");
        try jws.write(comptime valueName(context, info.child));
        try jws.objectField("const");
        try jws.write(info.attrs.@"const");
        if (nullable) {
            try jws.objectField("nullable");
            try jws.write(true);
        }
    }

    /// The name of a scalar or registered type, or a compile error.
    fn valueName(comptime context: []const u8, comptime T: type) []const u8 {
        if (registeredName(T)) |name| return name;
        return switch (@typeInfo(T)) {
            .bool, .int, .float => publicTypeName(T),
            .@"opaque" => if (T == anyopaque)
                "opaque"
            else
                @compileError(context ++ ": the type registry cannot name " ++ @typeName(T)),
            else => @compileError(context ++ ": the type registry cannot name " ++ @typeName(T)),
        };
    }

    /// The registered name of a Zig type, including handles. Integer
    /// typedefs and callbacks are never returned, since their Zig types are
    /// shared by unrelated values.
    fn registeredName(comptime T: type) ?[]const u8 {
        for (type_decls) |decl| {
            if (isTypeLookupKind(decl) and decl.T == T) return decl.name;
        }
        return null;
    }

    fn writePackedType(
        comptime Layout: type,
        jws: *std.json.Stringify,
    ) std.Io.Writer.Error!void {
        try writeSizeAlign(Layout.Zig, jws);
        try jws.objectField("underlying");
        try jws.write(publicTypeName(Layout.Backing));
        try jws.objectField("bits");
        try jws.beginObject();
        try writePackedBits(Layout, jws);
        try jws.endObject();
    }

    fn writePackedBits(
        comptime Layout: type,
        jws: *std.json.Stringify,
    ) std.Io.Writer.Error!void {
        inline for (@typeInfo(Layout.Zig).@"struct".field_names) |field| {
            const field_tag = @field(Layout.Field, field);
            const name = comptime Layout.fieldName(field_tag) orelse continue;
            const options = Layout.fieldOptions(field_tag);

            try jws.objectField(name);
            try jws.beginObject();
            try jws.objectField("lsb");
            try jws.write(Layout.bitOffset(field_tag));
            try jws.objectField("width");
            try jws.write(Layout.bitWidth(field_tag));

            switch (options.encoding) {
                .scalar => {
                    try jws.objectField("type");
                    try jws.write(options.type_name orelse publicTypeName(@FieldType(Layout.Zig, field)));
                },
                .@"packed" => |Nested| {
                    try jws.objectField("kind");
                    try jws.write("packed");
                    try jws.objectField("bits");
                    try jws.beginObject();
                    try writePackedBits(Nested, jws);
                    try jws.endObject();
                },
                .tagged_union => |UnionLayout| try writePackedTaggedUnion(Layout, UnionLayout, jws),
            }
            try jws.endObject();
        }
    }

    fn writePackedTaggedUnion(
        comptime Layout: type,
        comptime UnionLayout: type,
        jws: *std.json.Stringify,
    ) std.Io.Writer.Error!void {
        try jws.objectField("kind");
        try jws.write("union");
        try jws.objectField("tag");
        try jws.write(Layout.fieldName(UnionLayout.tag_field).?);
        try jws.objectField("arms");
        try jws.beginObject();

        const tag_options = Layout.fieldOptions(UnionLayout.tag_field);
        const tag_type_name = tag_options.type_name orelse publicTypeName(UnionLayout.Tag);
        inline for (@typeInfo(UnionLayout.Tag).@"enum".field_names) |tag| {
            try writeEnumObjectField(tag_type_name, tag, jws);
            const arm = UnionLayout.arm(@field(UnionLayout.Tag, tag)) orelse {
                try jws.write(null);
                continue;
            };
            switch (arm) {
                inline else => |ArmLayout| try writePackedArm(ArmLayout, jws),
            }
        }

        try jws.endObject();
    }

    fn writePackedArm(
        comptime Layout: type,
        jws: *std.json.Stringify,
    ) std.Io.Writer.Error!void {
        try jws.beginObject();
        try jws.objectField("kind");
        try jws.write("packed");
        try jws.objectField("width");
        try jws.write(@bitSizeOf(Layout.Zig));
        try jws.objectField("bits");
        try jws.beginObject();
        try writePackedBits(Layout, jws);
        try jws.endObject();
        try jws.endObject();
    }

    fn writeField(
        comptime decl: TypeDecl,
        comptime name: []const u8,
        comptime T: type,
        comptime offset: usize,
        jws: *std.json.Stringify,
    ) std.Io.Writer.Error!void {
        try jws.objectField(name);
        try jws.beginObject();
        try jws.objectField("offset");
        try jws.write(offset);
        try jws.objectField("size");
        try jws.write(@sizeOf(T));
        try writeFieldType(decl.name, name, T, jws);
        if (decl.tagged_union) |tagged| {
            if (std.mem.eql(u8, name, tagged.value_field)) {
                try jws.objectField("tag");
                try jws.write(tagged.tag_field);
                try writeTaggedArms(decl, tagged, jws);
            }
        }
        try jws.endObject();
    }

    fn writeSizeAlign(comptime T: type, jws: *std.json.Stringify) std.Io.Writer.Error!void {
        try jws.objectField("size");
        try jws.write(@sizeOf(T));
        try jws.objectField("align");
        try jws.write(@alignOf(T));
    }

    fn writeFieldType(
        comptime owner: []const u8,
        comptime field_name: []const u8,
        comptime T: type,
        jws: *std.json.Stringify,
    ) std.Io.Writer.Error!void {
        if (comptime std.mem.eql(u8, owner, "GhosttyCellsView") and
            std.mem.eql(u8, field_name, "ptr"))
        {
            try writePointerTypeNamed(T, true, "GhosttyCell", jws);
            return;
        }
        if (comptime std.mem.eql(u8, owner, "GhosttyGridRef") and
            std.mem.eql(u8, field_name, "node"))
        {
            try writePointerTypeNamed(T, true, "opaque", jws);
            return;
        }
        // Function pointer fields normally have the element type "function".
        // These name their typedefs so the manifest records each signature.
        if (comptime std.mem.eql(u8, owner, "GhosttyAllocatorVtable")) {
            const callback: ?[]const u8 = comptime if (std.mem.eql(u8, field_name, "alloc"))
                "GhosttyAllocatorAllocFn"
            else if (std.mem.eql(u8, field_name, "resize"))
                "GhosttyAllocatorResizeFn"
            else if (std.mem.eql(u8, field_name, "remap"))
                "GhosttyAllocatorRemapFn"
            else if (std.mem.eql(u8, field_name, "free"))
                "GhosttyAllocatorFreeFn"
            else
                null;
            if (comptime callback) |name| {
                try writePointerTypeNamed(T, @typeInfo(T) == .optional, name, jws);
                return;
            }
        }

        if (comptime fieldTypeOverride(owner, field_name)) |name| {
            try jws.objectField("type");
            try jws.write(name);
            return;
        }

        switch (@typeInfo(T)) {
            .array => |info| {
                try jws.objectField("type");
                try jws.write("array");
                try jws.objectField("elem");
                switch (@typeInfo(info.child)) {
                    // An array of pointers, such as the reserved slots of
                    // GhosttyAllocatorVtable, describes its element in the
                    // pointer field form.
                    .optional => |elem| {
                        try jws.beginObject();
                        try writePointerType(elem.child, true, jws);
                        try jws.endObject();
                    },
                    .pointer => {
                        try jws.beginObject();
                        try writePointerType(info.child, false, jws);
                        try jws.endObject();
                    },
                    else => try jws.write(publicTypeName(info.child)),
                }
                try jws.objectField("count");
                try jws.write(info.len);
            },
            .optional => |info| try writePointerType(info.child, true, jws),
            .pointer => try writePointerType(T, false, jws),
            else => {
                try jws.objectField("type");
                try jws.write(publicTypeName(T));
            },
        }
    }

    fn writePointerType(
        comptime T: type,
        comptime nullable: bool,
        jws: *std.json.Stringify,
    ) std.Io.Writer.Error!void {
        const info = @typeInfo(T).pointer;
        try jws.objectField("type");
        try jws.write("pointer");
        try jws.objectField("elem");
        try jws.write(publicTypeName(info.child));
        try jws.objectField("const");
        try jws.write(info.attrs.@"const");
        if (nullable) {
            try jws.objectField("nullable");
            try jws.write(true);
        }
    }

    fn writePointerTypeNamed(
        comptime T: type,
        comptime nullable: bool,
        comptime elem: []const u8,
        jws: *std.json.Stringify,
    ) std.Io.Writer.Error!void {
        const pointer_type = switch (@typeInfo(T)) {
            .optional => |info| info.child,
            .pointer => T,
            else => unreachable,
        };
        const info = @typeInfo(pointer_type).pointer;
        try jws.objectField("type");
        try jws.write("pointer");
        try jws.objectField("elem");
        try jws.write(elem);
        try jws.objectField("const");
        try jws.write(info.attrs.@"const");
        if (nullable) {
            try jws.objectField("nullable");
            try jws.write(true);
        }
    }

    fn fieldTypeOverride(comptime owner: []const u8, comptime field_name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, field_name, "value")) {
            if (std.mem.eql(u8, owner, "GhosttyPoint")) return "GhosttyPointValue";
            if (std.mem.eql(u8, owner, "GhosttySgrAttribute")) return "GhosttySgrAttributeValue";
            if (std.mem.eql(u8, owner, "GhosttyStyleColor")) return "GhosttyStyleColorValue";
            if (std.mem.eql(u8, owner, "GhosttyTerminalResizeWindow")) return "GhosttyTerminalResizeWindowValue";
            if (std.mem.eql(u8, owner, "GhosttyTerminalScrollViewport")) return "GhosttyTerminalScrollViewportValue";
            if (std.mem.eql(u8, owner, "GhosttyTerminalUnknownSequence")) return "GhosttyTerminalUnknownSequenceValue";
        }
        if (std.mem.eql(u8, owner, "GhosttyStyleColor") and std.mem.eql(u8, field_name, "tag"))
            return "GhosttyStyleColorTag";
        if (std.mem.eql(u8, owner, "GhosttyStyle") and std.mem.eql(u8, field_name, "flags"))
            return "GhosttyStyleFlags";
        if (std.mem.eql(u8, owner, "GhosttyStyleColorValue") and std.mem.eql(u8, field_name, "palette"))
            return "GhosttyColorPaletteIndex";
        if (std.mem.eql(u8, owner, "GhosttySgrAttributeValue")) {
            if (std.mem.eql(u8, field_name, "underline")) return "GhosttySgrUnderline";
            if (std.mem.endsWith(u8, field_name, "_8") or std.mem.endsWith(u8, field_name, "_256"))
                return "GhosttyColorPaletteIndex";
        }
        if (std.mem.eql(u8, owner, "GhosttyTerminalModeConfig") and std.mem.eql(u8, field_name, "mode"))
            return "GhosttyMode";
        return null;
    }

    fn writeTaggedArms(
        comptime decl: TypeDecl,
        comptime tagged: TypeDecl.TaggedUnion,
        jws: *std.json.Stringify,
    ) std.Io.Writer.Error!void {
        const Tag = tagged.tag_enum orelse @FieldType(decl.T, tagged.tag_field);
        try jws.objectField("arms");
        try jws.beginObject();
        inline for (@typeInfo(Tag).@"enum".field_names) |field| {
            try writeEnumObjectField(publicTypeName(Tag), field, jws);
            if (comptime taggedArm(decl, field)) |arm| try jws.write(arm) else try jws.write(null);
        }
        try jws.endObject();
    }

    fn taggedArm(comptime decl: TypeDecl, comptime tag_name: []const u8) ?[]const u8 {
        const tagged = decl.tagged_union.?;
        const Tag = tagged.tag_enum orelse @FieldType(decl.T, tagged.tag_field);
        if (tagged.arm_source == .generated)
            return decl.T.cFieldRename(@field(Tag, tag_name));

        const Value = @FieldType(decl.T, tagged.value_field);
        if (!@hasField(Value, tag_name)) return null;
        return if (@sizeOf(@FieldType(Value, tag_name)) == 0) null else tag_name;
    }

    fn publicTypeName(comptime T: type) []const u8 {
        inline for (type_decls) |decl| switch (decl.kind) {
            .@"struct", .@"union", .@"enum" => if (T == decl.T) return decl.name,
            .@"packed", .alias, .@"opaque", .callback => {},
        };
        return switch (@typeInfo(T)) {
            .bool => "bool",
            .float => |info| switch (info.bits) {
                32 => "f32",
                64 => "f64",
                else => "opaque",
            },
            .int => |info| intName(info.signedness, info.bits),
            .comptime_int => "comptime_int",
            .void => "void",
            .@"opaque" => "opaque",
            .@"fn" => "function",
            .@"enum" => "enum",
            .@"struct" => "struct",
            .@"union" => "union",
            else => "opaque",
        };
    }

    fn intName(comptime signedness: std.lang.Signedness, comptime bits: u16) []const u8 {
        return switch (signedness) {
            .signed => switch (bits) {
                8 => "i8",
                16 => "i16",
                32 => "i32",
                64 => "i64",
                else => std.fmt.comptimePrint("i{d}", .{bits}),
            },
            .unsigned => switch (bits) {
                8 => "u8",
                16 => "u16",
                32 => "u32",
                64 => "u64",
                else => std.fmt.comptimePrint("u{d}", .{bits}),
            },
        };
    }

    fn writeEnumObjectField(
        comptime enum_name: []const u8,
        comptime zig_name: []const u8,
        jws: *std.json.Stringify,
    ) std.Io.Writer.Error!void {
        try jws.objectField(comptime TypeDecl.enumValueName(enum_name, zig_name));
    }

    fn isBuiltinType(name: []const u8) bool {
        const builtins = [_][]const u8{
            "array", "bool",   "f32",     "f64", "function", "i8",  "i16", "i32",
            "i64",   "opaque", "pointer", "u8",  "u16",      "u32", "u64", "void",
        };
        for (builtins) |builtin_name| {
            if (std.mem.eql(u8, name, builtin_name)) return true;
        }
        if (name.len > 1 and (name[0] == 'i' or name[0] == 'u') and
            name[1] >= '1' and name[1] <= '9')
        {
            for (name[2..]) |c| if (!std.ascii.isDigit(c)) return false;
            return true;
        }
        return false;
    }
};

test "manifest parses and is versioned" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 1), root.get("schema").?.integer);
    try std.testing.expect(root.contains("abi"));
    try std.testing.expectEqual(
        @as(i64, c_abi.max_alignment),
        root.get("abi").?.object.get("max_alignment").?.integer,
    );
    try std.testing.expect(root.contains("library_version"));
    const manifest_types = root.get("types").?.object;
    try std.testing.expectEqual(type_decls.len, manifest_types.count());
    inline for (type_decls) |decl| try std.testing.expect(manifest_types.contains(decl.name));

    const cursor_fields = manifest_types.get("GhosttyRenderStateCursor").?.object
        .get("fields").?.object;
    try std.testing.expect(cursor_fields.contains("size"));
    try std.testing.expect(cursor_fields.contains("viewport_has_value"));
    try std.testing.expect(cursor_fields.contains("viewport_x"));
    try std.testing.expect(cursor_fields.contains("viewport_y"));
    try std.testing.expect(cursor_fields.contains("wide_tail"));
    try std.testing.expect(cursor_fields.contains("visible"));
    try std.testing.expect(cursor_fields.contains("blinking"));
    try std.testing.expect(cursor_fields.contains("password_input"));
    try std.testing.expect(cursor_fields.contains("visual_style"));
}

test "manifest describes enums, arrays, and tagged unions" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const manifest_types = parsed.value.object.get("types").?.object;

    const data = manifest_types.get("GhosttyRenderStateData").?.object;
    try std.testing.expectEqualStrings("enum", data.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, @backingInt(render.Data.dirty)), data.get("values").?.object.get("DIRTY").?.integer);

    const colors = manifest_types.get("GhosttyRenderStateColors").?.object;
    const palette = colors.get("fields").?.object.get("palette").?.object;
    try std.testing.expectEqualStrings("array", palette.get("type").?.string);
    try std.testing.expectEqualStrings("GhosttyColorRgb", palette.get("elem").?.string);
    try std.testing.expectEqual(@as(i64, 256), palette.get("count").?.integer);

    const style_color = manifest_types.get("GhosttyStyleColor").?.object;
    const value = style_color.get("fields").?.object.get("value").?.object;
    try std.testing.expectEqualStrings("GhosttyStyleColorValue", value.get("type").?.string);
    try std.testing.expectEqualStrings("tag", value.get("tag").?.string);
    try std.testing.expectEqualStrings("palette", value.get("arms").?.object.get("PALETTE").?.string);
    try std.testing.expect(value.get("arms").?.object.get("NONE").? == .null);
}

test "manifest describes the frozen style layout" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const manifest_types = parsed.value.object.get("types").?.object;

    // GhosttyStyle is a plain 16-byte struct on every target, with no
    // size field.
    const style_desc = manifest_types.get("GhosttyStyle").?.object;
    try std.testing.expectEqualStrings("struct", style_desc.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 16), style_desc.get("size").?.integer);
    try std.testing.expectEqual(@as(i64, 2), style_desc.get("align").?.integer);
    const style_fields = style_desc.get("fields").?.object;
    try std.testing.expectEqual(@as(usize, 5), style_fields.count());
    try std.testing.expect(!style_fields.contains("size"));
    const expected_style = [_]struct { []const u8, i64, i64, []const u8 }{
        .{ "fg_color", 0, 4, "GhosttyStyleColor" },
        .{ "bg_color", 4, 4, "GhosttyStyleColor" },
        .{ "underline_color", 8, 4, "GhosttyStyleColor" },
        .{ "flags", 12, 2, "GhosttyStyleFlags" },
        .{ "reserved", 14, 2, "u16" },
    };
    for (expected_style) |entry| {
        const name, const offset, const size, const type_name = entry;
        const field = style_fields.get(name).?.object;
        try std.testing.expectEqual(offset, field.get("offset").?.integer);
        try std.testing.expectEqual(size, field.get("size").?.integer);
        try std.testing.expectEqualStrings(type_name, field.get("type").?.string);
    }

    // The color is a byte tag followed by a three byte payload.
    const color_desc = manifest_types.get("GhosttyStyleColor").?.object;
    try std.testing.expectEqual(@as(i64, 4), color_desc.get("size").?.integer);
    try std.testing.expectEqual(@as(i64, 1), color_desc.get("align").?.integer);
    const color_fields = color_desc.get("fields").?.object;
    const tag = color_fields.get("tag").?.object;
    try std.testing.expectEqual(@as(i64, 0), tag.get("offset").?.integer);
    try std.testing.expectEqual(@as(i64, 1), tag.get("size").?.integer);
    try std.testing.expectEqualStrings("GhosttyStyleColorTag", tag.get("type").?.string);
    const value = color_fields.get("value").?.object;
    try std.testing.expectEqual(@as(i64, 1), value.get("offset").?.integer);
    try std.testing.expectEqual(@as(i64, 3), value.get("size").?.integer);
    try std.testing.expectEqualStrings("rgb", value.get("arms").?.object.get("RGB").?.string);
    try std.testing.expectEqual(@as(i64, 3), manifest_types.get("GhosttyStyleColorValue").?.object
        .get("size").?.integer);

    // The flags are a packed u16 matching the GHOSTTY_STYLE_FLAG_* bits.
    const flags_desc = manifest_types.get("GhosttyStyleFlags").?.object;
    try std.testing.expectEqualStrings("packed", flags_desc.get("kind").?.string);
    try std.testing.expectEqualStrings("u16", flags_desc.get("underlying").?.string);
    const flag_bits = flags_desc.get("bits").?.object;
    try std.testing.expectEqual(@as(usize, 9), flag_bits.count());
    const expected_flags = [_]struct { []const u8, i64, i64, []const u8 }{
        .{ "bold", 0, 1, "bool" },
        .{ "italic", 1, 1, "bool" },
        .{ "faint", 2, 1, "bool" },
        .{ "blink", 3, 1, "bool" },
        .{ "inverse", 4, 1, "bool" },
        .{ "invisible", 5, 1, "bool" },
        .{ "strikethrough", 6, 1, "bool" },
        .{ "overline", 7, 1, "bool" },
        .{ "underline", 8, 3, "GhosttySgrUnderline" },
    };
    for (expected_flags) |entry| {
        const name, const lsb, const width, const type_name = entry;
        const bit = flag_bits.get(name).?.object;
        try std.testing.expectEqual(lsb, bit.get("lsb").?.integer);
        try std.testing.expectEqual(width, bit.get("width").?.integer);
        try std.testing.expectEqualStrings(type_name, bit.get("type").?.string);
    }
}

test "manifest describes render state overscan types" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const manifest_types = parsed.value.object.get("types").?.object;

    const overscan = manifest_types.get("GhosttyRenderStateOverscan").?.object;
    try std.testing.expectEqual(@as(i64, 4), overscan.get("size").?.integer);
    const overscan_fields = overscan.get("fields").?.object;
    try std.testing.expectEqual(@as(i64, 0), overscan_fields.get("above").?.object.get("offset").?.integer);
    try std.testing.expectEqual(@as(i64, 2), overscan_fields.get("below").?.object.get("offset").?.integer);

    const row_id = manifest_types.get("GhosttyRenderStateRowId").?.object;
    try std.testing.expectEqual(@as(i64, 16), row_id.get("size").?.integer);
    const bits = row_id.get("fields").?.object.get("bits").?.object;
    try std.testing.expectEqual(@as(i64, 0), bits.get("offset").?.integer);
    try std.testing.expectEqualStrings("array", bits.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 2), bits.get("count").?.integer);

    const data_values = manifest_types.get("GhosttyRenderStateData").?.object
        .get("values").?.object;
    try std.testing.expectEqual(@as(i64, 20), data_values.get("OVERSCAN").?.integer);
    try std.testing.expectEqual(@as(i64, 21), data_values.get("OVERSCAN_REQUEST").?.integer);

    const row_data_values = manifest_types.get("GhosttyRenderStateRowData").?.object
        .get("values").?.object;
    try std.testing.expectEqual(@as(i64, 6), row_data_values.get("VIEWPORT_Y").?.integer);
    try std.testing.expectEqual(@as(i64, 7), row_data_values.get("ID").?.integer);

    const option_values = manifest_types.get("GhosttyRenderStateOption").?.object
        .get("values").?.object;
    try std.testing.expectEqual(@as(i64, 2), option_values.get("OVERSCAN").?.integer);
}

test "manifest describes the complete packed cell layout" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const manifest_types = parsed.value.object.get("types").?.object;
    const descriptor = manifest_types.get("GhosttyCell").?.object;

    try std.testing.expectEqualStrings("packed", descriptor.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, @sizeOf(page.Cell.CLayout.Zig)), descriptor.get("size").?.integer);
    try std.testing.expectEqualStrings("u64", descriptor.get("underlying").?.string);

    const bits = descriptor.get("bits").?.object;
    inline for (@typeInfo(page.Cell.CLayout.Zig).@"struct".field_names) |field| {
        const field_tag = @field(page.Cell.CLayout.Field, field);
        const name = comptime page.Cell.CLayout.fieldName(field_tag);
        if (name) |public_name| {
            const bit = bits.get(public_name).?.object;
            try std.testing.expectEqual(
                @as(i64, @intCast(@bitOffsetOf(page.Cell.CLayout.Zig, field))),
                bit.get("lsb").?.integer,
            );
            try std.testing.expectEqual(
                @as(i64, @intCast(@bitSizeOf(@FieldType(page.Cell.CLayout.Zig, field)))),
                bit.get("width").?.integer,
            );
        } else {
            try std.testing.expect(!bits.contains(field));
        }
    }

    const content = bits.get("content").?.object;
    try std.testing.expectEqualStrings("union", content.get("kind").?.string);
    try std.testing.expectEqualStrings("content_tag", content.get("tag").?.string);
    const arms = content.get("arms").?.object;

    const Content = @FieldType(page.Cell.CLayout.Zig, "content");
    const Codepoint = @FieldType(Content, "codepoint");
    const codepoint = arms.get("CODEPOINT").?.object;
    const grapheme = arms.get("CODEPOINT_GRAPHEME").?.object;
    try expectPackedArmField(codepoint, "codepoint", Codepoint, "data", "u21");
    try expectPackedArmField(grapheme, "codepoint", Codepoint, "data", "u21");
    try expectPackedArmField(
        arms.get("BG_COLOR_PALETTE").?.object,
        "index",
        @FieldType(Content, "color_palette"),
        "data",
        "GhosttyColorPaletteIndex",
    );

    const rgb = arms.get("BG_COLOR_RGB").?.object;
    const Rgb = @FieldType(Content, "color_rgb");
    inline for (@typeInfo(Rgb).@"struct".field_names) |field|
        try expectPackedArmField(rgb, field, Rgb, field, "u8");
}

test "manifest packed cell layouts decode real values" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const manifest_types = parsed.value.object.get("types").?.object;
    const cell_bits = manifest_types.get("GhosttyCell").?.object.get("bits").?.object;

    var codepoint = page.Cell.CLayout.Zig.init('A');
    try expectDecodedCellContent(manifest_types, cell_bits, @bitCast(codepoint), "codepoint", 'A');

    codepoint.content_tag = .codepoint_grapheme;
    try expectDecodedCellContent(manifest_types, cell_bits, @bitCast(codepoint), "codepoint", 'A');

    var palette: page.Cell.CLayout.Zig = @bitCast(@as(u64, 0));
    palette.content_tag = .bg_color_palette;
    palette.content = .{ .color_palette = .{ .data = 173 } };
    try expectDecodedCellContent(manifest_types, cell_bits, @bitCast(palette), "index", 173);

    var rgb: page.Cell.CLayout.Zig = @bitCast(@as(u64, 0));
    rgb.content_tag = .bg_color_rgb;
    rgb.content = .{ .color_rgb = .{ .r = 0x12, .g = 0x34, .b = 0x56 } };
    const rgb_arm = activeCellContentArm(manifest_types, cell_bits, @bitCast(rgb));
    const content = extractManifestBits(@bitCast(rgb), cell_bits.get("content").?.object);
    try std.testing.expectEqual(@as(u64, 0x12), extractManifestBits(content, rgb_arm.get("bits").?.object.get("r").?.object));
    try std.testing.expectEqual(@as(u64, 0x34), extractManifestBits(content, rgb_arm.get("bits").?.object.get("g").?.object));
    try std.testing.expectEqual(@as(u64, 0x56), extractManifestBits(content, rgb_arm.get("bits").?.object.get("b").?.object));
}

test "manifest uses public enum names" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const manifest_types = parsed.value.object.get("types").?.object;

    const cell_content = manifest_types.get("GhosttyCellContentTag").?.object.get("values").?.object;
    try std.testing.expect(cell_content.contains("TAG_MAX_VALUE"));
    try std.testing.expect(!cell_content.contains("MAX_VALUE"));

    const sgr_values = manifest_types.get("GhosttySgrAttributeTag").?.object.get("values").?.object;
    try std.testing.expectEqual(@as(i64, 9), sgr_values.get("UNDERLINE_COLOR_256").?.integer);
    try std.testing.expectEqual(@as(i64, 23), sgr_values.get("BG_8").?.integer);
    try std.testing.expect(!sgr_values.contains("256_UNDERLINE_COLOR"));

    const sgr_arms = manifest_types.get("GhosttySgrAttribute").?.object
        .get("fields").?.object.get("value").?.object.get("arms").?.object;
    try std.testing.expectEqualStrings("underline_color_256", sgr_arms.get("UNDERLINE_COLOR_256").?.string);
    try std.testing.expectEqualStrings("bg_8", sgr_arms.get("BG_8").?.string);

    const terminal_values = manifest_types.get("GhosttyTerminalOption").?.object.get("values").?.object;
    try std.testing.expectEqual(@as(i64, 7), terminal_values.get("SIZE").?.integer);
    try std.testing.expect(!terminal_values.contains("SIZE_CB"));
    try std.testing.expectEqual(@as(i64, 43), terminal_values.get("SEMANTIC_PROMPT").?.integer);
    try std.testing.expectEqual(@as(i64, 44), terminal_values.get("RESET").?.integer);

    const semantic_prompt_values = manifest_types.get("GhosttySemanticPromptKind").?.object.get("values").?.object;
    try std.testing.expectEqual(@as(i64, 0), semantic_prompt_values.get("INVALID").?.integer);
    try std.testing.expectEqual(@as(i64, 4), semantic_prompt_values.get("COMMAND_END").?.integer);

    const prompt_kind_values = manifest_types.get("GhosttySemanticPromptPromptKind").?.object.get("values").?.object;
    try std.testing.expectEqual(@as(i64, 3), prompt_kind_values.get("SECONDARY").?.integer);

    const osc_values = manifest_types.get("GhosttyOscCommandType").?.object.get("values").?.object;
    try std.testing.expectEqual(@as(i64, 22), osc_values.get("KITTY_TEXT_SIZING").?.integer);
    try std.testing.expectEqual(@as(i64, 23), osc_values.get("KITTY_CLIPBOARD_PROTOCOL").?.integer);
    try std.testing.expectEqual(@as(i64, 24), osc_values.get("KITTY_DND_PROTOCOL").?.integer);
    try std.testing.expectEqual(@as(i64, 25), osc_values.get("HIERARCHICAL_CONTEXT").?.integer);
    try std.testing.expectEqual(@as(i64, 26), osc_values.get("KITTY_DESKTOP_NOTIFICATION").?.integer);
    try std.testing.expect(osc_values.contains("TYPE_MAX_VALUE"));
    try std.testing.expect(!osc_values.contains("MAX_VALUE"));

    const mouse_shape_values = manifest_types.get("GhosttyMouseShape").?.object.get("values").?.object;
    try std.testing.expectEqual(@as(i64, 8), mouse_shape_values.get("TEXT").?.integer);
    try std.testing.expectEqual(@as(i64, 33), mouse_shape_values.get("ZOOM_OUT").?.integer);
    try std.testing.expect(mouse_shape_values.contains("MAX_VALUE"));

    const terminal_data_values = manifest_types.get("GhosttyTerminalData").?.object.get("values").?.object;
    try std.testing.expectEqual(@as(i64, 41), terminal_data_values.get("MOUSE_SHAPE").?.integer);

    const key_values = manifest_types.get("GhosttyKey").?.object.get("values").?.object;
    try std.testing.expect(key_values.contains("A"));
    try std.testing.expect(!key_values.contains("KEY_A"));

    const mode_values = manifest_types.get("GhosttyModeReportState").?.object.get("values").?.object;
    try std.testing.expectEqual(@as(i64, 0), mode_values.get("NOT_RECOGNIZED").?.integer);
    try std.testing.expectEqual(@as(i64, 4), mode_values.get("PERMANENTLY_RESET").?.integer);

    const kitty_kind_values = manifest_types.get("GhosttyRenderStateKittyPlacementKind").?.object.get("values").?.object;
    try std.testing.expectEqual(@as(i64, 1), kitty_kind_values.get("RELATIVE").?.integer);
    try std.testing.expectEqual(@as(i64, 2), kitty_kind_values.get("FIXED").?.integer);
}

test "manifest named references resolve" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const manifest_types = parsed.value.object.get("types").?.object;

    var type_iterator = manifest_types.iterator();
    while (type_iterator.next()) |type_entry| {
        const descriptor = type_entry.value_ptr.object;
        if (descriptor.get("bits")) |bits_value| {
            try expectManifestBitsValid(
                manifest_types,
                bits_value.object,
                @intCast(descriptor.get("size").?.integer * 8),
            );
        }
        const fields_value = descriptor.get("fields") orelse continue;
        var field_iterator = fields_value.object.iterator();
        while (field_iterator.next()) |field_entry| {
            const field = field_entry.value_ptr.object;
            const field_type = field.get("type").?.string;
            try expectTypeReferenceResolves(manifest_types, field);

            if (field.get("arms")) |arms_value| {
                const union_descriptor = manifest_types.get(field_type).?.object;
                const union_fields = union_descriptor.get("fields").?.object;
                const tag_field_name = field.get("tag").?.string;
                const tag_type_name = fields_value.object.get(tag_field_name).?.object.get("type").?.string;
                const tag_values = manifest_types.get(tag_type_name).?.object.get("values").?.object;
                var arm_iterator = arms_value.object.iterator();
                while (arm_iterator.next()) |arm_entry| {
                    try std.testing.expect(tag_values.contains(arm_entry.key_ptr.*));
                    if (arm_entry.value_ptr.* == .null) continue;
                    try std.testing.expect(union_fields.contains(arm_entry.value_ptr.string));
                }
            }
        }
    }

    // Key value types, callback parameters and callback return types.
    type_iterator = manifest_types.iterator();
    while (type_iterator.next()) |type_entry| {
        const descriptor = type_entry.value_ptr.object;
        if (descriptor.get("keys")) |keys| {
            const values = descriptor.get("values").?.object;
            var key_iterator = keys.object.iterator();
            while (key_iterator.next()) |key_entry| {
                try std.testing.expect(values.contains(key_entry.key_ptr.*));
                try expectTypeReferenceResolves(manifest_types, key_entry.value_ptr.object);
            }
        }
        if (descriptor.get("params")) |params| {
            for (params.array.items) |param|
                try expectTypeReferenceResolves(manifest_types, param.object);
            try expectTypeReferenceResolves(manifest_types, descriptor.get("return").?.object);
        }
    }
}

test "manifest types the value of every key" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const manifest_types = parsed.value.object.get("types").?.object;

    // Every get or set key enum has a keys object with every key but
    // INVALID, and no other enum has one.
    inline for (type_decls) |decl| {
        if (decl.kind != .@"enum") continue;
        const descriptor = manifest_types.get(decl.name).?.object;
        if (comptime Json.keyDirection(decl) == null) {
            try std.testing.expect(!descriptor.contains("keys"));
            continue;
        }
        const keys = descriptor.get("keys").?.object;
        const values = descriptor.get("values").?.object;
        try std.testing.expect(!keys.contains("INVALID"));
        try std.testing.expect(!keys.contains(decl.sentinel_suffix));
        // Every value except INVALID and the sentinel is a key.
        const skipped: usize = if (values.contains("INVALID")) 2 else 1;
        try std.testing.expectEqual(values.count() - skipped, keys.count());
    }

    const usize_name = comptime Json.publicTypeName(usize);
    const expected = [_]struct { []const u8, []const u8, []const u8, []const u8 }{
        // Input keys whose InType is the value pointer itself.
        .{ "GhosttyTerminalOption", "SCROLLBACK_MAX_BYTES", "in", usize_name },
        .{ "GhosttyTerminalOption", "TITLE", "in", "GhosttyString" },
        .{ "GhosttyTerminalOption", "SELECTION", "in", "GhosttySelection" },
        .{ "GhosttyTerminalOption", "USERDATA", "in", "opaque" },
        .{ "GhosttyTerminalOption", "BELL", "in", "GhosttyTerminalBellFn" },
        .{ "GhosttyTerminalOption", "RESET", "in", "GhosttyTerminalResetFn" },
        .{ "GhosttyTerminalOption", "SIZE", "in", "GhosttyTerminalSizeFn" },
        .{ "GhosttySysOption", "LOG", "in", "GhosttySysLogFn" },
        // Input keys whose InType is the value itself.
        .{ "GhosttyKeyEncoderOption", "ALT_ESC_PREFIX", "in", "bool" },
        .{ "GhosttyKeyEncoderOption", "KITTY_FLAGS", "in", "GhosttyKittyKeyFlags" },
        .{ "GhosttyMouseEncoderOption", "SIZE", "in", "GhosttyMouseEncoderSize" },
        .{ "GhosttyKittyGraphicsPlacementIteratorOption", "LAYER", "in", "u32" },
        .{ "GhosttyFormatterOption", "EMIT", "in", "GhosttyFormatterFormat" },
        .{ "GhosttyFormatterOption", "SELECTION", "in", "GhosttySelection" },
        .{ "GhosttyFormatterOption", "EXTRAS", "in", "GhosttyFormatterExtras" },
        .{ "GhosttyOscOption", "UNKNOWN_MAX_BYTES", "in", usize_name },
        .{ "GhosttySearchOption", "NEEDLE", "in", "GhosttyString" },
        .{ "GhosttySelectionGestureEventOption", "REF", "in", "GhosttyGridRef" },
        .{ "GhosttySelectionGestureEventOption", "REPEAT_DISTANCE", "in", "f64" },
        .{ "GhosttySnapshotDecoderOption", "MAX_CONTINUATION_BYTES", "in", usize_name },
        .{ "GhosttySnapshotDecoderOption", "KITTY_IMAGE_STORAGE_LIMIT", "in", "u64" },
        // Output keys.
        .{ "GhosttyBuildInfo", "VERSION_STRING", "out", "GhosttyString" },
        .{ "GhosttyBuildInfo", "VERSION_MAJOR", "out", usize_name },
        .{ "GhosttyBuildInfo", "OPTIMIZE", "out", "GhosttyOptimizeMode" },
        .{ "GhosttyBuildInfo", "KITTY_GRAPHICS", "out", "bool" },
        .{ "GhosttyTerminalData", "KITTY_GRAPHICS", "out", "GhosttyKittyGraphics" },
        .{ "GhosttyKittyGraphicsData", "PLACEMENT_ITERATOR", "out", "GhosttyKittyGraphicsPlacementIterator" },
        .{ "GhosttyRenderStateData", "ROW_ITERATOR", "out", "GhosttyRenderStateRowIterator" },
        .{ "GhosttyRenderStateRowData", "RAW", "out", "GhosttyRow" },
        .{ "GhosttyRenderStateRowCellsData", "RAW", "out", "GhosttyCell" },
        .{ "GhosttyCellData", "STYLE_ID", "out", "GhosttyStyleId" },
        .{ "GhosttyTerminalData", "COLS", "out", "u16" },
        .{ "GhosttySnapshotDecoderData", "PROGRESS_SCREEN", "out", "GhosttyTerminalScreen" },
    };
    for (expected) |entry| {
        const enum_name, const key_name, const direction, const type_name = entry;
        errdefer std.log.err("{s} {s}", .{ enum_name, key_name });
        const key = manifest_types.get(enum_name).?.object
            .get("keys").?.object.get(key_name).?.object;
        try std.testing.expectEqualStrings(direction, key.get("direction").?.string);
        try std.testing.expectEqualStrings(type_name, key.get("type").?.string);
    }

    // The palette is an array value.
    const palette = manifest_types.get("GhosttyTerminalOption").?.object
        .get("keys").?.object.get("COLOR_PALETTE").?.object;
    try std.testing.expectEqualStrings("array", palette.get("type").?.string);
    try std.testing.expectEqualStrings("GhosttyColorRgb", palette.get("elem").?.string);
    try std.testing.expectEqual(@as(i64, 256), palette.get("count").?.integer);

    // Every feature key reports a bool.
    var build_keys = manifest_types.get("GhosttyBuildInfo").?.object
        .get("keys").?.object.iterator();
    var features: usize = 0;
    while (build_keys.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.key_ptr.*, "FEATURE_")) continue;
        features += 1;
        try std.testing.expectEqualStrings("bool", entry.value_ptr.object.get("type").?.string);
    }
    try std.testing.expectEqual(@as(usize, 9), features);
}

test "manifest describes callback signatures" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const manifest_types = parsed.value.object.get("types").?.object;

    const bell = manifest_types.get("GhosttyTerminalBellFn").?.object;
    try std.testing.expectEqualStrings("callback", bell.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, @sizeOf(*anyopaque)), bell.get("size").?.integer);
    const bell_params = bell.get("params").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), bell_params.len);
    try std.testing.expectEqualStrings("GhosttyTerminal", bell_params[0].object.get("type").?.string);
    const userdata = bell_params[1].object;
    try std.testing.expectEqualStrings("pointer", userdata.get("type").?.string);
    try std.testing.expectEqualStrings("opaque", userdata.get("elem").?.string);
    try std.testing.expect(!userdata.get("const").?.bool);
    try std.testing.expect(userdata.get("nullable").?.bool);
    try std.testing.expectEqualStrings("void", bell.get("return").?.object.get("type").?.string);

    const write_pty = manifest_types.get("GhosttyTerminalWritePtyFn").?.object
        .get("params").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), write_pty.len);
    const data = write_pty[2].object;
    try std.testing.expectEqualStrings("pointer", data.get("type").?.string);
    try std.testing.expectEqualStrings("u8", data.get("elem").?.string);
    try std.testing.expect(data.get("const").?.bool);
    try std.testing.expect(!data.contains("nullable"));

    const enquiry = manifest_types.get("GhosttyTerminalEnquiryFn").?.object;
    try std.testing.expectEqualStrings("GhosttyString", enquiry.get("return").?.object.get("type").?.string);

    // An array of nullable pointers describes its element as a pointer.
    const reserved = manifest_types.get("GhosttyAllocatorVtable").?.object
        .get("fields").?.object.get("reserved").?.object;
    try std.testing.expectEqualStrings("array", reserved.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 4), reserved.get("count").?.integer);
    const slot = reserved.get("elem").?.object;
    try std.testing.expectEqualStrings("pointer", slot.get("type").?.string);
    try std.testing.expectEqualStrings("opaque", slot.get("elem").?.string);
    try std.testing.expect(slot.get("nullable").?.bool);
}

/// Check that the names in a type reference, such as a field, a key value
/// or a callback parameter, are built in or registered.
fn expectTypeReferenceResolves(
    manifest_types: std.json.ObjectMap,
    reference: std.json.ObjectMap,
) !void {
    const type_name = reference.get("type").?.string;
    if (!Json.isBuiltinType(type_name))
        try std.testing.expect(manifest_types.contains(type_name));

    const elem = reference.get("elem") orelse return;
    switch (elem) {
        .string => |name| if (!Json.isBuiltinType(name))
            try std.testing.expect(manifest_types.contains(name)),
        .object => |pointer| {
            try std.testing.expectEqualStrings("pointer", pointer.get("type").?.string);
            try expectTypeReferenceResolves(manifest_types, pointer);
        },
        else => return error.TestUnexpectedResult,
    }
}

fn expectPackedArmField(
    arm: std.json.ObjectMap,
    manifest_name: []const u8,
    comptime T: type,
    comptime zig_name: []const u8,
    expected_type: []const u8,
) !void {
    try std.testing.expectEqualStrings("packed", arm.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, @bitSizeOf(T)), arm.get("width").?.integer);
    const bit = arm.get("bits").?.object.get(manifest_name).?.object;
    try std.testing.expectEqual(@as(i64, @bitOffsetOf(T, zig_name)), bit.get("lsb").?.integer);
    try std.testing.expectEqual(@as(i64, @bitSizeOf(@FieldType(T, zig_name))), bit.get("width").?.integer);
    try std.testing.expectEqualStrings(expected_type, bit.get("type").?.string);
}

fn extractManifestBits(value: u64, bit: std.json.ObjectMap) u64 {
    const lsb: u6 = @intCast(bit.get("lsb").?.integer);
    const width: u7 = @intCast(bit.get("width").?.integer);
    const mask = if (width == 64)
        std.math.maxInt(u64)
    else
        (@as(u64, 1) << @intCast(width)) - 1;
    return (value >> lsb) & mask;
}

fn activeCellContentArm(
    manifest_types: std.json.ObjectMap,
    cell_bits: std.json.ObjectMap,
    raw: u64,
) std.json.ObjectMap {
    const content_tag = cell_bits.get("content_tag").?.object;
    const value = extractManifestBits(raw, content_tag);
    const enum_values = manifest_types.get(content_tag.get("type").?.string).?.object
        .get("values").?.object;
    var iterator = enum_values.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.integer == value)
            return cell_bits.get("content").?.object.get("arms").?.object
                .get(entry.key_ptr.*).?.object;
    }
    unreachable;
}

fn expectDecodedCellContent(
    manifest_types: std.json.ObjectMap,
    cell_bits: std.json.ObjectMap,
    raw: u64,
    field_name: []const u8,
    expected: u64,
) !void {
    const arm = activeCellContentArm(manifest_types, cell_bits, raw);
    const content = extractManifestBits(raw, cell_bits.get("content").?.object);
    try std.testing.expectEqual(
        expected,
        extractManifestBits(content, arm.get("bits").?.object.get(field_name).?.object),
    );
}

fn expectManifestBitsValid(
    manifest_types: std.json.ObjectMap,
    bits: std.json.ObjectMap,
    container_width: usize,
) !void {
    var iterator = bits.iterator();
    while (iterator.next()) |entry| {
        const bit = entry.value_ptr.object;
        const lsb: usize = @intCast(bit.get("lsb").?.integer);
        const width: usize = @intCast(bit.get("width").?.integer);
        try std.testing.expect(lsb + width <= container_width);

        if (bit.get("type")) |type_value| {
            const type_name = type_value.string;
            try std.testing.expect(Json.isBuiltinType(type_name) or manifest_types.contains(type_name));
            continue;
        }

        const kind = bit.get("kind").?.string;
        if (std.mem.eql(u8, kind, "packed")) {
            try expectManifestBitsValid(manifest_types, bit.get("bits").?.object, width);
            continue;
        }

        try std.testing.expectEqualStrings("union", kind);
        const tag_name = bit.get("tag").?.string;
        const tag = bits.get(tag_name).?.object;
        const enum_values = manifest_types.get(tag.get("type").?.string).?.object
            .get("values").?.object;
        var arm_iterator = bit.get("arms").?.object.iterator();
        while (arm_iterator.next()) |arm_entry| {
            try std.testing.expect(enum_values.contains(arm_entry.key_ptr.*));
            if (arm_entry.value_ptr.* == .null) continue;
            const arm = arm_entry.value_ptr.object;
            const arm_width: usize = @intCast(arm.get("width").?.integer);
            try std.testing.expect(arm_width <= width);
            try expectManifestBitsValid(manifest_types, arm.get("bits").?.object, arm_width);
        }
    }
}
