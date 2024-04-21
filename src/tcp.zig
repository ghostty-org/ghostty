//! TCP implementation. The TCP implementation is responsible for
//! responding to TCP requests and dispatching them to the app's Mailbox.
pub const Thread = @import("tcp/Thread.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("tcp/Command.zig");
    _ = @import("tcp/Server.zig");
}
