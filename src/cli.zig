const diags = @import("cli/diagnostics.zig");

pub const args = @import("cli/args.zig");
pub const Action = @import("cli/action.zig").Action;
pub const CompatibilityHandler = args.CompatibilityHandler;
pub const compatibilityRenamed = args.compatibilityRenamed;
pub const DiagnosticList = diags.DiagnosticList;
pub const Diagnostic = diags.Diagnostic;
pub const Location = diags.Location;

test {
    @import("std").testing.refAllDecls(@This());
}
