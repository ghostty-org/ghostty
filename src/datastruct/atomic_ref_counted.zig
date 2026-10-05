const std = @import("std");
const Allocator = std.mem.Allocator;

/// Shared ownership of a value with a deinit(Allocator) method. Implemented by
/// atomic reference-counting to defer deinit to the last reference.
///
/// The allocator used to initialize the control block must be the same as the
/// allocator of the value so that .deinit(alloc) can free inner allocations.
///
/// Like Rust's Arc, clone shares ownership and makeMut clones the inner value
/// only when it is shared. .makeMut() requires T.dupe(Allocator) for deep
/// copying. https://doc.rust-lang.org/std/sync/struct.Arc.html#method.make_mut
///
/// The allocator used must outlive all references and support cross-thread
/// frees when references are transferred between threads.
pub fn AtomicRefCounted(comptime T: type) type {
    return struct {
        const Self = @This();

        refs: std.atomic.Value(usize) = .init(1),
        value: T,

        /// Initialise an instance, after this point the data is still uniquely
        /// owned until a copy of the shared AtomicRefCounted(T) is made with
        /// .clone(). On allocation failure the caller retains ownership of
        /// value.
        pub fn init(alloc: Allocator, value: T) Allocator.Error!*const Self {
            const result = try alloc.create(Self);
            result.* = .{ .value = value };
            return result;
        }

        /// Clone shared ownership, incrementing the ref-count, without copying
        /// the inner value.
        ///
        /// Paired with .release(alloc) to decrement.
        pub fn clone(self: *const Self) *const Self {
            const previous = @constCast(self).refs.fetchAdd(1, .monotonic);
            if (previous >= std.math.maxInt(isize))
                @panic("AtomicRefCounted reference count overflow");
            std.debug.assert(previous > 0);
            return self;
        }

        /// Release to decrement the ref-count, potentially deinitialising the
        /// inner allocation as well if the ref-count drops to 0.
        pub fn release(self: *const Self, alloc: Allocator) void {
            const mutable = @constCast(self);
            const previous = mutable.refs.fetchSub(1, .release);
            std.debug.assert(previous > 0);
            if (previous == 1) {
                _ = mutable.refs.load(.acquire);
                mutable.value.deinit(alloc);
                alloc.destroy(mutable);
            }
        }

        /// Return an owned value safe for mutation, replacing this handle with
        /// a clone of the value if other owners exist. Failure leaves the
        /// handle unchanged.
        pub fn makeMut(handle: **const Self, alloc: Allocator) Allocator.Error!*T {
            comptime {
                if (!std.meta.hasFn(T, "dupe"))
                    @compileError("AtomicRefCounted(" ++ @typeName(T) ++ ").makeMut requires pub fn dupe(*const T, Allocator) Allocator.Error!T");
                _ = @as(*const fn (*const T, Allocator) Allocator.Error!T, &T.dupe);
            }
            const current = handle.*;
            // Acquire synchronizes with prior owners' releases before mutation.
            if (current.refs.load(.acquire) == 1) return &@constCast(current).value;

            var copy = try current.value.dupe(alloc);
            errdefer copy.deinit(alloc);
            const replacement = try Self.init(alloc, copy);
            handle.* = replacement;
            current.release(alloc);
            return &@constCast(replacement).value;
        }
    };
}

test "AtomicRefCounted releases the inner value only on final release" {
    const Value = struct {
        destroyed: *usize,

        pub fn deinit(self: *@This(), _: Allocator) void {
            self.destroyed.* += 1;
        }
    };
    const Arc = AtomicRefCounted(Value);
    const alloc = std.testing.allocator;
    var destroyed: usize = 0;
    const shared = try Arc.init(alloc, .{ .destroyed = &destroyed });
    try std.testing.expectEqual(1, shared.refs.load(.monotonic));
    const retained = shared.clone();
    try std.testing.expectEqual(2, retained.refs.load(.monotonic));
    shared.release(alloc);
    try std.testing.expectEqual(1, retained.refs.load(.monotonic));
    try std.testing.expectEqual(0, destroyed);
    retained.release(alloc);
    try std.testing.expectEqual(1, destroyed);

    const unique = try Arc.init(alloc, .{ .destroyed = &destroyed });
    try std.testing.expectEqual(1, unique.refs.load(.monotonic));
    try std.testing.expectEqual(1, destroyed);
    unique.release(alloc);
    try std.testing.expectEqual(2, destroyed);
}
