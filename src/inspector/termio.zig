const std = @import("std");
const Allocator = std.mem.Allocator;
const cimgui = @import("cimgui");
const terminal = @import("../terminal/main.zig");
const CircBuf = @import("../datastruct/main.zig").CircBuf;
const Surface = @import("../Surface.zig");

/// The stream handler for our inspector.
pub const Stream = terminal.Stream(VTHandler);

/// VT event circular buffer.
pub const VTEventRing = CircBuf(VTEvent, undefined);

/// VT event
pub const VTEvent = struct {
    /// Sequence number, just monotonically increasing.
    seq: usize = 1,

    /// Kind of event, for filtering
    kind: Kind,

    /// The formatted string of the event. This is allocated. We format the
    /// event for now because there is so much data to copy if we wanted to
    /// store the raw event.
    str: [:0]const u8,

    /// Various metadata at the time of the event (before processing).
    cursor: terminal.Screen.Cursor,
    scrolling_region: terminal.Terminal.ScrollingRegion,
    metadata: Metadata.Unmanaged = .{},

    /// imgui selection state
    imgui_selected: bool = false,

    const Kind = enum { print, execute, csi, esc, osc, dcs, apc };
    const Metadata = std.StringHashMap([:0]const u8);

    /// Initialize the event information for the given parser action.
    pub fn init(
        alloc: Allocator,
        surface: *Surface,
        action: terminal.Parser.Action,
    ) !VTEvent {
        var md = Metadata.init(alloc);
        errdefer md.deinit();
        var buf = std.ArrayList(u8).init(alloc);
        defer buf.deinit();
        try encodeAction(alloc, buf.writer(), &md, action);
        const str = try buf.toOwnedSliceSentinel(0);
        errdefer alloc.free(str);

        const kind: Kind = switch (action) {
            .print => .print,
            .execute => .execute,
            .csi_dispatch => .csi,
            .esc_dispatch => .esc,
            .osc_dispatch => .osc,
            .dcs_hook, .dcs_put, .dcs_unhook => .dcs,
            .apc_start, .apc_put, .apc_end => .apc,
        };

        const t = surface.renderer_state.terminal;

        return .{
            .kind = kind,
            .str = str,
            .cursor = t.screen.cursor,
            .scrolling_region = t.scrolling_region,
            .metadata = md.unmanaged,
        };
    }

    pub fn deinit(self: *VTEvent, alloc: Allocator) void {
        {
            var it = self.metadata.valueIterator();
            while (it.next()) |v| alloc.free(v.*);
            self.metadata.deinit(alloc);
        }

        alloc.free(self.str);
    }

    /// Returns true if the event passes the given filter.
    pub fn passFilter(
        self: *const VTEvent,
        filter: *cimgui.c.ImGuiTextFilter,
    ) bool {
        // Check our main string
        if (cimgui.c.ImGuiTextFilter_PassFilter(
            filter,
            self.str.ptr,
            null,
        )) return true;

        // We also check all metadata keys and values
        var it = self.metadata.iterator();
        while (it.next()) |entry| {
            var buf: [256]u8 = undefined;
            const key = std.fmt.bufPrintZ(&buf, "{s}", .{entry.key_ptr.*}) catch continue;
            if (cimgui.c.ImGuiTextFilter_PassFilter(
                filter,
                key.ptr,
                null,
            )) return true;
            if (cimgui.c.ImGuiTextFilter_PassFilter(
                filter,
                entry.value_ptr.ptr,
                null,
            )) return true;
        }

        return false;
    }

    /// Encode a parser action as a string that we show in the logs.
    fn encodeAction(
        alloc: Allocator,
        writer: anytype,
        md: *Metadata,
        action: terminal.Parser.Action,
    ) !void {
        switch (action) {
            .print => try encodePrint(writer, action),
            .execute => try encodeExecute(writer, action),
            .csi_dispatch => |v| try encodeCSI(writer, v),
            .esc_dispatch => |v| try encodeEsc(writer, v),
            .osc_dispatch => |v| try encodeOSC(alloc, writer, md, v),
            else => try writer.print("{}", .{action}),
        }
    }

    fn encodePrint(writer: anytype, action: terminal.Parser.Action) !void {
        const ch = action.print;
        try writer.print("'{u}' (U+{X})", .{ ch, ch });
    }

    fn encodeExecute(writer: anytype, action: terminal.Parser.Action) !void {
        const ch = action.execute;
        switch (ch) {
            0x00 => try writer.writeAll("NUL"),
            0x01 => try writer.writeAll("SOH"),
            0x02 => try writer.writeAll("STX"),
            0x03 => try writer.writeAll("ETX"),
            0x04 => try writer.writeAll("EOT"),
            0x05 => try writer.writeAll("ENQ"),
            0x06 => try writer.writeAll("ACK"),
            0x07 => try writer.writeAll("BEL"),
            0x08 => try writer.writeAll("BS"),
            0x09 => try writer.writeAll("HT"),
            0x0A => try writer.writeAll("LF"),
            0x0B => try writer.writeAll("VT"),
            0x0C => try writer.writeAll("FF"),
            0x0D => try writer.writeAll("CR"),
            0x0E => try writer.writeAll("SO"),
            0x0F => try writer.writeAll("SI"),
            else => try writer.writeAll("?"),
        }
        try writer.print(" (0x{X})", .{ch});
    }

    fn encodeCSI(writer: anytype, csi: terminal.Parser.Action.CSI) !void {
        for (csi.intermediates) |v| try writer.print("{c} ", .{v});
        for (csi.params, 0..) |v, i| {
            if (i != 0) try writer.writeByte(';');
            try writer.print("{d}", .{v});
        }
        if (csi.intermediates.len > 0 or csi.params.len > 0) try writer.writeByte(' ');
        try writer.writeByte(csi.final);
    }

    fn encodeEsc(writer: anytype, esc: terminal.Parser.Action.ESC) !void {
        for (esc.intermediates) |v| try writer.print("{c} ", .{v});
        try writer.writeByte(esc.final);
    }

    fn encodeOSC(
        alloc: Allocator,
        writer: anytype,
        md: *Metadata,
        osc: terminal.osc.Command,
    ) !void {
        // The description is just the tag
        try writer.print("{s} ", .{@tagName(osc)});

        // Add additional fields to metadata
        switch (osc) {
            inline else => |v, tag| if (tag == osc) {
                try encodeMetadata(alloc, md, v);
            },
        }
    }

    fn encodeMetadata(
        alloc: Allocator,
        md: *Metadata,
        v: anytype,
    ) !void {
        switch (@TypeOf(v)) {
            void => {},
            []const u8 => try md.put("data", try alloc.dupeZ(u8, v)),
            else => |T| switch (@typeInfo(T)) {
                .@"struct" => |info| inline for (info.fields) |field| {
                    try encodeMetadataSingle(
                        alloc,
                        md,
                        field.name,
                        @field(v, field.name),
                    );
                },

                .@"union" => |info| {
                    const Tag = info.tag_type orelse @compileError("Unions must have a tag");
                    const tag_name = @tagName(@as(Tag, v));
                    inline for (info.fields) |field| {
                        if (std.mem.eql(u8, field.name, tag_name)) {
                            if (field.type == void) {
                                break try md.put("data", tag_name);
                            } else {
                                break try encodeMetadataSingle(alloc, md, tag_name, @field(v, field.name));
                            }
                        }
                    }
                },

                else => {
                    @compileLog(T);
                    @compileError("unsupported type, see log");
                },
            },
        }
    }

    fn encodeMetadataSingle(
        alloc: Allocator,
        md: *Metadata,
        key: []const u8,
        value: anytype,
    ) !void {
        const Value = @TypeOf(value);
        const info = @typeInfo(Value);
        switch (info) {
            .optional => if (value) |unwrapped| {
                try encodeMetadataSingle(alloc, md, key, unwrapped);
            } else {
                try md.put(key, try alloc.dupeZ(u8, "(unset)"));
            },

            .bool => try md.put(
                key,
                try alloc.dupeZ(u8, if (value) "true" else "false"),
            ),

            .@"enum" => try md.put(
                key,
                try alloc.dupeZ(u8, @tagName(value)),
            ),

            .@"union" => |u| {
                const Tag = u.tag_type orelse @compileError("Unions must have a tag");
                const tag_name = @tagName(@as(Tag, value));
                inline for (u.fields) |field| {
                    if (std.mem.eql(u8, field.name, tag_name)) {
                        const s = if (field.type == void)
                            try alloc.dupeZ(u8, tag_name)
                        else
                            try std.fmt.allocPrintZ(alloc, "{s}={}", .{
                                tag_name,
                                @field(value, field.name),
                            });

                        try md.put(key, s);
                    }
                }
            },

            .@"struct" => try md.put(
                key,
                try alloc.dupeZ(u8, @typeName(Value)),
            ),

            else => switch (Value) {
                u8, u16 => try md.put(
                    key,
                    try std.fmt.allocPrintZ(alloc, "{}", .{value}),
                ),

                []const u8 => try md.put(key, try alloc.dupeZ(u8, value)),

                else => |T| {
                    @compileLog(T);
                    @compileError("unsupported type, see log");
                },
            },
        }
    }
};

/// Our VT stream handler.
pub const VTHandler = struct {
    /// The surface that the inspector is attached to. We use this instead
    /// of the inspector because this is pointer-stable.
    surface: *Surface,

    /// True if the handler is currently recording.
    active: bool = true,

    /// Current sequence number
    current_seq: usize = 1,

    /// Exclude certain actions by tag.
    filter_exclude: ActionTagSet = .initMany(&.{.print}),
    filter_text: *cimgui.c.ImGuiTextFilter,

    const ActionTagSet = std.EnumSet(terminal.Parser.Action.Tag);

    pub fn init(surface: *Surface) VTHandler {
        return .{
            .surface = surface,
            .filter_text = cimgui.c.ImGuiTextFilter_ImGuiTextFilter(""),
        };
    }

    pub fn deinit(self: *VTHandler) void {
        cimgui.c.ImGuiTextFilter_destroy(self.filter_text);
    }

    /// This is called with every single terminal action.
    pub fn handleManually(self: *VTHandler, action: terminal.Parser.Action) !bool {
        const insp = self.surface.inspector orelse return false;

        // We always increment the sequence number, even if we're paused or
        // filter out the event. This helps show the user that there is a gap
        // between events and roughly how large that gap was.
        defer self.current_seq +%= 1;

        // If we're pausing, then we ignore all events.
        if (!self.active) return true;

        // We ignore certain action types that are too noisy.
        switch (action) {
            .dcs_put, .apc_put => return true,
            else => {},
        }

        // If we requested a specific type to be ignored, ignore it.
        // We return true because we did "handle" it by ignoring it.
        if (self.filter_exclude.contains(std.meta.activeTag(action))) return true;

        // Build our event
        const alloc = self.surface.alloc;
        var ev = try VTEvent.init(alloc, self.surface, action);
        ev.seq = self.current_seq;
        errdefer ev.deinit(alloc);

        // Check if the event passes the filter
        if (!ev.passFilter(self.filter_text)) {
            ev.deinit(alloc);
            return true;
        }

        const max_capacity = 100;
        insp.vt_events.append(ev) catch |err| switch (err) {
            error.OutOfMemory => if (insp.vt_events.capacity() < max_capacity) {
                // We're out of memory, but we can allocate to our capacity.
                const new_capacity = @min(insp.vt_events.capacity() * 2, max_capacity);
                try insp.vt_events.resize(insp.surface.alloc, new_capacity);
                try insp.vt_events.append(ev);
            } else {
                var it = insp.vt_events.iterator(.forward);
                if (it.next()) |old_ev| old_ev.deinit(insp.surface.alloc);
                insp.vt_events.deleteOldest(1);
                try insp.vt_events.append(ev);
            },

            else => return err,
        };

        return true;
    }
};
