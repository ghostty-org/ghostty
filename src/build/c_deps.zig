const std = @import("std");

const Config = @import("Config.zig");

pub const CDeps = enum {
    @"ghostty-h",
    @"ghostty-vt-h",
};

const Key = struct {
    dep: CDeps,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
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
        return h.final();
    }

    pub fn eql(_: Context, a: Key, b: Key, _: usize) bool {
        return a.dep == b.dep and
            a.target.result.cpu.arch == b.target.result.cpu.arch and
            a.target.result.cpu.features.eql(b.target.result.cpu.features) and
            a.target.result.os.tag == b.target.result.os.tag and
            a.target.result.abi == b.target.result.abi and
            a.optimize == b.optimize;
    }
};

var modules: std.ArrayHashMapUnmanaged(Key, Value, Context, false) = .empty;

pub const Options = struct {
    target: ?std.Build.ResolvedTarget = null,
    optimize: ?std.builtin.OptimizeMode = null,
};

var _translate_c_dep: ?*std.Build.Dependency = null;

/// Add the specified C dependency to the given module.
pub fn add(b: *std.Build, dep: CDeps, module: *std.Build.Module, config: *const Config, options: Options) !void {
    const translate_c = b.lazyImport(@This(), "translate_c") orelse return;
    const translate_c_dep = d1: {
        if (_translate_c_dep) |d2| break :d1 d2;
        const d3 = b.lazyDependency("translate_c", .{}) orelse return;
        _translate_c_dep = d3;
        break :d1 d3;
    };

    const target = options.target orelse config.target;
    const optimize = options.optimize orelse config.optimize;

    // TranslateC requires libc, and these targets don't have libc
    if (target.result.cpu.arch.isWasm()) return;
    if (target.result.os.tag == .windows) return;

    const key: Key = .{
        .dep = dep,
        .target = target,
        .optimize = optimize,
    };

    const value = modules.get(key) orelse value: {
        const value = switch (dep) {
            .@"ghostty-h" => v: {
                // Verify our internal libghostty header.
                const translated: translate_c.Translator = .init(translate_c_dep, .{
                    .c_source_file = b.addWriteFiles().add(
                        "ghostty_h_c.h",
                        \\#include <ghostty.h>
                        ,
                    ),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                });
                translated.addSystemIncludePath(b.path("include"));
                break :v translated.mod;
            },

            .@"ghostty-vt-h" => v: {
                // Verify our libghostty-vt header.
                const translated: translate_c.Translator = .init(translate_c_dep, .{
                    .c_source_file = b.addWriteFiles().add(
                        "ghostty_vt_h_c.h",
                        \\#include <ghostty/vt.h>
                        ,
                    ),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                });
                translated.addSystemIncludePath(b.path("include"));
                break :v translated.mod;
            },
        };

        try modules.put(b.allocator, key, value);
        break :value value;
    };

    module.addImport(@tagName(dep), value);
}
