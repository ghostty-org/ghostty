const std = @import("std");

/// Options set by Zig build.zig and exposed via `terminal_options`.
pub const Options = struct {
    /// The target artifact to build. This will gate some functionality.
    artifact: Artifact,

    /// Whether Oniguruma regex support is available. If this isn't
    /// available, some features will be disabled. This may be outdated,
    /// but the specific disabled features are:
    ///
    /// - Kitty graphics protocol
    /// - Tmux control mode
    ///
    oniguruma: bool,

    /// Whether to build SIMD-accelerated code paths. This pulls in more
    /// build-time dependencies and adds libc as a runtime dependency,
    /// but results in significant performance improvements.
    simd: bool,

    /// True if we should enable the "slow" runtime safety checks. These
    /// are runtime safety checks that are slower than typical and should
    /// generally be disabled in production builds.
    slow_runtime_safety: bool,

    /// Force C ABI mode on or off. If not set, then it will be set based on
    /// Options.
    c_abi: bool,

    /// Add the required build options for the terminal module.
    pub fn add(
        self: Options,
        b: *std.Build,
        m: *std.Build.Module,
    ) void {
        const opts = b.addOptions();
        opts.addOption(Artifact, "artifact", self.artifact);
        opts.addOption(bool, "c_abi", self.c_abi);
        opts.addOption(bool, "oniguruma", self.oniguruma);
        opts.addOption(bool, "simd", self.simd);
        opts.addOption(bool, "slow_runtime_safety", self.slow_runtime_safety);

        // These are synthesized based on other options.
        opts.addOption(bool, "kitty_graphics", self.oniguruma);
        opts.addOption(bool, "tmux_control_mode", self.oniguruma);

        m.addOptions("terminal_options", opts);
    }
};

pub const Artifact = enum {
    /// Ghostty application
    ghostty,

    /// libghostty-vt, Zig module
    lib,
};
