const std = @import("std");
const builtin = @import("builtin");

/// The power state of the system.
pub const PowerState = enum { ac, battery, critical };

/// Information about the current power state of the system.
pub const PowerInfo = struct {
    state: PowerState,
    battery_percent: ?u8,
};

/// Get the current power info with a given critical threshold.
/// On non-Linux/macOS platforms, always returns .ac with null battery.
pub fn getPowerInfo(critical_threshold: u8) PowerInfo {
    if (comptime builtin.os.tag == .linux) {
        return getPowerInfoFromPath("/sys/class/power_supply", critical_threshold);
    } else if (comptime builtin.os.tag == .macos) {
        return getMacOSPowerInfo(critical_threshold);
    }
    return .{ .state = .ac, .battery_percent = null };
}

fn getMacOSPowerInfo(critical_threshold: u8) PowerInfo {
    if (comptime builtin.os.tag != .macos) unreachable;

    const c = @cImport({
        @cInclude("IOKit/ps/IOPowerSources.h");
        @cInclude("IOKit/ps/IOPSKeys.h");
    });

    const fallback: PowerInfo = .{ .state = .ac, .battery_percent = null };

    const info = c.IOPSCopyPowerSourcesInfo() orelse return fallback;
    defer c.CFRelease(info);

    const list = c.IOPSCopyPowerSourcesList(info) orelse return fallback;
    defer c.CFRelease(list);

    const count = c.CFArrayGetCount(list);
    if (count == 0) return fallback;

    // Check providing power source type
    const source_type = c.IOPSGetProvidingPowerSourceType(info);
    const is_battery = if (source_type) |st|
        c.CFStringCompare(st, c.CFSTR("Battery Power"), 0) == c.kCFCompareEqualTo
    else
        false;

    // Get capacity from first power source
    var battery_percent: ?u8 = null;
    {
        const ps = c.CFArrayGetValueAtIndex(list, 0);
        const desc = c.IOPSGetPowerSourceDescription(info, ps); // "Get" — do NOT CFRelease
        if (desc) |d| {
            const cap_key = c.CFSTR(c.kIOPSCurrentCapacityKey);
            if (c.CFDictionaryGetValue(d, cap_key)) |cap_val| {
                var cap: c_int = 0;
                if (c.CFNumberGetValue(@ptrCast(cap_val), c.kCFNumberIntType, &cap)) {
                    if (cap >= 0 and cap <= 100) {
                        battery_percent = @intCast(@as(u32, @bitCast(cap)));
                    }
                }
            }
        }
    }

    if (!is_battery) {
        return .{ .state = .ac, .battery_percent = battery_percent };
    }

    // On battery — check critical threshold
    if (battery_percent) |cap| {
        if (critical_threshold > 0 and cap <= critical_threshold) {
            return .{ .state = .critical, .battery_percent = cap };
        }
    }

    return .{ .state = .battery, .battery_percent = battery_percent };
}

/// Get power info by reading from a sysfs-like directory structure.
/// Never errors — returns .ac with null on any failure.
pub fn getPowerInfoFromPath(base_path: []const u8, critical_threshold: u8) PowerInfo {
    const fallback: PowerInfo = .{ .state = .ac, .battery_percent = null };

    var dir = std.fs.openDirAbsolute(base_path, .{ .iterate = true }) catch return fallback;
    defer dir.close();

    var it = dir.iterate();

    var ac_online = false;
    var battery_charging = false;
    var found_battery = false;
    var lowest_capacity: ?u8 = null;

    while (it.next() catch return fallback) |entry| {
        // Open the supply subdirectory
        var supply_dir = dir.openDir(entry.name, .{}) catch continue;
        defer supply_dir.close();

        // Read the type file
        var type_buf: [64]u8 = undefined;
        const supply_type = readSysFile(supply_dir, "type", &type_buf) orelse continue;

        if (std.mem.eql(u8, supply_type, "Mains")) {
            // Check if AC adapter is online
            var online_buf: [8]u8 = undefined;
            const online = readSysFile(supply_dir, "online", &online_buf) orelse continue;
            if (std.mem.eql(u8, online, "1")) {
                ac_online = true;
            }
        } else if (std.mem.eql(u8, supply_type, "Battery")) {
            found_battery = true;

            // Read battery status
            var status_buf: [32]u8 = undefined;
            if (readSysFile(supply_dir, "status", &status_buf)) |status| {
                if (std.mem.eql(u8, status, "Charging") or std.mem.eql(u8, status, "Full")) {
                    battery_charging = true;
                }
            }

            // Read battery capacity
            var capacity_buf: [8]u8 = undefined;
            if (readSysFile(supply_dir, "capacity", &capacity_buf)) |cap_str| {
                const capacity = std.fmt.parseInt(u8, cap_str, 10) catch continue;
                if (lowest_capacity == null or capacity < lowest_capacity.?) {
                    lowest_capacity = capacity;
                }
            }
        }
    }

    // Determine state
    if (ac_online or battery_charging or !found_battery) {
        return .{
            .state = .ac,
            .battery_percent = lowest_capacity,
        };
    }

    const capacity = lowest_capacity orelse return fallback;

    const state: PowerState = if (critical_threshold > 0 and capacity <= critical_threshold)
        .critical
    else
        .battery;

    return .{
        .state = state,
        .battery_percent = capacity,
    };
}

/// Read a single-line sysfs file from the given directory, trimming whitespace.
/// Returns null on any error or if buffer is too small.
fn readSysFile(dir: std.fs.Dir, name: []const u8, buf: []u8) ?[]const u8 {
    var file = dir.openFile(name, .{}) catch return null;
    defer file.close();

    const n = file.read(buf) catch return null;
    if (n == 0) return null;

    return std.mem.trim(u8, buf[0..n], &std.ascii.whitespace);
}

// ============================================================
// Tests
// ============================================================

test "power: AC power only" {
    if (comptime builtin.os.tag != .linux) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);

    // Create AC adapter entry
    try tmp.dir.makeDir("AC0");
    var ac_dir = try tmp.dir.openDir("AC0", .{});
    defer ac_dir.close();
    try writeFile(ac_dir, "type", "Mains\n");
    try writeFile(ac_dir, "online", "1\n");

    const info = getPowerInfoFromPath(base, 20);
    try std.testing.expectEqual(PowerState.ac, info.state);
    try std.testing.expectEqual(@as(?u8, null), info.battery_percent);
}

test "power: battery discharging at 50%" {
    if (comptime builtin.os.tag != .linux) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);

    try tmp.dir.makeDir("BAT0");
    var bat_dir = try tmp.dir.openDir("BAT0", .{});
    defer bat_dir.close();
    try writeFile(bat_dir, "type", "Battery\n");
    try writeFile(bat_dir, "status", "Discharging\n");
    try writeFile(bat_dir, "capacity", "50\n");

    const info = getPowerInfoFromPath(base, 20);
    try std.testing.expectEqual(PowerState.battery, info.state);
    try std.testing.expectEqual(@as(?u8, 50), info.battery_percent);
}

test "power: battery critical at 15% (threshold 20)" {
    if (comptime builtin.os.tag != .linux) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);

    try tmp.dir.makeDir("BAT0");
    var bat_dir = try tmp.dir.openDir("BAT0", .{});
    defer bat_dir.close();
    try writeFile(bat_dir, "type", "Battery\n");
    try writeFile(bat_dir, "status", "Discharging\n");
    try writeFile(bat_dir, "capacity", "15\n");

    const info = getPowerInfoFromPath(base, 20);
    try std.testing.expectEqual(PowerState.critical, info.state);
    try std.testing.expectEqual(@as(?u8, 15), info.battery_percent);
}

test "power: battery charging" {
    if (comptime builtin.os.tag != .linux) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);

    try tmp.dir.makeDir("BAT0");
    var bat_dir = try tmp.dir.openDir("BAT0", .{});
    defer bat_dir.close();
    try writeFile(bat_dir, "type", "Battery\n");
    try writeFile(bat_dir, "status", "Charging\n");
    try writeFile(bat_dir, "capacity", "40\n");

    const info = getPowerInfoFromPath(base, 20);
    try std.testing.expectEqual(PowerState.ac, info.state);
    try std.testing.expectEqual(@as(?u8, 40), info.battery_percent);
}

test "power: battery full" {
    if (comptime builtin.os.tag != .linux) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);

    try tmp.dir.makeDir("BAT0");
    var bat_dir = try tmp.dir.openDir("BAT0", .{});
    defer bat_dir.close();
    try writeFile(bat_dir, "type", "Battery\n");
    try writeFile(bat_dir, "status", "Full\n");
    try writeFile(bat_dir, "capacity", "100\n");

    const info = getPowerInfoFromPath(base, 20);
    try std.testing.expectEqual(PowerState.ac, info.state);
    try std.testing.expectEqual(@as(?u8, 100), info.battery_percent);
}

test "power: no power supply directory" {
    if (comptime builtin.os.tag != .linux) return;

    const info = getPowerInfoFromPath("/nonexistent/path/that/does/not/exist", 20);
    try std.testing.expectEqual(PowerState.ac, info.state);
    try std.testing.expectEqual(@as(?u8, null), info.battery_percent);
}

test "power: malformed capacity file" {
    if (comptime builtin.os.tag != .linux) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);

    try tmp.dir.makeDir("BAT0");
    var bat_dir = try tmp.dir.openDir("BAT0", .{});
    defer bat_dir.close();
    try writeFile(bat_dir, "type", "Battery\n");
    try writeFile(bat_dir, "status", "Discharging\n");
    try writeFile(bat_dir, "capacity", "not_a_number\n");

    // Battery found but capacity couldn't be parsed → fallback
    const info = getPowerInfoFromPath(base, 20);
    try std.testing.expectEqual(PowerState.ac, info.state);
    try std.testing.expectEqual(@as(?u8, null), info.battery_percent);
}

test "power: empty directory" {
    if (comptime builtin.os.tag != .linux) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);

    const info = getPowerInfoFromPath(base, 20);
    try std.testing.expectEqual(PowerState.ac, info.state);
    try std.testing.expectEqual(@as(?u8, null), info.battery_percent);
}

test "power: multiple batteries uses lowest capacity" {
    if (comptime builtin.os.tag != .linux) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);

    try tmp.dir.makeDir("BAT0");
    var bat0_dir = try tmp.dir.openDir("BAT0", .{});
    defer bat0_dir.close();
    try writeFile(bat0_dir, "type", "Battery\n");
    try writeFile(bat0_dir, "status", "Discharging\n");
    try writeFile(bat0_dir, "capacity", "70\n");

    try tmp.dir.makeDir("BAT1");
    var bat1_dir = try tmp.dir.openDir("BAT1", .{});
    defer bat1_dir.close();
    try writeFile(bat1_dir, "type", "Battery\n");
    try writeFile(bat1_dir, "status", "Discharging\n");
    try writeFile(bat1_dir, "capacity", "30\n");

    const info = getPowerInfoFromPath(base, 20);
    try std.testing.expectEqual(PowerState.battery, info.state);
    try std.testing.expectEqual(@as(?u8, 30), info.battery_percent);
}

test "power: AC online plus battery discharging" {
    if (comptime builtin.os.tag != .linux) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);

    try tmp.dir.makeDir("AC0");
    var ac_dir = try tmp.dir.openDir("AC0", .{});
    defer ac_dir.close();
    try writeFile(ac_dir, "type", "Mains\n");
    try writeFile(ac_dir, "online", "1\n");

    try tmp.dir.makeDir("BAT0");
    var bat_dir = try tmp.dir.openDir("BAT0", .{});
    defer bat_dir.close();
    try writeFile(bat_dir, "type", "Battery\n");
    try writeFile(bat_dir, "status", "Discharging\n");
    try writeFile(bat_dir, "capacity", "45\n");

    const info = getPowerInfoFromPath(base, 20);
    try std.testing.expectEqual(PowerState.ac, info.state);
    try std.testing.expectEqual(@as(?u8, 45), info.battery_percent);
}

test "power: threshold boundary (capacity == threshold)" {
    if (comptime builtin.os.tag != .linux) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);

    try tmp.dir.makeDir("BAT0");
    var bat_dir = try tmp.dir.openDir("BAT0", .{});
    defer bat_dir.close();
    try writeFile(bat_dir, "type", "Battery\n");
    try writeFile(bat_dir, "status", "Discharging\n");
    try writeFile(bat_dir, "capacity", "20\n");

    const info = getPowerInfoFromPath(base, 20);
    try std.testing.expectEqual(PowerState.critical, info.state);
    try std.testing.expectEqual(@as(?u8, 20), info.battery_percent);
}

test "power: capacity at 0%" {
    if (comptime builtin.os.tag != .linux) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);

    try tmp.dir.makeDir("BAT0");
    var bat_dir = try tmp.dir.openDir("BAT0", .{});
    defer bat_dir.close();
    try writeFile(bat_dir, "type", "Battery\n");
    try writeFile(bat_dir, "status", "Discharging\n");
    try writeFile(bat_dir, "capacity", "0\n");

    const info = getPowerInfoFromPath(base, 20);
    try std.testing.expectEqual(PowerState.critical, info.state);
    try std.testing.expectEqual(@as(?u8, 0), info.battery_percent);
}

test "power: threshold 0 disables critical" {
    if (comptime builtin.os.tag != .linux) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);

    try tmp.dir.makeDir("BAT0");
    var bat_dir = try tmp.dir.openDir("BAT0", .{});
    defer bat_dir.close();
    try writeFile(bat_dir, "type", "Battery\n");
    try writeFile(bat_dir, "status", "Discharging\n");
    try writeFile(bat_dir, "capacity", "5\n");

    const info = getPowerInfoFromPath(base, 0);
    try std.testing.expectEqual(PowerState.battery, info.state);
    try std.testing.expectEqual(@as(?u8, 5), info.battery_percent);
}

test "power: capacity 100 while discharging" {
    if (comptime builtin.os.tag != .linux) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);

    try tmp.dir.makeDir("BAT0");
    var bat_dir = try tmp.dir.openDir("BAT0", .{});
    defer bat_dir.close();
    try writeFile(bat_dir, "type", "Battery\n");
    try writeFile(bat_dir, "status", "Discharging\n");
    try writeFile(bat_dir, "capacity", "100\n");

    const info = getPowerInfoFromPath(base, 20);
    try std.testing.expectEqual(PowerState.battery, info.state);
    try std.testing.expectEqual(@as(?u8, 100), info.battery_percent);
}

// Helper to write a file in a directory
fn writeFile(dir: std.fs.Dir, name: []const u8, content: []const u8) !void {
    var file = try dir.createFile(name, .{});
    defer file.close();
    try file.writeAll(content);
}
