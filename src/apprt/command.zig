//! Whether the apprt for this build implements a given binding action.
//! Command palettes use this to hide commands that would do nothing.
//!
//! Each apprt owns its own table:
//!
//!   * macOS, iOS: `embedded/command.zig`
//!   * GTK: `gtk/command.zig`

const build_config = @import("../build_config.zig");
const Action = @import("../input/Binding.zig").Action;

/// Mirrors the runtime selection in `apprt.zig`.
const impl = switch (build_config.artifact) {
    .exe => switch (build_config.app_runtime) {
        .none => all,
        .gtk => @import("gtk/command.zig"),
    },
    .lib => @import("embedded/command.zig"),
    .wasm_module => all,
};

/// No apprt means no command palette, so nothing to hide.
const all = struct {
    fn supported(_: Action) bool {
        return true;
    }
};

/// Returns true if the apprt this build targets implements `action`.
/// Actions the core handles itself are supported everywhere.
pub fn supported(action: Action) bool {
    return impl.supported(action);
}

comptime {
    // Analyze every table, not just ours, so a new action is a compile
    // error for all apprts at once. The `&` is required: `_ = f` resolves
    // the decl without analyzing its body.
    _ = &@import("embedded/command.zig").supported;
    _ = &@import("gtk/command.zig").supported;
}

test {
    _ = @import("embedded/command.zig");
    _ = @import("gtk/command.zig");
}
