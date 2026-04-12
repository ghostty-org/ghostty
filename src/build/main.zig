//! Build logic for Ghostty. A single "build.zig" file became far too complex
//! and spaghetti, so this package extracts the build logic into smaller,
//! more manageable pieces.

pub const Config = @import("Config.zig");

// Artifacts
pub const GhosttyExe = @import("GhosttyExe.zig");
pub const SharedDeps = @import("SharedDeps.zig");

// Steps

// Helpers
pub const requireZig = @import("zig.zig").requireZig;
