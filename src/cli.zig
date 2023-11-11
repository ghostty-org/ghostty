pub const args = @import("cli/args.zig");
pub const Action  = cli.Action;
pub const ActionXtra = cli.ActionXtra;
pub const welcome_msg = cli.cli_welcome_msg;
const cli = @import("cli/action.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
