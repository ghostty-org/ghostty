const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");
const lib = @import("../lib.zig");
const CAllocator = lib.alloc.Allocator;
const SelectionGesture = @import("../SelectionGesture.zig");
const selection_codepoints = @import("../selection_codepoints.zig");
const grid_ref = @import("grid_ref.zig");
const point = @import("../point.zig");
const selection_c = @import("selection.zig");
const terminal_c = @import("terminal.zig");
const types = @import("types.zig");
const Result = @import("result.zig").Result;

const log = std.log.scoped(.selection_gesture_c);

/// C: GhosttySelectionGesture
pub const Gesture = ?*GestureWrapper;

/// C: GhosttySelectionGestureEvent
pub const Event = ?*EventWrapper;

const GestureWrapper = struct {
    alloc: std.mem.Allocator,
    gesture: SelectionGesture = .init,
};

const EventWrapper = struct {
    alloc: std.mem.Allocator,
    event: union(EventType) {
        press: SelectionGesture.Press,
        release: SelectionGesture.Release,
        drag: SelectionGesture.Drag,
        autoscroll_tick: SelectionGesture.AutoscrollTick,
        deep_press: SelectionGesture.DeepPress,
    },

    // Validation sidecar for required event fields that don't have safe
    // sentinels in the real SelectionGesture payloads. For example, PageList.Pin
    // contains a non-null node pointer and Geometry has no meaningful zero
    // value. Keep these as one-bit flags so dispatch can reject incomplete C
    // events instead of using undefined placeholder data.
    event_validation: packed struct {
        press_pin_set: bool = false,
        drag_pin_set: bool = false,
        drag_geometry_set: bool = false,
        autoscroll_tick_viewport_set: bool = false,
        autoscroll_tick_geometry_set: bool = false,
    } = .{},

    // Backing storage for Press/Drag/AutoscrollTick.word_boundary_codepoints.
    // The C API receives codepoints as borrowed uint32_t values, but
    // SelectionGesture stores a []const u21 slice. We copy/convert into
    // event-owned storage so the real payload can safely point at it until the
    // event is changed or freed.
    word_boundary_codepoints: ?[]u21 = null,

    // Backing storage for Press.behaviors. The C API sets behaviors as a value
    // struct, but SelectionGesture.Press stores a pointer to a [3]Behavior.
    // Keep the array on the event wrapper so the Press payload can point at a
    // stable location for the lifetime of the event.
    behaviors: [3]Behavior = SelectionGesture.default_behaviors,

    fn init(self: *EventWrapper, event_type: EventType) void {
        self.event = switch (event_type) {
            .press => .{ .press = self.defaultPress() },
            .release => .{ .release = self.defaultRelease() },
            .drag => .{ .drag = self.defaultDrag() },
            .autoscroll_tick => .{ .autoscroll_tick = self.defaultAutoscrollTick() },
            .deep_press => .{ .deep_press = self.defaultDeepPress() },
        };
    }

    fn defaultPress(self: *EventWrapper) SelectionGesture.Press {
        return .{
            .time = null,
            .pin = undefined,
            .xpos = 0,
            .ypos = 0,
            .max_distance = 0,
            .repeat_interval = 0,
            .word_boundary_codepoints = &selection_codepoints.default_word_boundaries,
            .behaviors = &self.behaviors,
        };
    }

    fn defaultRelease(self: *EventWrapper) SelectionGesture.Release {
        _ = self;
        return .{ .pin = null };
    }

    fn defaultDrag(self: *EventWrapper) SelectionGesture.Drag {
        _ = self;
        return .{
            .pin = undefined,
            .xpos = 0,
            .ypos = 0,
            .rectangle = false,
            .word_boundary_codepoints = &selection_codepoints.default_word_boundaries,
            .geometry = undefined,
        };
    }

    fn defaultAutoscrollTick(self: *EventWrapper) SelectionGesture.AutoscrollTick {
        _ = self;
        return .{
            .viewport = undefined,
            .xpos = 0,
            .ypos = 0,
            .rectangle = false,
            .word_boundary_codepoints = &selection_codepoints.default_word_boundaries,
            .geometry = undefined,
        };
    }

    fn defaultDeepPress(self: *EventWrapper) SelectionGesture.DeepPress {
        _ = self;
        return .{
            .word_boundary_codepoints = &selection_codepoints.default_word_boundaries,
        };
    }

    fn deinit(self: *EventWrapper) void {
        if (self.word_boundary_codepoints) |cps| {
            if (cps.len > 0) self.alloc.free(cps);
        }
    }
};

/// C: GhosttySelectionGestureBehavior
pub const Behavior = SelectionGesture.Behavior;

/// C: GhosttySelectionGestureAutoscroll
pub const Autoscroll = SelectionGesture.Autoscroll;

/// C: GhosttySelectionGestureBehaviors
pub const Behaviors = extern struct {
    single_click: Behavior,
    double_click: Behavior,
    triple_click: Behavior,
};

/// C: GhosttySelectionGestureData
pub const Data = enum(c_int) {
    click_count = 0,
    dragged = 1,
    autoscroll = 2,
    behavior = 3,
    anchor = 4,

    pub fn OutType(comptime self: Data) type {
        return switch (self) {
            .click_count => u8,
            .dragged => bool,
            .autoscroll => Autoscroll,
            .behavior => Behavior,
            .anchor => grid_ref.CGridRef,
        };
    }
};

/// C: GhosttySelectionGestureEventType
pub const EventType = enum(c_int) {
    press = 0,
    release = 1,
    drag = 2,
    autoscroll_tick = 3,
    deep_press = 4,
};

/// C: GhosttySelectionGestureEventOption
pub const EventOption = enum(c_int) {
    ref = 0,
    position = 1,
    repeat_distance = 2,
    time_ns = 3,
    repeat_interval_ns = 4,
    word_boundary_codepoints = 5,
    behaviors = 6,
    rectangle = 7,
    geometry = 8,
    viewport = 9,

    pub fn Type(comptime self: EventOption) type {
        return switch (self) {
            .ref => grid_ref.CGridRef,
            .position => types.SurfacePosition,
            .repeat_distance => f64,
            .time_ns => u64,
            .repeat_interval_ns => u64,
            .word_boundary_codepoints => types.Codepoints,
            .behaviors => Behaviors,
            .rectangle => bool,
            .geometry => Geometry,
            .viewport => point.Coordinate,
        };
    }
};

/// C: GhosttySelectionGestureGeometry
pub const Geometry = extern struct {
    columns: u32,
    cell_width: u32,
    padding_left: u32,
    screen_height: u32,

    fn toZig(self: Geometry) ?SelectionGesture.Drag.Geometry {
        if (self.columns == 0) return null;
        if (self.cell_width == 0) return null;
        if (self.screen_height == 0) return null;
        return .{
            .columns = self.columns,
            .cell_width = self.cell_width,
            .padding_left = self.padding_left,
            .screen_height = self.screen_height,
        };
    }
};

pub fn new(
    alloc_: ?*const CAllocator,
    out_gesture: ?*Gesture,
) callconv(lib.calling_conv) Result {
    const out = out_gesture orelse return .invalid_value;

    const alloc = lib.alloc.default(alloc_);
    const gesture = alloc.create(GestureWrapper) catch {
        out.* = null;
        return .out_of_memory;
    };
    gesture.* = .{
        .alloc = alloc,
    };
    out.* = gesture;
    return .success;
}

pub fn event_new(
    alloc_: ?*const CAllocator,
    out_event: ?*Event,
    event_type: EventType,
) callconv(lib.calling_conv) Result {
    const out = out_event orelse return .invalid_value;
    _ = std.meta.intToEnum(EventType, @intFromEnum(event_type)) catch
        return .invalid_value;

    const alloc = lib.alloc.default(alloc_);
    const event = alloc.create(EventWrapper) catch {
        out.* = null;
        return .out_of_memory;
    };
    event.* = .{
        .alloc = alloc,
        .event = undefined,
    };
    event.init(event_type);
    out.* = event;
    return .success;
}

pub fn free(
    gesture_: Gesture,
    terminal: terminal_c.Terminal,
) callconv(lib.calling_conv) void {
    const wrapper = gesture_ orelse return;
    if (terminal_c.zigTerminal(terminal)) |t| {
        wrapper.gesture.deinit(t);
    }
    const alloc = wrapper.alloc;
    alloc.destroy(wrapper);
}

pub fn event_free(event_: Event) callconv(lib.calling_conv) void {
    const event = event_ orelse return;
    event.deinit();
    const alloc = event.alloc;
    alloc.destroy(event);
}

pub fn reset(
    gesture_: Gesture,
    terminal: terminal_c.Terminal,
) callconv(lib.calling_conv) void {
    const wrapper = gesture_ orelse return;
    const t = terminal_c.zigTerminal(terminal) orelse return;
    wrapper.gesture.reset(t);
}

pub fn handle_event(
    gesture_: Gesture,
    terminal: terminal_c.Terminal,
    event_: Event,
    out_selection: ?*selection_c.CSelection,
) callconv(lib.calling_conv) Result {
    const wrapper = gesture_ orelse return .invalid_value;
    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const event_wrapper = event_ orelse return .invalid_value;

    return switch (event_wrapper.event) {
        .press => |press| {
            if (!event_wrapper.event_validation.press_pin_set) return .invalid_value;
            const sel = wrapper.gesture.press(t, press) catch return .out_of_memory;
            if (out_selection) |out| {
                out.* = selection_c.CSelection.fromZig(sel orelse return .no_value);
            } else if (sel == null) return .no_value;
            return .success;
        },
        .release => |release| {
            wrapper.gesture.release(t, release);
            return .no_value;
        },
        .drag => |drag| {
            if (!event_wrapper.event_validation.drag_pin_set) return .invalid_value;
            if (!event_wrapper.event_validation.drag_geometry_set) return .invalid_value;
            const sel = wrapper.gesture.drag(t, drag);
            if (out_selection) |out| {
                out.* = selection_c.CSelection.fromZig(sel orelse return .no_value);
            } else if (sel == null) return .no_value;
            return .success;
        },
        .autoscroll_tick => |tick| {
            if (!event_wrapper.event_validation.autoscroll_tick_viewport_set) return .invalid_value;
            if (!event_wrapper.event_validation.autoscroll_tick_geometry_set) return .invalid_value;
            const sel = wrapper.gesture.autoscrollTick(t, tick);
            if (out_selection) |out| {
                out.* = selection_c.CSelection.fromZig(sel orelse return .no_value);
            } else if (sel == null) return .no_value;
            return .success;
        },
        .deep_press => |deep_press| {
            const sel = wrapper.gesture.deepPress(t, deep_press);
            if (out_selection) |out| {
                out.* = selection_c.CSelection.fromZig(sel orelse return .no_value);
            } else if (sel == null) return .no_value;
            return .success;
        },
    };
}

pub fn event_set(
    event_: Event,
    option: EventOption,
    value: ?*const anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.meta.intToEnum(EventOption, @intFromEnum(option)) catch {
            log.warn("selection_gesture_event_set invalid option value={d}", .{@intFromEnum(option)});
            return .invalid_value;
        };
    }

    return switch (option) {
        inline else => |comptime_option| eventSetTyped(
            event_,
            comptime_option,
            if (value) |ptr| @ptrCast(@alignCast(ptr)) else null,
        ),
    };
}

pub fn get(
    gesture_: Gesture,
    terminal: terminal_c.Terminal,
    data: Data,
    out: ?*anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.meta.intToEnum(Data, @intFromEnum(data)) catch {
            log.warn("selection_gesture_get invalid data value={d}", .{@intFromEnum(data)});
            return .invalid_value;
        };
    }

    const out_ptr = out orelse return .invalid_value;
    return switch (data) {
        inline else => |comptime_data| getTyped(
            gesture_,
            terminal,
            comptime_data,
            @ptrCast(@alignCast(out_ptr)),
        ),
    };
}

pub fn get_multi(
    gesture_: Gesture,
    terminal: terminal_c.Terminal,
    count: usize,
    keys: ?[*]const Data,
    values: ?[*]?*anyopaque,
    out_written: ?*usize,
) callconv(lib.calling_conv) Result {
    const k = keys orelse return .invalid_value;
    const v = values orelse return .invalid_value;

    for (0..count) |i| {
        const result = get(gesture_, terminal, k[i], v[i]);
        if (result != .success) {
            if (out_written) |w| w.* = i;
            return result;
        }
    }
    if (out_written) |w| w.* = count;
    return .success;
}

fn getTyped(
    gesture_: Gesture,
    terminal: terminal_c.Terminal,
    comptime data: Data,
    out: *data.OutType(),
) Result {
    const wrapper = gesture_ orelse return .invalid_value;
    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;

    switch (data) {
        .click_count => out.* = wrapper.gesture.left_click_count,
        .dragged => out.* = wrapper.gesture.left_click_dragged,
        .autoscroll => out.* = wrapper.gesture.left_drag_autoscroll,
        .behavior => out.* = wrapper.gesture.left_click_behavior,
        .anchor => {
            const pin = wrapper.gesture.validatedLeftClickPin(&t.screens) orelse
                return .no_value;
            out.* = .fromPin(pin.*);
        },
    }

    return .success;
}

fn eventSetTyped(
    event_: Event,
    comptime option: EventOption,
    value: ?*const option.Type(),
) Result {
    const event = event_ orelse return .invalid_value;
    return switch (event.event) {
        .press => |*press| pressSetTyped(event, press, option, value),
        .release => |*release| releaseSetTyped(release, option, value),
        .drag => |*drag| dragSetTyped(event, drag, option, value),
        .autoscroll_tick => |*tick| autoscrollTickSetTyped(event, tick, option, value),
        .deep_press => |*deep_press| deepPressSetTyped(event, deep_press, option, value),
    };
}

fn pressSetTyped(
    event: *EventWrapper,
    press: *SelectionGesture.Press,
    comptime option: EventOption,
    value: ?*const option.Type(),
) Result {
    const v = value orelse {
        switch (option) {
            .ref => event.event_validation.press_pin_set = false,
            .position => {
                press.xpos = 0;
                press.ypos = 0;
            },
            .repeat_distance => press.max_distance = 0,
            .time_ns => press.time = null,
            .repeat_interval_ns => press.repeat_interval = 0,
            .word_boundary_codepoints => clearWordBoundaryCodepoints(
                event,
                &press.word_boundary_codepoints,
            ),
            .behaviors => {
                event.behaviors = SelectionGesture.default_behaviors;
                press.behaviors = &event.behaviors;
            },
            .rectangle,
            .geometry,
            .viewport,
            => return .invalid_value,
        }
        return .success;
    };

    switch (option) {
        .ref => {
            press.pin = v.toPin() orelse return .invalid_value;
            event.event_validation.press_pin_set = true;
        },
        .position => {
            press.xpos = v.x;
            press.ypos = v.y;
        },
        .repeat_distance => press.max_distance = v.*,
        .time_ns => press.time = instantFromNs(v.*),
        .repeat_interval_ns => press.repeat_interval = v.*,
        .word_boundary_codepoints => return trySetWordBoundaryCodepoints(
            event,
            &press.word_boundary_codepoints,
            v,
        ),
        .behaviors => {
            if (!validBehavior(v.single_click) or
                !validBehavior(v.double_click) or
                !validBehavior(v.triple_click)) return .invalid_value;
            event.behaviors = .{ v.single_click, v.double_click, v.triple_click };
            press.behaviors = &event.behaviors;
        },
        .rectangle,
        .geometry,
        .viewport,
        => return .invalid_value,
    }

    return .success;
}

fn releaseSetTyped(
    release: *SelectionGesture.Release,
    comptime option: EventOption,
    value: ?*const option.Type(),
) Result {
    switch (option) {
        .ref => {
            const v = value orelse {
                release.pin = null;
                return .success;
            };
            release.pin = v.toPin() orelse return .invalid_value;
        },

        .position,
        .repeat_distance,
        .time_ns,
        .repeat_interval_ns,
        .word_boundary_codepoints,
        .behaviors,
        .rectangle,
        .geometry,
        .viewport,
        => return .invalid_value,
    }

    return .success;
}

fn dragSetTyped(
    event: *EventWrapper,
    drag: *SelectionGesture.Drag,
    comptime option: EventOption,
    value: ?*const option.Type(),
) Result {
    const v = value orelse {
        switch (option) {
            .ref => event.event_validation.drag_pin_set = false,
            .position => {
                drag.xpos = 0;
                drag.ypos = 0;
            },
            .word_boundary_codepoints => clearWordBoundaryCodepoints(
                event,
                &drag.word_boundary_codepoints,
            ),
            .rectangle => drag.rectangle = false,
            .geometry => event.event_validation.drag_geometry_set = false,
            .viewport => return .invalid_value,

            .repeat_distance,
            .time_ns,
            .repeat_interval_ns,
            .behaviors,
            => return .invalid_value,
        }
        return .success;
    };

    switch (option) {
        .ref => {
            drag.pin = v.toPin() orelse return .invalid_value;
            event.event_validation.drag_pin_set = true;
        },
        .position => {
            drag.xpos = v.x;
            drag.ypos = v.y;
        },
        .word_boundary_codepoints => return trySetWordBoundaryCodepoints(
            event,
            &drag.word_boundary_codepoints,
            v,
        ),
        .rectangle => drag.rectangle = v.*,
        .geometry => {
            drag.geometry = v.toZig() orelse return .invalid_value;
            event.event_validation.drag_geometry_set = true;
        },
        .viewport => return .invalid_value,

        .repeat_distance,
        .time_ns,
        .repeat_interval_ns,
        .behaviors,
        => return .invalid_value,
    }

    return .success;
}

fn autoscrollTickSetTyped(
    event: *EventWrapper,
    tick: *SelectionGesture.AutoscrollTick,
    comptime option: EventOption,
    value: ?*const option.Type(),
) Result {
    const v = value orelse {
        switch (option) {
            .viewport => event.event_validation.autoscroll_tick_viewport_set = false,
            .position => {
                tick.xpos = 0;
                tick.ypos = 0;
            },
            .word_boundary_codepoints => clearWordBoundaryCodepoints(
                event,
                &tick.word_boundary_codepoints,
            ),
            .rectangle => tick.rectangle = false,
            .geometry => event.event_validation.autoscroll_tick_geometry_set = false,

            .ref,
            .repeat_distance,
            .time_ns,
            .repeat_interval_ns,
            .behaviors,
            => return .invalid_value,
        }
        return .success;
    };

    switch (option) {
        .viewport => {
            tick.viewport = v.*;
            event.event_validation.autoscroll_tick_viewport_set = true;
        },
        .position => {
            tick.xpos = v.x;
            tick.ypos = v.y;
        },
        .word_boundary_codepoints => return trySetWordBoundaryCodepoints(
            event,
            &tick.word_boundary_codepoints,
            v,
        ),
        .rectangle => tick.rectangle = v.*,
        .geometry => {
            tick.geometry = v.toZig() orelse return .invalid_value;
            event.event_validation.autoscroll_tick_geometry_set = true;
        },

        .ref,
        .repeat_distance,
        .time_ns,
        .repeat_interval_ns,
        .behaviors,
        => return .invalid_value,
    }

    return .success;
}

fn deepPressSetTyped(
    event: *EventWrapper,
    deep_press: *SelectionGesture.DeepPress,
    comptime option: EventOption,
    value: ?*const option.Type(),
) Result {
    const v = value orelse {
        switch (option) {
            .word_boundary_codepoints => clearWordBoundaryCodepoints(
                event,
                &deep_press.word_boundary_codepoints,
            ),

            .ref,
            .position,
            .repeat_distance,
            .time_ns,
            .repeat_interval_ns,
            .behaviors,
            .rectangle,
            .geometry,
            .viewport,
            => return .invalid_value,
        }
        return .success;
    };

    switch (option) {
        .word_boundary_codepoints => return trySetWordBoundaryCodepoints(
            event,
            &deep_press.word_boundary_codepoints,
            v,
        ),

        .ref,
        .position,
        .repeat_distance,
        .time_ns,
        .repeat_interval_ns,
        .behaviors,
        .rectangle,
        .geometry,
        .viewport,
        => return .invalid_value,
    }

    return .success;
}

fn trySetWordBoundaryCodepoints(
    event: *EventWrapper,
    target: *[]const u21,
    value: *const types.Codepoints,
) Result {
    if (value.len > 0 and value.ptr == null) return .invalid_value;
    clearWordBoundaryCodepoints(event, target);
    const ptr = value.ptr orelse {
        event.word_boundary_codepoints = &.{};
        target.* = event.word_boundary_codepoints.?;
        return .success;
    };
    const copy = event.alloc.alloc(u21, value.len) catch return .out_of_memory;
    errdefer event.alloc.free(copy);
    for (copy, ptr[0..value.len]) |*dst, cp| {
        dst.* = std.math.cast(u21, cp) orelse return .invalid_value;
    }
    event.word_boundary_codepoints = copy;
    target.* = copy;
    return .success;
}

fn clearWordBoundaryCodepoints(event: *EventWrapper, target: *[]const u21) void {
    if (event.word_boundary_codepoints) |cps| {
        if (cps.len > 0) event.alloc.free(cps);
    }
    event.word_boundary_codepoints = null;
    target.* = &selection_codepoints.default_word_boundaries;
}

fn instantFromNs(ns: u64) std.time.Instant {
    return switch (builtin.os.tag) {
        .windows, .uefi, .wasi => .{ .timestamp = ns },
        else => .{ .timestamp = .{
            .sec = @intCast(ns / std.time.ns_per_s),
            .nsec = @intCast(ns % std.time.ns_per_s),
        } },
    };
}

fn validBehavior(behavior: Behavior) bool {
    _ = std.meta.intToEnum(Behavior, @intFromEnum(behavior)) catch return false;
    return true;
}

test "selection gesture lifecycle and get" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{ .cols = 5, .rows = 2, .max_scrollback = 10_000 },
    ));
    defer terminal_c.free(terminal);

    var gesture: Gesture = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &gesture,
    ));
    defer free(gesture, terminal);

    var click_count: u8 = 255;
    try testing.expectEqual(Result.success, get(gesture, terminal, .click_count, &click_count));
    try testing.expectEqual(@as(u8, 0), click_count);

    var dragged = true;
    try testing.expectEqual(Result.success, get(gesture, terminal, .dragged, &dragged));
    try testing.expect(!dragged);

    var autoscroll: Autoscroll = .up;
    try testing.expectEqual(Result.success, get(gesture, terminal, .autoscroll, &autoscroll));
    try testing.expectEqual(Autoscroll.none, autoscroll);

    var behavior: Behavior = .word;
    try testing.expectEqual(Result.success, get(gesture, terminal, .behavior, &behavior));
    try testing.expectEqual(Behavior.cell, behavior);

    var anchor: grid_ref.CGridRef = undefined;
    try testing.expectEqual(Result.no_value, get(gesture, terminal, .anchor, &anchor));
}

test "selection gesture get_multi" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{ .cols = 5, .rows = 2, .max_scrollback = 10_000 },
    ));
    defer terminal_c.free(terminal);

    var gesture: Gesture = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &gesture,
    ));
    defer free(gesture, terminal);

    const keys = [_]Data{ .click_count, .dragged, .autoscroll, .behavior };
    var click_count: u8 = 255;
    var dragged = true;
    var autoscroll: Autoscroll = .up;
    var behavior: Behavior = .word;
    var values = [_]?*anyopaque{
        &click_count,
        &dragged,
        &autoscroll,
        &behavior,
    };
    var written: usize = 0;

    try testing.expectEqual(Result.success, get_multi(
        gesture,
        terminal,
        keys.len,
        &keys,
        &values,
        &written,
    ));
    try testing.expectEqual(keys.len, written);
    try testing.expectEqual(@as(u8, 0), click_count);
    try testing.expect(!dragged);
    try testing.expectEqual(Autoscroll.none, autoscroll);
    try testing.expectEqual(Behavior.cell, behavior);
}

test "selection gesture get_multi returns first failing index" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{ .cols = 5, .rows = 2, .max_scrollback = 10_000 },
    ));
    defer terminal_c.free(terminal);

    var gesture: Gesture = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &gesture,
    ));
    defer free(gesture, terminal);

    const keys = [_]Data{ .click_count, .anchor, .dragged };
    var click_count: u8 = 255;
    var anchor: grid_ref.CGridRef = undefined;
    var dragged = true;
    var values = [_]?*anyopaque{ &click_count, &anchor, &dragged };
    var written: usize = 0;

    try testing.expectEqual(Result.no_value, get_multi(
        gesture,
        terminal,
        keys.len,
        &keys,
        &values,
        &written,
    ));
    try testing.expectEqual(@as(usize, 1), written);
    try testing.expectEqual(@as(u8, 0), click_count);
    try testing.expect(dragged);
}

test "selection gesture event set clear and free" {
    var event: Event = null;
    try testing.expectEqual(Result.success, event_new(
        &lib.alloc.test_allocator,
        &event,
        .press,
    ));
    defer event_free(event);

    const in_pos: types.SurfacePosition = .{ .x = 12.5, .y = -3.25 };
    try testing.expectEqual(Result.success, event_set(event, .position, &in_pos));
    try testing.expectEqual(@as(f64, 12.5), event.?.event.press.xpos);
    try testing.expectEqual(@as(f64, -3.25), event.?.event.press.ypos);

    try testing.expectEqual(Result.success, event_set(event, .position, null));
    try testing.expectEqual(@as(f64, 0), event.?.event.press.xpos);
    try testing.expectEqual(@as(f64, 0), event.?.event.press.ypos);

    const repeat_distance: f64 = 4.0;
    try testing.expectEqual(Result.success, event_set(event, .repeat_distance, &repeat_distance));
    try testing.expectEqual(repeat_distance, event.?.event.press.max_distance);
}

test "selection gesture event copies clears and frees codepoints" {
    var event: Event = null;
    try testing.expectEqual(Result.success, event_new(
        &lib.alloc.test_allocator,
        &event,
        .press,
    ));
    defer event_free(event);

    var values = [_]u32{ ' ', '\t' };
    const in: types.Codepoints = .{ .ptr = &values, .len = values.len };
    try testing.expectEqual(Result.success, event_set(event, .word_boundary_codepoints, &in));

    values[0] = 'x';

    try testing.expectEqual(@as(usize, 2), event.?.event.press.word_boundary_codepoints.len);
    try testing.expectEqual(@as(u21, ' '), event.?.event.press.word_boundary_codepoints[0]);
    try testing.expectEqual(@as(u21, '\t'), event.?.event.press.word_boundary_codepoints[1]);

    const invalid: types.Codepoints = .{ .ptr = null, .len = 1 };
    try testing.expectEqual(Result.invalid_value, event_set(event, .word_boundary_codepoints, &invalid));

    try testing.expectEqual(Result.success, event_set(event, .word_boundary_codepoints, null));
    try testing.expectEqual(
        selection_codepoints.default_word_boundaries.len,
        event.?.event.press.word_boundary_codepoints.len,
    );

    const empty: types.Codepoints = .{ .ptr = null, .len = 0 };
    try testing.expectEqual(Result.success, event_set(event, .word_boundary_codepoints, &empty));
    try testing.expectEqual(@as(usize, 0), event.?.event.press.word_boundary_codepoints.len);
}

test "selection gesture event behaviors" {
    var event: Event = null;
    try testing.expectEqual(Result.success, event_new(
        &lib.alloc.test_allocator,
        &event,
        .press,
    ));
    defer event_free(event);

    const in: Behaviors = .{
        .single_click = .cell,
        .double_click = .word,
        .triple_click = .line,
    };
    try testing.expectEqual(Result.success, event_set(event, .behaviors, &in));
    try testing.expectEqual(Behavior.cell, event.?.event.press.behaviors[0]);
    try testing.expectEqual(Behavior.word, event.?.event.press.behaviors[1]);
    try testing.expectEqual(Behavior.line, event.?.event.press.behaviors[2]);
}

test "selection gesture event applies press" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{ .cols = 5, .rows = 2, .max_scrollback = 10_000 },
    ));
    defer terminal_c.free(terminal);

    var gesture: Gesture = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &gesture,
    ));
    defer free(gesture, terminal);

    var press_event: Event = null;
    try testing.expectEqual(Result.success, event_new(
        &lib.alloc.test_allocator,
        &press_event,
        .press,
    ));
    defer event_free(press_event);

    terminal_c.vt_write(terminal, "abc", 3);

    var ref: grid_ref.CGridRef = undefined;
    try testing.expectEqual(Result.success, terminal_c.grid_ref(terminal, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 1, .y = 0 } },
    }, &ref));
    try testing.expectEqual(Result.success, event_set(press_event, .ref, &ref));
    const behaviors: Behaviors = .{
        .single_click = .word,
        .double_click = .word,
        .triple_click = .line,
    };
    try testing.expectEqual(Result.success, event_set(press_event, .behaviors, &behaviors));

    var sel: selection_c.CSelection = undefined;
    try testing.expectEqual(Result.success, handle_event(gesture, terminal, press_event, &sel));
    try testing.expectEqual(@as(u16, 0), sel.start.toPin().?.x);
    try testing.expectEqual(@as(u16, 2), sel.end.toPin().?.x);

    try testing.expectEqual(Result.success, handle_event(gesture, terminal, press_event, null));
}

test "selection gesture event press requires ref" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{ .cols = 5, .rows = 2, .max_scrollback = 10_000 },
    ));
    defer terminal_c.free(terminal);

    var gesture: Gesture = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &gesture,
    ));
    defer free(gesture, terminal);

    var press_event: Event = null;
    try testing.expectEqual(Result.success, event_new(
        &lib.alloc.test_allocator,
        &press_event,
        .press,
    ));
    defer event_free(press_event);

    var sel: selection_c.CSelection = undefined;
    try testing.expectEqual(Result.invalid_value, handle_event(gesture, terminal, press_event, &sel));
}

test "selection gesture event null output still reports no selection" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{ .cols = 5, .rows = 2, .max_scrollback = 10_000 },
    ));
    defer terminal_c.free(terminal);

    var gesture: Gesture = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &gesture,
    ));
    defer free(gesture, terminal);

    var press_event: Event = null;
    try testing.expectEqual(Result.success, event_new(
        &lib.alloc.test_allocator,
        &press_event,
        .press,
    ));
    defer event_free(press_event);

    var ref: grid_ref.CGridRef = undefined;
    try testing.expectEqual(Result.success, terminal_c.grid_ref(terminal, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 1, .y = 0 } },
    }, &ref));
    try testing.expectEqual(Result.success, event_set(press_event, .ref, &ref));

    try testing.expectEqual(Result.no_value, handle_event(gesture, terminal, press_event, null));
}

test "selection gesture event applies release" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{ .cols = 5, .rows = 2, .max_scrollback = 10_000 },
    ));
    defer terminal_c.free(terminal);

    var gesture: Gesture = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &gesture,
    ));
    defer free(gesture, terminal);

    var press_event: Event = null;
    try testing.expectEqual(Result.success, event_new(
        &lib.alloc.test_allocator,
        &press_event,
        .press,
    ));
    defer event_free(press_event);

    var release_event: Event = null;
    try testing.expectEqual(Result.success, event_new(
        &lib.alloc.test_allocator,
        &release_event,
        .release,
    ));
    defer event_free(release_event);

    var ref: grid_ref.CGridRef = undefined;
    try testing.expectEqual(Result.success, terminal_c.grid_ref(terminal, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 1, .y = 0 } },
    }, &ref));
    try testing.expectEqual(Result.success, event_set(press_event, .ref, &ref));
    try testing.expectEqual(Result.success, event_set(release_event, .ref, &ref));

    try testing.expectEqual(Result.no_value, handle_event(gesture, terminal, press_event, null));
    try testing.expectEqual(Result.no_value, handle_event(gesture, terminal, release_event, null));

    var dragged = true;
    try testing.expectEqual(Result.success, get(gesture, terminal, .dragged, &dragged));
    try testing.expect(!dragged);

    const pos: types.SurfacePosition = .{ .x = 0, .y = 0 };
    try testing.expectEqual(Result.invalid_value, event_set(release_event, .position, &pos));
}

test "selection gesture release without ref marks dragged" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{ .cols = 5, .rows = 2, .max_scrollback = 10_000 },
    ));
    defer terminal_c.free(terminal);

    var gesture: Gesture = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &gesture,
    ));
    defer free(gesture, terminal);

    var press_event: Event = null;
    try testing.expectEqual(Result.success, event_new(
        &lib.alloc.test_allocator,
        &press_event,
        .press,
    ));
    defer event_free(press_event);

    var release_event: Event = null;
    try testing.expectEqual(Result.success, event_new(
        &lib.alloc.test_allocator,
        &release_event,
        .release,
    ));
    defer event_free(release_event);

    var ref: grid_ref.CGridRef = undefined;
    try testing.expectEqual(Result.success, terminal_c.grid_ref(terminal, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 1, .y = 0 } },
    }, &ref));
    try testing.expectEqual(Result.success, event_set(press_event, .ref, &ref));

    try testing.expectEqual(Result.no_value, handle_event(gesture, terminal, press_event, null));
    try testing.expectEqual(Result.no_value, handle_event(gesture, terminal, release_event, null));

    var dragged = false;
    try testing.expectEqual(Result.success, get(gesture, terminal, .dragged, &dragged));
    try testing.expect(dragged);
}

test "selection gesture event applies drag" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{ .cols = 5, .rows = 2, .max_scrollback = 10_000 },
    ));
    defer terminal_c.free(terminal);

    terminal_c.vt_write(terminal, "abcde", 5);

    var gesture: Gesture = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &gesture,
    ));
    defer free(gesture, terminal);

    var press_event: Event = null;
    try testing.expectEqual(Result.success, event_new(
        &lib.alloc.test_allocator,
        &press_event,
        .press,
    ));
    defer event_free(press_event);

    var drag_event: Event = null;
    try testing.expectEqual(Result.success, event_new(
        &lib.alloc.test_allocator,
        &drag_event,
        .drag,
    ));
    defer event_free(drag_event);

    var press_ref: grid_ref.CGridRef = undefined;
    try testing.expectEqual(Result.success, terminal_c.grid_ref(terminal, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 1, .y = 0 } },
    }, &press_ref));
    try testing.expectEqual(Result.success, event_set(press_event, .ref, &press_ref));

    const press_pos: types.SurfacePosition = .{ .x = 10, .y = 10 };
    try testing.expectEqual(Result.success, event_set(press_event, .position, &press_pos));
    try testing.expectEqual(Result.no_value, handle_event(gesture, terminal, press_event, null));

    var drag_ref: grid_ref.CGridRef = undefined;
    try testing.expectEqual(Result.success, terminal_c.grid_ref(terminal, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 3, .y = 0 } },
    }, &drag_ref));
    try testing.expectEqual(Result.success, event_set(drag_event, .ref, &drag_ref));

    const drag_pos: types.SurfacePosition = .{ .x = 36, .y = 10 };
    try testing.expectEqual(Result.success, event_set(drag_event, .position, &drag_pos));
    const geometry: Geometry = .{
        .columns = 5,
        .cell_width = 10,
        .padding_left = 0,
        .screen_height = 20,
    };
    try testing.expectEqual(Result.success, event_set(drag_event, .geometry, &geometry));

    var sel: selection_c.CSelection = undefined;
    try testing.expectEqual(Result.success, handle_event(gesture, terminal, drag_event, &sel));
    try testing.expectEqual(@as(u16, 1), sel.start.toPin().?.x);
    try testing.expectEqual(@as(u16, 3), sel.end.toPin().?.x);

    var dragged = false;
    try testing.expectEqual(Result.success, get(gesture, terminal, .dragged, &dragged));
    try testing.expect(dragged);
}

test "selection gesture drag requires ref and geometry" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{ .cols = 5, .rows = 2, .max_scrollback = 10_000 },
    ));
    defer terminal_c.free(terminal);

    var gesture: Gesture = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &gesture,
    ));
    defer free(gesture, terminal);

    var drag_event: Event = null;
    try testing.expectEqual(Result.success, event_new(
        &lib.alloc.test_allocator,
        &drag_event,
        .drag,
    ));
    defer event_free(drag_event);

    var sel: selection_c.CSelection = undefined;
    try testing.expectEqual(Result.invalid_value, handle_event(gesture, terminal, drag_event, &sel));

    var ref: grid_ref.CGridRef = undefined;
    try testing.expectEqual(Result.success, terminal_c.grid_ref(terminal, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 1, .y = 0 } },
    }, &ref));
    try testing.expectEqual(Result.success, event_set(drag_event, .ref, &ref));
    try testing.expectEqual(Result.invalid_value, handle_event(gesture, terminal, drag_event, &sel));

    const invalid_geometry: Geometry = .{
        .columns = 5,
        .cell_width = 0,
        .padding_left = 0,
        .screen_height = 20,
    };
    try testing.expectEqual(Result.invalid_value, event_set(drag_event, .geometry, &invalid_geometry));
}

test "selection gesture event applies autoscroll tick" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{ .cols = 5, .rows = 2, .max_scrollback = 10_000 },
    ));
    defer terminal_c.free(terminal);

    terminal_c.vt_write(terminal, "abcde\r\nfghij", 12);

    var gesture: Gesture = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &gesture,
    ));
    defer free(gesture, terminal);

    var press_event: Event = null;
    try testing.expectEqual(Result.success, event_new(
        &lib.alloc.test_allocator,
        &press_event,
        .press,
    ));
    defer event_free(press_event);

    var drag_event: Event = null;
    try testing.expectEqual(Result.success, event_new(
        &lib.alloc.test_allocator,
        &drag_event,
        .drag,
    ));
    defer event_free(drag_event);

    var tick_event: Event = null;
    try testing.expectEqual(Result.success, event_new(
        &lib.alloc.test_allocator,
        &tick_event,
        .autoscroll_tick,
    ));
    defer event_free(tick_event);

    const geometry: Geometry = .{
        .columns = 5,
        .cell_width = 10,
        .padding_left = 0,
        .screen_height = 20,
    };

    var press_ref: grid_ref.CGridRef = undefined;
    try testing.expectEqual(Result.success, terminal_c.grid_ref(terminal, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 1, .y = 0 } },
    }, &press_ref));
    try testing.expectEqual(Result.success, event_set(press_event, .ref, &press_ref));
    const press_pos: types.SurfacePosition = .{ .x = 10, .y = 10 };
    try testing.expectEqual(Result.success, event_set(press_event, .position, &press_pos));
    try testing.expectEqual(Result.no_value, handle_event(gesture, terminal, press_event, null));

    var drag_ref: grid_ref.CGridRef = undefined;
    try testing.expectEqual(Result.success, terminal_c.grid_ref(terminal, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 3, .y = 1 } },
    }, &drag_ref));
    try testing.expectEqual(Result.success, event_set(drag_event, .ref, &drag_ref));
    const drag_pos: types.SurfacePosition = .{ .x = 36, .y = 20 };
    try testing.expectEqual(Result.success, event_set(drag_event, .position, &drag_pos));
    try testing.expectEqual(Result.success, event_set(drag_event, .geometry, &geometry));
    var sel: selection_c.CSelection = undefined;
    try testing.expectEqual(Result.success, handle_event(gesture, terminal, drag_event, &sel));

    var autoscroll: Autoscroll = .none;
    try testing.expectEqual(Result.success, get(gesture, terminal, .autoscroll, &autoscroll));
    try testing.expectEqual(Autoscroll.down, autoscroll);

    const viewport: point.Coordinate = .{ .x = 3, .y = 1 };
    try testing.expectEqual(Result.success, event_set(tick_event, .viewport, &viewport));
    try testing.expectEqual(Result.success, event_set(tick_event, .position, &drag_pos));
    try testing.expectEqual(Result.success, event_set(tick_event, .geometry, &geometry));

    try testing.expectEqual(Result.success, handle_event(gesture, terminal, tick_event, &sel));
}

test "selection gesture autoscroll tick requires viewport and geometry" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{ .cols = 5, .rows = 2, .max_scrollback = 10_000 },
    ));
    defer terminal_c.free(terminal);

    var gesture: Gesture = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &gesture,
    ));
    defer free(gesture, terminal);

    var tick_event: Event = null;
    try testing.expectEqual(Result.success, event_new(
        &lib.alloc.test_allocator,
        &tick_event,
        .autoscroll_tick,
    ));
    defer event_free(tick_event);

    var sel: selection_c.CSelection = undefined;
    try testing.expectEqual(Result.invalid_value, handle_event(gesture, terminal, tick_event, &sel));

    const viewport: point.Coordinate = .{ .x = 1, .y = 0 };
    try testing.expectEqual(Result.success, event_set(tick_event, .viewport, &viewport));
    try testing.expectEqual(Result.invalid_value, handle_event(gesture, terminal, tick_event, &sel));

    var ref: grid_ref.CGridRef = undefined;
    try testing.expectEqual(Result.success, terminal_c.grid_ref(terminal, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 1, .y = 0 } },
    }, &ref));
    try testing.expectEqual(Result.invalid_value, event_set(tick_event, .ref, &ref));
}

test "selection gesture event applies deep press" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{ .cols = 5, .rows = 2, .max_scrollback = 10_000 },
    ));
    defer terminal_c.free(terminal);

    terminal_c.vt_write(terminal, "abcde", 5);

    var gesture: Gesture = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &gesture,
    ));
    defer free(gesture, terminal);

    var press_event: Event = null;
    try testing.expectEqual(Result.success, event_new(
        &lib.alloc.test_allocator,
        &press_event,
        .press,
    ));
    defer event_free(press_event);

    var deep_press_event: Event = null;
    try testing.expectEqual(Result.success, event_new(
        &lib.alloc.test_allocator,
        &deep_press_event,
        .deep_press,
    ));
    defer event_free(deep_press_event);

    var ref: grid_ref.CGridRef = undefined;
    try testing.expectEqual(Result.success, terminal_c.grid_ref(terminal, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 2, .y = 0 } },
    }, &ref));
    try testing.expectEqual(Result.success, event_set(press_event, .ref, &ref));
    try testing.expectEqual(Result.no_value, handle_event(gesture, terminal, press_event, null));

    var sel: selection_c.CSelection = undefined;
    try testing.expectEqual(Result.success, handle_event(gesture, terminal, deep_press_event, &sel));
    try testing.expectEqual(@as(u16, 0), sel.start.toPin().?.x);
    try testing.expectEqual(@as(u16, 4), sel.end.toPin().?.x);

    var dragged = false;
    try testing.expectEqual(Result.success, get(gesture, terminal, .dragged, &dragged));
    try testing.expect(dragged);

    const pos: types.SurfacePosition = .{ .x = 0, .y = 0 };
    try testing.expectEqual(Result.invalid_value, event_set(deep_press_event, .position, &pos));
}

test "selection gesture deep press without active anchor returns no value" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        .{ .cols = 5, .rows = 2, .max_scrollback = 10_000 },
    ));
    defer terminal_c.free(terminal);

    var gesture: Gesture = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &gesture,
    ));
    defer free(gesture, terminal);

    var deep_press_event: Event = null;
    try testing.expectEqual(Result.success, event_new(
        &lib.alloc.test_allocator,
        &deep_press_event,
        .deep_press,
    ));
    defer event_free(deep_press_event);

    var sel: selection_c.CSelection = undefined;
    try testing.expectEqual(Result.no_value, handle_event(gesture, terminal, deep_press_event, &sel));
}

test "selection gesture free null" {
    free(null, null);
}

test "selection gesture event free null" {
    event_free(null);
}
