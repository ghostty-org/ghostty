//! A single benchmark case.
const Benchmark = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const macos = @import("macos");
const build_config = @import("../build_config.zig");

ptr: *anyopaque,
vtable: VTable,

/// Create a new benchmark from a pointer and a vtable.
///
/// This usually is only called by benchmark implementations, not
/// benchmark users.
pub fn init(
    pointer: anytype,
    vtable: VTable,
) Benchmark {
    const Ptr = @TypeOf(pointer);
    assert(@typeInfo(Ptr) == .pointer); // Must be a pointer
    assert(@typeInfo(Ptr).pointer.size == .one); // Must be a single-item pointer
    assert(@typeInfo(@typeInfo(Ptr).pointer.child) == .@"struct"); // Must point to a struct
    return .{ .ptr = pointer, .vtable = vtable };
}

/// Run the benchmark.
pub fn run(
    self: Benchmark,
    mode: RunMode,
) Error!RunResult {
    // Run our setup function if it exists. We do this first because
    // we don't want this part of our benchmark and we want to fail fast.
    if (self.vtable.setupFn) |func| try func(self.ptr);
    defer if (self.vtable.teardownFn) |func| func(self.ptr);

    // Our result accumulator. This will be returned at the end of the run.
    var result: RunResult = .{};

    // If we're on macOS, we setup signposts so its easier to find
    // the results in Instruments. There's a lot of nasty comptime stuff
    // here but its just to ensure this does nothing on other platforms.
    const signpost_name = "ghostty";
    const signpost: if (builtin.target.os.tag.isDarwin()) struct {
        log: *macos.os.Log,
        id: macos.os.signpost.Id,
    } else void = if (builtin.target.os.tag.isDarwin()) darwin: {
        macos.os.signpost.init();
        const log = macos.os.Log.create(
            build_config.bundle_id,
            macos.os.signpost.Category.points_of_interest,
        );
        const id = macos.os.signpost.Id.forPointer(log, self.ptr);
        macos.os.signpost.intervalBegin(log, id, signpost_name);
        break :darwin .{ .log = log, .id = id };
    } else {};
    defer if (comptime builtin.target.os.tag.isDarwin()) {
        macos.os.signpost.intervalEnd(
            signpost.log,
            signpost.id,
            signpost_name,
        );
        signpost.log.release();
    };

    const start = std.time.Instant.now() catch return error.BenchmarkFailed;
    while (true) {
        // Run our step function. If it fails, we return the error.
        try self.vtable.stepFn(self.ptr);
        result.iterations += 1;

        // Get our current monotonic time and check our exit conditions.
        const now = std.time.Instant.now() catch return error.BenchmarkFailed;
        const exit = switch (mode) {
            .once => true,
            .duration => |ns| now.since(start) >= ns,
        };

        if (exit) {
            result.duration = now.since(start);
            return result;
        }
    }

    // We exit within the loop body.
    unreachable;
}

/// The type of benchmark run. This is used to determine how the benchmark
/// is executed.
pub const RunMode = union(enum) {
    /// Run the benchmark exactly once.
    once,

    /// Run the benchmark for a fixed duration in nanoseconds. This
    /// will not interrupt a running step so if the granularity of the
    /// duration is too low, benchmark results may be inaccurate.
    duration: u64,
};

/// The result of a benchmark run.
pub const RunResult = struct {
    /// The total iterations that step was executed. For "once" run
    /// modes this will always be 1.
    iterations: u32 = 0,

    /// The total time taken for the run. For "duration" run modes
    /// this will be relatively close to the requested duration.
    /// The units are nanoseconds.
    duration: u64 = 0,
};

/// The possible errors that can occur during various stages of the
/// benchmark. Right now its just "failure" which ends the benchmark.
pub const Error = error{BenchmarkFailed};

/// The vtable that must be provided to invoke the real implementation.
pub const VTable = struct {
    /// A single step to execute the benchmark. This should do the work
    /// that is under test. This may be called multiple times if we're
    /// testing throughput.
    stepFn: *const fn (ptr: *anyopaque) Error!void,

    /// Setup and teardown functions. These are called once before
    /// the first step and once after the last step. They are not part
    /// of the benchmark results (unless you're benchmarking the full
    /// binary).
    setupFn: ?*const fn (ptr: *anyopaque) Error!void = null,
    teardownFn: ?*const fn (ptr: *anyopaque) void = null,
};

test Benchmark {
    // This test fails on FreeBSD so skip:
    //
    // /home/runner/work/ghostty/ghostty/src/benchmark/Benchmark.zig:165:5: 0x3cd2de1 in decltest.Benchmark (ghostty-test)
    //     try testing.expect(result.duration > 0);
    //     ^
    if (builtin.os.tag == .freebsd) return error.SkipZigTest;

    const testing = std.testing;
    const Simple = struct {
        const Self = @This();

        setup_i: usize = 0,
        step_i: usize = 0,

        pub fn benchmark(self: *Self) Benchmark {
            return .init(self, .{
                .stepFn = step,
                .setupFn = setup,
            });
        }

        fn setup(ptr: *anyopaque) Error!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.setup_i += 1;
        }

        fn step(ptr: *anyopaque) Error!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.step_i += 1;
        }
    };

    var s: Simple = .{};
    const b = s.benchmark();
    const result = try b.run(.once);
    try testing.expectEqual(1, s.setup_i);
    try testing.expectEqual(1, s.step_i);
    try testing.expectEqual(1, result.iterations);
    try testing.expect(result.duration > 0);
}
