const std = @import("std");
const Allocator = std.mem.Allocator;

const max_closed_tabs = 10;

pub const LastClosedTab = struct {
    title: ?[]const u8,
    cwd: ?[]const u8,
    contents: ?[]const u8,

    pub fn deinit(self: *LastClosedTab, alloc: Allocator) void {
        if (self.title) |t| alloc.free(t);
        if (self.cwd) |c| alloc.free(c);
        if (self.contents) |c| alloc.free(c);
    }
};

pub const LastClosedTabs = struct {
    this: std.BoundedArray(LastClosedTab, max_closed_tabs) = std.BoundedArray(LastClosedTab, max_closed_tabs).init(0) catch unreachable,

    pub fn push(self: *LastClosedTabs, tab: LastClosedTab) void {
        if (self.this.len == max_closed_tabs) {
            // Remove oldest tab and free its memory
            self.this.buffer[0] = tab;
            // Shift all elements left
            for (0..self.this.len - 1) |i| {
                self.this.buffer[i] = self.this.buffer[i + 1];
            }
        } else {
            self.this.append(tab) catch unreachable;
        }
    }

    pub fn deinit(self: *LastClosedTabs, alloc: Allocator) void {
        for (0..self.this.len) |i| {
            self.this.buffer[i].deinit(alloc);
        }
        self.this.len = 0;
    }

    pub fn get(self: *LastClosedTabs, index: usize) ?*LastClosedTab {
        if (index >= self.this.len) return null;
        return &self.this.buffer[index];
    }

    pub fn pop(self: *LastClosedTabs) ?LastClosedTab {
        if (self.this.len == 0) return null;
        self.this.len -= 1;
        return self.this.buffer[self.this.len];
    }
};
