const std = @import("std");

/// A generic way to dispatch version checks of a runtime dependency.
///
/// The runtimeVersion function is expected to be created from the library we link against.
/// The comptime_version is optional
pub fn VersionChecked(
    comptime dependency_name: []const u8,
    comptime log_scope: @TypeOf(std.log.scoped(.enum_literal)),
    comptime getRuntimeVersion: fn () std.SemanticVersion,
    comptime comptime_version_: ?std.SemanticVersion,
) type {
    return struct {
        const Self = @This();
        const name = dependency_name;
        const log = log_scope;
        const comptime_version = comptime_version_;

        /// Verifies that the running dependency version is at least the given
        /// version.
        ///
        /// This can be run in both a comptime and runtime context. If it is run in a
        /// comptime context, it will only check the version in the headers. If it is
        /// run in a runtime context, it will check the actual version of the library we
        /// are linked against. So generally  you probably want to do both checks!
        ///
        /// This is inlined so that the comptime checks will disable the runtime checks
        /// if the comptime checks fail.
        pub inline fn atLeast(
            comptime major: u16,
            comptime minor: u16,
            comptime micro: u16,
        ) bool {

            // If no comptime version is known or our header has lower versions than the
            // given version, we can return false immediately. This prevents us from compiling
            // against unknown symbols and makes runtime checks very slightly faster.
            comptime if (Self.comptime_version) |version| {
                if (version.order(.{
                    .major = major,
                    .minor = minor,
                    .patch = micro,
                }) == .lt) return false;
            };

            // If we're in comptime then we can't check the runtime version.
            if (@inComptime()) return true;

            return Self.runtimeAtLeast(major, minor, micro);
        }

        pub inline fn until(
            comptime major: u16,
            comptime minor: u16,
            comptime micro: u16,
        ) bool {

            // If no comptime version is known or our header has lower versions than the
            // given version, we can return false immediately. This prevents us from compiling
            // against unknown symbols and makes runtime checks very slightly faster.
            comptime if (Self.comptime_version) |version| {
                if (version.order(.{
                    .major = major,
                    .minor = minor,
                    .patch = micro,
                }) == .lt) return true;
            };

            // If we're in comptime then we can't check the runtime version.
            if (@inComptime()) return false;

            return Self.runtimeUntil(major, minor, micro);
        }

        /// Verifies that the dependency version at runtime is at least the given version.
        ///
        /// This function should be used in cases where only the runtime behavior
        /// is affected by the version check. For checks which would affect code
        /// generation, use `atLeast`.
        pub inline fn runtimeAtLeast(
            comptime major: u16,
            comptime minor: u16,
            comptime micro: u16,
        ) bool {
            // We use the functions instead of the constants such as c.GTK_MINOR_VERSION
            // because the function gets the actual runtime version.
            const runtime_version = getRuntimeVersion();
            return runtime_version.order(.{
                .major = major,
                .minor = minor,
                .patch = micro,
            }) != .lt;
        }

        /// Verifies that the dependency version is less than the given version.
        ///
        /// This function should be used when only the runtime version matters.
        /// Instead use the `until` function to perform a comptime check for
        /// the version being built against matters for code generation while falling
        /// back to the runtime check.
        pub inline fn runtimeUntil(
            comptime major: u16,
            comptime minor: u16,
            comptime micro: u16,
        ) bool {
            const runtime_version = getRuntimeVersion();
            return runtime_version.order(.{
                .major = major,
                .minor = minor,
                .patch = micro,
            }) == .lt;
        }

        pub fn logVersion() void {
            if (Self.comptime_version) |comptime_version__| {
                Self.log.info("{s} version build={} runtime={}", .{
                    Self.name,
                    comptime_version__,
                    getRuntimeVersion(),
                });
            } else {
                Self.log.info("{s} version runtime={}", .{
                    Self.name,
                    getRuntimeVersion(),
                });
            }
        }

        test "atLeast" {
            const testing = std.testing;
            const version = Self.comptime_version orelse std.SemanticVersion{ 1, 1, 1 };

            const funs = &.{ atLeast, runtimeAtLeast, runtimeUntil };
            inline for (funs) |fun| {
                try testing.expect(fun(version.major, version.minor, version.patch));

                try testing.expect(!fun(version.major, version.minor, version.patch + 1));
                try testing.expect(!fun(version.major, version.minor + 1, version.patch));
                try testing.expect(!fun(version.major + 1, version.minor, version.patch));

                try testing.expect(fun(version.major - 1, version.minor, version.patch));
                try testing.expect(fun(version.major - 1, version.minor + 1, version.patch));
                try testing.expect(fun(version.major - 1, version.minor, version.patch + 1));

                try testing.expect(fun(version.major, version.minor - 1, version.patch + 1));
            }
        }
    };
}
