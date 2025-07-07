//! Build logic for Ghostty. A single "build.zig" file became far too complex
//! and spaghetti, so this package extracts the build logic into smaller,
//! more manageable pieces.

pub const gtk = @import("gtk.zig");
pub const Config = @import("Config.zig");
pub const GitVersion = @import("GitVersion.zig");

// Artifacts
pub const GhosttyBench = @import("GhosttyBench.zig");
pub const GhosttyDist = @import("GhosttyDist.zig");
pub const GhosttyDocs = @import("GhosttyDocs.zig");
pub const GhosttyExe = @import("GhosttyExe.zig");
pub const GhosttyFrameData = @import("GhosttyFrameData.zig");
pub const GhosttyLib = @import("GhosttyLib.zig");
pub const GhosttyResources = @import("GhosttyResources.zig");
pub const GhosttyI18n = @import("GhosttyI18n.zig");
pub const GhosttyXcodebuild = @import("GhosttyXcodebuild.zig");
pub const GhosttyXCFramework = @import("GhosttyXCFramework.zig");
pub const GhosttyWebdata = @import("GhosttyWebdata.zig");
pub const HelpStrings = @import("HelpStrings.zig");
pub const SharedDeps = @import("SharedDeps.zig");
pub const UnicodeTables = @import("UnicodeTables.zig");

// Steps
pub const LibtoolStep = @import("LibtoolStep.zig");
pub const LipoStep = @import("LipoStep.zig");
pub const MetallibStep = @import("MetallibStep.zig");
pub const XCFrameworkStep = @import("XCFrameworkStep.zig");

// Shell completions
pub const fish_completions = @import("fish_completions.zig").completions;
pub const zsh_completions = @import("zsh_completions.zig").completions;
pub const bash_completions = @import("bash_completions.zig").completions;

// Helpers
pub const requireZig = @import("zig.zig").requireZig;
