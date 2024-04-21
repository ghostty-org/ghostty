//! TCP implementation. The TCP implementation is responsible for
//! responding to TCP requests and dispatching them to the app's Mailbox.

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("tcp/Command.zig");
    _ = @import("tcp/Server.zig");
}
