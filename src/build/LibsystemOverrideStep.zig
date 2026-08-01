//! Wraps a Darwin static archive with the libsystem_override.sh
//! post-processing step so that consumers linking the archive bind
//! well-known libc/libm symbols (memcpy, memmove, memset, cos, sin,
//! ...) to Apple's libSystem instead of the bundled Zig compiler-rt.
//! See src/build/libsystem_override.sh for the full rationale.
//!
//! This applies to every static archive we produce, public
//! (e.g. libghostty-vt) and app-internal alike: the compiler-rt
//! bundle must stay because the few symbols libSystem does not
//! provide (f128 conversions, *q math, sincos*, ___zig_probe_stack)
//! have live references, e.g. from the bundled ubsan runtime and
//! x86_64 stack probing in Debug builds.
//!
//! Note shared libraries can't use either approach: Zig 0.16 links
//! compiler-rt as an eagerly-included object, so its definitions are
//! already bound into the dylib at link time and cannot be repaired
//! post-hoc. That needs an upstream Zig fix.
const std = @import("std");
const builtin = @import("builtin");

pub const Result = struct {
    /// The step performing the override, or null if the override
    /// doesn't apply to this target/host (in which case `output` is
    /// the unmodified input).
    step: ?*std.Build.Step,
    output: std.Build.LazyPath,
};

/// Post-process the given static archive on Darwin. Requires a Darwin
/// host for the Apple toolchain (nmedit); in all other configurations
/// this is a no-op and the input is returned unmodified, which is
/// functional (the bundled compiler-rt symbols are used), just slower.
pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    input: std.Build.LazyPath,
    out_name: []const u8,
) Result {
    if (!target.result.os.tag.isDarwin() or
        comptime !builtin.os.tag.isDarwin())
    {
        return .{ .step = null, .output = input };
    }

    const run = b.addSystemCommand(&.{"/bin/sh"});
    run.setName("libsystem override");
    run.addFileArg(b.path("src/build/libsystem_override.sh"));
    run.addFileArg(input);
    const output = run.addOutputFileArg(out_name);
    return .{ .step = &run.step, .output = output };
}
