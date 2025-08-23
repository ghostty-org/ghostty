const diags = @import("cli/diagnostics.zig");

pub const args = @import("cli/args.zig");
pub const action = @import("cli/action.zig");
pub const ghostty = @import("cli/ghostty.zig");
pub const CompatibilityHandler = args.CompatibilityHandler;
pub const compatibilityRenamed = args.compatibilityRenamed;
pub const DiagnosticList = diags.DiagnosticList;
pub const Diagnostic = diags.Diagnostic;
pub const Location = diags.Location;

test {
    @import("std").testing.refAllDecls(@This());
}
