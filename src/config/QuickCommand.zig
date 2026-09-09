//! Repeatable commands sent to an existing terminal, never launched as processes.
const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("../cli/args.zig");
const formatterpkg = @import("formatter.zig");
const Self = @This();

value: std.ArrayListUnmanaged(Entry) = .empty,
value_c: std.ArrayListUnmanaged(Entry.C) = .empty,

pub const Entry = struct {
    title: [:0]const u8,
    command: [:0]const u8,
    action: enum { insert, execute } = .insert,
    group: ?[:0]const u8 = null,

    pub const C = extern struct {
        title: [*:0]const u8,
        command: [*:0]const u8,
        group: ?[*:0]const u8,
        execute: bool,
    };

    fn cval(self: Entry) Entry.C {
        return .{
            .title = self.title.ptr,
            .command = self.command.ptr,
            .group = if (self.group) |g| g.ptr else null,
            .execute = self.action == .execute,
        };
    }

    fn validate(self: Entry) !void {
        if (std.mem.trim(u8, self.title, " ").len == 0) return error.QuickCommandTitleRequired;
        if (std.mem.trim(u8, self.command, " ").len == 0) return error.QuickCommandTextRequired;
        for ([_][]const u8{ self.title, self.command }) |text| {
            if (!std.unicode.utf8ValidateSlice(text)) return error.QuickCommandInvalidUtf8;
            for (text) |byte| {
                if (byte < 0x20 or byte == 0x7f) return error.QuickCommandControlCharacter;
            }
        }
        if (self.group) |grp| {
            if (!std.unicode.utf8ValidateSlice(grp)) return error.QuickCommandInvalidUtf8;
            for (grp) |byte| {
                if (byte < 0x20 or byte == 0x7f) return error.QuickCommandControlCharacter;
            }
        }
    }
};

pub const C = extern struct {
    commands: [*]const Entry.C,
    len: usize,
};

pub fn cval(self: *const Self) C {
    return .{ .commands = self.value_c.items.ptr, .len = self.value_c.items.len };
}

pub fn parseCLI(self: *Self, alloc: Allocator, input_: ?[]const u8) !void {
    const input = input_ orelse "";
    if (input.len == 0) {
        self.value.clearRetainingCapacity();
        self.value_c.clearRetainingCapacity();
        return;
    }
    const entry = args.parseAutoStruct(Entry, alloc, input, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.QuickCommandExpectedTitleCommandAndInsertOrExecute,
    };
    try entry.validate();
    try self.value.ensureUnusedCapacity(alloc, 1);
    try self.value_c.ensureUnusedCapacity(alloc, 1);
    self.value.appendAssumeCapacity(entry);
    self.value_c.appendAssumeCapacity(entry.cval());
}

pub fn clone(self: *const Self, alloc: Allocator) Allocator.Error!Self {
    var result: Self = .{};
    try result.value.ensureTotalCapacity(alloc, self.value.items.len);
    try result.value_c.ensureTotalCapacity(alloc, self.value.items.len);
    for (self.value.items) |entry| {
        const copy: Entry = .{
            .title = try alloc.dupeZ(u8, entry.title),
            .command = try alloc.dupeZ(u8, entry.command),
            .action = entry.action,
            .group = if (entry.group) |g| try alloc.dupeZ(u8, g) else null,
        };
        result.value.appendAssumeCapacity(copy);
        result.value_c.appendAssumeCapacity(copy.cval());
    }
    return result;
}

pub fn equal(self: Self, other: Self) bool {
    if (self.value.items.len != other.value.items.len) return false;
    for (self.value.items, other.value.items) |a, b| {
        if (a.action != b.action or !std.mem.eql(u8, a.title, b.title) or
            !std.mem.eql(u8, a.command, b.command)) return false;
        if (a.group == null and b.group != null) return false;
        if (a.group != null and b.group == null) return false;
        if (a.group != null and b.group != null and !std.mem.eql(u8, a.group.?, b.group.?)) return false;
    }
    return true;
}

pub fn formatEntry(self: Self, formatter: formatterpkg.EntryFormatter) !void {
    if (self.value.items.len == 0) return formatter.formatEntry(void, {});
    for (self.value.items) |entry| {
        var writer: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer writer.deinit();
        if (entry.group) |grp| {
            try writer.writer.print("title:\"{f}\",command:\"{f}\",action:{s},group:\"{f}\"", .{
                std.zig.fmtString(entry.title), std.zig.fmtString(entry.command), @tagName(entry.action), std.zig.fmtString(grp),
            });
        } else {
            try writer.writer.print("title:\"{f}\",command:\"{f}\",action:{s}", .{
                std.zig.fmtString(entry.title), std.zig.fmtString(entry.command), @tagName(entry.action),
            });
        }
        try formatter.formatEntry([]const u8, writer.written());
    }
}

test "QuickCommand parsing, validation and reset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var list: Self = .{};
    try list.parseCLI(alloc, "title:Preparar,command:\"git commit -m \\\"\\\"\",group:Git");
    try list.parseCLI(alloc, "title:\"Pruebas 👻\",command:\" echo a,b \",action:execute,group:Linux");
    try std.testing.expectEqualStrings("git commit -m \"\"", list.value.items[0].command);
    try std.testing.expectEqual(.insert, list.value.items[0].action);
    try std.testing.expectEqualStrings("Git", list.value.items[0].group.?);
    try std.testing.expectEqualStrings(" echo a,b ", list.value.items[1].command);
    try std.testing.expect(list.value_c.items[1].execute);
    try std.testing.expectEqualStrings("Linux", std.mem.span(list.value_c.items[1].group.?));
    for ([_][]const u8{ "title:x", "title:x,command:y,action:bad", "unknown:x", "title:\"unterminated" }) |invalid| {
        try std.testing.expectError(error.QuickCommandExpectedTitleCommandAndInsertOrExecute, list.parseCLI(alloc, invalid));
    }
    try std.testing.expectError(error.QuickCommandTextRequired, list.parseCLI(alloc, "title:x,command:\" \""));
    try std.testing.expectError(error.QuickCommandControlCharacter, list.parseCLI(alloc, "title:x,command:\"x\\n\""));
    try std.testing.expectEqual(@as(usize, 2), list.value.items.len);
    try list.parseCLI(alloc, "");
    try std.testing.expectEqual(@as(usize, 0), list.cval().len);
}

test "QuickCommand clone owns C strings and formatter roundtrip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var list: Self = .{};
    try list.parseCLI(source_arena.allocator(), "title:Unicode,command:\"echo \\\"á👻\\\" \\\\n\",action:execute,group:\"Cisco Systems\"");
    const copy = try list.clone(arena.allocator());
    try std.testing.expect(list.equal(copy));
    source_arena.deinit();
    try std.testing.expectEqualStrings("echo \"á👻\" \\n", std.mem.span(copy.cval().commands[0].command));
    try std.testing.expectEqualStrings("Cisco Systems", std.mem.span(copy.cval().commands[0].group.?));
    var writer: std.Io.Writer.Allocating = .init(arena.allocator());
    defer writer.deinit();
    try copy.formatEntry(formatterpkg.entryFormatter("quick-command", &writer.writer));
    const prefix = "quick-command = ";
    var reparsed: Self = .{};
    try reparsed.parseCLI(arena.allocator(), std.mem.trimEnd(u8, writer.written()[prefix.len..], "\n"));
    try std.testing.expect(copy.equal(reparsed));
}
