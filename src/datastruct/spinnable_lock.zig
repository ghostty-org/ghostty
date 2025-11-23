const std = @import("std");
const builtin = @import("builtin");

// TODO: Explore thread safety; we have a 32 bit lock value,
//       so we might as well use it to store the thread ID
//       there (ensuring that 0 isn't a valid thread ID),
//       and then at least in debug mode add some asserts
//       about ownership with that.

/// How many times we loop when trying to obtain the lock
/// by spinning before we give up and use the futex instead.
///
/// This number is arbitrary and I just based it on some other
/// spin-then-block lock implementations I've seen in the wild.
///
/// NOTE(Qwerasd):
/// This number seems to work well for Ghostty, at least on
/// my machine, and my assumption is that on proportionally
/// slower machines the individual checks will take longer,
/// so it won't create a drastic difference where the lock
/// doesn't work as intended on certain machines.
const spin_tries = 10_000;

pub const LockingMethod = enum {
    /// Spin on the lock for a bit before giving up and
    /// using the futex instead. We give up because we
    /// don't want to waste too much CPU time if we're
    /// wrong about the lock being released soon.
    ///
    /// Use this if you're reasonably certain that the
    /// lock won't be held by anyone else for very long.
    ///
    /// (Very long being more than a few thousand cycles.)
    spin_then_block,

    /// Use the futex to lock, you should use this when
    /// you're not sure whether whoever is holding the
    /// lock might hold it for a considerable period of
    /// time.
    futex,
};

/// A futex-based lock which provides a method to spin
/// the lock for some time before deferring to a futex.
///
/// This is useful for when you are reasonably certain
/// that no other thread will hold the lock for very
/// long (more than a few thousand cycles), since if
/// that's the case then the futex will be quite slow
/// since the thread has to go to sleep and wakes back
/// up in order to obtain the lock, which can take an
/// order of magnitude longer than the lock was really
/// held for in reality.
pub fn SpinnableLock(comptime default_locking_method: LockingMethod) type {
    return extern struct {
        const Self = @This();

        value: u32 = 0,

        /// Use the default locking method to obtain the lock.
        ///
        /// In order to use a different method, use `lockWith`.
        pub inline fn lock(self: *Self) void {
            self.lockWith(default_locking_method);
        }

        /// Obtain the lock using the specified method.
        pub inline fn lockWith(
            self: *Self,
            comptime method: LockingMethod,
        ) void {
            switch (method) {
                .spin_then_block => self.lockSpinThenBlock(),
                .futex => self.lockFutex(),
            }
        }

        /// Try to obtain the lock.
        ///
        /// Returns true if successful, false otherwise.
        pub inline fn tryLock(self: *Self) bool {
            const ptr: *u32 = @ptrCast(self);
            return @atomicLoad(u32, ptr, .monotonic) == 0 and
                @cmpxchgWeak(u32, ptr, 0, 1, .acquire, .monotonic) == null;
        }

        /// Release the lock.
        pub inline fn unlock(self: *Self) void {
            // We need to use `release` ordering here to
            // ensure that the critical section does not
            // get reordered before this write.
            @atomicStore(u32, &self.value, 0, .release);
            @call(
                .always_inline,
                std.Thread.Futex.wake,
                .{ @as(*const std.atomic.Value(u32), @ptrCast(self)), 1 },
            );
        }

        inline fn lockSpinThenBlock(self: *Self) void {
            var tries: usize = spin_tries;
            while (tries > 0) : (tries -= 1) {
                if (self.tryLock()) {
                    // Optimize for the uncontended case.
                    @branchHint(.likely);
                    return;
                }
                std.atomic.spinLoopHint();
            } else {
                // Optimize for the success of the spin lock, if this
                // is regularly failing over to the futex then someone
                // is using it wrong, since you should only spin lock
                // if you're relatively certain you'll get it within
                // the spin section.
                @branchHint(.cold);
                self.lockFutex();
            }
        }

        inline fn lockFutex(self: *Self) void {
            const ptr: *u32 = @ptrCast(self);
            while (true) {
                std.Thread.Futex.wait(@ptrCast(ptr), 1);
                if (self.tryLock()) return;
            }
        }
    };
}
