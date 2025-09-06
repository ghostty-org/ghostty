const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;
const logpkg = @import("log.zig");
const Log = logpkg.Log;

/// This should be called once at the start of the program to intialize
/// some required state for signpost logging.
///
/// This is all to workaround a Zig bug:
/// https://github.com/ziglang/zig/issues/24370
pub fn init() void {
    if (__dso_handle != null) return;

    const sym = comptime sym: {
        const root = @import("root");

        // If we have a main function, use that as the symbol.
        if (@hasDecl(root, "main")) break :sym root.main;

        // Otherwise, we're in a library, so we just use the first
        // function in our root module. I actually don't know if this is
        // all required or if we can just use the real `__dso_handle` symbol,
        // but this seems to work for now.
        for (@typeInfo(root).@"struct".decls) |decl_info| {
            const decl = @field(root, decl_info.name);
            if (@typeInfo(@TypeOf(decl)) == .@"fn") break :sym decl;
        }

        @compileError("no functions found in root module");
    };

    // Since __dso_handle is not automatically populated by the linker,
    // we populate it by looking up the main function's module address
    // which should be a mach-o header.
    var info: DlInfo = undefined;
    const result = dladdr(sym, &info);
    assert(result != 0);
    __dso_handle = @ptrCast(@alignCast(info.dli_fbase));
}

/// This should REALLY be an extern var that is populated by the linker,
/// but there is a Zig bug: https://github.com/ziglang/zig/issues/24370
var __dso_handle: ?*c.mach_header = null;

// Import the necessary C functions and types
extern "c" fn dladdr(addr: ?*const anyopaque, info: *DlInfo) c_int;

// Define the Dl_info structure
const DlInfo = extern struct {
    dli_fname: [*:0]const u8, // Pathname of shared object
    dli_fbase: ?*anyopaque, // Base address of shared object
    dli_sname: [*:0]const u8, // Name of nearest symbol
    dli_saddr: ?*anyopaque, // Address of nearest symbol
};

/// Checks whether signpost logging is enabled for the given log handle.
/// Returns true if signposts will be recorded for this log, false otherwise.
/// This can be used to avoid expensive operations when signpost logging is disabled.
///
/// https://developer.apple.com/documentation/os/os_signpost_enabled?language=objc
pub fn enabled(log: *Log) bool {
    return c.os_signpost_enabled(@ptrCast(log));
}

/// Emits a signpost event - a single point in time marker.
/// Events are useful for marking when specific actions occur, such as
/// user interactions, state changes, or other discrete occurrences.
/// The event will appear as a vertical line in Instruments.
///
/// https://developer.apple.com/documentation/os/os_signpost_event_emit?language=objc
pub fn emitEvent(
    log: *Log,
    id: Id,
    comptime name: [:0]const u8,
) void {
    emitWithName(log, id, .event, name);
}

/// Marks the beginning of a time interval.
/// Use this with intervalEnd to measure the duration of operations.
/// The same ID must be used for both the begin and end calls.
/// Intervals appear as horizontal bars in Instruments timeline.
///
/// https://developer.apple.com/documentation/os/os_signpost_interval_begin?language=objc
pub fn intervalBegin(log: *Log, id: Id, comptime name: [:0]const u8) void {
    emitWithName(log, id, .interval_begin, name);
}

/// Marks the end of a time interval.
/// Must be paired with a prior intervalBegin call using the same ID.
/// The name should match the name used in intervalBegin.
/// Instruments will calculate and display the duration between begin and end.
///
/// https://developer.apple.com/documentation/os/os_signpost_interval_end?language=objc
pub fn intervalEnd(log: *Log, id: Id, comptime name: [:0]const u8) void {
    emitWithName(log, id, .interval_end, name);
}

/// The internal function to emit a signpost with a specific name.
fn emitWithName(
    log: *Log,
    id: Id,
    typ: Type,
    comptime name: [:0]const u8,
) void {
    // Init must be called by this point.
    assert(__dso_handle != null);

    var buf: [2]u8 = @splat(0);
    c._os_signpost_emit_with_name_impl(
        __dso_handle,
        @ptrCast(log),
        @intFromEnum(typ),
        @intFromEnum(id),
        name.ptr,
        "".ptr,
        &buf,
        buf.len,
    );
}

/// https://developer.apple.com/documentation/os/os_signpost_id_t?language=objc
pub const Id = enum(u64) {
    null = 0, // OS_SIGNPOST_ID_NULL
    invalid = 0xFFFFFFFFFFFFFFFF, // OS_SIGNPOST_ID_INVALID
    exclusive = 0xEEEEB0B5B2B2EEEE, // OS_SIGNPOST_ID_EXCLUSIVE
    _,

    /// Generates a new signpost ID for use with signpost operations.
    /// The ID is unique for the given log handle and can be used to track
    /// asynchronous operations or mark specific points of interest in the code.
    /// Returns a unique signpost ID that can be used with os_signpost functions.
    ///
    /// https://developer.apple.com/documentation/os/os_signpost_id_generate?language=objc
    pub fn generate(log: *Log) Id {
        return @enumFromInt(c.os_signpost_id_generate(@ptrCast(log)));
    }

    /// Creates a signpost ID based on a pointer value.
    /// This is useful for tracking operations associated with a specific object
    /// or memory location. The same pointer will always generate the same ID
    /// for a given log handle, allowing correlation of signpost events.
    /// Pass null to get the null signpost ID.
    ///
    /// https://developer.apple.com/documentation/os/os_signpost_id_for_pointer?language=objc
    pub fn forPointer(log: *Log, ptr: ?*anyopaque) Id {
        return @enumFromInt(c.os_signpost_id_make_with_pointer(
            @ptrCast(log),
            @ptrCast(ptr),
        ));
    }

    test "generate ID" {
        // We can't really test the return value because it may return null
        // if signposts are disabled.
        const id: Id = .generate(Log.create("com.mitchellh.ghostty", "test"));
        try std.testing.expect(id != .invalid);
    }

    test "generate ID for pointer" {
        var foo: usize = 0x1234;
        const id: Id = .forPointer(Log.create("com.mitchellh.ghostty", "test"), &foo);
        try std.testing.expect(id != .null);
    }
};

/// https://developer.apple.com/documentation/os/ossignposttype?language=objc
pub const Type = enum(u8) {
    event = 0, // OS_SIGNPOST_EVENT
    interval_begin = 1, // OS_SIGNPOST_INTERVAL_BEGIN
    interval_end = 2, // OS_SIGNPOST_INTERVAL_END

    pub const mask: u8 = 0x03; // OS_SIGNPOST_TYPE_MASK
};

/// Special os_log category values that surface in Instruments and other
/// tooling.
pub const Category = struct {
    /// Points of Interest appear as a dedicated track in Instruments.
    /// Use this for high-level application events that help understand
    /// the flow of your application.
    pub const points_of_interest: [:0]const u8 = "PointsOfInterest";

    /// Dynamic Tracing category enables runtime-configurable logging.
    /// Signposts in this category can be enabled/disabled dynamically
    /// without recompiling.
    pub const dynamic_tracing: [:0]const u8 = "DynamicTracing";

    /// Dynamic Stack Tracing category captures call stacks at signpost
    /// events. This provides deeper debugging information but has higher
    /// performance overhead.
    pub const dynamic_stack_tracing: [:0]const u8 = "DynamicStackTracing";
};

test {
    _ = Id;
}

test enabled {
    _ = enabled(Log.create("com.mitchellh.ghostty", "test"));
}

test "intervals" {
    init();

    const log = Log.create("com.mitchellh.ghostty", "test");
    defer log.release();

    // Test that we can begin and end an interval
    const id = Id.generate(log);
    intervalBegin(log, id, "Test Interval");
}
