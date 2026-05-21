pub const String = extern struct {
    ptr: [*]const u8,
    len: usize,

    pub fn init(zig: anytype) String {
        return switch (@TypeOf(zig)) {
            []u8, []const u8 => .{
                .ptr = zig.ptr,
                .len = zig.len,
            },
            else => |v| @compileLog(v),
        };
    }
};
