const std = @import("std");
const c = @import("api.zig").c;
const Context = @import("Context.zig");

pub const Options = struct {
    context: *Context,
    usage: c.VkBufferUsageFlags,
};

pub const Handle = struct {
    context: *Context,
    buffer: c.VkBuffer,
    memory: c.VkDeviceMemory,
    size: usize,
    deferred: *Context.DeferredBuffer,

    pub fn init(opts: Options, size_: usize) !Handle {
        const size = @max(size_, 1);
        var info = std.mem.zeroes(c.VkBufferCreateInfo);
        info.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        info.size = size;
        info.usage = opts.usage;
        info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

        var buffer: c.VkBuffer = null;
        try Context.result(c.vkCreateBuffer(opts.context.device, &info, null, &buffer));
        errdefer c.vkDestroyBuffer(opts.context.device, buffer, null);

        var requirements = std.mem.zeroes(c.VkMemoryRequirements);
        c.vkGetBufferMemoryRequirements(opts.context.device, buffer, &requirements);

        var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.allocationSize = requirements.size;
        alloc_info.memoryTypeIndex = try opts.context.memoryType(
            requirements.memoryTypeBits,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );

        var memory: c.VkDeviceMemory = null;
        try Context.result(c.vkAllocateMemory(opts.context.device, &alloc_info, null, &memory));
        errdefer c.vkFreeMemory(opts.context.device, memory, null);
        try Context.result(c.vkBindBufferMemory(opts.context.device, buffer, memory, 0));

        const deferred = try opts.context.alloc.create(Context.DeferredBuffer);
        errdefer opts.context.alloc.destroy(deferred);
        deferred.* = .{ .buffer = buffer, .memory = memory };

        return .{
            .context = opts.context,
            .buffer = buffer,
            .memory = memory,
            .size = size,
            .deferred = deferred,
        };
    }

    pub fn deinit(self: Handle) void {
        self.context.deferBuffer(self.deferred);
    }

    pub fn write(self: Handle, offset: usize, bytes: []const u8) !void {
        if (offset + bytes.len > self.size) return error.BufferOverflow;
        var mapped: ?*anyopaque = null;
        try Context.result(c.vkMapMemory(
            self.context.device,
            self.memory,
            offset,
            bytes.len,
            0,
            &mapped,
        ));
        defer c.vkUnmapMemory(self.context.device, self.memory);
        const dst: [*]u8 = @ptrCast(mapped.?);
        @memcpy(dst[0..bytes.len], bytes);
    }
};

pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        opts: Options,
        buffer: Handle,
        len: usize,

        pub fn init(opts: Options, len: usize) !Self {
            return .{
                .opts = opts,
                .buffer = try .init(opts, len * @sizeOf(T)),
                .len = len,
            };
        }

        pub fn initFill(opts: Options, data: []const T) !Self {
            var self: Self = .{
                .opts = opts,
                .buffer = try .init(opts, data.len * @sizeOf(T)),
                .len = data.len,
            };
            errdefer self.buffer.deinit();
            try self.buffer.write(0, std.mem.sliceAsBytes(data));
            return self;
        }

        pub fn deinit(self: Self) void {
            self.buffer.deinit();
        }

        pub fn sync(self: *Self, data: []const T) !void {
            if (data.len > self.len) {
                const new_len = @max(data.len * 2, 1);
                const replacement = try Handle.init(self.opts, new_len * @sizeOf(T));
                self.buffer.deinit();
                self.buffer = replacement;
                self.len = new_len;
            }
            try self.buffer.write(0, std.mem.sliceAsBytes(data));
        }

        pub fn syncFromArrayLists(self: *Self, lists: []const std.ArrayListUnmanaged(T)) !usize {
            var total_len: usize = 0;
            for (lists) |list| total_len += list.items.len;
            if (total_len > self.len) {
                const new_len = @max(total_len * 2, 1);
                const replacement = try Handle.init(self.opts, new_len * @sizeOf(T));
                self.buffer.deinit();
                self.buffer = replacement;
                self.len = new_len;
            }

            var offset: usize = 0;
            for (lists) |list| {
                const bytes = std.mem.sliceAsBytes(list.items);
                try self.buffer.write(offset, bytes);
                offset += bytes.len;
            }
            return total_len;
        }
    };
}
