const std = @import("std");

pub const Module = enum {
    datastruct,
    fastmem,
    quirks,
    tripwire,
};

const Key = struct {
    dep: Module,
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

fn get(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, dep: Module) *std.Build.Module {
    const key: Key = .{
        .dep = dep,
        .target = target,
        .optimize = optimize,
    };

    return modules.get(key) orelse mod: {
        const value = switch (dep) {
            .datastruct => b.createModule(.{
                .root_source_file = b.path("src/datastruct/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{
                        .name = "fastmem",
                        .module = get(b, target, optimize, .fastmem),
                    },
                    .{
                        .name = "quirks",
                        .module = get(b, target, optimize, .quirks),
                    },
                },
            }),
            .fastmem => b.createModule(.{
                .root_source_file = b.path("src/fastmem.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .quirks => b.createModule(.{
                .root_source_file = b.path("src/quirks.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .tripwire => b.createModule(.{
                .root_source_file = b.path("src/tripwire.zig"),
                .target = target,
                .optimize = optimize,
            }),
        };

        modules.put(b.allocator, key, value) catch unreachable;
        break :mod value;
    };
}

pub fn add(module: *std.Build.Module) void {
    const b = module.owner;

    // We could use our config.target/optimize fields here but its more
    // correct to always match our step.
    const target = module.resolved_target.?;
    const optimize = module.optimize orelse .Debug;

    inline for (std.meta.fields(Module)) |f| {
        module.addImport(f.name, get(b, target, optimize, @enumFromInt(f.value)));
    }
}
