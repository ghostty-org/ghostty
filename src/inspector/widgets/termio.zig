const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const cimgui = @import("dcimgui");
const terminal = @import("../../terminal/main.zig");
const CircBuf = @import("../../datastruct/main.zig").CircBuf;
const Surface = @import("../../Surface.zig");
const screen = @import("screen.zig");

/// VT event stream inspector widget.
pub const Stream = struct {
    events: VTEvent.Ring,
    parser_stream: VTHandler.Stream,

    /// The currently selected event sequence number for keyboard navigation
    selected_event_seq: ?u32 = null,

    /// Flag indicating whether we need to scroll to the selected item
    need_scroll_to_selected: bool = false,

    /// Flag indicating whether the selection was made by keyboard
    is_keyboard_selection: bool = false,

    pub fn init(alloc: Allocator) !Stream {
        var events: VTEvent.Ring = try .init(alloc, 2);
        errdefer events.deinit(alloc);

        var handler: VTHandler = .init;
        errdefer handler.deinit();

        return .{
            .events = events,
            .parser_stream = .initAlloc(alloc, handler),
        };
    }

    pub fn deinit(self: *Stream, alloc: Allocator) void {
        var it = self.events.iterator(.forward);
        while (it.next()) |v| v.deinit(alloc);
        self.events.deinit(alloc);

        self.parser_stream.deinit();
    }

    pub fn recordPtyRead(
        self: *Stream,
        alloc: Allocator,
        t: *terminal.Terminal,
        data: []const u8,
    ) !void {
        self.parser_stream.handler.state = .{
            .alloc = alloc,
            .terminal = t,
            .events = &self.events,
        };
        defer self.parser_stream.handler.state = null;
        try self.parser_stream.nextSlice(data);
    }

    pub fn draw(
        self: *Stream,
        alloc: Allocator,
        palette: *const terminal.color.Palette,
    ) void {
        const events = &self.events;
        const handler = &self.parser_stream.handler;
        const popup_filter = "Filter";

        // Controls
        {
            const pause_play: [:0]const u8 = if (!handler.paused)
                "Pause##pause_play"
            else
                "Resume##pause_play";
            if (cimgui.c.ImGui_Button(pause_play.ptr)) {
                handler.paused = !handler.paused;
            }

            cimgui.c.ImGui_SameLineEx(0, cimgui.c.ImGui_GetStyle().*.ItemInnerSpacing.x);
            if (cimgui.c.ImGui_Button("Filter")) {
                cimgui.c.ImGui_OpenPopup(
                    popup_filter,
                    cimgui.c.ImGuiPopupFlags_None,
                );
            }

            if (!events.empty()) {
                cimgui.c.ImGui_SameLineEx(0, cimgui.c.ImGui_GetStyle().*.ItemInnerSpacing.x);
                if (cimgui.c.ImGui_Button("Clear")) {
                    var it = events.iterator(.forward);
                    while (it.next()) |v| v.deinit(alloc);
                    events.clear();

                    handler.current_seq = 1;
                }
            }
        }

        // Events Table
        if (events.empty()) {
            cimgui.c.ImGui_Text("Waiting for events...");
        } else {
            // TODO: Eventually
            // eventTable(events);
        }

        {
            cimgui.c.ImGui_Separator();

            _ = cimgui.c.ImGui_BeginTable(
                "table_vt_events",
                3,
                cimgui.c.ImGuiTableFlags_RowBg |
                    cimgui.c.ImGuiTableFlags_Borders,
            );
            defer cimgui.c.ImGui_EndTable();

            cimgui.c.ImGui_TableSetupColumn(
                "Seq",
                cimgui.c.ImGuiTableColumnFlags_WidthFixed,
            );
            cimgui.c.ImGui_TableSetupColumn(
                "Kind",
                cimgui.c.ImGuiTableColumnFlags_WidthFixed,
            );
            cimgui.c.ImGui_TableSetupColumn(
                "Description",
                cimgui.c.ImGuiTableColumnFlags_WidthStretch,
            );

            // Handle keyboard navigation when window is focused
            if (cimgui.c.ImGui_IsWindowFocused(cimgui.c.ImGuiFocusedFlags_RootAndChildWindows)) {
                const key_pressed = getKeyAction();

                switch (key_pressed) {
                    .none => {},
                    .up, .down => {
                        // If no event is selected, select the first/last event based on direction
                        if (self.selected_event_seq == null) {
                            if (!events.empty()) {
                                var it = events.iterator(if (key_pressed == .up) .forward else .reverse);
                                if (it.next()) |ev| {
                                    self.selected_event_seq = @as(u32, @intCast(ev.seq));
                                }
                            }
                        } else {
                            // Find next/previous event based on current selection
                            var it = events.iterator(.reverse);
                            switch (key_pressed) {
                                .down => {
                                    var found = false;
                                    while (it.next()) |ev| {
                                        if (found) {
                                            self.selected_event_seq = @as(u32, @intCast(ev.seq));
                                            break;
                                        }
                                        if (ev.seq == self.selected_event_seq.?) {
                                            found = true;
                                        }
                                    }
                                },
                                .up => {
                                    var prev_ev: ?*const VTEvent = null;
                                    while (it.next()) |ev| {
                                        if (ev.seq == self.selected_event_seq.?) {
                                            if (prev_ev) |prev| {
                                                self.selected_event_seq = @as(u32, @intCast(prev.seq));
                                                break;
                                            }
                                        }
                                        prev_ev = ev;
                                    }
                                },
                                .none => unreachable,
                            }
                        }

                        // Mark that we need to scroll to the newly selected item
                        self.need_scroll_to_selected = true;
                        self.is_keyboard_selection = true;
                    },
                }
            }

            var it = events.iterator(.reverse);
            while (it.next()) |ev| {
                // Need to push an ID so that our selectable is unique.
                cimgui.c.ImGui_PushIDPtr(ev);
                defer cimgui.c.ImGui_PopID();

                cimgui.c.ImGui_TableNextRow();
                _ = cimgui.c.ImGui_TableNextColumn();

                // Store the previous selection state to detect changes
                const was_selected = ev.imgui_selected;

                // Update selection state based on keyboard navigation
                if (self.selected_event_seq) |seq| {
                    ev.imgui_selected = (@as(u32, @intCast(ev.seq)) == seq);
                }

                // Handle selectable widget
                if (cimgui.c.ImGui_SelectableBoolPtr(
                    "##select",
                    &ev.imgui_selected,
                    cimgui.c.ImGuiSelectableFlags_SpanAllColumns,
                )) {
                    // If selection state changed, update keyboard navigation state
                    if (ev.imgui_selected != was_selected) {
                        self.selected_event_seq = if (ev.imgui_selected)
                            @as(u32, @intCast(ev.seq))
                        else
                            null;
                        self.is_keyboard_selection = false;
                    }
                }

                cimgui.c.ImGui_SameLine();
                cimgui.c.ImGui_Text("%d", ev.seq);
                _ = cimgui.c.ImGui_TableNextColumn();
                cimgui.c.ImGui_Text("%s", @tagName(ev.kind).ptr);
                _ = cimgui.c.ImGui_TableNextColumn();
                cimgui.c.ImGui_Text("%s", ev.raw_description.ptr);

                // If the event is selected, we render info about it. For now
                // we put this in the last column because that's the widest and
                // imgui has no way to make a column span.
                if (ev.imgui_selected) {
                    {
                        screen.cursorTable(&ev.cursor);
                        screen.cursorStyle(&ev.cursor, palette);

                        _ = cimgui.c.ImGui_BeginTable(
                            "details",
                            2,
                            cimgui.c.ImGuiTableFlags_None,
                        );
                        defer cimgui.c.ImGui_EndTable();
                        {
                            cimgui.c.ImGui_TableNextRow();
                            {
                                _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                                cimgui.c.ImGui_Text("Scroll Region");
                            }
                            {
                                _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                                cimgui.c.ImGui_Text(
                                    "T=%d B=%d L=%d R=%d",
                                    ev.scrolling_region.top,
                                    ev.scrolling_region.bottom,
                                    ev.scrolling_region.left,
                                    ev.scrolling_region.right,
                                );
                            }
                        }

                        var md_it = ev.metadata.iterator();
                        while (md_it.next()) |entry| {
                            var buf: [256]u8 = undefined;
                            const key = std.fmt.bufPrintZ(&buf, "{s}", .{entry.key_ptr.*}) catch
                                "<internal error>";
                            cimgui.c.ImGui_TableNextRow();
                            _ = cimgui.c.ImGui_TableNextColumn();
                            cimgui.c.ImGui_Text("%s", key.ptr);
                            _ = cimgui.c.ImGui_TableNextColumn();
                            cimgui.c.ImGui_Text("%s", entry.value_ptr.ptr);
                        }
                    }

                    // If this is the selected event and scrolling is needed, scroll to it
                    if (self.need_scroll_to_selected and self.is_keyboard_selection) {
                        cimgui.c.ImGui_SetScrollHereY(0.5);
                        self.need_scroll_to_selected = false;
                    }
                }
            }
        } // table

        if (cimgui.c.ImGui_BeginPopupModal(
            popup_filter,
            null,
            cimgui.c.ImGuiWindowFlags_AlwaysAutoResize,
        )) {
            defer cimgui.c.ImGui_EndPopup();

            cimgui.c.ImGui_Text("Changed filter settings will only affect future events.");

            cimgui.c.ImGui_Separator();

            {
                _ = cimgui.c.ImGui_BeginTable(
                    "table_filter_kind",
                    3,
                    cimgui.c.ImGuiTableFlags_None,
                );
                defer cimgui.c.ImGui_EndTable();

                inline for (@typeInfo(terminal.Parser.Action.Tag).@"enum".fields) |field| {
                    const tag = @field(terminal.Parser.Action.Tag, field.name);
                    if (tag == .apc_put or tag == .dcs_put) continue;

                    _ = cimgui.c.ImGui_TableNextColumn();
                    var value = !handler.filter_exclude.contains(tag);
                    if (cimgui.c.ImGui_Checkbox(@tagName(tag).ptr, &value)) {
                        if (value) {
                            handler.filter_exclude.remove(tag);
                        } else {
                            handler.filter_exclude.insert(tag);
                        }
                    }
                }
            } // Filter kind table

            cimgui.c.ImGui_Separator();

            cimgui.c.ImGui_Text(
                "Filter by string. Empty displays all, \"abc\" finds lines\n" ++
                    "containing \"abc\", \"abc,xyz\" finds lines containing \"abc\"\n" ++
                    "or \"xyz\", \"-abc\" excludes lines containing \"abc\".",
            );
            _ = cimgui.c.ImGuiTextFilter_Draw(
                &handler.filter_text,
                "##filter_text",
                0,
            );

            cimgui.c.ImGui_Separator();
            if (cimgui.c.ImGui_Button("Close")) {
                cimgui.c.ImGui_CloseCurrentPopup();
            }
        } // filter popup
    }
};

/// Helper function to check keyboard state and determine navigation action.
fn getKeyAction() KeyAction {
    const keys = .{
        .{ .key = cimgui.c.ImGuiKey_J, .action = KeyAction.down },
        .{ .key = cimgui.c.ImGuiKey_DownArrow, .action = KeyAction.down },
        .{ .key = cimgui.c.ImGuiKey_K, .action = KeyAction.up },
        .{ .key = cimgui.c.ImGuiKey_UpArrow, .action = KeyAction.up },
    };

    inline for (keys) |k| {
        if (cimgui.c.ImGui_IsKeyPressed(k.key)) {
            return k.action;
        }
    }
    return .none;
}

pub fn eventTable(events: *const VTEvent.Ring) void {
    if (!cimgui.c.ImGui_BeginTable(
        "events",
        3,
        cimgui.c.ImGuiTableFlags_RowBg |
            cimgui.c.ImGuiTableFlags_Borders,
    )) return;
    defer cimgui.c.ImGui_EndTable();

    cimgui.c.ImGui_TableSetupColumn(
        "Seq",
        cimgui.c.ImGuiTableColumnFlags_WidthFixed,
    );
    cimgui.c.ImGui_TableSetupColumn(
        "Kind",
        cimgui.c.ImGuiTableColumnFlags_WidthFixed,
    );
    cimgui.c.ImGui_TableSetupColumn(
        "Description",
        cimgui.c.ImGuiTableColumnFlags_WidthStretch,
    );

    var it = events.iterator(.reverse);
    while (it.next()) |ev| {
        // Need to push an ID so that our selectable is unique.
        cimgui.c.ImGui_PushIDPtr(ev);
        defer cimgui.c.ImGui_PopID();

        cimgui.c.ImGui_TableNextRow();
        _ = cimgui.c.ImGui_TableNextColumn();

        cimgui.c.ImGui_SameLine();
        cimgui.c.ImGui_Text("%d", ev.seq);
        _ = cimgui.c.ImGui_TableNextColumn();
        cimgui.c.ImGui_Text("%s", @tagName(ev.kind).ptr);
        _ = cimgui.c.ImGui_TableNextColumn();
        cimgui.c.ImGui_Text("%s", ev.raw_description.ptr);
    }
}

/// VT event. This isn't public because this is just how we store internal
/// events.
const VTEvent = struct {
    /// The arena that all allocated memory for this event is stored.
    arena_state: ArenaAllocator.State,

    /// Sequence number, just monotonically increasing and wrapping if
    /// it ever overflows. It gives us a nice way to visualize progress.
    seq: usize = 1,

    /// Kind of event, for filtering
    kind: Kind,

    /// The description of the raw event in a more human-friendly format.
    /// For example for control sequences this is the full sequence but
    /// control characters are replaced with human-readable names, e.g.
    /// 0x07 (bell) becomes BEL.
    raw_description: [:0]const u8,

    /// Various metadata at the time of the event (before processing).
    cursor: terminal.Screen.Cursor,
    scrolling_region: terminal.Terminal.ScrollingRegion,
    metadata: Metadata.Unmanaged = .{},

    /// imgui selection state
    imgui_selected: bool = false,

    const Kind = enum { print, execute, csi, esc, osc, dcs, apc };
    const Metadata = std.StringHashMap([:0]const u8);

    /// Circular buffer of VT events.
    pub const Ring = CircBuf(VTEvent, undefined);

    /// Initialize the event information for the given parser action.
    pub fn init(
        alloc_gpa: Allocator,
        t: *const terminal.Terminal,
        action: terminal.Parser.Action,
    ) !VTEvent {
        var arena: ArenaAllocator = .init(alloc_gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        var md = Metadata.init(alloc);
        var buf: std.Io.Writer.Allocating = .init(alloc);
        try encodeAction(alloc, &buf.writer, &md, action);
        const desc = try buf.toOwnedSliceSentinel(0);

        const kind: Kind = switch (action) {
            .print => .print,
            .execute => .execute,
            .csi_dispatch => .csi,
            .esc_dispatch => .esc,
            .osc_dispatch => .osc,
            .dcs_hook, .dcs_put, .dcs_unhook => .dcs,
            .apc_start, .apc_put, .apc_end => .apc,
        };

        return .{
            .arena_state = arena.state,
            .kind = kind,
            .raw_description = desc,
            .cursor = t.screens.active.cursor,
            .scrolling_region = t.scrolling_region,
            .metadata = md.unmanaged,
        };
    }

    pub fn deinit(self: *VTEvent, alloc_gpa: Allocator) void {
        var arena = self.arena_state.promote(alloc_gpa);
        arena.deinit();
    }

    /// Returns true if the event passes the given filter.
    pub fn passFilter(
        self: *const VTEvent,
        filter: *const cimgui.c.ImGuiTextFilter,
    ) bool {
        // Check our main string
        if (cimgui.c.ImGuiTextFilter_PassFilter(
            filter,
            self.raw_description.ptr,
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
        writer: *std.Io.Writer,
        md: *Metadata,
        action: terminal.Parser.Action,
    ) !void {
        switch (action) {
            .print => try encodePrint(writer, action),
            .execute => try encodeExecute(writer, action),
            .csi_dispatch => |v| try encodeCSI(writer, v),
            .esc_dispatch => |v| try encodeEsc(writer, v),
            .osc_dispatch => |v| try encodeOSC(alloc, writer, md, v),
            else => try writer.print("{f}", .{action}),
        }
    }

    fn encodePrint(writer: *std.Io.Writer, action: terminal.Parser.Action) !void {
        const ch = action.print;
        try writer.print("'{u}' (U+{X})", .{ ch, ch });
    }

    fn encodeExecute(writer: *std.Io.Writer, action: terminal.Parser.Action) !void {
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

    fn encodeCSI(writer: *std.Io.Writer, csi: terminal.Parser.Action.CSI) !void {
        for (csi.intermediates) |v| try writer.print("{c} ", .{v});
        for (csi.params, 0..) |v, i| {
            if (i != 0) try writer.writeByte(';');
            try writer.print("{d}", .{v});
        }
        if (csi.intermediates.len > 0 or csi.params.len > 0) try writer.writeByte(' ');
        try writer.writeByte(csi.final);
    }

    fn encodeEsc(writer: *std.Io.Writer, esc: terminal.Parser.Action.ESC) !void {
        for (esc.intermediates) |v| try writer.print("{c} ", .{v});
        try writer.writeByte(esc.final);
    }

    fn encodeOSC(
        alloc: Allocator,
        writer: *std.Io.Writer,
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
            []const u8,
            [:0]const u8,
            => try md.put("data", try alloc.dupeZ(u8, v)),
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
                        else if (field.type == [:0]const u8 or field.type == []const u8)
                            try std.fmt.allocPrintSentinel(alloc, "{s}={s}", .{
                                tag_name,
                                @field(value, field.name),
                            }, 0)
                        else
                            try std.fmt.allocPrintSentinel(alloc, "{s}={}", .{
                                tag_name,
                                @field(value, field.name),
                            }, 0);

                        try md.put(key, s);
                    }
                }
            },

            .@"struct" => try md.put(
                key,
                try alloc.dupeZ(u8, @typeName(Value)),
            ),

            else => switch (Value) {
                []const u8,
                [:0]const u8,
                => try md.put(key, try alloc.dupeZ(u8, value)),

                else => |T| switch (@typeInfo(T)) {
                    .int => try md.put(
                        key,
                        try std.fmt.allocPrintSentinel(alloc, "{}", .{value}, 0),
                    ),
                    else => {
                        @compileLog(T);
                        @compileError("unsupported type, see log");
                    },
                },
            },
        }
    }
};

/// Our VT stream handler for the Stream widget. This isn't public
/// because there is no reason to use this directly.
const VTHandler = struct {
    /// The capture state, must be set before use. If null, then
    /// events are dropped.
    state: ?State,

    /// True to pause this artificially.
    paused: bool,

    /// Current sequence number
    current_seq: usize,

    /// Exclude certain actions by tag.
    filter_exclude: ActionTagSet,
    filter_text: cimgui.c.ImGuiTextFilter,

    const Stream = terminal.Stream(VTHandler);

    pub const ActionTagSet = std.EnumSet(terminal.Parser.Action.Tag);

    pub const State = struct {
        /// The allocator to use for the events.
        alloc: Allocator,

        /// The terminal state at the time of the event.
        terminal: *const terminal.Terminal,

        /// The event ring to write events to.
        events: *VTEvent.Ring,
    };

    pub const init: VTHandler = .{
        .state = null,
        .paused = false,
        .current_seq = 1,
        .filter_exclude = .initMany(&.{.print}),
        .filter_text = .{},
    };

    pub fn deinit(self: *VTHandler) void {
        // Required for the parser stream interface
        _ = self;
    }

    pub fn vt(
        self: *VTHandler,
        comptime action: VTHandler.Stream.Action.Tag,
        value: VTHandler.Stream.Action.Value(action),
    ) !void {
        _ = self;
        _ = value;
    }

    /// This is called with every single terminal action.
    pub fn vtRaw(self: *VTHandler, action: terminal.Parser.Action) !bool {
        const state: *State = if (self.state) |*s| s else return true;
        const alloc = state.alloc;
        const vt_events = state.events;

        // We always increment the sequence number, even if we're paused or
        // filter out the event. This helps show the user that there is a gap
        // between events and roughly how large that gap was.
        defer self.current_seq +%= 1;

        // If we're manually paused, we ignore all events.
        if (self.paused) return true;

        // We ignore certain action types that are too noisy.
        switch (action) {
            .dcs_put, .apc_put => return true,
            else => {},
        }

        // If we requested a specific type to be ignored, ignore it.
        // We return true because we did "handle" it by ignoring it.
        if (self.filter_exclude.contains(std.meta.activeTag(action))) return true;

        // Build our event
        var ev: VTEvent = try .init(
            alloc,
            state.terminal,
            action,
        );
        ev.seq = self.current_seq;
        errdefer ev.deinit(alloc);

        // Check if the event passes the filter
        if (!ev.passFilter(&self.filter_text)) {
            ev.deinit(alloc);
            return true;
        }

        const max_capacity = 100;
        vt_events.append(ev) catch |err| switch (err) {
            error.OutOfMemory => if (vt_events.capacity() < max_capacity) {
                // We're out of memory, but we can allocate to our capacity.
                const new_capacity = @min(vt_events.capacity() * 2, max_capacity);
                try vt_events.resize(alloc, new_capacity);
                try vt_events.append(ev);
            } else {
                var it = vt_events.iterator(.forward);
                if (it.next()) |old_ev| old_ev.deinit(alloc);
                vt_events.deleteOldest(1);
                try vt_events.append(ev);
            },

            else => return err,
        };

        // Do NOT skip it, because we want to record more information
        // about this event.
        return false;
    }
};

/// Enum representing keyboard navigation actions
const KeyAction = enum {
    down,
    none,
    up,
};
