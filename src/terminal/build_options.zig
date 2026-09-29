const std = @import("std");

/// Options set by Zig build.zig and exposed via `terminal_options`.
pub const Options = struct {
    pub const Artifact = enum {
        /// Ghostty application
        ghostty,

        /// libghostty-vt, Zig module
        lib,
    };

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

    /// Optional feature gates, all enabled by default. See Features.
    features: Features = .{},

    /// The version of the application.
    version: std.SemanticVersion,

    /// Optional features for lib artifacts. Disabling a feature removes
    /// its C API exports and any stream-integrated handling from the
    /// build, primarily so size-conscious embedders (e.g. wasm) can trim
    /// the binary. The Ghostty application itself always builds with
    /// every feature enabled.
    ///
    /// Field names are the accepted tokens for `-Dvt-features`, which
    /// acts like `-Dcpu`: comma-separated modifications applied on top
    /// of the default (all enabled) set. `+feature` and `feature`
    /// enable, `-feature` disables. The special name `all` refers to
    /// every feature, so `-Dvt-features=-all,+render-state` builds only
    /// the render state API. Hyphens in names are interchangeable with
    /// underscores. Fields are emitted verbatim as bool options on the
    /// `terminal_options` module.
    pub const Features = packed struct {
        /// Terminal state serialization: encode a full terminal (screen
        /// contents, scrollback, cursor, styles, modes, etc.) to a
        /// compact binary format and decode it back into a live
        /// terminal. Used for session persistence, window restoration,
        /// and moving terminal state between processes.
        ///
        /// C API: `ghostty_snapshot_*` and, together with
        /// `grid_introspection`, `ghostty_tracked_grid_ref_snapshot`.
        snapshot: bool = true,

        /// Textual export of terminal contents as plain text, VT
        /// (replayable escape sequences), or HTML, with optional extras
        /// such as cursor position, palette, modes, and tabstops. Used
        /// for copy-to-clipboard, dump-to-file, and debugging.
        ///
        /// C API: `ghostty_formatter_*` and, together with `selection`,
        /// `ghostty_terminal_selection_format_*`.
        formatter: bool = true,

        /// Text selection: select word/line/output/all, selection
        /// ordering, adjustment, and containment math, and the
        /// click/drag gesture state machine (single/double/triple
        /// click behaviors). Selections are expressed in grid
        /// references, so enabling this also keeps the untracked grid
        /// reference constructors even if `grid_introspection` is
        /// disabled.
        ///
        /// C API: `ghostty_terminal_select_*`,
        /// `ghostty_terminal_selection_*`, `ghostty_selection_gesture_*`.
        selection: bool = true,

        /// Terminal search: find matches for a string in the active
        /// area and scrollback (ASCII case-insensitive), with results
        /// that survive primary/alternate screen switches, resize, and
        /// scrollback pruning, plus match selection with wrap-around
        /// and viewport scrolling. Used to implement find bars.
        ///
        /// C API: `ghostty_search_*`.
        search: bool = true,

        /// The render state API: a coherent, update-in-place view of
        /// the visible screen (rows, cells, styles, cursor, colors,
        /// palette) designed to drive a renderer at frame rates. This
        /// is the primary read path for embedders that draw the
        /// terminal.
        ///
        /// C API: `ghostty_render_state_*`.
        render_state: bool = true,

        /// Encoding of host input events into the byte sequences a
        /// terminal application expects: keyboard input (including the
        /// Kitty keyboard protocol), mouse reporting, focus reporting,
        /// and (bracketed) paste. Any interactive embedder needs this;
        /// a read-only viewer does not.
        ///
        /// C API: `ghostty_key_event_*`, `ghostty_key_encoder_*`,
        /// `ghostty_mouse_event_*`, `ghostty_mouse_encoder_*`,
        /// `ghostty_focus_encode`, `ghostty_paste_*`.
        input_encode: bool = true,

        /// Color utilities: luminance, perceived luminance, and
        /// contrast math (e.g. for minimum-contrast rendering), color
        /// string parsing (`#rrggbb`, X11 color names, XParseColor
        /// `rgb:`/`rgbi:` device specs), the default 256-color palette
        /// and palette generation from configurable bases, and the X11
        /// color name table itself.
        ///
        /// C API: `ghostty_color_*`.
        color: bool = true,

        /// Direct inspection of grid contents at a position via grid
        /// references: cell and row data getters (codepoints,
        /// graphemes, style, hyperlink URI, wrap state, ...) plus
        /// tracked grid references that stay valid across terminal
        /// updates. Used for hyperlink hover/open, accessibility, and
        /// tests; deliberately not built for render loops (use
        /// `render_state` for that).
        ///
        /// C API: `ghostty_grid_ref_*`, `ghostty_tracked_grid_ref_*`,
        /// `ghostty_cell_get*`, `ghostty_row_get*`, and (shared with
        /// `selection`) `ghostty_terminal_grid_ref` /
        /// `ghostty_terminal_point_from_grid_ref`.
        grid_introspection: bool = true,

        /// The APC glyph protocol: a Ghostty extension that lets
        /// terminal applications register custom font glyphs (glyf
        /// outlines) for private-use-area codepoints. Embedders that
        /// don't render registered glyphs can disable this; the
        /// sequences are still consumed and safely ignored.
        ///
        /// No C API surface of its own; this gates the stream handling
        /// and glossary storage.
        glyph_protocol: bool = true,

        /// The Kitty graphics protocol: APC command parsing, image
        /// transmission and storage (PNG decoding via the sys
        /// interface), and placement tracking, plus the read APIs a
        /// renderer uses to draw placed images. Disabled sequences are
        /// still consumed and safely ignored.
        ///
        /// This requires the ability to get timestamps from the OS, so
        /// it is always disabled on freestanding targets (e.g.
        /// wasm32-freestanding) regardless of this setting.
        ///
        /// C API: `ghostty_kitty_graphics_*`.
        kitty_graphics: bool = true,

        pub fn parse(list: []const u8) error{UnknownFeature}!Features {
            // Modifications apply on top of the default set.
            var result: Features = .{};

            var it = std.mem.splitAny(u8, list, ", ");
            while (it.next()) |raw| {
                if (raw.len == 0) continue;

                var name = raw;
                var enable = true;
                switch (name[0]) {
                    '+' => name = name[1..],
                    '-' => {
                        enable = false;
                        name = name[1..];
                    },
                    else => {},
                }

                // A dangling sign with no name is malformed.
                if (name.len == 0) return error.UnknownFeature;

                // The special name "all" refers to every feature.
                if (std.mem.eql(u8, name, "all")) {
                    inline for (@typeInfo(Features).@"struct".fields) |field| {
                        @field(result, field.name) = enable;
                    }
                    continue;
                }

                var found = false;
                inline for (@typeInfo(Features).@"struct".fields) |field| {
                    if (eqlName(name, field.name)) {
                        @field(result, field.name) = enable;
                        found = true;
                    }
                }
                if (!found) return error.UnknownFeature;
            }

            return result;
        }

        /// Feature name equality where '-' in the input matches '_' in
        /// the field name.
        fn eqlName(input: []const u8, name: []const u8) bool {
            if (input.len != name.len) return false;
            for (input, name) |a, b| {
                const norm: u8 = if (a == '-') '_' else a;
                if (norm != b) return false;
            }
            return true;
        }

        test "parse" {
            const testing = std.testing;

            const none: Features = @bitCast(
                @as(@typeInfo(Features).@"struct".backing_integer.?, 0),
            );

            // Empty input keeps the defaults.
            try testing.expectEqual(Features{}, try Features.parse(""));

            // All three token forms, comma separated.
            try testing.expectEqual(
                Features{ .snapshot = false },
                try Features.parse("-snapshot"),
            );
            try testing.expectEqual(
                Features{ .snapshot = false, .formatter = false },
                try Features.parse("-snapshot,+render_state,-formatter,color"),
            );

            // The special "all" name refers to every feature.
            try testing.expectEqual(none, try Features.parse("-all"));
            try testing.expectEqual(Features{}, try Features.parse("-all,+all"));
            var render_only = none;
            render_only.render_state = true;
            try testing.expectEqual(
                render_only,
                try Features.parse("-all,+render-state"),
            );

            // Hyphens are interchangeable with underscores.
            try testing.expectEqual(
                Features{ .input_encode = false, .grid_introspection = false },
                try Features.parse("-input-encode,-grid_introspection"),
            );

            // Later tokens win.
            try testing.expectEqual(
                Features{},
                try Features.parse("-snapshot,+snapshot"),
            );

            // Unknown names and dangling signs are errors.
            try testing.expectError(error.UnknownFeature, Features.parse("bogus"));
            try testing.expectError(error.UnknownFeature, Features.parse("-snapshot,-"));
        }
    };

    /// Whether the Kitty graphics feature is effectively enabled for
    /// the given target. Kitty graphics requires the ability to get
    /// timestamps and there is no way to do that on freestanding
    /// targets, so it is always disabled there regardless of the
    /// feature setting.
    pub fn kittyGraphics(self: Options, target: std.Target) bool {
        if (target.os.tag == .freestanding) return false;
        return self.features.kitty_graphics;
    }

    /// Add the required build options for the terminal module.
    ///
    /// The memory referenced by self is expected to stick around (it isn't
    /// copied), since we expect we're in a build environment.
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
        opts.addOption(bool, "tmux_control_mode", self.oniguruma);

        // Feature gates, emitted as flat bools (e.g. `options.snapshot`).
        const target = m.resolved_target.?.result;
        inline for (@typeInfo(Features).@"struct".fields) |field| {
            var value = @field(self.features, field.name);

            // Kitty graphics is force-disabled on some targets; see
            // kittyGraphics for details.
            if (comptime std.mem.eql(u8, field.name, "kitty_graphics")) {
                value = self.kittyGraphics(target);
            }

            opts.addOption(bool, field.name, value);
        }

        // Version information.
        opts.addOption(
            []const u8,
            "version_string",
            b.fmt(
                "{f}",
                .{self.version},
            ),
        );
        opts.addOption(usize, "version_major", self.version.major);
        opts.addOption(usize, "version_minor", self.version.minor);
        opts.addOption(usize, "version_patch", self.version.patch);
        opts.addOption(?[]const u8, "version_pre", self.version.pre);
        opts.addOption(?[]const u8, "version_build", self.version.build);

        m.addOptions("terminal_options", opts);
    }
};

test {
    _ = Options.Features;
}
