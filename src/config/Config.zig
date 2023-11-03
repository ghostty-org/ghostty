/// Config is the main config struct. These fields map directly to the
/// CLI flag names hence we use a lot of `@""` syntax to support hyphens.
const Config = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const fontpkg = @import("../font/main.zig");
const inputpkg = @import("../input.zig");
const terminal = @import("../terminal/main.zig");
const internal_os = @import("../os/main.zig");
const cli = @import("../cli.zig");

const Key = @import("key.zig").Key;
const KeyValue = @import("key.zig").Value;
const ErrorList = @import("ErrorList.zig");
const MetricModifier = fontpkg.face.Metrics.Modifier;

const log = std.log.scoped(.config);

/// Used on Unixes for some defaults.
const c = @cImport({
    @cInclude("unistd.h");
});

/// The font families to use.
/// You can generate the list of valid values using the CLI:
///   path/to/ghostty/cli +list-fonts
///
/// Changing this configuration at runtime will only affect new terminals,
/// i.e. new windows, tabs, etc.
@"font-family": ?[:0]const u8 = null,
@"font-family-bold": ?[:0]const u8 = null,
@"font-family-italic": ?[:0]const u8 = null,
@"font-family-bold-italic": ?[:0]const u8 = null,

/// The named font style to use for each of the requested terminal font
/// styles. This looks up the style based on the font style string advertised
/// by the font itself. For example, "Iosevka Heavy" has a style of "Heavy".
///
/// You can also use these fields to completely disable a font style. If
/// you set the value of the configuration below to literal "false" then
/// that font style will be disabled. If the running program in the terminal
/// requests a disabled font style, the regular font style will be used
/// instead.
///
/// These are only valid if its corresponding font-family is also specified.
/// If no font-family is specified, then the font-style is ignored unless
/// you're disabling the font style.
@"font-style": FontStyle = .{ .default = {} },
@"font-style-bold": FontStyle = .{ .default = {} },
@"font-style-italic": FontStyle = .{ .default = {} },
@"font-style-bold-italic": FontStyle = .{ .default = {} },

/// Apply a font feature. This can be repeated multiple times to enable
/// multiple font features. You can NOT set multiple font features with
/// a single value (yet).
///
/// The font feature will apply to all fonts rendered by Ghostty. A
/// future enhancement will allow targeting specific faces.
///
/// A valid value is the name of a feature. Prefix the feature with a
/// "-" to explicitly disable it. Example: "ss20" or "-ss20".
///
/// To disable programming ligatures, use "-calt" since this is the typical
/// feature name for programming ligatures. To look into what font features
/// your font has and what they do, use a font inspection tool such as
/// fontdrop.info.
///
/// To generally disable most ligatures, use "-calt", "-liga", and "-dlig"
/// (as separate repetitive entries in your config).
@"font-feature": RepeatableString = .{},

/// Font size in points
@"font-size": u8 = switch (builtin.os.tag) {
    // On Mac we default a little bigger since this tends to look better.
    // This is purely subjective but this is easy to modify.
    .macos => 13,
    else => 12,
},

/// A repeatable configuration to set one or more font variations values
/// for a variable font. A variable font is a single font, usually
/// with a filename ending in "-VF.ttf" or "-VF.otf" that contains
/// one or more configurable axes for things such as weight, slant,
/// etc. Not all fonts support variations; only fonts that explicitly
/// state they are variable fonts will work.
///
/// The format of this is "id=value" where "id" is the axis identifier.
/// An axis identifier is always a 4 character string, such as "wght".
/// To get the list of supported axes, look at your font documentation
/// or use a font inspection tool.
///
/// Invalid ids and values are usually ignored. For example, if a font
/// only supports weights from 100 to 700, setting "wght=800" will
/// do nothing (it will not be clamped to 700). You must consult your
/// font's documentation to see what values are supported.
///
/// Common axes are: "wght" (weight), "slnt" (slant), "ital" (italic),
/// "opsz" (optical size), "wdth" (width), "GRAD" (gradient), etc.
@"font-variation": RepeatableFontVariation = .{},
@"font-variation-bold": RepeatableFontVariation = .{},
@"font-variation-italic": RepeatableFontVariation = .{},
@"font-variation-bold-italic": RepeatableFontVariation = .{},

/// Force one or a range of Unicode codepoints to map to a specific named
/// font. This is useful if you want to support special symbols or if you
/// want to use specific glyphs that render better for your specific font.
///
/// The syntax is "codepoint=fontname" where "codepoint" is either a
/// single codepoint or a range. Codepoints must be specified as full
/// Unicode hex values, such as "U+ABCD". Codepoints ranges are specified
/// as "U+ABCD-U+DEFG". You can specify multiple ranges for the same font
/// separated by commas, such as "U+ABCD-U+DEFG,U+1234-U+5678=fontname".
/// The font name is the same value as you would use for "font-family".
///
/// This configuration can be repeated multiple times to specify multiple
/// codepoint mappings.
///
/// Changing this configuration at runtime will only affect new terminals,
/// i.e. new windows, tabs, etc.
@"font-codepoint-map": RepeatableCodepointMap = .{},

/// Draw fonts with a thicker stroke, if supported. This is only supported
/// currently on macOS.
@"font-thicken": bool = false,

/// All of the configurations behavior adjust various metrics determined
/// by the font. The values can be integers (1, -1, etc.) or a percentage
/// (20%, -15%, etc.). In each case, the values represent the amount to
/// change the original value.
///
/// For example, a value of "1" increases the value by 1; it does not set
/// it to literally 1. A value of "20%" increases the value by 20%. And so
/// on.
///
/// There is little to no validation on these values so the wrong values
/// (i.e. "-100%") can cause the terminal to be unusable. Use with caution
/// and reason.
///
/// Some values are clamped to minimum or maximum values. This can make it
/// appear that certain values are ignored. For example, the underline
/// position is clamped to the height of a cell. If you set the underline
/// position so high that it extends beyond the bottom of the cell size,
/// it will be clamped to the bottom of the cell.
@"adjust-cell-width": ?MetricModifier = null,
@"adjust-cell-height": ?MetricModifier = null,
@"adjust-font-baseline": ?MetricModifier = null,
@"adjust-underline-position": ?MetricModifier = null,
@"adjust-underline-thickness": ?MetricModifier = null,
@"adjust-strikethrough-position": ?MetricModifier = null,
@"adjust-strikethrough-thickness": ?MetricModifier = null,

/// Background color for the window.
background: Color = .{ .r = 0x28, .g = 0x2C, .b = 0x34 },

/// Foreground color for the window.
foreground: Color = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF },

/// The foreground and background color for selection. If this is not
/// set, then the selection color is just the inverted window background
/// and foreground (note: not to be confused with the cell bg/fg).
@"selection-foreground": ?Color = null,
@"selection-background": ?Color = null,

/// Color palette for the 256 color form that many terminal applications
/// use. The syntax of this configuration is "N=HEXCODE" where "n"
/// is 0 to 255 (for the 256 colors) and HEXCODE is a typical RGB
/// color code such as "#AABBCC". The 0 to 255 correspond to the
/// terminal color table.
///
/// For definitions on all the codes:
/// https://www.ditig.com/256-colors-cheat-sheet
palette: Palette = .{},

/// The color of the cursor. If this is not set, a default will be chosen.
@"cursor-color": ?Color = null,

/// The opacity level (opposite of transparency) of the cursor.
/// A value of 1 is fully opaque and a value of 0 is fully transparent.
/// A value less than 0 or greater than 1 will be clamped to the nearest
/// valid value. Note that a sufficiently small value such as 0.3 may be
/// effectively invisible and may make it difficult to find the cursor.
@"cursor-opacity": f64 = 1.0,

/// The style of the cursor. This sets the default style. A running
/// programn can still request an explicit cursor style using escape
/// sequences (such as CSI q). Shell configurations will often request
/// specific cursor styles.
///
/// Caveat: Shell integration currently defaults to always be a bar
/// In order to fix it, we probably would want to add something similar to Kitty's
/// shell integration options (no-cursor). For more information see:
/// https://sw.kovidgoyal.net/kitty/conf/#opt-kitty.shell_integration
@"cursor-style": terminal.Cursor.Style = .block,

/// Whether the cursor shall blink
@"cursor-style-blink": bool = true,

/// The color of the text under the cursor. If this is not set, a default
/// will be chosen.
@"cursor-text": ?Color = null,

/// Hide the mouse immediately when typing. The mouse becomes visible
/// again when the mouse is used. The mouse is only hidden if the mouse
/// cursor is over the active terminal surface.
@"mouse-hide-while-typing": bool = false,

/// Determines whether running programs can detect the shift key pressed
/// with a mouse click. Typically, the shift key is used to extend mouse
/// selection.
///
/// The default value of "false" means that the shift key is not sent
/// with the mouse protocol and will extend the selection. This value
/// can be conditionally overridden by the running program with the
/// XTSHIFTESCAPE sequence.
///
/// The value "true" means that the shift key is sent with the mouse
/// protocol but the running program can override this behavior with
/// XTSHIFTESCAPE.
///
/// The value "never" is the same as "false" but the running program
/// cannot override this behavior with XTSHIFTESCAPE. The value "always"
/// is the same as "true" but the running program cannot override this
/// behavior with XTSHIFTESCAPE.
///
/// If you always want shift to extend mouse selection even if the
/// program requests otherwise, set this to "never".
@"mouse-shift-capture": MouseShiftCapture = .false,

/// The opacity level (opposite of transparency) of the background.
/// A value of 1 is fully opaque and a value of 0 is fully transparent.
/// A value less than 0 or greater than 1 will be clamped to the nearest
/// valid value.
///
/// Changing this value at runtime (and reloading config) will only
/// affect new windows, tabs, and splits.
@"background-opacity": f64 = 1.0,

/// A positive value enables blurring of the background when
/// background-opacity is less than 1. The value is the blur radius to
/// apply. A value of 20 is reasonable for a good looking blur.
/// Higher values will cause strange rendering issues as well as
/// performance issues.
///
/// This is only supported on macOS.
@"background-blur-radius": u8 = 0,

/// The opacity level (opposite of transparency) of an unfocused split.
/// Unfocused splits by default are slightly faded out to make it easier
/// to see which split is focused. To disable this feature, set this
/// value to 1.
///
/// A value of 1 is fully opaque and a value of 0 is fully transparent.
/// Because "0" is not useful (it makes the window look very weird), the
/// minimum value is 0.15. This value still looks weird but you can at least
/// see what's going on. A value outside of the range 0.15 to 1 will be
/// clamped to the nearest valid value.
@"unfocused-split-opacity": f64 = 0.85,

/// The command to run, usually a shell. If this is not an absolute path,
/// it'll be looked up in the PATH. If this is not set, a default will
/// be looked up from your system. The rules for the default lookup are:
///
///   - SHELL environment variable
///   - passwd entry (user information)
///
command: ?[]const u8 = null,

/// A single argument to pass to the command. This can be repeated to
/// pass multiple arguments. This slightly clunky configuration style is
/// so that Ghostty doesn't have to perform any sort of shell parsing
/// to find argument boundaries.
///
/// This cannot be used to override argv[0]. argv[0] will always be
/// set by Ghostty to be the command (possibly with a hyphen-prefix to
/// indicate that it is a login shell, depending on the OS).
@"command-arg": RepeatableString = .{},

/// The directory to change to after starting the command.
///
/// This setting is secondary to the "window-inherit-working-directory"
/// setting. If a previous Ghostty terminal exists in the same process,
/// "window-inherit-working-directory" will take precedence. Otherwise,
/// this setting will be used. Typically, this setting is used only
/// for the first window.
///
/// The default is "inherit" except in special scenarios listed next.
/// On macOS, if Ghostty can detect it is launched from launchd
/// (double-clicked) or `open`, then it defaults to "home".
/// On Linux with GTK, if Ghostty can detect it was launched from
/// a desktop launcher, then it defaults to "home".
///
/// The value of this must be an absolute value or one of the special
/// values below:
///
///   - "home" - The home directory of the executing user.
///   - "inherit" - The working directory of the launching process.
///
@"working-directory": ?[]const u8 = null,

/// Key bindings. The format is "trigger=action". Duplicate triggers
/// will overwrite previously set values.
///
/// Trigger: "+"-separated list of keys and modifiers. Example:
/// "ctrl+a", "ctrl+shift+b", "up". Some notes:
///
///   - modifiers cannot repeat, "ctrl+ctrl+a" is invalid.
///   - modifiers and keys can be in any order, "shift+a+ctrl" is weird,
///     but valid.
///   - only a single key input is allowed, "ctrl+a+b" is invalid.
///
/// Action is the action to take when the trigger is satisfied. It takes
/// the format "action" or "action:param". The latter form is only valid
/// if the action requires a parameter.
///
///   - "ignore" - Do nothing, ignore the key input. This can be used to
///     black hole certain inputs to have no effect.
///   - "unbind" - Remove the binding. This makes it so the previous action
///     is removed, and the key will be sent through to the child command
///     if it is printable.
///   - "csi:text" - Send a CSI sequence. i.e. "csi:A" sends "cursor up".
///
/// Some notes for the action:
///
///   - The parameter is taken as-is after the ":". Double quotes or
///     other mechanisms are included and NOT parsed. If you want to
///     send a string value that includes spaces, wrap the entire
///     trigger/action in double quotes. Example: --keybind="up=csi:A B"
///
keybind: Keybinds = .{},

/// Window padding. This applies padding between the terminal cells and
/// the window border. The "x" option applies to the left and right
/// padding and the "y" option is top and bottom. The value is in points,
/// meaning that it will be scaled appropriately for screen DPI.
///
/// If this value is set too large, the screen will render nothing, because
/// the grid will be completely squished by the padding. It is up to you
/// as the user to pick a reasonable value. If you pick an unreasonable
/// value, a warning will appear in the logs.
@"window-padding-x": u32 = 2,
@"window-padding-y": u32 = 2,

/// The viewport dimensions are usually not perfectly divisible by
/// the cell size. In this case, some extra padding on the end of a
/// column and the bottom of the final row may exist. If this is true,
/// then this extra padding is automatically balanced between all four
/// edges to minimize imbalance on one side. If this is false, the top
/// left grid cell will always hug the edge with zero padding other than
/// what may be specified with the other "window-padding" options.
///
/// If other "window-padding" fields are set and this is true, this will
/// still apply. The other padding is applied first and may affect how
/// many grid cells actually exist, and this is applied last in order
/// to balance the padding given a certain viewport size and grid cell size.
@"window-padding-balance": bool = false,

/// If true, new windows and tabs will inherit the working directory of
/// the previously focused window. If no window was previously focused,
/// the default working directory will be used (the "working-directory"
/// option).
@"window-inherit-working-directory": bool = true,

/// If true, new windows and tabs will inherit the font size of the previously
/// focused window. If no window was previously focused, the default
/// font size will be used. If this is false, the default font size
/// specified in the configuration "font-size" will be used.
@"window-inherit-font-size": bool = true,

/// If false, windows won't have native decorations, i.e. titlebar and
/// borders.
@"window-decoration": bool = true,

/// The theme to use for the windows. The default is "system" which
/// means that whatever the system theme is will be used. This can
/// also be set to "light" or "dark" to force a specific theme regardless
/// of the system settings.
///
/// This is currently only supported on macOS and linux.
@"window-theme": WindowTheme = .system,

/// The initial window size. This size is in terminal grid cells by default.
///
/// We don't currently support specifying a size in pixels but a future
/// change can enable that. If this isn't specified, the app runtime will
/// determine some default size.
///
/// Note that the window manager may put limits on the size or override
/// the size. For example, a tiling window manager may force the window
/// to be a certain size to fit within the grid. There is nothing Ghostty
/// will do about this, but it will make an effort.
///
/// This will not affect new tabs, splits, or other nested terminal
/// elements. This only affects the initial window size of any new window.
/// Changing this value will not affect the size of the window after
/// it has been created. This is only used for the initial size.
///
/// BUG: On Linux with GTK, the calculated window size will not properly
/// take into account window decorations. As a result, the grid dimensions
/// will not exactly match this configuration. If window decorations are
/// disabled (see window-decorations), then this will work as expected.
///
/// Windows smaller than 10 wide by 4 high are not allowed.
@"window-height": u32 = 0,
@"window-width": u32 = 0,

/// Resize the window in discrete increments of the focused surface's
/// cell size. If this is disabled, surfaces are resized in pixel increments.
/// Currently only supported on macOS.
@"window-step-resize": bool = false,

/// Whether to allow programs running in the terminal to read/write to
/// the system clipboard (OSC 52, for googling). The default is to
/// disallow clipboard reading but allow writing.
@"clipboard-read": bool = false,
@"clipboard-write": bool = true,

/// Trims trailing whitespace on data that is copied to the clipboard.
/// This does not affect data sent to the clipboard via "clipboard-write".
@"clipboard-trim-trailing-spaces": bool = true,

/// The total amount of bytes that can be used for image data (i.e.
/// the Kitty image protocol) per terminal scren. The maximum value
/// is 4,294,967,295 (4GB). The default is 320MB. If this is set to zero,
/// then all image protocols will be disabled.
///
/// This value is separate for primary and alternate screens so the
/// effective limit per surface is double.
@"image-storage-limit": u32 = 320 * 1000 * 1000,

/// Whether to automatically copy selected text to the clipboard. "true"
/// will only copy on systems that support a selection clipboard.
///
/// The value "clipboard" will copy to the system clipboard, making this
/// work on macOS. Note that middle-click will also paste from the system
/// clipboard in this case.
///
/// Note that if this is disabled, middle-click paste will also be
/// disabled.
@"copy-on-select": CopyOnSelect = .true,

/// The time in milliseconds between clicks to consider a click a repeat
/// (double, triple, etc.) or an entirely new single click. A value of
/// zero will use a platform-specific default. The default on macOS
/// is determined by the OS settings. On every other platform it is 500ms.
@"click-repeat-interval": u32 = 0,

/// Additional configuration files to read.
@"config-file": RepeatableString = .{},

/// Confirms that a surface should be closed before closing it. This defaults
/// to true. If set to false, surfaces will close without any confirmation.
@"confirm-close-surface": bool = true,

/// Whether or not to quit after the last window is closed. This defaults
/// to false. Currently only supported on macOS. On Linux, the process always
/// exits after the last window is closed.
@"quit-after-last-window-closed": bool = false,

/// Whether to enable shell integration auto-injection or not. Shell
/// integration greatly enhances the terminal experience by enabling
/// a number of features:
///
///   * Working directory reporting so new tabs, splits inherit the
///     previous terminal's working directory.
///   * Prompt marking that enables the "jump_to_prompt" keybinding.
///   * If you're sitting at a prompt, closing a terminal will not ask
///     for confirmation.
///   * Resizing the window with a complex prompt usually paints much
///     better.
///
/// Allowable values are:
///
///   * "none" - Do not do any automatic injection. You can still manually
///     configure your shell to enable the integration.
///   * "detect" - Detect the shell based on the filename.
///   * "fish", "zsh" - Use this specific shell injection scheme.
///
/// The default value is "detect".
@"shell-integration": ShellIntegration = .detect,

/// Sets the reporting format for OSC sequences that request color information.
/// Ghostty currently supports OSC 10 (foreground) and OSC 11 (background) queries,
/// and by default the reported values are scaled-up RGB values, where each component
/// are 16 bits. This is how most terminals report these values. However, some legacy
/// applications may require 8-bit, unscaled, components. We also support turning off
/// reporting alltogether. The components are lowercase hex values.
///
/// Allowable values are:
///
///   * "none" - OSC 10/11 queries receive no reply
///   * "8-bit" - Color components are return unscaled, i.e. rr/gg/bb
///   * "16-bit" - Color components are returned scaled, e.g. rrrr/gggg/bbbb
///
/// The default value is "16-bit".
@"osc-color-report-format": OSCColorReportFormat = .@"16-bit",

/// If true, allows the "KAM" mode (ANSI mode 2) to be used within
/// the terminal. KAM disables keyboard input at the request of the
/// application. This is not a common feature and is not recommended
/// to be enabled. This will not be documented further because
/// if you know you need KAM, you know. If you don't know if you
/// need KAM, you don't need it.
@"vt-kam-allowed": bool = false,

/// If anything other than false, fullscreen mode on macOS will not use the
/// native fullscreen, but make the window fullscreen without animations and
/// using a new space. It's faster than the native fullscreen mode since it
/// doesn't use animations.
///
/// Allowable values are:
///
///   * "visible-menu" - Use non-native macOS fullscreen, keep the menu bar visible
///   * "true" - Use non-native macOS fullscreen, hide the menu bar
///   * "false" - Use native macOS fullscreeen
@"macos-non-native-fullscreen": NonNativeFullscreen = .false,

/// If true, the Option key will be treated as Alt. This makes terminal
/// sequences expecting Alt to work properly, but will break Unicode
/// input sequences on macOS if you use them via the alt key. You may
/// set this to false to restore the macOS alt-key unicode sequences
/// but this will break terminal sequences expecting Alt to work.
///
/// Note that if an Option-sequence doesn't produce a printable
/// character, it will be treated as Alt regardless of this setting.
/// (i.e. alt+ctrl+a).
///
/// This does not work with GLFW builds.
@"macos-option-as-alt": OptionAsAlt = .false,

/// If true, the Ghostty GTK application will run in single-instance mode:
/// each new `ghostty` process launched will result in a new window if there
/// is already a running process.
///
/// If false, each new ghostty process will launch a separate application.
///
/// The default value is "desktop" which will default to "true" if Ghostty
/// detects it was launched from the .desktop file such as an app launcher.
/// If Ghostty is launched from the command line, it will default to "false".
///
/// Note that debug builds of Ghostty have a separate single-instance ID
/// so you can test single instance without conflicting with release builds.
@"gtk-single-instance": GtkSingleInstance = .desktop,

/// If true (default), then the Ghostty GTK tabs will be "wide." Wide tabs
/// are the new typical Gnome style where tabs fill their available space.
/// If you set this to false then tabs will only take up space they need,
/// which is the old style.
@"gtk-wide-tabs": bool = true,

/// This will be used to set the TERM environment variable.
/// HACK: We set this with an "xterm" prefix because vim uses that to enable key
/// protocols (specifically this will enable 'modifyOtherKeys'), among other
/// features. An option exists in vim to modify this: `:set
/// keyprotocol=ghostty:kitty`, however a bug in the implementation prevents it
/// from working properly. https://github.com/vim/vim/pull/13211 fixes this.
term: []const u8 = "xterm-ghostty",

/// This is set by the CLI parser for deinit.
_arena: ?ArenaAllocator = null,

/// List of errors that occurred while loading. This can be accessed directly
/// by callers. It is only underscore-prefixed so it can't be set by the
/// configuration file.
_errors: ErrorList = .{},

pub fn deinit(self: *Config) void {
    if (self._arena) |arena| arena.deinit();
    self.* = undefined;
}

/// Load the configuration according to the default rules:
///
///   1. Defaults
///   2. XDG Config File
///   3. CLI flags
///   4. Recursively defined configuration files
///
pub fn load(alloc_gpa: Allocator) !Config {
    var result = try default(alloc_gpa);
    errdefer result.deinit();

    // If we have a configuration file in our home directory, parse that first.
    try result.loadDefaultFiles(alloc_gpa);

    // Parse the config from the CLI args
    try result.loadCliArgs(alloc_gpa);

    // Parse the config files that were added from our file and CLI args.
    try result.loadRecursiveFiles(alloc_gpa);
    try result.finalize();

    return result;
}

pub fn default(alloc_gpa: Allocator) Allocator.Error!Config {
    // Build up our basic config
    var result: Config = .{
        ._arena = ArenaAllocator.init(alloc_gpa),
    };
    errdefer result.deinit();
    const alloc = result._arena.?.allocator();

    // Add our default keybindings
    try result.keybind.set.put(
        alloc,
        .{ .key = .space, .mods = .{ .super = true, .alt = true, .ctrl = true } },
        .{ .reload_config = {} },
    );

    {
        // On macOS we default to super but Linux ctrl+shift since
        // ctrl+c is to kill the process.
        const mods: inputpkg.Mods = if (builtin.target.isDarwin())
            .{ .super = true }
        else
            .{ .ctrl = true, .shift = true };

        try result.keybind.set.put(
            alloc,
            .{ .key = .c, .mods = mods },
            .{ .copy_to_clipboard = {} },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .v, .mods = mods },
            .{ .paste_from_clipboard = {} },
        );
    }

    // Fonts
    try result.keybind.set.put(
        alloc,
        .{ .key = .equal, .mods = ctrlOrSuper(.{}) },
        .{ .increase_font_size = 1 },
    );
    try result.keybind.set.put(
        alloc,
        .{ .key = .minus, .mods = ctrlOrSuper(.{}) },
        .{ .decrease_font_size = 1 },
    );
    try result.keybind.set.put(
        alloc,
        .{ .key = .zero, .mods = ctrlOrSuper(.{}) },
        .{ .reset_font_size = {} },
    );

    try result.keybind.set.put(
        alloc,
        .{ .key = .j, .mods = ctrlOrSuper(.{ .shift = true }) },
        .{ .write_scrollback_file = {} },
    );

    // Windowing
    if (comptime !builtin.target.isDarwin()) {
        try result.keybind.set.put(
            alloc,
            .{ .key = .n, .mods = .{ .ctrl = true, .shift = true } },
            .{ .new_window = {} },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .w, .mods = .{ .ctrl = true, .shift = true } },
            .{ .close_surface = {} },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .q, .mods = .{ .ctrl = true, .shift = true } },
            .{ .quit = {} },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .f4, .mods = .{ .alt = true } },
            .{ .close_window = {} },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .t, .mods = .{ .ctrl = true, .shift = true } },
            .{ .new_tab = {} },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .left, .mods = .{ .ctrl = true, .shift = true } },
            .{ .previous_tab = {} },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .right, .mods = .{ .ctrl = true, .shift = true } },
            .{ .next_tab = {} },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .page_up, .mods = .{ .ctrl = true } },
            .{ .previous_tab = {} },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .page_down, .mods = .{ .ctrl = true } },
            .{ .next_tab = {} },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .o, .mods = .{ .ctrl = true, .shift = true } },
            .{ .new_split = .right },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .e, .mods = .{ .ctrl = true, .shift = true } },
            .{ .new_split = .down },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .left_bracket, .mods = .{ .ctrl = true, .super = true } },
            .{ .goto_split = .previous },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .right_bracket, .mods = .{ .ctrl = true, .super = true } },
            .{ .goto_split = .next },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .up, .mods = .{ .ctrl = true, .alt = true } },
            .{ .goto_split = .top },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .down, .mods = .{ .ctrl = true, .alt = true } },
            .{ .goto_split = .bottom },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .left, .mods = .{ .ctrl = true, .alt = true } },
            .{ .goto_split = .left },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .right, .mods = .{ .ctrl = true, .alt = true } },
            .{ .goto_split = .right },
        );

        // Viewport scrolling
        try result.keybind.set.put(
            alloc,
            .{ .key = .home, .mods = .{ .shift = true } },
            .{ .scroll_to_top = {} },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .end, .mods = .{ .shift = true } },
            .{ .scroll_to_bottom = {} },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .page_up, .mods = .{ .shift = true } },
            .{ .scroll_page_up = {} },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .page_down, .mods = .{ .shift = true } },
            .{ .scroll_page_down = {} },
        );

        // Semantic prompts
        try result.keybind.set.put(
            alloc,
            .{ .key = .page_up, .mods = .{ .shift = true, .ctrl = true } },
            .{ .jump_to_prompt = -1 },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .page_down, .mods = .{ .shift = true, .ctrl = true } },
            .{ .jump_to_prompt = 1 },
        );

        // Inspector, matching Chromium
        try result.keybind.set.put(
            alloc,
            .{ .key = .i, .mods = .{ .shift = true, .ctrl = true } },
            .{ .inspector = .toggle },
        );
    }
    {
        // Cmd+N for goto tab N
        const start = @intFromEnum(inputpkg.Key.one);
        const end = @intFromEnum(inputpkg.Key.nine);
        var i: usize = start;
        while (i <= end) : (i += 1) {
            // On macOS we default to super but everywhere else
            // is alt.
            const mods: inputpkg.Mods = if (builtin.target.isDarwin())
                .{ .super = true }
            else
                .{ .alt = true };

            try result.keybind.set.put(
                alloc,
                .{ .key = @enumFromInt(i), .mods = mods },
                .{ .goto_tab = (i - start) + 1 },
            );
        }
    }

    // Toggle fullscreen
    try result.keybind.set.put(
        alloc,
        .{ .key = .enter, .mods = ctrlOrSuper(.{}) },
        .{ .toggle_fullscreen = {} },
    );

    // Toggle zoom a split
    try result.keybind.set.put(
        alloc,
        .{ .key = .enter, .mods = ctrlOrSuper(.{ .shift = true }) },
        .{ .toggle_split_zoom = {} },
    );

    // Mac-specific keyboard bindings.
    if (comptime builtin.target.isDarwin()) {
        try result.keybind.set.put(
            alloc,
            .{ .key = .q, .mods = .{ .super = true } },
            .{ .quit = {} },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .comma, .mods = .{ .super = true, .shift = true } },
            .{ .reload_config = {} },
        );

        try result.keybind.set.put(
            alloc,
            .{ .key = .k, .mods = .{ .super = true } },
            .{ .clear_screen = {} },
        );

        // Viewport scrolling
        try result.keybind.set.put(
            alloc,
            .{ .key = .home, .mods = .{ .super = true } },
            .{ .scroll_to_top = {} },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .end, .mods = .{ .super = true } },
            .{ .scroll_to_bottom = {} },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .page_up, .mods = .{ .super = true } },
            .{ .scroll_page_up = {} },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .page_down, .mods = .{ .super = true } },
            .{ .scroll_page_down = {} },
        );

        // Semantic prompts
        try result.keybind.set.put(
            alloc,
            .{ .key = .up, .mods = .{ .super = true, .shift = true } },
            .{ .jump_to_prompt = -1 },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .down, .mods = .{ .super = true, .shift = true } },
            .{ .jump_to_prompt = 1 },
        );

        // Mac windowing
        try result.keybind.set.put(
            alloc,
            .{ .key = .n, .mods = .{ .super = true } },
            .{ .new_window = {} },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .w, .mods = .{ .super = true } },
            .{ .close_surface = {} },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .w, .mods = .{ .super = true, .shift = true } },
            .{ .close_window = {} },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .t, .mods = .{ .super = true } },
            .{ .new_tab = {} },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .left_bracket, .mods = .{ .super = true, .shift = true } },
            .{ .previous_tab = {} },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .right_bracket, .mods = .{ .super = true, .shift = true } },
            .{ .next_tab = {} },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .d, .mods = .{ .super = true } },
            .{ .new_split = .right },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .d, .mods = .{ .super = true, .shift = true } },
            .{ .new_split = .down },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .left_bracket, .mods = .{ .super = true } },
            .{ .goto_split = .previous },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .right_bracket, .mods = .{ .super = true } },
            .{ .goto_split = .next },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .up, .mods = .{ .super = true, .alt = true } },
            .{ .goto_split = .top },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .down, .mods = .{ .super = true, .alt = true } },
            .{ .goto_split = .bottom },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .left, .mods = .{ .super = true, .alt = true } },
            .{ .goto_split = .left },
        );
        try result.keybind.set.put(
            alloc,
            .{ .key = .right, .mods = .{ .super = true, .alt = true } },
            .{ .goto_split = .right },
        );

        // Inspector, matching Chromium
        try result.keybind.set.put(
            alloc,
            .{ .key = .i, .mods = .{ .alt = true, .super = true } },
            .{ .inspector = .toggle },
        );
    }

    return result;
}

/// This sets either "ctrl" or "super" to true (but not both)
/// on mods depending on if the build target is Mac or not. On
/// Mac, we default to super (i.e. super+c for copy) and on
/// non-Mac we default to ctrl (i.e. ctrl+c for copy).
fn ctrlOrSuper(mods: inputpkg.Mods) inputpkg.Mods {
    var copy = mods;
    if (comptime builtin.target.isDarwin()) {
        copy.super = true;
    } else {
        copy.ctrl = true;
    }

    return copy;
}

/// Load the configuration from the default file locations. Currently,
/// this loads from $XDG_CONFIG_HOME/ghostty/config.
pub fn loadDefaultFiles(self: *Config, alloc: Allocator) !void {
    const home_config_path = try internal_os.xdg.config(alloc, .{ .subdir = "ghostty/config" });
    defer alloc.free(home_config_path);

    const cwd = std.fs.cwd();
    if (cwd.openFile(home_config_path, .{})) |file| {
        defer file.close();
        std.log.info("reading configuration file path={s}", .{home_config_path});

        var buf_reader = std.io.bufferedReader(file.reader());
        var iter = cli.args.lineIterator(buf_reader.reader());
        try cli.args.parse(Config, alloc, self, &iter);
    } else |err| switch (err) {
        error.FileNotFound => std.log.info(
            "homedir config not found, not loading path={s}",
            .{home_config_path},
        ),

        else => std.log.warn(
            "error reading homedir config file, not loading err={} path={s}",
            .{ err, home_config_path },
        ),
    }
}

/// Load and parse the CLI args.
pub fn loadCliArgs(self: *Config, alloc_gpa: Allocator) !void {
    switch (builtin.os.tag) {
        .windows => {},

        // Fast-path if we are non-Windows and no args, do nothing.
        else => if (std.os.argv.len <= 1) return,
    }

    // Parse the config from the CLI args
    var iter = try std.process.argsWithAllocator(alloc_gpa);
    defer iter.deinit();
    try cli.args.parse(Config, alloc_gpa, self, &iter);
}

/// Load and parse the config files that were added in the "config-file" key.
pub fn loadRecursiveFiles(self: *Config, alloc: Allocator) !void {
    // TODO(mitchellh): support nesting (config-file in a config file)
    // TODO(mitchellh): detect cycles when nesting

    if (self.@"config-file".list.items.len == 0) return;

    const arena_alloc = self._arena.?.allocator();
    const cwd = std.fs.cwd();
    const len = self.@"config-file".list.items.len;
    for (self.@"config-file".list.items) |path| {
        var file = cwd.openFile(path, .{}) catch |err| {
            try self._errors.add(arena_alloc, .{
                .message = try std.fmt.allocPrintZ(
                    arena_alloc,
                    "error opening config-file {s}: {}",
                    .{ path, err },
                ),
            });
            continue;
        };
        defer file.close();

        var buf_reader = std.io.bufferedReader(file.reader());
        var iter = cli.args.lineIterator(buf_reader.reader());
        try cli.args.parse(Config, alloc, self, &iter);

        // We don't currently support adding more config files to load
        // from within a loaded config file. This can be supported
        // later.
        if (self.@"config-file".list.items.len > len) {
            try self._errors.add(arena_alloc, .{
                .message = try std.fmt.allocPrintZ(
                    arena_alloc,
                    "config-file cannot be used in a config-file. Found in {s}",
                    .{path},
                ),
            });
        }
    }
}

pub fn finalize(self: *Config) !void {
    // If we have a font-family set and don't set the others, default
    // the others to the font family. This way, if someone does
    // --font-family=foo, then we try to get the stylized versions of
    // "foo" as well.
    if (self.@"font-family") |family| {
        const fields = &[_][]const u8{
            "font-family-bold",
            "font-family-italic",
            "font-family-bold-italic",
        };
        inline for (fields) |field| {
            if (@field(self, field) == null) {
                @field(self, field) = family;
            }
        }
    }

    // Prevent setting TERM to an empty string
    if (self.term.len == 0) {
        // HACK: See comment above at definition
        self.term = "xterm-ghostty";
    }

    // The default for the working directory depends on the system.
    const wd = self.@"working-directory" orelse wd: {
        // If we have no working directory set, our default depends on
        // whether we were launched from the desktop or CLI.
        if (internal_os.launchedFromDesktop()) {
            break :wd "home";
        }

        break :wd "inherit";
    };

    // If we are missing either a command or home directory, we need
    // to look up defaults which is kind of expensive. We only do this
    // on desktop.
    const wd_home = std.mem.eql(u8, "home", wd);
    if (comptime !builtin.target.isWasm()) {
        if (self.command == null or wd_home) command: {
            const alloc = self._arena.?.allocator();

            // First look up the command using the SHELL env var if needed.
            // We don't do this in flatpak because SHELL in Flatpak is always
            // set to /bin/sh.
            if (self.command) |cmd|
                log.info("shell src=config value={s}", .{cmd})
            else {
                if (!internal_os.isFlatpak()) {
                    if (std.process.getEnvVarOwned(alloc, "SHELL")) |value| {
                        log.info("default shell source=env value={s}", .{value});
                        self.command = value;

                        // If we don't need the working directory, then we can exit now.
                        if (!wd_home) break :command;
                    } else |_| {}
                }
            }

            // We need the passwd entry for the remainder
            const pw = try internal_os.passwd.get(alloc);
            if (self.command == null) {
                if (pw.shell) |sh| {
                    log.info("default shell src=passwd value={s}", .{sh});
                    self.command = sh;
                }
            }

            if (wd_home) {
                if (pw.home) |home| {
                    log.info("default working directory src=passwd value={s}", .{home});
                    self.@"working-directory" = home;
                }
            }

            if (self.command == null) {
                log.warn("no default shell found, will default to using sh", .{});
            }
        }
    }

    // If we have the special value "inherit" then set it to null which
    // does the same. In the future we should change to a tagged union.
    if (std.mem.eql(u8, wd, "inherit")) self.@"working-directory" = null;

    // Default our click interval
    if (self.@"click-repeat-interval" == 0) {
        self.@"click-repeat-interval" = internal_os.clickInterval() orelse 500;
    }

    // Clamp our split opacity
    self.@"unfocused-split-opacity" = @min(1.0, @max(0.15, self.@"unfocused-split-opacity"));

    // Minimmum window size
    if (self.@"window-width" > 0) self.@"window-width" = @max(10, self.@"window-width");
    if (self.@"window-height" > 0) self.@"window-height" = @max(4, self.@"window-height");
}

/// Callback for src/cli/args.zig to allow us to handle special cases
/// like `--help` or `-e`. Returns "false" if the CLI parsing should halt.
pub fn parseManuallyHook(self: *Config, alloc: Allocator, arg: []const u8, iter: anytype) !bool {
    // If it isn't "-e" then we just continue parsing normally.
    if (!std.mem.eql(u8, arg, "-e")) return true;

    // The first value is the command to run.
    if (iter.next()) |command| {
        self.command = try alloc.dupe(u8, command);
    } else {
        try self._errors.add(alloc, .{
            .message = try std.fmt.allocPrintZ(
                alloc,
                "missing command after -e",
                .{},
            ),
        });

        return false;
    }

    // All further arguments are parameters
    self.@"command-arg".list.clearRetainingCapacity();
    while (iter.next()) |param| {
        try self.@"command-arg".parseCLI(alloc, param);
    }

    // Do not continue, we consumed everything.
    return false;
}

/// Create a shallow copy of this config. This will share all the memory
/// allocated with the previous config but will have a new arena for
/// any changes or new allocations. The config should have `deinit`
/// called when it is complete.
///
/// Beware: these shallow clones are not meant for a long lifetime,
/// they are just meant to exist temporarily for the duration of some
/// modifications. It is very important that the original config not
/// be deallocated while shallow clones exist.
pub fn shallowClone(self: *const Config, alloc_gpa: Allocator) Config {
    var result = self.*;
    result._arena = ArenaAllocator.init(alloc_gpa);
    return result;
}

/// Create a copy of this configuration. This is useful as a starting
/// point for modifying a configuration since a config can NOT be
/// modified once it is in use by an app or surface.
pub fn clone(self: *const Config, alloc_gpa: Allocator) !Config {
    // Start with an empty config with a new arena we're going
    // to use for all our copies.
    var result: Config = .{
        ._arena = ArenaAllocator.init(alloc_gpa),
    };
    errdefer result.deinit();
    const alloc = result._arena.?.allocator();

    inline for (@typeInfo(Config).Struct.fields) |field| {
        if (!@hasField(Key, field.name)) continue;
        @field(result, field.name) = try cloneValue(
            alloc,
            field.type,
            @field(self, field.name),
        );
    }

    return result;
}

fn cloneValue(alloc: Allocator, comptime T: type, src: T) !T {
    // Do known named types first
    switch (T) {
        []const u8 => return try alloc.dupe(u8, src),
        [:0]const u8 => return try alloc.dupeZ(u8, src),

        else => {},
    }

    // If we're a type that can have decls and we have clone, then
    // call clone and be done.
    const t = @typeInfo(T);
    if (t == .Struct or t == .Enum or t == .Union) {
        if (@hasDecl(T, "clone")) return try src.clone(alloc);
    }

    // Back into types of types
    switch (t) {
        inline .Bool,
        .Int,
        .Float,
        .Enum,
        .Union,
        => return src,

        .Optional => |info| return try cloneValue(
            alloc,
            info.child,
            src orelse return null,
        ),

        .Struct => return try src.clone(alloc),

        else => {
            @compileLog(T);
            @compileError("unsupported field type");
        },
    }
}

/// Returns an iterator that goes through each changed field from
/// old to new. The order of old or new do not matter.
pub fn changeIterator(old: *const Config, new: *const Config) ChangeIterator {
    return .{
        .old = old,
        .new = new,
    };
}

/// Returns true if the given key has changed from old to new. This
/// requires the key to be comptime known to make this more efficient.
pub fn changed(self: *const Config, new: *const Config, comptime key: Key) bool {
    // Get the field at comptime
    const field = comptime field: {
        const fields = std.meta.fields(Config);
        for (fields) |field| {
            if (@field(Key, field.name) == key) {
                break :field field;
            }
        }

        unreachable;
    };

    const old_value = @field(self, field.name);
    const new_value = @field(new, field.name);
    return !equalField(field.type, old_value, new_value);
}

/// This yields a key for every changed field between old and new.
pub const ChangeIterator = struct {
    old: *const Config,
    new: *const Config,
    i: usize = 0,

    pub fn next(self: *ChangeIterator) ?Key {
        const fields = comptime std.meta.fields(Key);
        while (self.i < fields.len) {
            switch (self.i) {
                inline 0...(fields.len - 1) => |i| {
                    const field = fields[i];
                    const key = @field(Key, field.name);
                    self.i += 1;
                    if (self.old.changed(self.new, key)) return key;
                },

                else => unreachable,
            }
        }

        return null;
    }
};

const TestIterator = struct {
    data: []const []const u8,
    i: usize = 0,

    pub fn next(self: *TestIterator) ?[]const u8 {
        if (self.i >= self.data.len) return null;
        const result = self.data[self.i];
        self.i += 1;
        return result;
    }
};

test "parse hook: invalid command" {
    const testing = std.testing;
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();
    const alloc = cfg._arena.?.allocator();

    var it: TestIterator = .{ .data = &.{"foo"} };
    try testing.expect(try cfg.parseManuallyHook(alloc, "--command", &it));
    try testing.expect(cfg.command == null);
}

test "parse e: command only" {
    const testing = std.testing;
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();
    const alloc = cfg._arena.?.allocator();

    var it: TestIterator = .{ .data = &.{"foo"} };
    try testing.expect(!try cfg.parseManuallyHook(alloc, "-e", &it));
    try testing.expectEqualStrings("foo", cfg.command.?);
}

test "parse e: command and args" {
    const testing = std.testing;
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();
    const alloc = cfg._arena.?.allocator();

    var it: TestIterator = .{ .data = &.{ "echo", "foo", "bar baz" } };
    try testing.expect(!try cfg.parseManuallyHook(alloc, "-e", &it));
    try testing.expectEqualStrings("echo", cfg.command.?);
    try testing.expectEqual(@as(usize, 2), cfg.@"command-arg".list.items.len);
    try testing.expectEqualStrings("foo", cfg.@"command-arg".list.items[0]);
    try testing.expectEqualStrings("bar baz", cfg.@"command-arg".list.items[1]);
}

test "parse e: command replaces args" {
    const testing = std.testing;
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();
    const alloc = cfg._arena.?.allocator();

    try cfg.@"command-arg".parseCLI(alloc, "foo");
    try testing.expectEqual(@as(usize, 1), cfg.@"command-arg".list.items.len);

    var it: TestIterator = .{ .data = &.{"echo"} };
    try testing.expect(!try cfg.parseManuallyHook(alloc, "-e", &it));
    try testing.expectEqualStrings("echo", cfg.command.?);
    try testing.expectEqual(@as(usize, 0), cfg.@"command-arg".list.items.len);
}

test "clone default" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var source = try Config.default(alloc);
    defer source.deinit();
    var dest = try source.clone(alloc);
    defer dest.deinit();

    // Should have no changes
    var it = source.changeIterator(&dest);
    try testing.expectEqual(@as(?Key, null), it.next());

    // I want to do this but this doesn't work (the API doesn't work)
    // try testing.expectEqualDeep(dest, source);
}

test "changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var source = try Config.default(alloc);
    defer source.deinit();
    var dest = try source.clone(alloc);
    defer dest.deinit();
    dest.@"font-family" = "something else";

    try testing.expect(source.changed(&dest, .@"font-family"));
    try testing.expect(!source.changed(&dest, .@"font-size"));
}

/// A config-specific helper to determine if two values of the same
/// type are equal. This isn't the same as std.mem.eql or std.testing.equals
/// because we expect structs to implement their own equality.
///
/// This also doesn't support ALL Zig types, because we only add to it
/// as we need types for the config.
fn equalField(comptime T: type, old: T, new: T) bool {
    // Do known named types first
    switch (T) {
        inline []const u8,
        [:0]const u8,
        => return std.mem.eql(u8, old, new),

        else => {},
    }

    // Back into types of types
    switch (@typeInfo(T)) {
        .Void => return true,

        inline .Bool,
        .Int,
        .Float,
        .Enum,
        => return old == new,

        .Optional => |info| {
            if (old == null and new == null) return true;
            if (old == null or new == null) return false;
            return equalField(info.child, old.?, new.?);
        },

        .Struct => |info| {
            if (@hasDecl(T, "equal")) return old.equal(new);

            // If a struct doesn't declare an "equal" function, we fall back
            // to a recursive field-by-field compare.
            inline for (info.fields) |field_info| {
                if (!equalField(
                    field_info.type,
                    @field(old, field_info.name),
                    @field(new, field_info.name),
                )) return false;
            }
            return true;
        },

        .Union => |info| {
            const tag_type = info.tag_type.?;
            const old_tag = std.meta.activeTag(old);
            const new_tag = std.meta.activeTag(new);
            if (old_tag != new_tag) return false;

            inline for (info.fields) |field_info| {
                if (@field(tag_type, field_info.name) == old_tag) {
                    return equalField(
                        field_info.type,
                        @field(old, field_info.name),
                        @field(new, field_info.name),
                    );
                }
            }

            unreachable;
        },

        else => {
            @compileLog(T);
            @compileError("unsupported field type");
        },
    }
}

/// Valid values for macos-non-native-fullscreen
/// c_int because it needs to be extern compatible
/// If this is changed, you must also update ghostty.h
pub const NonNativeFullscreen = enum(c_int) {
    false,
    true,
    @"visible-menu",
};

/// Valid values for macos-option-as-alt.
pub const OptionAsAlt = enum {
    false,
    true,
    left,
    right,
};

/// Color represents a color using RGB.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    /// Convert this to the terminal RGB struct
    pub fn toTerminalRGB(self: Color) terminal.color.RGB {
        return .{ .r = self.r, .g = self.g, .b = self.b };
    }

    pub fn parseCLI(input: ?[]const u8) !Color {
        return fromHex(input orelse return error.ValueRequired);
    }

    /// Deep copy of the struct. Required by Config.
    pub fn clone(self: Color, _: Allocator) !Color {
        return self;
    }

    /// Compare if two of our value are requal. Required by Config.
    pub fn equal(self: Color, other: Color) bool {
        return std.meta.eql(self, other);
    }

    /// fromHex parses a color from a hex value such as #RRGGBB. The "#"
    /// is optional.
    pub fn fromHex(input: []const u8) !Color {
        // Trim the beginning '#' if it exists
        const trimmed = if (input.len != 0 and input[0] == '#') input[1..] else input;

        // We expect exactly 6 for RRGGBB
        if (trimmed.len != 6) return error.InvalidValue;

        // Parse the colors two at a time.
        var result: Color = undefined;
        comptime var i: usize = 0;
        inline while (i < 6) : (i += 2) {
            const v: u8 =
                ((try std.fmt.charToDigit(trimmed[i], 16)) * 16) +
                try std.fmt.charToDigit(trimmed[i + 1], 16);

            @field(result, switch (i) {
                0 => "r",
                2 => "g",
                4 => "b",
                else => unreachable,
            }) = v;
        }

        return result;
    }

    test "fromHex" {
        const testing = std.testing;

        try testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0 }, try Color.fromHex("#000000"));
        try testing.expectEqual(Color{ .r = 10, .g = 11, .b = 12 }, try Color.fromHex("#0A0B0C"));
        try testing.expectEqual(Color{ .r = 10, .g = 11, .b = 12 }, try Color.fromHex("0A0B0C"));
        try testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255 }, try Color.fromHex("FFFFFF"));
    }
};

/// Palette is the 256 color palette for 256-color mode. This is still
/// used by many terminal applications.
pub const Palette = struct {
    const Self = @This();

    /// The actual value that is updated as we parse.
    value: terminal.color.Palette = terminal.color.default,

    pub fn parseCLI(
        self: *Self,
        input: ?[]const u8,
    ) !void {
        const value = input orelse return error.ValueRequired;
        const eqlIdx = std.mem.indexOf(u8, value, "=") orelse
            return error.InvalidValue;

        const key = try std.fmt.parseInt(u8, value[0..eqlIdx], 10);
        const rgb = try Color.parseCLI(value[eqlIdx + 1 ..]);
        self.value[key] = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b };
    }

    /// Deep copy of the struct. Required by Config.
    pub fn clone(self: Self, _: Allocator) !Self {
        return self;
    }

    /// Compare if two of our value are requal. Required by Config.
    pub fn equal(self: Self, other: Self) bool {
        return std.meta.eql(self, other);
    }

    test "parseCLI" {
        const testing = std.testing;

        var p: Self = .{};
        try p.parseCLI("0=#AABBCC");
        try testing.expect(p.value[0].r == 0xAA);
        try testing.expect(p.value[0].g == 0xBB);
        try testing.expect(p.value[0].b == 0xCC);
    }

    test "parseCLI overflow" {
        const testing = std.testing;

        var p: Self = .{};
        try testing.expectError(error.Overflow, p.parseCLI("256=#AABBCC"));
    }
};

/// RepeatableString is a string value that can be repeated to accumulate
/// a list of strings. This isn't called "StringList" because I find that
/// sometimes leads to confusion that it _accepts_ a list such as
/// comma-separated values.
pub const RepeatableString = struct {
    const Self = @This();

    // Allocator for the list is the arena for the parent config.
    list: std.ArrayListUnmanaged([]const u8) = .{},

    pub fn parseCLI(self: *Self, alloc: Allocator, input: ?[]const u8) !void {
        const value = input orelse return error.ValueRequired;
        const copy = try alloc.dupe(u8, value);
        try self.list.append(alloc, copy);
    }

    /// Deep copy of the struct. Required by Config.
    pub fn clone(self: *const Self, alloc: Allocator) !Self {
        return .{
            .list = try self.list.clone(alloc),
        };
    }

    /// Compare if two of our value are requal. Required by Config.
    pub fn equal(self: Self, other: Self) bool {
        const itemsA = self.list.items;
        const itemsB = other.list.items;
        if (itemsA.len != itemsB.len) return false;
        for (itemsA, itemsB) |a, b| {
            if (!std.mem.eql(u8, a, b)) return false;
        } else return true;
    }

    test "parseCLI" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var list: Self = .{};
        try list.parseCLI(alloc, "A");
        try list.parseCLI(alloc, "B");

        try testing.expectEqual(@as(usize, 2), list.list.items.len);
    }
};

/// FontVariation is a repeatable configuration value that sets a single
/// font variation value. Font variations are configurations for what
/// are often called "variable fonts." The font files usually end in
/// "-VF.ttf."
///
/// The value for this is in the format of `id=value` where `id` is the
/// 4-character font variation axis identifier and `value` is the
/// floating point value for that axis. For more details on font variations
/// see the MDN font-variation-settings documentation since this copies that
/// behavior almost exactly:
///
/// https://developer.mozilla.org/en-US/docs/Web/CSS/font-variation-settings
pub const RepeatableFontVariation = struct {
    const Self = @This();

    // Allocator for the list is the arena for the parent config.
    list: std.ArrayListUnmanaged(fontpkg.face.Variation) = .{},

    pub fn parseCLI(self: *Self, alloc: Allocator, input_: ?[]const u8) !void {
        const input = input_ orelse return error.ValueRequired;
        const eql_idx = std.mem.indexOf(u8, input, "=") orelse return error.InvalidValue;
        const whitespace = " \t";
        const key = std.mem.trim(u8, input[0..eql_idx], whitespace);
        const value = std.mem.trim(u8, input[eql_idx + 1 ..], whitespace);
        if (key.len != 4) return error.InvalidValue;
        try self.list.append(alloc, .{
            .id = fontpkg.face.Variation.Id.init(@ptrCast(key.ptr)),
            .value = std.fmt.parseFloat(f64, value) catch return error.InvalidValue,
        });
    }

    /// Deep copy of the struct. Required by Config.
    pub fn clone(self: *const Self, alloc: Allocator) !Self {
        return .{
            .list = try self.list.clone(alloc),
        };
    }

    /// Compare if two of our value are requal. Required by Config.
    pub fn equal(self: Self, other: Self) bool {
        const itemsA = self.list.items;
        const itemsB = other.list.items;
        if (itemsA.len != itemsB.len) return false;
        for (itemsA, itemsB) |a, b| {
            if (!std.meta.eql(a, b)) return false;
        } else return true;
    }

    test "parseCLI" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var list: Self = .{};
        try list.parseCLI(alloc, "wght=200");
        try list.parseCLI(alloc, "slnt=-15");

        try testing.expectEqual(@as(usize, 2), list.list.items.len);
        try testing.expectEqual(fontpkg.face.Variation{
            .id = fontpkg.face.Variation.Id.init("wght"),
            .value = 200,
        }, list.list.items[0]);
        try testing.expectEqual(fontpkg.face.Variation{
            .id = fontpkg.face.Variation.Id.init("slnt"),
            .value = -15,
        }, list.list.items[1]);
    }

    test "parseCLI with whitespace" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var list: Self = .{};
        try list.parseCLI(alloc, "wght =200");
        try list.parseCLI(alloc, "slnt= -15");

        try testing.expectEqual(@as(usize, 2), list.list.items.len);
        try testing.expectEqual(fontpkg.face.Variation{
            .id = fontpkg.face.Variation.Id.init("wght"),
            .value = 200,
        }, list.list.items[0]);
        try testing.expectEqual(fontpkg.face.Variation{
            .id = fontpkg.face.Variation.Id.init("slnt"),
            .value = -15,
        }, list.list.items[1]);
    }
};

/// Stores a set of keybinds.
pub const Keybinds = struct {
    set: inputpkg.Binding.Set = .{},

    pub fn parseCLI(self: *Keybinds, alloc: Allocator, input: ?[]const u8) !void {
        var copy: ?[]u8 = null;
        var value = value: {
            const value = input orelse return error.ValueRequired;

            // If we don't have a colon, use the value as-is, no copy
            if (std.mem.indexOf(u8, value, ":") == null)
                break :value value;

            // If we have a colon, we copy the whole value for now. We could
            // do this more efficiently later if we wanted to.
            const buf = try alloc.alloc(u8, value.len);
            copy = buf;

            std.mem.copy(u8, buf, value);
            break :value buf;
        };
        errdefer if (copy) |v| alloc.free(v);

        const binding = try inputpkg.Binding.parse(value);
        switch (binding.action) {
            .unbind => self.set.remove(binding.trigger),
            else => if (binding.consumed) {
                try self.set.put(alloc, binding.trigger, binding.action);
            } else {
                try self.set.putUnconsumed(alloc, binding.trigger, binding.action);
            },
        }
    }

    /// Deep copy of the struct. Required by Config.
    pub fn clone(self: *const Keybinds, alloc: Allocator) !Keybinds {
        return .{
            .set = .{
                .bindings = try self.set.bindings.clone(alloc),
                .reverse = try self.set.reverse.clone(alloc),
                .unconsumed = try self.set.unconsumed.clone(alloc),
            },
        };
    }

    /// Compare if two of our value are requal. Required by Config.
    pub fn equal(self: Keybinds, other: Keybinds) bool {
        const self_map = self.set.bindings;
        const other_map = other.set.bindings;
        if (self_map.count() != other_map.count()) return false;

        var it = self_map.iterator();
        while (it.next()) |self_entry| {
            const other_entry = other_map.getEntry(self_entry.key_ptr.*) orelse
                return false;
            if (!equalField(
                inputpkg.Binding.Action,
                self_entry.value_ptr.*,
                other_entry.value_ptr.*,
            )) return false;
        }

        return true;
    }

    test "parseCLI" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var set: Keybinds = .{};
        try set.parseCLI(alloc, "shift+a=copy_to_clipboard");
        try set.parseCLI(alloc, "shift+a=csi:hello");
    }
};

/// See "font-codepoint-map" for documentation.
pub const RepeatableCodepointMap = struct {
    const Self = @This();

    map: fontpkg.CodepointMap = .{},

    pub fn parseCLI(self: *Self, alloc: Allocator, input_: ?[]const u8) !void {
        const input = input_ orelse return error.ValueRequired;
        const eql_idx = std.mem.indexOf(u8, input, "=") orelse return error.InvalidValue;
        const whitespace = " \t";
        const key = std.mem.trim(u8, input[0..eql_idx], whitespace);
        const value = std.mem.trim(u8, input[eql_idx + 1 ..], whitespace);
        const valueZ = try alloc.dupeZ(u8, value);

        var p: UnicodeRangeParser = .{ .input = key };
        while (try p.next()) |range| {
            try self.map.add(alloc, .{
                .range = range,
                .descriptor = .{
                    .family = valueZ,
                    .monospace = false, // we allow any font
                },
            });
        }
    }

    /// Deep copy of the struct. Required by Config.
    pub fn clone(self: *const Self, alloc: Allocator) !Self {
        return .{
            .map = .{ .list = try self.map.list.clone(alloc) },
        };
    }

    /// Compare if two of our value are requal. Required by Config.
    pub fn equal(self: Self, other: Self) bool {
        const itemsA = self.map.list.slice();
        const itemsB = other.map.list.slice();
        if (itemsA.len != itemsB.len) return false;
        for (0..itemsA.len) |i| {
            const a = itemsA.get(i);
            const b = itemsB.get(i);
            if (!std.meta.eql(a, b)) return false;
        } else return true;
    }

    /// Parses the list of Unicode codepoint ranges. Valid syntax:
    ///
    ///   "" (empty returns null)
    ///   U+1234
    ///   U+1234-5678
    ///   U+1234,U+5678
    ///   U+1234-5678,U+5678
    ///   U+1234,U+5678-U+9ABC
    ///
    /// etc.
    const UnicodeRangeParser = struct {
        input: []const u8,
        i: usize = 0,

        pub fn next(self: *UnicodeRangeParser) !?[2]u21 {
            // Once we're EOF then we're done without an error.
            if (self.eof()) return null;

            // One codepoint no matter what
            const start = try self.parseCodepoint();
            if (self.eof()) return .{ start, start };

            // We're allowed to have any whitespace here
            self.consumeWhitespace();

            // Otherwise we expect either a range or a comma
            switch (self.input[self.i]) {
                // Comma means we have another codepoint but in a different
                // range so we return our current codepoint.
                ',' => {
                    self.advance();
                    self.consumeWhitespace();
                    if (self.eof()) return error.InvalidValue;
                    return .{ start, start };
                },

                // Hyphen means we have a range.
                '-' => {
                    self.advance();
                    self.consumeWhitespace();
                    if (self.eof()) return error.InvalidValue;
                    const end = try self.parseCodepoint();
                    self.consumeWhitespace();
                    if (!self.eof() and self.input[self.i] != ',') return error.InvalidValue;
                    self.advance();
                    self.consumeWhitespace();
                    if (start > end) return error.InvalidValue;
                    return .{ start, end };
                },

                else => return error.InvalidValue,
            }
        }

        fn consumeWhitespace(self: *UnicodeRangeParser) void {
            while (!self.eof()) {
                switch (self.input[self.i]) {
                    ' ', '\t' => self.advance(),
                    else => return,
                }
            }
        }

        fn parseCodepoint(self: *UnicodeRangeParser) !u21 {
            if (self.input[self.i] != 'U') return error.InvalidValue;
            self.advance();
            if (self.eof()) return error.InvalidValue;
            if (self.input[self.i] != '+') return error.InvalidValue;
            self.advance();
            if (self.eof()) return error.InvalidValue;

            const start_i = self.i;
            while (true) {
                const current = self.input[self.i];
                const is_hex = (current >= '0' and current <= '9') or
                    (current >= 'A' and current <= 'F') or
                    (current >= 'a' and current <= 'f');
                if (!is_hex) break;

                // Advance but break on EOF
                self.advance();
                if (self.eof()) break;
            }

            // If we didn't consume a single character, we have an error.
            if (start_i == self.i) return error.InvalidValue;

            return std.fmt.parseInt(u21, self.input[start_i..self.i], 16) catch
                return error.InvalidValue;
        }

        fn advance(self: *UnicodeRangeParser) void {
            self.i += 1;
        }

        fn eof(self: *const UnicodeRangeParser) bool {
            return self.i >= self.input.len;
        }
    };

    test "parseCLI" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var list: Self = .{};
        try list.parseCLI(alloc, "U+ABCD=Comic Sans");
        try list.parseCLI(alloc, "U+0001 - U+0005=Verdana");
        try list.parseCLI(alloc, "U+0006-U+0009, U+ABCD=Courier");

        try testing.expectEqual(@as(usize, 4), list.map.list.len);
        {
            const entry = list.map.list.get(0);
            try testing.expectEqual([2]u21{ 0xABCD, 0xABCD }, entry.range);
            try testing.expectEqualStrings("Comic Sans", entry.descriptor.family.?);
        }
        {
            const entry = list.map.list.get(1);
            try testing.expectEqual([2]u21{ 1, 5 }, entry.range);
            try testing.expectEqualStrings("Verdana", entry.descriptor.family.?);
        }
        {
            const entry = list.map.list.get(2);
            try testing.expectEqual([2]u21{ 6, 9 }, entry.range);
            try testing.expectEqualStrings("Courier", entry.descriptor.family.?);
        }
        {
            const entry = list.map.list.get(3);
            try testing.expectEqual([2]u21{ 0xABCD, 0xABCD }, entry.range);
            try testing.expectEqualStrings("Courier", entry.descriptor.family.?);
        }
    }
};

pub const FontStyle = union(enum) {
    const Self = @This();

    /// Use the default font style that font discovery finds.
    default: void,

    /// Disable this font style completely. This will fall back to using
    /// the regular font when this style is encountered.
    false: void,

    /// A specific named font style to use for this style.
    name: [:0]const u8,

    pub fn parseCLI(self: *Self, alloc: Allocator, input: ?[]const u8) !void {
        const value = input orelse return error.ValueRequired;

        if (std.mem.eql(u8, value, "default")) {
            self.* = .{ .default = {} };
            return;
        }

        if (std.mem.eql(u8, value, "false")) {
            self.* = .{ .false = {} };
            return;
        }

        const nameZ = try alloc.dupeZ(u8, value);
        self.* = .{ .name = nameZ };
    }

    /// Returns the string name value that can be used with a font
    /// descriptor.
    pub fn nameValue(self: Self) ?[:0]const u8 {
        return switch (self) {
            .default, .false => null,
            .name => self.name,
        };
    }

    test "parseCLI" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var p: Self = .{ .default = {} };
        try p.parseCLI(alloc, "default");
        try testing.expectEqual(Self{ .default = {} }, p);

        try p.parseCLI(alloc, "false");
        try testing.expectEqual(Self{ .false = {} }, p);

        try p.parseCLI(alloc, "bold");
        try testing.expectEqualStrings("bold", p.name);
    }
};

/// Options for copy on select behavior.
pub const CopyOnSelect = enum {
    /// Disables copy on select entirely.
    false,

    /// Copy on select is enabled, but goes to the selection clipboard.
    /// This is not supported on platforms such as macOS. This is the default.
    true,

    /// Copy on select is enabled and goes to the system clipboard.
    clipboard,
};

/// Shell integration values
pub const ShellIntegration = enum {
    none,
    detect,
    fish,
    zsh,
};

/// OSC 10 and 11 default color reporting format.
pub const OSCColorReportFormat = enum {
    none,
    @"8-bit",
    @"16-bit",
};

/// The default window theme.
pub const WindowTheme = enum {
    system,
    light,
    dark,
};

/// See gtk-single-instance
pub const GtkSingleInstance = enum {
    desktop,
    false,
    true,
};

/// See mouse-shift-capture
pub const MouseShiftCapture = enum {
    false,
    true,
    always,
    never,
};
