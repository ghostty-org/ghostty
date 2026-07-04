//! The crash package contains all the logic around crash handling,
//! whether that's setting up the system to catch crashes (Sentry client),
//! introspecting crash reports, writing crash reports to disk, etc.

const std = @import("std");
const builtin = @import("builtin");

const dir = if (builtin.target.os.tag == .visionos)
    struct {
        pub const StubDir = struct {};
        pub const StubReportIterator = struct {};
        pub const StubReport = struct {
            name: []const u8 = "",
            mtime: i128 = 0,
        };

        pub const Dir = StubDir;
        pub const ReportIterator = StubReportIterator;
        pub const Report = StubReport;

        pub fn defaultDir(alloc: std.mem.Allocator) !StubDir {
            _ = alloc;
            return .{};
        }
    }
else
    @import("dir.zig");

const sentry_envelope = if (builtin.target.os.tag == .visionos)
    struct {
        pub const Envelope = struct {};
    }
else
    @import("sentry_envelope.zig");

pub const sentry = if (builtin.target.os.tag == .visionos)
    struct {
        pub const ThreadState = struct {
            type: Type,
            surface: *@import("../Surface.zig"),

            pub const Type = enum { main, renderer, io };
        };

        pub threadlocal var thread_state: ?ThreadState = null;

        pub fn init(alloc: std.mem.Allocator) !void {
            _ = alloc;
        }

        pub fn deinit() void {}
    }
else
    @import("sentry.zig");

pub const Envelope = sentry_envelope.Envelope;
pub const defaultDir = dir.defaultDir;
pub const Dir = dir.Dir;
pub const ReportIterator = dir.ReportIterator;
pub const Report = dir.Report;

// The main init/deinit functions for global state.
pub const init = sentry.init;
pub const deinit = sentry.deinit;

test {
    @import("std").testing.refAllDecls(@This());
}
