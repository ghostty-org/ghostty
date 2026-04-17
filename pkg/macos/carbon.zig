pub const c = @import("c");

test {
    @import("std").testing.refAllDecls(@This());
}
