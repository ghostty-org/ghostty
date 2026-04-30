//! A library for injecting failures into Zig code for the express
//! purpose of testing error handling paths.
//!
//! Improper `errdefer` is one of the highest sources of bugs in Zig code.
//! Many `errdefer` points are hard to exercise in unit tests and rare
//! to encounter in production, so they often hide bugs. Worse, error
//! scenarios are most likely to put your code in an unexpected state
//! that can result in future assertion failures or memory safety issues.
//!
//! This module aims to solve this problem by providing a way to inject
//! errors at specific points in your code during unit tests, allowing you
//! to test every possible error path.
//!
//! # Usage
//!
//! To use this package, create a `tripwire.module` for each failable
//! function you want to test. The enum must be hand-curated to be the
//! set of fail points, and the error set comes directly from the function
//! itself.
//!
//! Pepper your function with `try tw.check` calls wherever you want to
//! have a testable failure point. You don't need every "try" to have
//! an associated tripwire check, only the ones you care about testing.
//! Usually, this is going to be the points where you want to test
//! errdefer logic above it.
//!
//! In unit tests, add `try tw.errorAlways` or related calls to
//! configure expected failures. Then, call your function. Finally, always
//! call `try tw.end(.reset)` to verify your expectations were met and
//! to reset the tripwire module for future tests.
//!
//! ```
//! const tw = tripwire.module(enum { alloc_buf, open_file }, myFunction);
//!
//! fn myFunction() tw.Error!void {
//!     try tw.check(.alloc_buf);
//!     const buf = try allocator.alloc(u8, 1024);
//!     errdefer allocator.free(buf);
//!
//!     try tw.check(.open_file);
//!     const file = try std.fs.cwd().openFile("foo.txt", .{});
//!     // ...
//! }
//!
//! test "myFunction fails on alloc" {
//!     tw.errorAlways(.alloc_buf, error.OutOfMemory);
//!     try std.testing.expectError(error.OutOfMemory, myFunction());
//!     try tw.end(.reset);
//! }
//! ```
//!
//! ## Transitive Function Calls
//!
//! To test transitive calls, there are two schools of thought:
//!
//!   1. Put a failure point above the transitive call in the caller
//!      and assume the child function error handling works correctly.
//!
//!   2. Create another tripwire module for the child function and
//!      trigger failures there. This is recommended if the child function
//!      can't really be called in isolation (e.g. its an auxiliary function
//!      to a public API).
//!
//! Either works, its situationally dependent which is better.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const testing = std.testing;

const log = std.log.scoped(.tripwire);

// Future ideas:
//
//   - Assert that the errors are actually tripped. e.g. you set a
//     errorAlways on a point, and want to verify it was tripped.
//   - Assert that every point is covered by at least one test. We
//     can probably use global state for this.
//   - Error only after a certain number of calls to a point.
//   - Error only on a range of calls (first 5 times, 2-7th time, etc.)
//
// I don't want to implement these until they're actually needed by
// some part of our codebase, but I want to list them here in case they
// do become useful.

/// A tripwire module that can be used to inject failures at specific points.
///
/// Outside of unit tests, this module is free and completely optimized away.
/// It takes up zero binary or runtime space and all function calls are
/// optimized out.
///
/// To use this module, add `check` (or related) calls prior to every
/// `try` operation that you want to be able to fail arbitrarily. Then,
/// in your unit tests, call the `error` family of functions to configure
/// when errors should be injected.
///
/// P is an enum type representing the failure points in the module.
/// E is the error set of possible errors that can be returned from the
/// failure points. You can use `anyerror` here but note you may have to
/// use `checkConstrained` to narrow down the error type when you call
/// it in your function (so your function can compile).
///
/// E may also be an error union type, in which case the error set of that
/// union is used as the error set for the tripwire module.
/// If E is a function, then the error set of the return value of that
/// function is used as the error set for the tripwire module.
pub fn module(
    comptime P: type,
    comptime E: anytype,
) type {
    return struct {
        /// The points this module can fail at.
        pub const FailPoint = P;

        /// The error set used for failures at the failure points.
        pub const Error = err: {
            const T = if (@TypeOf(E) == type) E else @TypeOf(E);
            break :err switch (@typeInfo(T)) {
                .error_set => E,
                .error_union => |info| info.error_set,
                .@"fn" => |info| @typeInfo(info.return_type.?).error_union.error_set,
                else => @compileError("E must be an error set or function type"),
            };
        };

        /// Whether our module is enabled or not. In the future we may
        /// want to make this a comptime parameter to the module.
        pub const enabled = builtin.is_test;

        comptime {
            assert(@typeInfo(FailPoint) == .@"enum");
            assert(@typeInfo(Error) == .error_set);
        }

        /// The configured tripwires for this module.
        var tripwires: TripwireMap = .{};
        const TripwireMap = std.EnumMap(FailPoint, Tripwire);
        const Tripwire = struct {
            /// Error to return when tripped
            err: Error,

            /// The amount of times this tripwire has been reached. This
            /// is NOT the number of times it has tripped, since we may
            /// have mins for that.
            reached: usize = 0,

            /// The minimum number of times this must be reached before
            /// tripping. After this point, it trips every time. This is
            /// a "before" check so if this is "1" then it'll trip the
            /// second time it's reached.
            min: usize = 0,

            /// True if this has been tripped at least once.
            tripped: bool = false,
        };

        /// Check for a failure at the given failure point. These should
        /// be placed directly before the `try` operation that may fail.
        pub fn check(point: FailPoint) callconv(callingConvention()) Error!void {
            if (comptime !enabled) return;
            return checkConstrained(point, Error);
        }

        /// Same as check but allows specifying a custom error type for the
        /// return value. This must be a subset of the module's Error type
        /// and will produce a runtime error if the configured tripwire
        /// error can't be cast to the ConstrainedError type.
        pub fn checkConstrained(
            point: FailPoint,
            comptime ConstrainedError: type,
        ) callconv(callingConvention()) ConstrainedError!void {
            if (comptime !enabled) return;
            const tripwire = tripwires.getPtr(point) orelse return;
            tripwire.reached += 1;
            if (tripwire.reached <= tripwire.min) return;
            tripwire.tripped = true;
            return tripwire.err;
        }

        /// Mark a failure point to always trip with the given error.
        pub fn errorAlways(point: FailPoint, err: Error) void {
            errorAfter(point, err, 0);
        }

        /// Mark a failure point to trip with the given error after
        /// the failure point is reached at least `min` times. A value of
        /// zero is equivalent to `errorAlways`.
        pub fn errorAfter(point: FailPoint, err: Error, min: usize) void {
            tripwires.put(point, .{ .err = err, .min = min });
        }

        /// Ends the tripwire session. This will raise an error if there
        /// were untripped error expectations. The reset mode specifies
        /// whether expectations are reset too. Expectations are always reset,
        /// even if this returns an error.
        pub fn end(reset_mode: enum { reset, retain }) error{UntrippedError}!void {
            var untripped: bool = false;
            var iter = tripwires.iterator();
            while (iter.next()) |entry| {
                if (!entry.value.tripped) {
                    log.warn("untripped point={s}", .{@tagName(entry.key)});
                    untripped = true;
                }
            }

            switch (reset_mode) {
                .reset => reset(),
                .retain => {},
            }

            if (untripped) return error.UntrippedError;
        }

        /// Unset all the tripwires. You should usually call `end` instead.
        pub fn reset() void {
            tripwires = .{};
        }

        /// Our calling convention is inline if our tripwire module is
        /// NOT enabled, so that all calls to `check` are optimized away.
        fn callingConvention() std.builtin.CallingConvention {
            return if (!enabled) .@"inline" else .auto;
        }
    };
}

test {
    const io = module(enum {
        read,
        write,
    }, anyerror);

    // Reset should work
    try io.end(.reset);

    // By default, its pass-through
    try io.check(.read);

    // Always trip
    io.errorAlways(.read, error.OutOfMemory);
    try testing.expectError(
        error.OutOfMemory,
        io.check(.read),
    );
    // Happens again
    try testing.expectError(
        error.OutOfMemory,
        io.check(.read),
    );
    try io.end(.reset);
}

test "module as error set" {
    const io = module(enum { read, write }, @TypeOf((struct {
        fn func() error{ Foo, Bar }!void {
            return error.Foo;
        }
    }).func));
    try io.end(.reset);
}

test "errorAfter" {
    const io = module(enum { read, write }, anyerror);
    // Trip after 2 calls (on the 3rd call)
    io.errorAfter(.read, error.OutOfMemory, 2);

    // First two calls succeed
    try io.check(.read);
    try io.check(.read);

    // Third call and on trips
    try testing.expectError(error.OutOfMemory, io.check(.read));
    try testing.expectError(error.OutOfMemory, io.check(.read));

    try io.end(.reset);
}

test "errorAfter untripped error if min not reached" {
    const io = module(enum { read }, anyerror);
    io.errorAfter(.read, error.OutOfMemory, 2);
    // Only call once, not enough to trip
    try io.check(.read);
    // end should fail because tripwire was set but never tripped
    try testing.expectError(
        error.UntrippedError,
        io.end(.reset),
    );
}
