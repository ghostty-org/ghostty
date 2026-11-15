const std = @import("std");
const translate_c = @import("translate_c");

const Config = @import("Config.zig");

pub const CDeps = enum {
    @"ghostty-h",
    @"ghostty-vt-h",
};

const Key = struct {
    dep: CDeps,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    link_libc: bool,
};

const Value = *std.Build.Module;

const Context = struct {
    pub fn hash(_: Context, key: Key) u32 {
        var h: std.hash.XxHash32 = .init(0);
        h.update(std.mem.asBytes(&key.dep));
        h.update(std.mem.asBytes(&key.target.result.cpu.arch));
        h.update(key.target.result.cpu.features.asBytes());
        h.update(std.mem.asBytes(&key.target.result.os.tag));
        h.update(std.mem.asBytes(&key.target.result.abi));
        h.update(std.mem.asBytes(&key.optimize));
        h.update(std.mem.asBytes(&key.link_libc));
        return h.final();
    }

    pub fn eql(_: Context, a: Key, b: Key, _: usize) bool {
        return a.dep == b.dep and
            a.target.result.cpu.arch == b.target.result.cpu.arch and
            a.target.result.cpu.features.eql(b.target.result.cpu.features) and
            a.target.result.os.tag == b.target.result.os.tag and
            a.target.result.abi == b.target.result.abi and
            a.optimize == b.optimize and
            a.link_libc == b.link_libc;
    }
};

var modules: std.ArrayHashMapUnmanaged(Key, Value, Context, false) = .empty;

pub const Options = struct {
    /// Defaults to the module's target, then the config's.
    target: ?std.Build.ResolvedTarget = null,

    /// Defaults to the module's optimize mode, then the config's.
    optimize: ?std.builtin.OptimizeMode = null,
};

/// Add the specified C dependency to the given module.
///
/// The header is translated for the module's own target unless `options`
/// says otherwise, since a test comparing C and Zig layouts is only
/// meaningful when both were laid out for the same target.
pub fn add(b: *std.Build, dep: CDeps, module: *std.Build.Module, config: *const Config, options: Options) !void {
    const target = options.target orelse module.resolved_target orelse config.target;
    const optimize = options.optimize orelse module.optimize orelse config.optimize;

    const link_libc = switch (dep) {
        // `ghostty.h` includes `<sys/types.h>`, which needs libc, and these
        // targets don't have one.
        .@"ghostty-h" => link_libc: {
            if (target.result.cpu.arch.isWasm()) return;
            if (target.result.os.tag == .windows) return;
            break :link_libc true;
        },

        // `ghostty/vt.h` needs nothing beyond stdint.h, stddef.h,
        // stdbool.h and limits.h, which the compiler provides, so it
        // translates for every target. Link libc only if the module
        // already does. Turning libc on would also change the module
        // itself. On wasm32-wasi, for example, it switches `std.posix` to
        // the libc definitions and breaks the build.
        .@"ghostty-vt-h" => module.link_libc orelse false,
    };

    const key: Key = .{
        .dep = dep,
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
    };

    const value = modules.get(key) orelse value: {
        const translated = try translate_c.init(b, .{
            .source = .{
                .includes = .{
                    .generated_name = b.fmt("{s}.h", .{@tagName(dep)}),
                    .files = &.{.{
                        .path = switch (dep) {
                            // Verify our internal libghostty header.
                            .@"ghostty-h" => "ghostty.h",
                            // Verify our libghostty-vt header.
                            .@"ghostty-vt-h" => "ghostty/vt.h",
                        },
                    }},
                },
            },
            .target = target,
            .optimize = optimize,
            .link_libc = link_libc,
            .system_include_paths = &.{b.path("include")},
        });
        const value = translated.mod;

        try modules.put(b.allocator, key, value);
        break :value value;
    };

    module.addImport(@tagName(dep), value);
}
