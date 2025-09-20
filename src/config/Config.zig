/// Config is the main config struct. These fields map directly to the
/// CLI flag names hence we use a lot of `@""` syntax to support hyphens.

// Pandoc is used to automatically generate manual pages and other forms of
// documentation, so documentation comments on fields in the Config struct
// should use Pandoc's flavor of Markdown.
//
// For a reference to Pandoc's Markdown see their [online
// manual.](https://pandoc.org/MANUAL.html#pandocs-markdown)

const Config = @This();

const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const global_state = &@import("../global.zig").state;
const fontpkg = @import("../font/main.zig");
const inputpkg = @import("../input.zig");
const terminal = @import("../terminal/main.zig");
const internal_os = @import("../os/main.zig");
const cli = @import("../cli.zig");

const conditional = @import("conditional.zig");
const Conditional = conditional.Conditional;
const formatterpkg = @import("formatter.zig");
const themepkg = @import("theme.zig");
const url = @import("url.zig");
const Key = @import("key.zig").Key;
const KeyValue = @import("key.zig").Value;
const ErrorList = @import("ErrorList.zig");
const MetricModifier = fontpkg.Metrics.Modifier;
const help_strings = @import("help_strings");
pub const Command = @import("command.zig").Command;
const RepeatableReadableIO = @import("io.zig").RepeatableReadableIO;
const RepeatableStringMap = @import("RepeatableStringMap.zig");
pub const Path = @import("path.zig").Path;
pub const RepeatablePath = @import("path.zig").RepeatablePath;

const log = std.log.scoped(.config);

/// Used on Unixes for some defaults.
const c = @cImport({
    @cInclude("unistd.h");
});

pub const compatibility = std.StaticStringMap(
    cli.CompatibilityHandler(Config),
).initComptime(&.{
    // Ghostty 1.1 introduced background-blur support for Linux which
    // doesn't support a specific radius value. The renaming is to let
    // one field be used for both platforms (macOS retained the ability
    // to set a radius).
    .{ "background-blur-radius", cli.compatibilityRenamed(Config, "background-blur") },

    // Ghostty 1.2 renamed all our adw options to gtk because we now have
    // a hard dependency on libadwaita.
    .{ "adw-toolbar-style", cli.compatibilityRenamed(Config, "gtk-toolbar-style") },

    // Ghostty 1.2 removed the `hidden` value from `gtk-tabs-location` and
    // moved it to `window-show-tab-bar`.
    .{ "gtk-tabs-location", compatGtkTabsLocation },

    // Ghostty 1.2 lets you set `cell-foreground` and `cell-background`
    // to match the cell foreground and background colors, respectively.
    // This can be used with `cursor-color` and `cursor-text` to recreate
    // this behavior. This applies to selection too.
    .{ "cursor-invert-fg-bg", compatCursorInvertFgBg },
    .{ "selection-invert-fg-bg", compatSelectionInvertFgBg },

    // Ghostty 1.2 merged `bold-is-bright` into the new `bold-color`
    // by setting the value to "bright".
    .{ "bold-is-bright", compatBoldIsBright },

    // Ghostty 1.2 removed the "desktop" option and renamed it to "detect".
    // The semantics also changed slightly but this is the correct mapping.
    .{ "gtk-single-instance", compatGtkSingleInstance },
});

/// The font families to use.
///
/// You can generate the list of valid values using the CLI:
///
///     ghostty +list-fonts
///
/// This configuration can be repeated multiple times to specify preferred
/// fallback fonts when the requested codepoint is not available in the primary
/// font. This is particularly useful for multiple languages, symbolic fonts,
/// etc.
///
/// Notes on emoji specifically: On macOS, Ghostty by default will always use
/// Apple Color Emoji and on Linux will always use Noto Emoji. You can
/// override this behavior by specifying a font family here that contains
/// emoji glyphs.
///
/// The specific styles (bold, italic, bold italic) do not need to be
/// explicitly set. If a style is not set, then the regular style (font-family)
/// will be searched for stylistic variants. If a stylistic variant is not
/// found, Ghostty will use the regular style. This prevents falling back to a
/// different font family just to get a style such as bold. This also applies
/// if you explicitly specify a font family for a style. For example, if you
/// set `font-family-bold = FooBar` and "FooBar" cannot be found, Ghostty will
/// use whatever font is set for `font-family` for the bold style.
///
/// Finally, some styles may be synthesized if they are not supported.
/// For example, if a font does not have an italic style and no alternative
/// italic font is specified, Ghostty will synthesize an italic style by
/// applying a slant to the regular style. If you want to disable these
/// synthesized styles then you can use the `font-style` configurations
/// as documented below.
///
/// You can disable styles completely by using the `font-style` set of
/// configurations. See the documentation for `font-style` for more information.
///
/// If you want to overwrite a previous set value rather than append a fallback,
/// specify the value as `""` (empty string) to reset the list and then set the
/// new values. For example:
///
///     font-family = ""
///     font-family = "My Favorite Font"
///
/// Setting any of these as CLI arguments will automatically clear the
/// values set in configuration files so you don't need to specify
/// `--font-family=""` before setting a new value. You only need to specify
/// this within config files if you want to clear previously set values in
/// configuration files or on the CLI if you want to clear values set on the
/// CLI.
@"font-family": RepeatableString = .{},
@"font-family-bold": RepeatableString = .{},
@"font-family-italic": RepeatableString = .{},
@"font-family-bold-italic": RepeatableString = .{},

/// The named font style to use for each of the requested terminal font styles.
/// This looks up the style based on the font style string advertised by the
/// font itself. For example, "Iosevka Heavy" has a style of "Heavy".
///
/// You can also use these fields to completely disable a font style. If you set
/// the value of the configuration below to literal `false` then that font style
/// will be disabled. If the running program in the terminal requests a disabled
/// font style, the regular font style will be used instead.
///
/// These are only valid if its corresponding font-family is also specified. If
/// no font-family is specified, then the font-style is ignored unless you're
/// disabling the font style.
@"font-style": FontStyle = .{ .default = {} },
@"font-style-bold": FontStyle = .{ .default = {} },
@"font-style-italic": FontStyle = .{ .default = {} },
@"font-style-bold-italic": FontStyle = .{ .default = {} },

/// Control whether Ghostty should synthesize a style if the requested style is
/// not available in the specified font-family.
///
/// Ghostty can synthesize bold, italic, and bold italic styles if the font
/// does not have a specific style. For bold, this is done by drawing an
/// outline around the glyph of varying thickness. For italic, this is done by
/// applying a slant to the glyph. For bold italic, both of these are applied.
///
/// Synthetic styles are not perfect and will generally not look as good
/// as a font that has the style natively. However, they are useful to
/// provide styled text when the font does not have the style.
///
/// Set this to "false" or "true" to disable or enable synthetic styles
/// completely. You can disable specific styles using "no-bold", "no-italic",
/// and "no-bold-italic". You can disable multiple styles by separating them
/// with a comma. For example, "no-bold,no-italic".
///
/// Available style keys are: `bold`, `italic`, `bold-italic`.
///
/// If synthetic styles are disabled, then the regular style will be used
/// instead if the requested style is not available. If the font has the
/// requested style, then the font will be used as-is since the style is
/// not synthetic.
///
/// Warning: An easy mistake is to disable `bold` or `italic` but not
/// `bold-italic`. Disabling only `bold` or `italic` will NOT disable either
/// in the `bold-italic` style. If you want to disable `bold-italic`, you must
/// explicitly disable it. You cannot partially disable `bold-italic`.
///
/// By default, synthetic styles are enabled.
@"font-synthetic-style": FontSyntheticStyle = .{},

/// Apply a font feature. To enable multiple font features you can repeat
/// this multiple times or use a comma-separated list of feature settings.
///
/// The syntax for feature settings is as follows, where `feat` is a feature:
///
///   * Enable features with e.g. `feat`, `+feat`, `feat on`, `feat=1`.
///   * Disabled features with e.g. `-feat`, `feat off`, `feat=0`.
///   * Set a feature value with e.g. `feat=2`, `feat = 3`, `feat 4`.
///   * Feature names may be wrapped in quotes, meaning this config should be
///     syntactically compatible with the `font-feature-settings` CSS property.
///
/// The syntax is fairly loose, but invalid settings will be silently ignored.
///
/// The font feature will apply to all fonts rendered by Ghostty. A future
/// enhancement will allow targeting specific faces.
///
/// To disable programming ligatures, use `-calt` since this is the typical
/// feature name for programming ligatures. To look into what font features
/// your font has and what they do, use a font inspection tool such as
/// [fontdrop.info](https://fontdrop.info).
///
/// To generally disable most ligatures, use `-calt, -liga, -dlig`.
@"font-feature": RepeatableString = .{},

/// Font size in points. This value can be a non-integer and the nearest integer
/// pixel size will be selected. If you have a high dpi display where 1pt = 2px
/// then you can get an odd numbered pixel size by specifying a half point.
///
/// For example, 13.5pt @ 2px/pt = 27px
///
/// Changing this configuration at runtime will only affect existing
/// terminals that have NOT manually adjusted their font size in some way
/// (e.g. increased or decreased the font size). Terminals that have manually
/// adjusted their font size will retain their manually adjusted size.
/// Otherwise, the font size of existing terminals will be updated on
/// reload.
///
/// On Linux with GTK, font size is scaled according to both display-wide and
/// text-specific scaling factors, which are often managed by your desktop
/// environment (e.g. the GNOME display scale and large text settings).
@"font-size": f32 = switch (builtin.os.tag) {
    // On macOS we default a little bigger since this tends to look better. This
    // is purely subjective but this is easy to modify.
    .macos => 13,
    else => 12,
},

/// A repeatable configuration to set one or more font variations values for
/// a variable font. A variable font is a single font, usually with a filename
/// ending in `-VF.ttf` or `-VF.otf` that contains one or more configurable axes
/// for things such as weight, slant, etc. Not all fonts support variations;
/// only fonts that explicitly state they are variable fonts will work.
///
/// The format of this is `id=value` where `id` is the axis identifier. An axis
/// identifier is always a 4 character string, such as `wght`. To get the list
/// of supported axes, look at your font documentation or use a font inspection
/// tool.
///
/// Invalid ids and values are usually ignored. For example, if a font only
/// supports weights from 100 to 700, setting `wght=800` will do nothing (it
/// will not be clamped to 700). You must consult your font's documentation to
/// see what values are supported.
///
/// Common axes are: `wght` (weight), `slnt` (slant), `ital` (italic), `opsz`
/// (optical size), `wdth` (width), `GRAD` (gradient), etc.
@"font-variation": RepeatableFontVariation = .{},
@"font-variation-bold": RepeatableFontVariation = .{},
@"font-variation-italic": RepeatableFontVariation = .{},
@"font-variation-bold-italic": RepeatableFontVariation = .{},

/// Force one or a range of Unicode codepoints to map to a specific named font.
/// This is useful if you want to support special symbols or if you want to use
/// specific glyphs that render better for your specific font.
///
/// The syntax is `codepoint=fontname` where `codepoint` is either a single
/// codepoint or a range. Codepoints must be specified as full Unicode
/// hex values, such as `U+ABCD`. Codepoints ranges are specified as
/// `U+ABCD-U+DEFG`. You can specify multiple ranges for the same font separated
/// by commas, such as `U+ABCD-U+DEFG,U+1234-U+5678=fontname`. The font name is
/// the same value as you would use for `font-family`.
///
/// This configuration can be repeated multiple times to specify multiple
/// codepoint mappings.
///
/// Changing this configuration at runtime will only affect new terminals,
/// i.e. new windows, tabs, etc.
@"font-codepoint-map": RepeatableCodepointMap = .{},

/// Draw fonts with a thicker stroke, if supported.
/// This is currently only supported on macOS.
@"font-thicken": bool = false,

/// Strength of thickening when `font-thicken` is enabled.
///
/// Valid values are integers between `0` and `255`. `0` does not correspond to
/// *no* thickening, rather it corresponds to the lightest available thickening.
///
/// Has no effect when `font-thicken` is set to `false`.
///
/// This is currently only supported on macOS.
@"font-thicken-strength": u8 = 255,

/// Locations to break font shaping into multiple runs.
///
/// A "run" is a contiguous segment of text that is shaped together. "Shaping"
/// is the process of converting text (codepoints) into glyphs (renderable
/// characters). This is how ligatures are formed, among other things.
/// For example, if a coding font turns "!=" into a single glyph, then it
/// must see "!" and "=" next to each other in a single run. When a run
/// is broken, the text is shaped separately. To continue our example, if
/// "!" is at the end of one run and "=" is at the start of the next run,
/// then the ligature will not be formed.
///
/// Ghostty breaks runs at certain points to improve readability or usability.
/// For example, Ghostty by default will break runs under the cursor so that
/// text editing can see the individual characters rather than a ligature.
/// This configuration lets you configure this behavior.
///
/// Combine values with a comma to set multiple options. Prefix an
/// option with "no-" to disable it. Enabling and disabling options
/// can be done at the same time.
///
/// Available options:
///
///   * `cursor` - Break runs under the cursor.
///
/// Available since: 1.2.0
@"font-shaping-break": FontShapingBreak = .{},

/// What color space to use when performing alpha blending.
///
/// This affects the appearance of text and of any images with transparency.
/// Additionally, custom shaders will receive colors in the configured space.
///
/// On macOS the default is `native`, on all other platforms the default is
/// `linear-corrected`.
///
/// Valid values:
///
/// * `native` - Perform alpha blending in the native color space for the OS.
///   On macOS this corresponds to Display P3, and on Linux it's sRGB.
///
/// * `linear` - Perform alpha blending in linear space. This will eliminate
///   the darkening artifacts around the edges of text that are very visible
///   when certain color combinations are used (e.g. red / green), but makes
///   dark text look much thinner than normal and light text much thicker.
///   This is also sometimes known as "gamma correction".
///
/// * `linear-corrected` - Same as `linear`, but with a correction step applied
///   for text that makes it look nearly or completely identical to `native`,
///   but without any of the darkening artifacts.
///
/// Available since: 1.1.0
@"alpha-blending": AlphaBlending =
    if (builtin.os.tag == .macos)
        .native
    else
        .@"linear-corrected",

/// All of the configurations behavior adjust various metrics determined by the
/// font. The values can be integers (1, -1, etc.) or a percentage (20%, -15%,
/// etc.). In each case, the values represent the amount to change the original
/// value.
///
/// For example, a value of `1` increases the value by 1; it does not set it to
/// literally 1. A value of `20%` increases the value by 20%. And so on.
///
/// There is little to no validation on these values so the wrong values (e.g.
/// `-100%`) can cause the terminal to be unusable. Use with caution and reason.
///
/// Some values are clamped to minimum or maximum values. This can make it
/// appear that certain values are ignored. For example, many `*-thickness`
/// adjustments cannot go below 1px.
///
/// `adjust-cell-height` has some additional behaviors to describe:
///
///   * The font will be centered vertically in the cell.
///
///   * The cursor will remain the same size as the font, but may be
///     adjusted separately with `adjust-cursor-height`.
///
///   * Powerline glyphs will be adjusted along with the cell height so
///     that things like status lines continue to look aligned.
@"adjust-cell-width": ?MetricModifier = null,
@"adjust-cell-height": ?MetricModifier = null,
/// Distance in pixels or percentage adjustment from the bottom of the cell to the text baseline.
/// Increase to move baseline UP, decrease to move baseline DOWN.
/// See the notes about adjustments in `adjust-cell-width`.
@"adjust-font-baseline": ?MetricModifier = null,
/// Distance in pixels or percentage adjustment from the top of the cell to the top of the underline.
/// Increase to move underline DOWN, decrease to move underline UP.
/// See the notes about adjustments in `adjust-cell-width`.
@"adjust-underline-position": ?MetricModifier = null,
/// Thickness in pixels of the underline.
/// See the notes about adjustments in `adjust-cell-width`.
@"adjust-underline-thickness": ?MetricModifier = null,
/// Distance in pixels or percentage adjustment from the top of the cell to the top of the strikethrough.
/// Increase to move strikethrough DOWN, decrease to move strikethrough UP.
/// See the notes about adjustments in `adjust-cell-width`.
@"adjust-strikethrough-position": ?MetricModifier = null,
/// Thickness in pixels or percentage adjustment of the strikethrough.
/// See the notes about adjustments in `adjust-cell-width`.
@"adjust-strikethrough-thickness": ?MetricModifier = null,
/// Distance in pixels or percentage adjustment from the top of the cell to the top of the overline.
/// Increase to move overline DOWN, decrease to move overline UP.
/// See the notes about adjustments in `adjust-cell-width`.
@"adjust-overline-position": ?MetricModifier = null,
/// Thickness in pixels or percentage adjustment of the overline.
/// See the notes about adjustments in `adjust-cell-width`.
@"adjust-overline-thickness": ?MetricModifier = null,
/// Thickness in pixels or percentage adjustment of the bar cursor and outlined rect cursor.
/// See the notes about adjustments in `adjust-cell-width`.
@"adjust-cursor-thickness": ?MetricModifier = null,
/// Height in pixels or percentage adjustment of the cursor. Currently applies to all cursor types:
/// bar, rect, and outlined rect.
/// See the notes about adjustments in `adjust-cell-width`.
@"adjust-cursor-height": ?MetricModifier = null,
/// Thickness in pixels or percentage adjustment of box drawing characters.
/// See the notes about adjustments in `adjust-cell-width`.
@"adjust-box-thickness": ?MetricModifier = null,
/// Height in pixels or percentage adjustment of maximum height for nerd font icons.
///
/// Increasing this value will allow nerd font icons to be larger, but won't
/// necessarily force them to be. Decreasing this value will make nerd font
/// icons smaller.
///
/// The default value for the icon height is 1.2 times the height of capital
/// letters in your primary font, so something like -16.6% would make icons
/// roughly the same height as capital letters.
///
/// See the notes about adjustments in `adjust-cell-width`.
///
/// Available in: 1.2.0
@"adjust-icon-height": ?MetricModifier = null,

/// The method to use for calculating the cell width of a grapheme cluster.
/// The default value is `unicode` which uses the Unicode standard to determine
/// grapheme width. This results in correct grapheme width but may result in
/// cursor-desync issues with some programs (such as shells) that may use a
/// legacy method such as `wcswidth`.
///
/// Valid values are:
///
/// * `legacy` - Use a legacy method to determine grapheme width, such as
///   wcswidth This maximizes compatibility with legacy programs but may result
///   in incorrect grapheme width for certain graphemes such as skin-tone
///   emoji, non-English characters, etc.
///
///   This is called "legacy" and not something more specific because the
///   behavior is undefined and we want to retain the ability to modify it.
///   For example, we may or may not use libc `wcswidth` now or in the future.
///
/// * `unicode` - Use the Unicode standard to determine grapheme width.
///
/// If a running program explicitly enables terminal mode 2027, then `unicode`
/// width will be forced regardless of this configuration. When mode 2027 is
/// reset, this configuration will be used again.
///
/// This configuration can be changed at runtime but will not affect existing
/// terminals. Only new terminals will use the new configuration.
@"grapheme-width-method": GraphemeWidthMethod = .unicode,

/// FreeType load flags to enable. The format of this is a list of flags to
/// enable separated by commas. If you prefix a flag with `no-` then it is
/// disabled. If you omit a flag, its default value is used, so you must
/// explicitly disable flags you don't want. You can also use `true` or `false`
/// to turn all flags on or off.
///
/// This configuration only applies to Ghostty builds that use FreeType.
/// This is usually the case only for Linux builds. macOS uses CoreText
/// and does not have an equivalent configuration.
///
/// Available flags:
///
///   * `hinting` - Enable or disable hinting. Enabled by default.
///
///   * `force-autohint` - Always use the freetype auto-hinter instead of
///     the font's native hinter. Disabled by default.
///
///   * `monochrome` - Instructs renderer to use 1-bit monochrome rendering.
///     This will disable anti-aliasing, and probably not look very good unless
///     you're using a pixel font. Disabled by default.
///
///   * `autohint` - Enable the freetype auto-hinter. Enabled by default.
///
/// Example: `hinting`, `no-hinting`, `force-autohint`, `no-force-autohint`
@"freetype-load-flags": FreetypeLoadFlags = .{},

/// A theme to use. This can be a built-in theme name, a custom theme
/// name, or an absolute path to a custom theme file. Ghostty also supports
/// specifying a different theme to use for light and dark mode. Each
/// option is documented below.
///
/// If the theme is an absolute pathname, Ghostty will attempt to load that
/// file as a theme. If that file does not exist or is inaccessible, an error
/// will be logged and no other directories will be searched.
///
/// If the theme is not an absolute pathname, two different directories will be
/// searched for a file name that matches the theme. This is case sensitive on
/// systems with case-sensitive filesystems. It is an error for a theme name to
/// include path separators unless it is an absolute pathname.
///
/// The first directory is the `themes` subdirectory of your Ghostty
/// configuration directory. This is `$XDG_CONFIG_HOME/ghostty/themes` or
/// `~/.config/ghostty/themes`.
///
/// The second directory is the `themes` subdirectory of the Ghostty resources
/// directory. Ghostty ships with a multitude of themes that will be installed
/// into this directory. On macOS, this list is in the
/// `Ghostty.app/Contents/Resources/ghostty/themes` directory. On Linux, this
/// list is in the `share/ghostty/themes` directory (wherever you installed the
/// Ghostty "share" directory.
///
/// To see a list of available themes, run `ghostty +list-themes`.
///
/// A theme file is simply another Ghostty configuration file. They share
/// the same syntax and same configuration options. A theme can set any valid
/// configuration option so please do not use a theme file from an untrusted
/// source. The built-in themes are audited to only set safe configuration
/// options.
///
/// Some options cannot be set within theme files. The reason these are not
/// supported should be self-evident. A theme file cannot set `theme` or
/// `config-file`. At the time of writing this, Ghostty will not show any
/// warnings or errors if you set these options in a theme file but they will
/// be silently ignored.
///
/// Any additional colors specified via background, foreground, palette, etc.
/// will override the colors specified in the theme.
///
/// To specify a different theme for light and dark mode, use the following
/// syntax: `light:theme-name,dark:theme-name`. For example:
/// `light:Rose Pine Dawn,dark:Rose Pine`. Whitespace around all values are
/// trimmed and order of light and dark does not matter. Both light and dark
/// must be specified in this form. In this form, the theme used will be
/// based on the current desktop environment theme.
///
/// There are some known bugs with light/dark mode theming. These will
/// be fixed in a future update:
///
///   - macOS: titlebar tabs style is not updated when switching themes.
theme: ?Theme = null,

/// Background color for the window.
/// Specified as either hex (`#RRGGBB` or `RRGGBB`) or a named X11 color.
background: Color = .{ .r = 0x28, .g = 0x2C, .b = 0x34 },

/// Foreground color for the window.
/// Specified as either hex (`#RRGGBB` or `RRGGBB`) or a named X11 color.
foreground: Color = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF },

/// Background image for the terminal.
///
/// This should be a path to a PNG or JPEG file, other image formats are
/// not yet supported.
///
/// The background image is currently per-terminal, not per-window. If
/// you are a heavy split user, the background image will be repeated across
/// splits. A future improvement to Ghostty will address this.
///
/// WARNING: Background images are currently duplicated in VRAM per-terminal.
/// For sufficiently large images, this could lead to a large increase in
/// memory usage (specifically VRAM usage). A future Ghostty improvement
/// will resolve this by sharing image textures across terminals.
///
/// Available since: 1.2.0
@"background-image": ?Path = null,

/// Background image opacity.
///
/// This is relative to the value of `background-opacity`.
///
/// A value of `1.0` (the default) will result in the background image being
/// placed on top of the general background color, and then the combined result
/// will be adjusted to the opacity specified by `background-opacity`.
///
/// A value less than `1.0` will result in the background image being mixed
/// with the general background color before the combined result is adjusted
/// to the configured `background-opacity`.
///
/// A value greater than `1.0` will result in the background image having a
/// higher opacity than the general background color. For instance, if the
/// configured `background-opacity` is `0.5` and `background-image-opacity`
/// is set to `1.5`, then the final opacity of the background image will be
/// `0.5 * 1.5 = 0.75`.
///
/// Available since: 1.2.0
@"background-image-opacity": f32 = 1.0,

/// Background image position.
///
/// Valid values are:
///   * `top-left`
///   * `top-center`
///   * `top-right`
///   * `center-left`
///   * `center`
///   * `center-right`
///   * `bottom-left`
///   * `bottom-center`
///   * `bottom-right`
///
/// The default value is `center`.
///
/// Available since: 1.2.0
@"background-image-position": BackgroundImagePosition = .center,

/// Background image fit.
///
/// Valid values are:
///
///  * `contain`
///
///    Preserving the aspect ratio, scale the background image to the largest
///    size that can still be contained within the terminal, so that the whole
///    image is visible.
///
///  * `cover`
///
///    Preserving the aspect ratio, scale the background image to the smallest
///    size that can completely cover the terminal. This may result in one or
///    more edges of the image being clipped by the edge of the terminal.
///
///  * `stretch`
///
///    Stretch the background image to the full size of the terminal, without
///    preserving the aspect ratio.
///
///  * `none`
///
///    Don't scale the background image.
///
/// The default value is `contain`.
///
/// Available since: 1.2.0
@"background-image-fit": BackgroundImageFit = .contain,

/// Whether to repeat the background image or not.
///
/// If this is set to true, the background image will be repeated if there
/// would otherwise be blank space around it because it doesn't completely
/// fill the terminal area.
///
/// The default value is `false`.
///
/// Available since: 1.2.0
@"background-image-repeat": bool = false,

/// The foreground and background color for selection. If this is not set, then
/// the selection color is just the inverted window background and foreground
/// (note: not to be confused with the cell bg/fg).
/// Specified as either hex (`#RRGGBB` or `RRGGBB`) or a named X11 color.
/// Since version 1.2.0, this can also be set to `cell-foreground` to match
/// the cell foreground color, or `cell-background` to match the cell
/// background color.
@"selection-foreground": ?TerminalColor = null,
@"selection-background": ?TerminalColor = null,

/// Whether to clear selected text when typing. This defaults to `true`.
/// This is typical behavior for most terminal emulators as well as
/// text input fields. If you set this to `false`, then the selected text
/// will not be cleared when typing.
///
/// "Typing" is specifically defined as any non-modifier (shift, control,
/// alt, etc.) keypress that produces data to be sent to the application
/// running within the terminal (e.g. the shell). Additionally, selection
/// is cleared when any preedit or composition state is started (e.g.
/// when typing languages such as Japanese).
///
/// If this is `false`, then the selection can still be manually
/// cleared by clicking once or by pressing `escape`.
///
/// Available since: 1.2.0
@"selection-clear-on-typing": bool = true,

/// Whether to clear selected text after copying. This defaults to `false`.
///
/// When set to `true`, the selection will be automatically cleared after
/// any copy operation that invokes the `copy_to_clipboard` keyboard binding.
/// Importantly, this will not clear the selection if the copy operation
/// was invoked via `copy-on-select`.
///
/// When set to `false`, the selection remains visible after copying, allowing
/// to see what was copied and potentially perform additional operations
/// on the same selection.
@"selection-clear-on-copy": bool = false,

/// The minimum contrast ratio between the foreground and background colors.
/// The contrast ratio is a value between 1 and 21. A value of 1 allows for no
/// contrast (e.g. black on black). This value is the contrast ratio as defined
/// by the [WCAG 2.0 specification](https://www.w3.org/TR/WCAG20/).
///
/// If you want to avoid invisible text (same color as background), a value of
/// 1.1 is a good value. If you want to avoid text that is difficult to read, a
/// value of 3 or higher is a good value. The higher the value, the more likely
/// that text will become black or white.
///
/// This value does not apply to Emoji or images.
@"minimum-contrast": f64 = 1,

/// Color palette for the 256 color form that many terminal applications use.
/// The syntax of this configuration is `N=COLOR` where `N` is 0 to 255 (for
/// the 256 colors in the terminal color table) and `COLOR` is a typical RGB
/// color code such as `#AABBCC` or `AABBCC`, or a named X11 color.
///
/// The palette index can be in decimal, binary, octal, or hexadecimal.
/// Decimal is assumed unless a prefix is used: `0b` for binary, `0o` for octal,
/// and `0x` for hexadecimal.
///
/// For definitions on the color indices and what they canonically map to,
/// [see this cheat sheet](https://www.ditig.com/256-colors-cheat-sheet).
palette: Palette = .{},

/// The color of the cursor. If this is not set, a default will be chosen.
///
/// Direct colors can be specified as either hex (`#RRGGBB` or `RRGGBB`)
/// or a named X11 color.
///
/// Additionally, special values can be used to set the color to match
/// other colors at runtime:
///
///   * `cell-foreground` - Match the cell foreground color.
///     (Available since: 1.2.0)
///
///   * `cell-background` - Match the cell background color.
///     (Available since: 1.2.0)
@"cursor-color": ?TerminalColor = null,

/// The opacity level (opposite of transparency) of the cursor. A value of 1
/// is fully opaque and a value of 0 is fully transparent. A value less than 0
/// or greater than 1 will be clamped to the nearest valid value. Note that a
/// sufficiently small value such as 0.3 may be effectively invisible and may
/// make it difficult to find the cursor.
@"cursor-opacity": f64 = 1.0,

/// The style of the cursor. This sets the default style. A running program can
/// still request an explicit cursor style using escape sequences (such as `CSI
/// q`). Shell configurations will often request specific cursor styles.
///
/// Note that shell integration will automatically set the cursor to a bar at
/// a prompt, regardless of this configuration. You can disable that behavior
/// by specifying `shell-integration-features = no-cursor` or disabling shell
/// integration entirely.
///
/// Valid values are:
///
///   * `block`
///   * `bar`
///   * `underline`
///   * `block_hollow`
@"cursor-style": terminal.CursorStyle = .block,

/// Sets the default blinking state of the cursor. This is just the default
/// state; running programs may override the cursor style using `DECSCUSR` (`CSI
/// q`).
///
/// If this is not set, the cursor blinks by default. Note that this is not the
/// same as a "true" value, as noted below.
///
/// If this is not set at all (`null`), then Ghostty will respect DEC Mode 12
/// (AT&T cursor blink) as an alternate approach to turning blinking on/off. If
/// this is set to any value other than null, DEC mode 12 will be ignored but
/// `DECSCUSR` will still be respected.
///
/// Valid values are:
///
///   * ` ` (blank)
///   * `true`
///   * `false`
@"cursor-style-blink": ?bool = null,

/// The color of the text under the cursor. If this is not set, a default will
/// be chosen.
/// Specified as either hex (`#RRGGBB` or `RRGGBB`) or a named X11 color.
/// Since version 1.2.0, this can also be set to `cell-foreground` to match
/// the cell foreground color, or `cell-background` to match the cell
/// background color.
@"cursor-text": ?TerminalColor = null,

/// Enables the ability to move the cursor at prompts by using `alt+click` on
/// Linux and `option+click` on macOS.
///
/// This feature requires shell integration (specifically prompt marking
/// via `OSC 133`) and only works in primary screen mode. Alternate screen
/// applications like vim usually have their own version of this feature but
/// this configuration doesn't control that.
///
/// It should be noted that this feature works by translating your desired
/// position into a series of synthetic arrow key movements, so some weird
/// behavior around edge cases are to be expected. This is unfortunately how
/// this feature is implemented across terminals because there isn't any other
/// way to implement it.
@"cursor-click-to-move": bool = true,

/// Hide the mouse immediately when typing. The mouse becomes visible again
/// when the mouse is used (button, movement, etc.). Platform-specific behavior
/// may dictate other scenarios where the mouse is shown. For example on macOS,
/// the mouse is shown again when a new window, tab, or split is created.
@"mouse-hide-while-typing": bool = false,

/// When to scroll the surface to the bottom. The format of this is a list of
/// options to enable separated by commas. If you prefix an option with `no-`
/// then it is disabled. If you omit an option, its default value is used.
///
/// Available options:
///
/// - `keystroke` If set, scroll the surface to the bottom when the user
///   presses a key that results in data being sent to the PTY (basically
///   anything but modifiers or keybinds that are processed by Ghostty).
///
/// - `output` If set, scroll the surface to the bottom if there is new data
///   to display. (Currently unimplemented.)
///
/// The default is `keystroke, no-output`.
@"scroll-to-bottom": ScrollToBottom = .default,

/// Determines whether running programs can detect the shift key pressed with a
/// mouse click. Typically, the shift key is used to extend mouse selection.
///
/// The default value of `false` means that the shift key is not sent with
/// the mouse protocol and will extend the selection. This value can be
/// conditionally overridden by the running program with the `XTSHIFTESCAPE`
/// sequence.
///
/// The value `true` means that the shift key is sent with the mouse protocol
/// but the running program can override this behavior with `XTSHIFTESCAPE`.
///
/// The value `never` is the same as `false` but the running program cannot
/// override this behavior with `XTSHIFTESCAPE`. The value `always` is the
/// same as `true` but the running program cannot override this behavior with
/// `XTSHIFTESCAPE`.
///
/// If you always want shift to extend mouse selection even if the program
/// requests otherwise, set this to `never`.
///
/// Valid values are:
///
///   * `true`
///   * `false`
///   * `always`
///   * `never`
@"mouse-shift-capture": MouseShiftCapture = .false,

/// Multiplier for scrolling distance with the mouse wheel. Any value less
/// than 0.01 or greater than 10,000 will be clamped to the nearest valid
/// value.
///
/// A value of "3" (default) scrolls 3 lines per tick.
///
/// Available since: 1.2.0
@"mouse-scroll-multiplier": f64 = 3.0,

/// The opacity level (opposite of transparency) of the background. A value of
/// 1 is fully opaque and a value of 0 is fully transparent. A value less than 0
/// or greater than 1 will be clamped to the nearest valid value.
///
/// On macOS, background opacity is disabled when the terminal enters native
/// fullscreen. This is because the background becomes gray and it can cause
/// widgets to show through which isn't generally desirable.
///
/// On macOS, changing this configuration requires restarting Ghostty completely.
@"background-opacity": f64 = 1.0,

/// Applies background opacity to cells with an explicit background color
/// set.
///
/// Normally, `background-opacity` is only applied to the window background.
/// If a cell has an explicit background color set, such as red, then that
/// background color will be fully opaque. An effect of this is that some
/// terminal applications that repaint the background color of the terminal
/// such as a Neovim and Tmux may not respect the `background-opacity`
/// (by design).
///
/// Setting this to `true` will apply the `background-opacity` to all cells
/// regardless of whether they have an explicit background color set or not.
///
/// Available since: 1.2.0
@"background-opacity-cells": bool = false,

/// Whether to blur the background when `background-opacity` is less than 1.
///
/// Valid values are:
///
///   * a nonnegative integer specifying the *blur intensity*
///   * `false`, equivalent to a blur intensity of 0
///   * `true`, equivalent to the default blur intensity of 20, which is
///     reasonable for a good looking blur. Higher blur intensities may
///     cause strange rendering and performance issues.
///
/// Supported on macOS and on some Linux desktop environments, including:
///
///   * KDE Plasma (Wayland and X11)
///
/// Warning: the exact blur intensity is _ignored_ under KDE Plasma, and setting
/// this setting to either `true` or any positive blur intensity value would
/// achieve the same effect. The reason is that KWin, the window compositor
/// powering Plasma, only has one global blur setting and does not allow
/// applications to specify individual blur settings.
///
/// To configure KWin's global blur setting, open System Settings and go to
/// "Apps & Windows" > "Window Management" > "Desktop Effects" and select the
/// "Blur" plugin. If disabled, enable it by ticking the checkbox to the left.
/// Then click on the "Configure" button and there will be two sliders that
/// allow you to set background blur and noise intensities for all apps,
/// including Ghostty.
///
/// All other Linux desktop environments are as of now unsupported. Users may
/// need to set environment-specific settings and/or install third-party plugins
/// in order to support background blur, as there isn't a unified interface for
/// doing so.
@"background-blur": BackgroundBlur = .false,

/// The opacity level (opposite of transparency) of an unfocused split.
/// Unfocused splits by default are slightly faded out to make it easier to see
/// which split is focused. To disable this feature, set this value to 1.
///
/// A value of 1 is fully opaque and a value of 0 is fully transparent. Because
/// "0" is not useful (it makes the window look very weird), the minimum value
/// is 0.15. This value still looks weird but you can at least see what's going
/// on. A value outside of the range 0.15 to 1 will be clamped to the nearest
/// valid value.
@"unfocused-split-opacity": f64 = 0.7,

/// The color to dim the unfocused split. Unfocused splits are dimmed by
/// rendering a semi-transparent rectangle over the split. This sets the color of
/// that rectangle and can be used to carefully control the dimming effect.
///
/// This will default to the background color.
///
/// Specified as either hex (`#RRGGBB` or `RRGGBB`) or a named X11 color.
@"unfocused-split-fill": ?Color = null,

/// The color of the split divider. If this is not set, a default will be chosen.
/// Specified as either hex (`#RRGGBB` or `RRGGBB`) or a named X11 color.
///
/// Available since: 1.1.0
@"split-divider-color": ?Color = null,

/// The command to run, usually a shell. If this is not an absolute path, it'll
/// be looked up in the `PATH`. If this is not set, a default will be looked up
/// from your system. The rules for the default lookup are:
///
///   * `SHELL` environment variable
///
///   * `passwd` entry (user information)
///
/// This can contain additional arguments to run the command with. If additional
/// arguments are provided, the command will be executed using `/bin/sh -c`
/// to offload shell argument expansion.
///
/// To avoid shell expansion altogether, prefix the command with `direct:`, e.g.
/// `direct:nvim foo`. This will avoid the roundtrip to `/bin/sh` but will also
/// not support any shell parsing such as arguments with spaces, filepaths with
/// `~`, globs, etc. (Available since: 1.2.0)
///
/// You can also explicitly prefix the command with `shell:` to always wrap the
/// command in a shell. This can be used to ensure our heuristics to choose the
/// right mode are not used in case they are wrong. (Available since: 1.2.0)
///
/// This command will be used for all new terminal surfaces, i.e. new windows,
/// tabs, etc. If you want to run a command only for the first terminal surface
/// created when Ghostty starts, use the `initial-command` configuration.
///
/// Ghostty supports the common `-e` flag for executing a command with
/// arguments. For example, `ghostty -e fish --with --custom --args`.
/// This flag sets the `initial-command` configuration, see that for more
/// information.
command: ?Command = null,

/// This is the same as "command", but only applies to the first terminal
/// surface created when Ghostty starts. Subsequent terminal surfaces will use
/// the `command` configuration.
///
/// After the first terminal surface is created (or closed), there is no
/// way to run this initial command again automatically. As such, setting
/// this at runtime works but will only affect the next terminal surface
/// if it is the first one ever created.
///
/// If you're using the `ghostty` CLI there is also a shortcut to set this
/// with arguments directly: you can use the `-e` flag. For example: `ghostty -e
/// fish --with --custom --args`. The `-e` flag automatically forces some
/// other behaviors as well:
///
///   * Disables shell expansion since the input is expected to already
///     be shell-expanded by the upstream (e.g. the shell used to type in
///     the `ghostty -e` command).
///
///   * `gtk-single-instance=false` - This ensures that a new instance is
///     launched and the CLI args are respected.
///
///   * `quit-after-last-window-closed=true` - This ensures that the Ghostty
///     process will exit when the command exits. Additionally, the
///     `quit-after-last-window-closed-delay` is unset.
///
///   * `shell-integration=detect` (if not `none`) - This prevents forcibly
///     injecting any configured shell integration into the command's
///     environment. With `-e` its highly unlikely that you're executing a
///     shell and forced shell integration is likely to cause problems
///     (e.g. by wrapping your command in a shell, setting env vars, etc.).
///     This is a safety measure to prevent unexpected behavior. If you want
///     shell integration with a `-e`-executed command, you must either
///     name your binary appropriately or source the shell integration script
///     manually.
@"initial-command": ?Command = null,

/// Extra environment variables to pass to commands launched in a terminal
/// surface. The format is `env=KEY=VALUE`.
///
/// `env = foo=bar`
/// `env = bar=baz`
///
/// Setting `env` to an empty string will reset the entire map to default
/// (empty).
///
/// `env =`
///
/// Setting a key to an empty string will remove that particular key and
/// corresponding value from the map.
///
/// `env = foo=bar`
/// `env = foo=`
///
/// will result in `foo` not being passed to the launched commands.
///
/// Setting a key multiple times will overwrite previous entries.
///
/// `env = foo=bar`
/// `env = foo=baz`
///
/// will result in `foo=baz` being passed to the launched commands.
///
/// These environment variables will override any existing environment
/// variables set by Ghostty. For example, if you set `GHOSTTY_RESOURCES_DIR`
/// then the value you set here will override the value Ghostty typically
/// automatically injects.
///
/// These environment variables _will not_ be passed to commands run by Ghostty
/// for other purposes, like `open` or `xdg-open` used to open URLs in your
/// browser.
///
/// Available since: 1.2.0
env: RepeatableStringMap = .{},

/// Data to send as input to the command on startup.
///
/// The configured `command` will be launched using the typical rules,
/// then the data specified as this input will be written to the pty
/// before any other input can be provided.
///
/// The bytes are sent as-is with no additional encoding. Therefore, be
/// cautious about input that can contain control characters, because this
/// can be used to execute programs in a shell.
///
/// The format of this value is:
///
///   * `raw:<string>` - Send raw text as-is. This uses Zig string literal
///     syntax so you can specify control characters and other standard
///     escapes.
///
///   * `path:<path>` - Read a filepath and send the contents. The path
///     must be to a file with finite length. e.g. don't use a device
///     such as `/dev/stdin` or `/dev/urandom` as these will block
///     terminal startup indefinitely. Files are limited to 10MB
///     in size to prevent excessive memory usage. If you have files
///     larger than this you should write a script to read the file
///     and send it to the terminal.
///
/// If no valid prefix is found, it is assumed to be a `raw:` input.
/// This is an ergonomic choice to allow you to simply write
/// `input = "Hello, world!"` (a common case) without needing to prefix
/// every value with `raw:`.
///
/// This can be repeated multiple times to send more data. The data
/// is concatenated directly with no separator characters in between
/// (e.g. no newline).
///
/// If any of the input sources do not exist, then none of the input
/// will be sent. Input sources are not verified until the terminal
/// is starting, so missing paths will not show up in config validation.
///
/// Changing this configuration at runtime will only affect new
/// terminals.
///
/// Available since: 1.2.0
input: RepeatableReadableIO = .{},

/// If true, keep the terminal open after the command exits. Normally, the
/// terminal window closes when the running command (such as a shell) exits.
/// With this true, the terminal window will stay open until any keypress is
/// received.
///
/// This is primarily useful for scripts or debugging.
@"wait-after-command": bool = false,

/// The number of milliseconds of runtime below which we consider a process exit
/// to be abnormal. This is used to show an error message when the process exits
/// too quickly.
///
/// On Linux, this must be paired with a non-zero exit code. On macOS, we allow
/// any exit code because of the way shell processes are launched via the login
/// command.
@"abnormal-command-exit-runtime": u32 = 250,

/// The size of the scrollback buffer in bytes. This also includes the active
/// screen. No matter what this is set to, enough memory will always be
/// allocated for the visible screen and anything leftover is the limit for
/// the scrollback.
///
/// When this limit is reached, the oldest lines are removed from the
/// scrollback.
///
/// Scrollback currently exists completely in memory. This means that the
/// larger this value, the larger potential memory usage. Scrollback is
/// allocated lazily up to this limit, so if you set this to a very large
/// value, it will not immediately consume a lot of memory.
///
/// This size is per terminal surface, not for the entire application.
///
/// It is not currently possible to set an unlimited scrollback buffer.
/// This is a future planned feature.
///
/// This can be changed at runtime but will only affect new terminal surfaces.
@"scrollback-limit": usize = 10_000_000, // 10MB

/// Match a regular expression against the terminal text and associate clicking
/// it with an action. This can be used to match URLs, file paths, etc. Actions
/// can be opening using the system opener (e.g. `open` or `xdg-open`) or
/// executing any arbitrary binding action.
///
/// Links that are configured earlier take precedence over links that are
/// configured later.
///
/// A default link that matches a URL and opens it in the system opener always
/// exists. This can be disabled using `link-url`.
///
/// TODO: This can't currently be set!
link: RepeatableLink = .{},

/// Enable URL matching. URLs are matched on hover with control (Linux) or
/// command (macOS) pressed and open using the default system application for
/// the linked URL.
///
/// The URL matcher is always lowest priority of any configured links (see
/// `link`). If you want to customize URL matching, use `link` and disable this.
@"link-url": bool = true,

/// Show link previews for a matched URL.
///
/// When true, link previews are shown for all matched URLs. When false, link
/// previews are never shown. When set to "osc8", link previews are only shown
/// for hyperlinks created with the OSC 8 sequence (in this case, the link text
/// can differ from the link destination).
///
/// Available since: 1.2.0
@"link-previews": LinkPreviews = .true,

/// Whether to start the window in a maximized state. This setting applies
/// to new windows and does not apply to tabs, splits, etc. However, this setting
/// will apply to all new windows, not just the first one.
///
/// Available since: 1.1.0
maximize: bool = false,

/// Start new windows in fullscreen. This setting applies to new windows and
/// does not apply to tabs, splits, etc. However, this setting will apply to all
/// new windows, not just the first one.
///
/// On macOS, this setting does not work if window-decoration is set to
/// "false", because native fullscreen on macOS requires window decorations
/// to be set.
fullscreen: bool = false,

/// The title Ghostty will use for the window. This will force the title of the
/// window to be this title at all times and Ghostty will ignore any set title
/// escape sequences programs (such as Neovim) may send.
///
/// If you want a blank title, set this to one or more spaces by quoting
/// the value. For example, `title = " "`. This effectively hides the title.
/// This is necessary because setting a blank value resets the title to the
/// default value of the running program.
///
/// This configuration can be reloaded at runtime. If it is set, the title
/// will update for all windows. If it is unset, the next title change escape
/// sequence will be honored but previous changes will not retroactively
/// be set. This latter case may require you to restart programs such as Neovim
/// to get the new title.
title: ?[:0]const u8 = null,

/// The setting that will change the application class value.
///
/// This controls the class field of the `WM_CLASS` X11 property (when running
/// under X11), the Wayland application ID (when running under Wayland), and the
/// bus name that Ghostty uses to connect to DBus.
///
/// Note that changing this value between invocations will create new, separate
/// instances, of Ghostty when running with `gtk-single-instance=true`. See that
/// option for more details.
///
/// Changing this value may break launching Ghostty from `.desktop` files, via
/// DBus activation, or systemd user services as the system is expecting Ghostty
/// to connect to DBus using the default `class` when it is launched.
///
/// The class name must follow the requirements defined [in the GTK
/// documentation](https://docs.gtk.org/gio/type_func.Application.id_is_valid.html).
///
/// The default is `com.mitchellh.ghostty`.
///
/// This only affects GTK builds.
class: ?[:0]const u8 = null,

/// This controls the instance name field of the `WM_CLASS` X11 property when
/// running under X11. It has no effect otherwise.
///
/// The default is `ghostty`.
///
/// This only affects GTK builds.
@"x11-instance-name": ?[:0]const u8 = null,

/// The directory to change to after starting the command.
///
/// This setting is secondary to the `window-inherit-working-directory`
/// setting. If a previous Ghostty terminal exists in the same process,
/// `window-inherit-working-directory` will take precedence. Otherwise, this
/// setting will be used. Typically, this setting is used only for the first
/// window.
///
/// The default is `inherit` except in special scenarios listed next. On macOS,
/// if Ghostty can detect it is launched from launchd (double-clicked) or
/// `open`, then it defaults to `home`. On Linux with GTK, if Ghostty can detect
/// it was launched from a desktop launcher, then it defaults to `home`.
///
/// The value of this must be an absolute value or one of the special values
/// below:
///
///   * `home` - The home directory of the executing user.
///
///   * `inherit` - The working directory of the launching process.
@"working-directory": ?[]const u8 = null,

/// Key bindings. The format is `trigger=action`. Duplicate triggers will
/// overwrite previously set values. The list of actions is available in
/// the documentation or using the `ghostty +list-actions` command.
///
/// Trigger: `+`-separated list of keys and modifiers. Example: `ctrl+a`,
/// `ctrl+shift+b`, `up`.
///
/// If the key is a single Unicode codepoint, the trigger will match
/// any presses that produce that codepoint. These are impacted by
/// keyboard layouts. For example, `a` will match the `a` key on a
/// QWERTY keyboard, but will match the `q` key on a AZERTY keyboard
/// (assuming US physical layout).
///
/// For Unicode codepoints, matching is done by comparing the set of
/// modifiers with the unmodified codepoint. The unmodified codepoint is
/// sometimes called an "unshifted character" in other software, but all
/// modifiers are considered, not only shift. For example, `ctrl+a` will match
/// `a` but not `ctrl+shift+a` (which is `A` on a US keyboard).
///
/// Further, codepoint matching is case-insensitive and the unmodified
/// codepoint is always case folded for comparison. As a result,
/// `ctrl+A` configured will match when `ctrl+a` is pressed. Note that
/// this means some key combinations are impossible depending on keyboard
/// layout. For example, `ctrl+_` is impossible on a US keyboard because
/// `_` is `shift+-` and `ctrl+shift+-` is not equal to `ctrl+_` (because
/// the modifiers don't match!). More details on impossible key combinations
/// can be found at this excellent source written by Qt developers:
/// https://doc.qt.io/qt-6/qkeysequence.html#keyboard-layout-issues
///
/// Physical key codes can be specified by using any of the key codes
/// as specified by the [W3C specification](https://www.w3.org/TR/uievents-code/).
/// For example, `KeyA` will match the physical `a` key on a US standard
/// keyboard regardless of the keyboard layout. These are case-sensitive.
///
/// For aesthetic reasons, the w3c codes also support snake case. For
/// example, `key_a` is equivalent to `KeyA`. The only exceptions are
/// function keys, e.g. `F1` is `f1` (no underscore). This is a consequence
/// of our internal code using snake case but is purposely supported
/// and tested so it is safe to use. It allows an all-lowercase binding
/// which I find more aesthetically pleasing.
///
/// Function keys such as `insert`, `up`, `f5`, etc. are also specified
/// using the keys as specified by the previously linked W3C specification.
///
/// Physical keys always match with a higher priority than Unicode codepoints,
/// so if you specify both `a` and `KeyA`, the physical key will always be used
/// regardless of what order they are configured.
///
/// Valid modifiers are `shift`, `ctrl` (alias: `control`), `alt` (alias: `opt`,
/// `option`), and `super` (alias: `cmd`, `command`). You may use the modifier
/// or the alias. When debugging keybinds, the non-aliased modifier will always
/// be used in output.
///
/// Note: The fn or "globe" key on keyboards are not supported as a
/// modifier. This is a limitation of the operating systems and GUI toolkits
/// that Ghostty uses.
///
/// Some additional notes for triggers:
///
///   * modifiers cannot repeat, `ctrl+ctrl+a` is invalid.
///
///   * modifiers and keys can be in any order, `shift+a+ctrl` is *weird*,
///     but valid.
///
///   * only a single key input is allowed, `ctrl+a+b` is invalid.
///
/// You may also specify multiple triggers separated by `>` to require a
/// sequence of triggers to activate the action. For example,
/// `ctrl+a>n=new_window` will only trigger the `new_window` action if the
/// user presses `ctrl+a` followed separately by `n`. In other software, this
/// is sometimes called a leader key, a key chord, a key table, etc. There
/// is no hardcoded limit on the number of parts in a sequence.
///
/// Warning: If you define a sequence as a CLI argument to `ghostty`,
/// you probably have to quote the keybind since `>` is a special character
/// in most shells. Example: ghostty --keybind='ctrl+a>n=new_window'
///
/// A trigger sequence has some special handling:
///
///   * Ghostty will wait an indefinite amount of time for the next key in
///     the sequence. There is no way to specify a timeout. The only way to
///     force the output of a prefix key is to assign another keybind to
///     specifically output that key (e.g. `ctrl+a>ctrl+a=text:foo`) or
///     press an unbound key which will send both keys to the program.
///
///   * If a prefix in a sequence is previously bound, the sequence will
///     override the previous binding. For example, if `ctrl+a` is bound to
///     `new_window` and `ctrl+a>n` is bound to `new_tab`, pressing `ctrl+a`
///     will do nothing.
///
///   * Adding to the above, if a previously bound sequence prefix is
///     used in a new, non-sequence binding, the entire previously bound
///     sequence will be unbound. For example, if you bind `ctrl+a>n` and
///     `ctrl+a>t`, and then bind `ctrl+a` directly, both `ctrl+a>n` and
///     `ctrl+a>t` will become unbound.
///
///   * Trigger sequences are not allowed for `global:` or `all:`-prefixed
///     triggers. This is a limitation we could remove in the future.
///
/// Action is the action to take when the trigger is satisfied. It takes the
/// format `action` or `action:param`. The latter form is only valid if the
/// action requires a parameter.
///
///   * `ignore` - Do nothing, ignore the key input. This can be used to
///     black hole certain inputs to have no effect.
///
///   * `unbind` - Remove the binding. This makes it so the previous action
///     is removed, and the key will be sent through to the child command
///     if it is printable. Unbind will remove any matching trigger,
///     including `physical:`-prefixed triggers without specifying the
///     prefix.
///
///   * `csi:text` - Send a CSI sequence. e.g. `csi:A` sends "cursor up".
///
///   * `esc:text` - Send an escape sequence. e.g. `esc:d` deletes to the
///     end of the word to the right.
///
///   * `text:text` - Send a string. Uses Zig string literal syntax.
///     e.g. `text:\x15` sends Ctrl-U.
///
///   * All other actions can be found in the documentation or by using the
///     `ghostty +list-actions` command.
///
/// Some notes for the action:
///
///   * The parameter is taken as-is after the `:`. Double quotes or
///     other mechanisms are included and NOT parsed. If you want to
///     send a string value that includes spaces, wrap the entire
///     trigger/action in double quotes. Example: `--keybind="up=csi:A B"`
///
/// There are some additional special values that can be specified for
/// keybind:
///
///   * `keybind=clear` will clear all set keybindings. Warning: this
///     removes ALL keybindings up to this point, including the default
///     keybindings.
///
/// The keybind trigger can be prefixed with some special values to change
/// the behavior of the keybind. These are:
///
///  * `all:`
///
///    Make the keybind apply to all terminal surfaces. By default,
///    keybinds only apply to the focused terminal surface. If this is true,
///    then the keybind will be sent to all terminal surfaces. This only
///    applies to actions that are surface-specific. For actions that
///    are already global (e.g. `quit`), this prefix has no effect.
///
///    Available since: 1.0.0
///
///  * `global:`
///
///    Make the keybind global. By default, keybinds only work within Ghostty
///    and under the right conditions (application focused, sometimes terminal
///    focused, etc.). If you want a keybind to work globally across your system
///    (e.g. even when Ghostty is not focused), specify this prefix.
///    This prefix implies `all:`.
///
///    Note: this does not work in all environments; see the additional notes
///    below for more information.
///
///    Available since: 1.0.0 on macOS, 1.2.0 on GTK
///
///  * `unconsumed:`
///
///    Do not consume the input. By default, a keybind will consume the input,
///    meaning that the associated encoding (if any) will not be sent to the
///    running program in the terminal. If you wish to send the encoded value
///    to the program, specify the `unconsumed:` prefix before the entire
///    keybind. For example: `unconsumed:ctrl+a=reload_config`. `global:` and
///    `all:`-prefixed keybinds will always consume the input regardless of
///    this setting. Since they are not associated with a specific terminal
///    surface, they're never encoded.
///
///    Available since: 1.0.0
///
///  * `performable:`
///
///    Only consume the input if the action is able to be performed.
///    For example, the `copy_to_clipboard` action will only consume the input
///    if there is a selection to copy. If there is no selection, Ghostty
///    behaves as if the keybind was not set. This has no effect with `global:`
///    or `all:`-prefixed keybinds. For key sequences, this will reset the
///    sequence if the action is not performable (acting identically to not
///    having a keybind set at all).
///
///    Performable keybinds will not appear as menu shortcuts in the
///    application menu. This is because the menu shortcuts force the
///    action to be performed regardless of the state of the terminal.
///    Performable keybinds will still work, they just won't appear as
///    a shortcut label in the menu.
///
///    Available since: 1.1.0
///
/// Keybind triggers are not unique per prefix combination. For example,
/// `ctrl+a` and `global:ctrl+a` are not two separate keybinds. The keybind
/// set later will overwrite the keybind set earlier. In this case, the
/// `global:` keybind will be used.
///
/// Multiple prefixes can be specified. For example,
/// `global:unconsumed:ctrl+a=reload_config` will make the keybind global
/// and not consume the input to reload the config.
///
/// Note: `global:` is only supported on macOS and certain Linux platforms.
///
/// On macOS, this feature requires accessibility permissions to be granted
/// to Ghostty. When a `global:` keybind is specified and Ghostty is launched
/// or reloaded, Ghostty will attempt to request these permissions.
/// If the permissions are not granted, the keybind will not work. On macOS,
/// you can find these permissions in System Preferences -> Privacy & Security
/// -> Accessibility.
///
/// On Linux, you need a desktop environment that implements the
/// [Global Shortcuts](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html)
/// protocol as a part of its XDG desktop protocol implementation.
/// Desktop environments that are known to support (or not support)
/// global shortcuts include:
///
///  - Users using KDE Plasma (since [5.27](https://kde.org/announcements/plasma/5/5.27.0/#wayland))
///    and GNOME (since [48](https://release.gnome.org/48/#and-thats-not-all)) should be able
///    to use global shortcuts with little to no configuration.
///
///  - Some manual configuration is required on Hyprland. Consult the steps
///    outlined on the [Hyprland Wiki](https://wiki.hyprland.org/Configuring/Binds/#dbus-global-shortcuts)
///    to set up global shortcuts correctly.
///    (Important: [`xdg-desktop-portal-hyprland`](https://wiki.hyprland.org/Hypr-Ecosystem/xdg-desktop-portal-hyprland/)
///    must also be installed!)
///
///  - Notably, global shortcuts have not been implemented on wlroots-based
///    compositors like Sway (see [upstream issue](https://github.com/emersion/xdg-desktop-portal-wlr/issues/240)).
keybind: Keybinds = .{},

/// Horizontal window padding. This applies padding between the terminal cells
/// and the left and right window borders. The value is in points, meaning that
/// it will be scaled appropriately for screen DPI.
///
/// If this value is set too large, the screen will render nothing, because the
/// grid will be completely squished by the padding. It is up to you as the user
/// to pick a reasonable value. If you pick an unreasonable value, a warning
/// will appear in the logs.
///
/// Changing this configuration at runtime will only affect new terminals, i.e.
/// new windows, tabs, etc.
///
/// To set a different left and right padding, specify two numerical values
/// separated by a comma. For example, `window-padding-x = 2,4` will set the
/// left padding to 2 and the right padding to 4. If you want to set both
/// paddings to the same value, you can use a single value. For example,
/// `window-padding-x = 2` will set both paddings to 2.
@"window-padding-x": WindowPadding = .{ .top_left = 2, .bottom_right = 2 },

/// Vertical window padding. This applies padding between the terminal cells and
/// the top and bottom window borders. The value is in points, meaning that it
/// will be scaled appropriately for screen DPI.
///
/// If this value is set too large, the screen will render nothing, because the
/// grid will be completely squished by the padding. It is up to you as the user
/// to pick a reasonable value. If you pick an unreasonable value, a warning
/// will appear in the logs.
///
/// Changing this configuration at runtime will only affect new terminals,
/// i.e. new windows, tabs, etc.
///
/// To set a different top and bottom padding, specify two numerical values
/// separated by a comma. For example, `window-padding-y = 2,4` will set the
/// top padding to 2 and the bottom padding to 4. If you want to set both
/// paddings to the same value, you can use a single value. For example,
/// `window-padding-y = 2` will set both paddings to 2.
@"window-padding-y": WindowPadding = .{ .top_left = 2, .bottom_right = 2 },

/// The viewport dimensions are usually not perfectly divisible by the cell
/// size. In this case, some extra padding on the end of a column and the bottom
/// of the final row may exist. If this is `true`, then this extra padding
/// is automatically balanced between all four edges to minimize imbalance on
/// one side. If this is `false`, the top left grid cell will always hug the
/// edge with zero padding other than what may be specified with the other
/// `window-padding` options.
///
/// If other `window-padding` fields are set and this is `true`, this will still
/// apply. The other padding is applied first and may affect how many grid cells
/// actually exist, and this is applied last in order to balance the padding
/// given a certain viewport size and grid cell size.
@"window-padding-balance": bool = false,

/// The color of the padding area of the window. Valid values are:
///
/// * `background` - The background color specified in `background`.
/// * `extend` - Extend the background color of the nearest grid cell.
/// * `extend-always` - Same as "extend" but always extends without applying
///   any of the heuristics that disable extending noted below.
///
/// The "extend" value will be disabled in certain scenarios. On primary
/// screen applications (e.g. not something like Neovim), the color will not
/// be extended vertically if any of the following are true:
///
/// * The nearest row has any cells that have the default background color.
///   The thinking is that in this case, the default background color looks
///   fine as a padding color.
/// * The nearest row is a prompt row (requires shell integration). The
///   thinking here is that prompts often contain powerline glyphs that
///   do not look good extended.
/// * The nearest row contains a perfect fit powerline character. These
///   don't look good extended.
@"window-padding-color": WindowPaddingColor = .background,

/// Synchronize rendering with the screen refresh rate. If true, this will
/// minimize tearing and align redraws with the screen but may cause input
/// latency. If false, this will maximize redraw frequency but may cause tearing,
/// and under heavy load may use more CPU and power.
///
/// This defaults to true because out-of-sync rendering on macOS can
/// cause kernel panics (macOS 14.4+) and performance issues for external
/// displays over some hardware such as DisplayLink. If you want to minimize
/// input latency, set this to false with the known aforementioned risks.
///
/// Changing this value at runtime will only affect new terminals.
///
/// This setting is only supported currently on macOS.
@"window-vsync": bool = true,

/// If true, new windows and tabs will inherit the working directory of the
/// previously focused window. If no window was previously focused, the default
/// working directory will be used (the `working-directory` option).
@"window-inherit-working-directory": bool = true,

/// If true, new windows and tabs will inherit the font size of the previously
/// focused window. If no window was previously focused, the default font size
/// will be used. If this is false, the default font size specified in the
/// configuration `font-size` will be used.
@"window-inherit-font-size": bool = true,

/// Configure a preference for window decorations. This setting specifies
/// a _preference_; the actual OS, desktop environment, window manager, etc.
/// may override this preference. Ghostty will do its best to respect this
/// preference but it may not always be possible.
///
/// Valid values:
///
///  * `none`
///
///    All window decorations will be disabled. Titlebar, borders, etc. will
///    not be shown. On macOS, this will also disable tabs (enforced by the
///    system).
///
///  * `auto`
///
///    Automatically decide to use either client-side or server-side
///    decorations based on the detected preferences of the current OS and
///    desktop environment. This option usually makes Ghostty look the most
///    "native" for your desktop.
///
///  * `client`
///
///    Prefer client-side decorations.
///
///    Available since: 1.1.0
///
///  * `server`
///
///    Prefer server-side decorations. This is only relevant on Linux with GTK,
///    either on X11, or Wayland on a compositor that supports the
///    `org_kde_kwin_server_decoration` protocol (e.g. KDE Plasma, but almost
///    any non-GNOME desktop supports this protocol).
///
///    If `server` is set but the environment doesn't support server-side
///    decorations, client-side decorations will be used instead.
///
///    Available since: 1.1.0
///
/// The default value is `auto`.
///
/// For the sake of backwards compatibility and convenience, this setting also
/// accepts boolean true and false values. If set to `true`, this is equivalent
/// to `auto`. If set to `false`, this is equivalent to `none`.
/// This is convenient for users who live primarily on systems that don't
/// differentiate between client and server-side decorations (e.g. macOS and
/// Windows).
///
/// The "toggle_window_decorations" keybind action can be used to create
/// a keybinding to toggle this setting at runtime.
///
/// macOS: To hide the titlebar without removing the native window borders
///        or rounded corners, use `macos-titlebar-style = hidden` instead.
@"window-decoration": WindowDecoration = .auto,

/// The font that will be used for the application's window and tab titles.
///
/// If this setting is left unset, the system default font will be used.
///
/// Note: any font available on the system may be used, this font is not
/// required to be a fixed-width font.
///
/// Available since: 1.1.0 (on GTK)
@"window-title-font-family": ?[:0]const u8 = null,

/// The text that will be displayed in the subtitle of the window. Valid values:
///
///   * `false` - Disable the subtitle.
///   * `working-directory` - Set the subtitle to the working directory of the
///      surface.
///
/// This feature is only supported on GTK.
///
/// Available since: 1.1.0
@"window-subtitle": WindowSubtitle = .false,

/// The theme to use for the windows. Valid values:
///
///   * `auto` - Determine the theme based on the configured terminal
///      background color. This has no effect if the "theme" configuration
///      has separate light and dark themes. In that case, the behavior
///      of "auto" is equivalent to "system".
///   * `system` - Use the system theme.
///   * `light` - Use the light theme regardless of system theme.
///   * `dark` - Use the dark theme regardless of system theme.
///   * `ghostty` - Use the background and foreground colors specified in the
///     Ghostty configuration. This is only supported on Linux builds.
///
/// On macOS, if `macos-titlebar-style` is "tabs", the window theme will be
/// automatically set based on the luminosity of the terminal background color.
/// This only applies to terminal windows. This setting will still apply to
/// non-terminal windows within Ghostty.
///
/// This is currently only supported on macOS and Linux.
@"window-theme": WindowTheme = .auto,

/// The color space to use when interpreting terminal colors. "Terminal colors"
/// refers to colors specified in your configuration and colors produced by
/// direct-color SGR sequences.
///
/// Valid values:
///
///   * `srgb` - Interpret colors in the sRGB color space. This is the default.
///   * `display-p3` - Interpret colors in the Display P3 color space.
///
/// This setting is currently only supported on macOS.
@"window-colorspace": WindowColorspace = .srgb,

/// The initial window size. This size is in terminal grid cells by default.
/// Both values must be set to take effect. If only one value is set, it is
/// ignored.
///
/// We don't currently support specifying a size in pixels but a future change
/// can enable that. If this isn't specified, the app runtime will determine
/// some default size.
///
/// Note that the window manager may put limits on the size or override the
/// size. For example, a tiling window manager may force the window to be a
/// certain size to fit within the grid. There is nothing Ghostty will do about
/// this, but it will make an effort.
///
/// Sizes larger than the screen size will be clamped to the screen size.
/// This can be used to create a maximized-by-default window size.
///
/// This will not affect new tabs, splits, or other nested terminal elements.
/// This only affects the initial window size of any new window. Changing this
/// value will not affect the size of the window after it has been created. This
/// is only used for the initial size.
///
/// BUG: On Linux with GTK, the calculated window size will not properly take
/// into account window decorations. As a result, the grid dimensions will not
/// exactly match this configuration. If window decorations are disabled (see
/// `window-decoration`), then this will work as expected.
///
/// Windows smaller than 10 wide by 4 high are not allowed.
@"window-height": u32 = 0,
@"window-width": u32 = 0,

/// The starting window position. This position is in pixels and is relative
/// to the top-left corner of the primary monitor. Both values must be set to take
/// effect. If only one value is set, it is ignored.
///
/// Note that the window manager may put limits on the position or override
/// the position. For example, a tiling window manager may force the window
/// to be a certain position to fit within the grid. There is nothing Ghostty
/// will do about this, but it will make an effort.
///
/// Also note that negative values are also up to the operating system and
/// window manager. Some window managers may not allow windows to be placed
/// off-screen.
///
/// Invalid positions are runtime-specific, but generally the positions are
/// clamped to the nearest valid position.
///
/// On macOS, the window position is relative to the top-left corner of
/// the visible screen area. This means that if the menu bar is visible, the
/// window will be placed below the menu bar.
///
/// Note: this is only supported on macOS. The GTK runtime does not support
/// setting the window position, as windows are only allowed position
/// themselves in X11 and not Wayland.
@"window-position-x": ?i16 = null,
@"window-position-y": ?i16 = null,

/// Whether to enable saving and restoring window state. Window state includes
/// their position, size, tabs, splits, etc. Some window state requires shell
/// integration, such as preserving working directories. See `shell-integration`
/// for more information.
///
/// There are three valid values for this configuration:
///
///   * `default` will use the default system behavior. On macOS, this
///     will only save state if the application is forcibly terminated
///     or if it is configured systemwide via Settings.app.
///
///   * `never` will never save window state.
///
///   * `always` will always save window state whenever Ghostty is exited.
///
/// If you change this value to `never` while Ghostty is not running, the next
/// Ghostty launch will NOT restore the window state.
///
/// If you change this value to `default` while Ghostty is not running and the
/// previous exit saved state, the next Ghostty launch will still restore the
/// window state. This is because Ghostty cannot know if the previous exit was
/// due to a forced save or not (macOS doesn't provide this information).
///
/// If you change this value so that window state is saved while Ghostty is not
/// running, the previous window state will not be restored because Ghostty only
/// saves state on exit if this is enabled.
///
/// The default value is `default`.
///
/// This is currently only supported on macOS. This has no effect on Linux.
@"window-save-state": WindowSaveState = .default,

/// Resize the window in discrete increments of the focused surface's cell size.
/// If this is disabled, surfaces are resized in pixel increments. Currently
/// only supported on macOS.
@"window-step-resize": bool = false,

/// The position where new tabs are created. Valid values:
///
///   * `current` - Insert the new tab after the currently focused tab,
///     or at the end if there are no focused tabs.
///
///   * `end` - Insert the new tab at the end of the tab list.
@"window-new-tab-position": WindowNewTabPosition = .current,

/// Whether to show the tab bar.
///
/// Valid values:
///
///  - `always`
///
///    Always display the tab bar, even when there's only one tab.
///
///    Available since: 1.2.0
///
///  - `auto` *(default)*
///
///    Automatically show and hide the tab bar. The tab bar is only
///    shown when there are two or more tabs present.
///
///  - `never`
///
///    Never show the tab bar. Tabs are only accessible via the tab
///    overview or by keybind actions.
///
/// Currently only supported on Linux (GTK).
@"window-show-tab-bar": WindowShowTabBar = .auto,

/// Background color for the window titlebar. This only takes effect if
/// window-theme is set to ghostty. Currently only supported in the GTK app
/// runtime.
///
/// Specified as either hex (`#RRGGBB` or `RRGGBB`) or a named X11 color.
@"window-titlebar-background": ?Color = null,

/// Foreground color for the window titlebar. This only takes effect if
/// window-theme is set to ghostty. Currently only supported in the GTK app
/// runtime.
///
/// Specified as either hex (`#RRGGBB` or `RRGGBB`) or a named X11 color.
@"window-titlebar-foreground": ?Color = null,

/// This controls when resize overlays are shown. Resize overlays are a
/// transient popup that shows the size of the terminal while the surfaces are
/// being resized. The possible options are:
///
///   * `always` - Always show resize overlays.
///   * `never` - Never show resize overlays.
///   * `after-first` - The resize overlay will not appear when the surface
///                     is first created, but will show up if the surface is
///                     subsequently resized.
///
/// The default is `after-first`.
@"resize-overlay": ResizeOverlay = .@"after-first",

/// If resize overlays are enabled, this controls the position of the overlay.
/// The possible options are:
///
///   * `center`
///   * `top-left`
///   * `top-center`
///   * `top-right`
///   * `bottom-left`
///   * `bottom-center`
///   * `bottom-right`
///
/// The default is `center`.
@"resize-overlay-position": ResizeOverlayPosition = .center,

/// If resize overlays are enabled, this controls how long the overlay is
/// visible on the screen before it is hidden. The default is ¾ of a second or
/// 750 ms.
///
/// The duration is specified as a series of numbers followed by time units.
/// Whitespace is allowed between numbers and units. Each number and unit will
/// be added together to form the total duration.
///
/// The allowed time units are as follows:
///
///   * `y` - 365 SI days, or 8760 hours, or 31536000 seconds. No adjustments
///     are made for leap years or leap seconds.
///   * `d` - one SI day, or 86400 seconds.
///   * `h` - one hour, or 3600 seconds.
///   * `m` - one minute, or 60 seconds.
///   * `s` - one second.
///   * `ms` - one millisecond, or 0.001 second.
///   * `us` or `µs` - one microsecond, or 0.000001 second.
///   * `ns` - one nanosecond, or 0.000000001 second.
///
/// Examples:
///   * `1h30m`
///   * `45s`
///
/// Units can be repeated and will be added together. This means that
/// `1h1h` is equivalent to `2h`. This is confusing and should be avoided.
/// A future update may disallow this.
///
/// The maximum value is `584y 49w 23h 34m 33s 709ms 551µs 615ns`. Any
/// value larger than this will be clamped to the maximum value.
///
/// Available since 1.0.0
@"resize-overlay-duration": Duration = .{ .duration = 750 * std.time.ns_per_ms },

/// If true, when there are multiple split panes, the mouse selects the pane
/// that is focused. This only applies to the currently focused window; e.g.
/// mousing over a split in an unfocused window will not focus that split
/// and bring the window to front.
///
/// Default is false.
@"focus-follows-mouse": bool = false,

/// Whether to allow programs running in the terminal to read/write to the
/// system clipboard (OSC 52, for googling). The default is to allow clipboard
/// reading after prompting the user and allow writing unconditionally.
///
/// Valid values are:
///
///   * `ask`
///   * `allow`
///   * `deny`
///
@"clipboard-read": ClipboardAccess = .ask,
@"clipboard-write": ClipboardAccess = .allow,

/// Trims trailing whitespace on data that is copied to the clipboard. This does
/// not affect data sent to the clipboard via `clipboard-write`.
@"clipboard-trim-trailing-spaces": bool = true,

/// Require confirmation before pasting text that appears unsafe. This helps
/// prevent a "copy/paste attack" where a user may accidentally execute unsafe
/// commands by pasting text with newlines.
@"clipboard-paste-protection": bool = true,

/// If true, bracketed pastes will be considered safe. By default, bracketed
/// pastes are considered safe. "Bracketed" pastes are pastes while the running
/// program has bracketed paste mode enabled (a setting set by the running
/// program, not the terminal emulator).
@"clipboard-paste-bracketed-safe": bool = true,

/// Enables or disabled title reporting (CSI 21 t). This escape sequence
/// allows the running program to query the terminal title. This is a common
/// security issue and is disabled by default.
///
/// Warning: This can expose sensitive information at best and enable
/// arbitrary code execution at worst (with a maliciously crafted title
/// and a minor amount of user interaction).
///
/// Available since: 1.0.1
@"title-report": bool = false,

/// The total amount of bytes that can be used for image data (e.g. the Kitty
/// image protocol) per terminal screen. The maximum value is 4,294,967,295
/// (4GiB). The default is 320MB. If this is set to zero, then all image
/// protocols will be disabled.
///
/// This value is separate for primary and alternate screens so the effective
/// limit per surface is double.
@"image-storage-limit": u32 = 320 * 1000 * 1000,

/// Whether to automatically copy selected text to the clipboard. `true`
/// will prefer to copy to the selection clipboard, otherwise it will copy to
/// the system clipboard.
///
/// The value `clipboard` will always copy text to the selection clipboard
/// as well as the system clipboard.
///
/// Middle-click paste will always use the selection clipboard. Middle-click
/// paste is always enabled even if this is `false`.
///
/// The default value is true on Linux and macOS.
@"copy-on-select": CopyOnSelect = switch (builtin.os.tag) {
    .linux => .true,
    .macos => .true,
    else => .false,
},

/// The action to take when the user right-clicks on the terminal surface.
///
/// Valid values:
///   * `context-menu` - Show the context menu.
///   * `paste` - Paste the contents of the clipboard.
///   * `copy` - Copy the selected text to the clipboard.
///   * `copy-or-paste` - If there is a selection, copy the selected text to
///      the clipboard; otherwise, paste the contents of the clipboard.
///   * `ignore` - Do nothing, ignore the right-click.
///
/// The default value is `context-menu`.
@"right-click-action": RightClickAction = .@"context-menu",

/// The time in milliseconds between clicks to consider a click a repeat
/// (double, triple, etc.) or an entirely new single click. A value of zero will
/// use a platform-specific default. The default on macOS is determined by the
/// OS settings. On every other platform it is 500ms.
@"click-repeat-interval": u32 = 0,

/// Additional configuration files to read. This configuration can be repeated
/// to read multiple configuration files. Configuration files themselves can
/// load more configuration files. Paths are relative to the file containing the
/// `config-file` directive. For command-line arguments, paths are relative to
/// the current working directory.
///
/// Prepend a ? character to the file path to suppress errors if the file does
/// not exist. If you want to include a file that begins with a literal ?
/// character, surround the file path in double quotes (").
///
/// Cycles are not allowed. If a cycle is detected, an error will be logged and
/// the configuration file will be ignored.
///
/// Configuration files are loaded after the configuration they're defined
/// within in the order they're defined. **THIS IS A VERY SUBTLE BUT IMPORTANT
/// POINT.** To put it another way: configuration files do not take effect
/// until after the entire configuration is loaded. For example, in the
/// configuration below:
///
/// ```
/// config-file = "foo"
/// a = 1
/// ```
///
/// If "foo" contains `a = 2`, the final value of `a` will be 2, because
/// `foo` is loaded after the configuration file that configures the
/// nested `config-file` value.
@"config-file": RepeatablePath = .{},

/// When this is true, the default configuration file paths will be loaded.
/// The default configuration file paths are currently only the XDG
/// config path ($XDG_CONFIG_HOME/ghostty/config).
///
/// If this is false, the default configuration paths will not be loaded.
/// This is targeted directly at using Ghostty from the CLI in a way
/// that minimizes external effects.
///
/// This is a CLI-only configuration. Setting this in a configuration file
/// will have no effect. It is not an error, but it will not do anything.
/// This configuration can only be set via CLI arguments.
@"config-default-files": bool = true,

/// Confirms that a surface should be closed before closing it.
///
/// This defaults to `true`. If set to `false`, surfaces will close without
/// any confirmation. This can also be set to `always`, which will always
/// confirm closing a surface, even if shell integration says a process isn't
/// running.
@"confirm-close-surface": ConfirmCloseSurface = .true,

/// Whether or not to quit after the last surface is closed.
///
/// This defaults to `false` on macOS since that is standard behavior for
/// a macOS application. On Linux, this defaults to `true` since that is
/// generally expected behavior.
///
/// On Linux, if this is `true`, Ghostty can delay quitting fully until a
/// configurable amount of time has passed after the last window is closed.
/// See the documentation of `quit-after-last-window-closed-delay`.
@"quit-after-last-window-closed": bool = builtin.os.tag == .linux,

/// Controls how long Ghostty will stay running after the last open surface has
/// been closed. This only has an effect if `quit-after-last-window-closed` is
/// also set to `true`.
///
/// The minimum value for this configuration is `1s`. Any values lower than
/// this will be clamped to `1s`.
///
/// The duration is specified as a series of numbers followed by time units.
/// Whitespace is allowed between numbers and units. Each number and unit will
/// be added together to form the total duration.
///
/// The allowed time units are as follows:
///
///   * `y` - 365 SI days, or 8760 hours, or 31536000 seconds. No adjustments
///     are made for leap years or leap seconds.
///   * `d` - one SI day, or 86400 seconds.
///   * `h` - one hour, or 3600 seconds.
///   * `m` - one minute, or 60 seconds.
///   * `s` - one second.
///   * `ms` - one millisecond, or 0.001 second.
///   * `us` or `µs` - one microsecond, or 0.000001 second.
///   * `ns` - one nanosecond, or 0.000000001 second.
///
/// Examples:
///   * `1h30m`
///   * `45s`
///
/// Units can be repeated and will be added together. This means that
/// `1h1h` is equivalent to `2h`. This is confusing and should be avoided.
/// A future update may disallow this.
///
/// The maximum value is `584y 49w 23h 34m 33s 709ms 551µs 615ns`. Any
/// value larger than this will be clamped to the maximum value.
///
/// By default `quit-after-last-window-closed-delay` is unset and
/// Ghostty will quit immediately after the last window is closed if
/// `quit-after-last-window-closed` is `true`.
///
/// Only implemented on Linux.
@"quit-after-last-window-closed-delay": ?Duration = null,

/// This controls whether an initial window is created when Ghostty
/// is run. Note that if `quit-after-last-window-closed` is `true` and
/// `quit-after-last-window-closed-delay` is set, setting `initial-window` to
/// `false` will mean that Ghostty will quit after the configured delay if no
/// window is ever created. Only implemented on Linux and macOS.
@"initial-window": bool = true,

/// The duration that undo operations remain available. After this
/// time, the operation will be removed from the undo stack and
/// cannot be undone.
///
/// The default value is 5 seconds.
///
/// This timeout applies per operation, meaning that if you perform
/// multiple operations, each operation will have its own timeout.
/// New operations do not reset the timeout of previous operations.
///
/// A timeout of zero will effectively disable undo operations. It is
/// not possible to set an infinite timeout, but you can set a very
/// large timeout to effectively disable the timeout (on the order of years).
/// This is highly discouraged, as it will cause the undo stack to grow
/// indefinitely, memory usage to grow unbounded, and terminal sessions
/// to never actually quit.
///
/// The duration is specified as a series of numbers followed by time units.
/// Whitespace is allowed between numbers and units. Each number and unit will
/// be added together to form the total duration.
///
/// The allowed time units are as follows:
///
///   * `y` - 365 SI days, or 8760 hours, or 31536000 seconds. No adjustments
///     are made for leap years or leap seconds.
///   * `d` - one SI day, or 86400 seconds.
///   * `h` - one hour, or 3600 seconds.
///   * `m` - one minute, or 60 seconds.
///   * `s` - one second.
///   * `ms` - one millisecond, or 0.001 second.
///   * `us` or `µs` - one microsecond, or 0.000001 second.
///   * `ns` - one nanosecond, or 0.000000001 second.
///
/// Examples:
///   * `1h30m`
///   * `45s`
///
/// Units can be repeated and will be added together. This means that
/// `1h1h` is equivalent to `2h`. This is confusing and should be avoided.
/// A future update may disallow this.
///
/// This configuration is only supported on macOS. Linux doesn't
/// support undo operations at all so this configuration has no
/// effect.
///
/// Available since: 1.2.0
@"undo-timeout": Duration = .{ .duration = 5 * std.time.ns_per_s },

/// The position of the "quick" terminal window. To learn more about the
/// quick terminal, see the documentation for the `toggle_quick_terminal`
/// binding action.
///
/// Valid values are:
///
///   * `top` - Terminal appears at the top of the screen.
///   * `bottom` - Terminal appears at the bottom of the screen.
///   * `left` - Terminal appears at the left of the screen.
///   * `right` - Terminal appears at the right of the screen.
///   * `center` - Terminal appears at the center of the screen.
///
/// On macOS, changing this configuration requires restarting Ghostty
/// completely.
///
/// Note: There is no default keybind for toggling the quick terminal.
/// To enable this feature, bind the `toggle_quick_terminal` action to a key.
@"quick-terminal-position": QuickTerminalPosition = .top,

/// The size of the quick terminal.
///
/// The size can be specified either as a percentage of the screen dimensions
/// (height/width), or as an absolute size in pixels. Percentage values are
/// suffixed with `%` (e.g. `20%`) while pixel values are suffixed with `px`
/// (e.g. `300px`). A bare value without a suffix is a config error.
///
/// When only one size is specified, the size parameter affects the size of
/// the quick terminal on its *primary axis*, which depends on its position:
/// height for quick terminals placed on the top or bottom, and width for left
/// or right. The primary axis of a centered quick terminal depends on the
/// monitor's orientation: height when on a landscape monitor, and width when
/// on a portrait monitor.
///
/// The *secondary axis* would be maximized for non-center positioned
/// quick terminals unless another size parameter is specified, separated
/// from the first by a comma (`,`). Percentage and pixel sizes can be mixed
/// together: for instance, a size of `50%,500px` for a top-positioned quick
/// terminal would be half a screen tall, and 500 pixels wide.
///
/// Available since: 1.2.0
@"quick-terminal-size": QuickTerminalSize = .{},

/// The layer of the quick terminal window. The higher the layer,
/// the more windows the quick terminal may conceal.
///
/// Valid values are:
///
///  * `overlay`
///
///    The quick terminal appears in front of all windows.
///
///  * `top` (default)
///
///    The quick terminal appears in front of normal windows but behind
///    fullscreen overlays like lock screens.
///
///  * `bottom`
///
///    The quick terminal appears behind normal windows but in front of
///    wallpapers and other windows in the background layer.
///
///  * `background`
///
///    The quick terminal appears behind all windows.
///
/// GTK Wayland only.
///
/// Available since: 1.2.0
@"gtk-quick-terminal-layer": QuickTerminalLayer = .top,
/// The namespace for the quick terminal window.
///
/// This is an identifier that is used by the Wayland compositor and/or
/// scripts to determine the type of layer surfaces and to possibly apply
/// unique effects.
///
/// GTK Wayland only.
///
/// Available since: 1.2.0
@"gtk-quick-terminal-namespace": [:0]const u8 = "ghostty-quick-terminal",

/// The screen where the quick terminal should show up.
///
/// Valid values are:
///
///  * `main` - The screen that the operating system recommends as the main
///    screen. On macOS, this is the screen that is currently receiving
///    keyboard input. This screen is defined by the operating system and
///    not chosen by Ghostty.
///
///  * `mouse` - The screen that the mouse is currently hovered over.
///
///  * `macos-menu-bar` - The screen that contains the macOS menu bar as
///    set in the display settings on macOS. This is a bit confusing because
///    every screen on macOS has a menu bar, but this is the screen that
///    contains the primary menu bar.
///
/// The default value is `main` because this is the recommended screen
/// by the operating system.
///
/// Only implemented on macOS.
@"quick-terminal-screen": QuickTerminalScreen = .main,

/// Duration (in seconds) of the quick terminal enter and exit animation.
/// Set it to 0 to disable animation completely. This can be changed at
/// runtime.
///
/// Only implemented on macOS.
@"quick-terminal-animation-duration": f64 = 0.2,

/// Automatically hide the quick terminal when focus shifts to another window.
/// Set it to false for the quick terminal to remain open even when it loses focus.
///
/// Defaults to true on macOS and on false on Linux/BSD. This is because global
/// shortcuts on Linux require system configuration and are considerably less
/// accessible than on macOS, meaning that it is more preferable to keep the
/// quick terminal open until the user has completed their task.
/// This default may change in the future.
@"quick-terminal-autohide": bool = switch (builtin.os.tag) {
    .linux => false,
    .macos => true,
    else => false,
},

/// This configuration option determines the behavior of the quick terminal
/// when switching between macOS spaces. macOS spaces are virtual desktops
/// that can be manually created or are automatically created when an
/// application is in full-screen mode.
///
/// Valid values are:
///
///  * `move` - When switching to another space, the quick terminal will
///    also moved to the current space.
///
///  * `remain` - The quick terminal will stay only in the space where it
///    was originally opened and will not follow when switching to another
///    space.
///
/// The default value is `move`.
///
/// Only implemented on macOS.
/// On Linux the behavior is always equivalent to `move`.
///
/// Available since: 1.1.0
@"quick-terminal-space-behavior": QuickTerminalSpaceBehavior = .move,

/// Determines under which circumstances that the quick terminal should receive
/// keyboard input. See the corresponding [Wayland documentation](https://wayland.app/protocols/wlr-layer-shell-unstable-v1#zwlr_layer_surface_v1:enum:keyboard_interactivity)
/// for a more detailed explanation of the behavior of each option.
///
/// > [!NOTE]
/// > The exact behavior of each option may differ significantly across
/// > compositors -- experiment with them on your system to find one that
/// > suits your liking!
///
/// Valid values are:
///
///  * `none`
///
///    The quick terminal will not receive any keyboard input.
///
///  * `on-demand` (default)
///
///    The quick terminal would only receive keyboard input when it is focused.
///
///  * `exclusive`
///
///    The quick terminal will always receive keyboard input, even when another
///    window is currently focused.
///
/// Only has an effect on Linux Wayland.
/// On macOS the behavior is always equivalent to `on-demand`.
///
/// Available since: 1.2.0
@"quick-terminal-keyboard-interactivity": QuickTerminalKeyboardInteractivity = .@"on-demand",

/// Whether to enable shell integration auto-injection or not. Shell integration
/// greatly enhances the terminal experience by enabling a number of features:
///
///   * Working directory reporting so new tabs, splits inherit the
///     previous terminal's working directory.
///
///   * Prompt marking that enables the "jump_to_prompt" keybinding.
///
///   * If you're sitting at a prompt, closing a terminal will not ask
///     for confirmation.
///
///   * Resizing the window with a complex prompt usually paints much
///     better.
///
/// Allowable values are:
///
///   * `none` - Do not do any automatic injection. You can still manually
///     configure your shell to enable the integration.
///
///   * `detect` - Detect the shell based on the filename.
///
///   * `bash`, `elvish`, `fish`, `zsh` - Use this specific shell injection scheme.
///
/// The default value is `detect`.
@"shell-integration": ShellIntegration = .detect,

/// Shell integration features to enable. These require our shell integration
/// to be loaded, either automatically via shell-integration or manually.
///
/// The format of this is a list of features to enable separated by commas. If
/// you prefix a feature with `no-` then it is disabled. If you omit a feature,
/// its default value is used, so you must explicitly disable features you don't
/// want. You can also use `true` or `false` to turn all features on or off.
///
/// Example: `cursor`, `no-cursor`, `sudo`, `no-sudo`, `title`, `no-title`
///
/// Available features:
///
///   * `cursor` - Set the cursor to a blinking bar at the prompt.
///
///   * `sudo` - Set sudo wrapper to preserve terminfo.
///
///   * `title` - Set the window title via shell integration.
///
///   * `ssh-env` - Enable SSH environment variable compatibility. Automatically
///     converts TERM from `xterm-ghostty` to `xterm-256color` when connecting to
///     remote hosts and propagates COLORTERM, TERM_PROGRAM, and TERM_PROGRAM_VERSION.
///     Whether or not these variables will be accepted by the remote host(s) will
///     depend on whether or not the variables are allowed in their sshd_config.
///     (Available since: 1.2.0)
///
///   * `ssh-terminfo` - Enable automatic terminfo installation on remote hosts.
///     Attempts to install Ghostty's terminfo entry using `infocmp` and `tic` when
///     connecting to hosts that lack it. Requires `infocmp` to be available locally
///     and `tic` to be available on remote hosts. Once terminfo is installed on a
///     remote host, it will be automatically "cached" to avoid repeat installations.
///     If desired, the `+ssh-cache` CLI action can be used to manage the installation
///     cache manually using various arguments.
///     (Available since: 1.2.0)
///
/// SSH features work independently and can be combined for optimal experience:
/// when both `ssh-env` and `ssh-terminfo` are enabled, Ghostty will install its
/// terminfo on remote hosts and use `xterm-ghostty` as TERM, falling back to
/// `xterm-256color` with environment variables if terminfo installation fails.
@"shell-integration-features": ShellIntegrationFeatures = .{},

/// Custom entries into the command palette.
///
/// Each entry requires the title, the corresponding action, and an optional
/// description. Each field should be prefixed with the field name, a colon
/// (`:`), and then the specified value. The syntax for actions is identical
/// to the one for keybind actions. Whitespace in between fields is ignored.
///
/// ```ini
/// command-palette-entry = title:Reset Font Style, action:csi:0m
/// command-palette-entry = title:Crash on Main Thread,description:Causes a crash on the main (UI) thread.,action:crash:main
/// ```
///
/// By default, the command palette is preloaded with most actions that might
/// be useful in an interactive setting yet do not have easily accessible or
/// memorizable shortcuts. The default entries can be cleared by setting this
/// setting to an empty value:
///
/// ```ini
/// command-palette-entry =
/// ```
///
/// Available since: 1.2.0
@"command-palette-entry": RepeatableCommand = .{},

/// Sets the reporting format for OSC sequences that request color information.
/// Ghostty currently supports OSC 10 (foreground), OSC 11 (background), and
/// OSC 4 (256 color palette) queries, and by default the reported values
/// are scaled-up RGB values, where each component are 16 bits. This is how
/// most terminals report these values. However, some legacy applications may
/// require 8-bit, unscaled, components. We also support turning off reporting
/// altogether. The components are lowercase hex values.
///
/// Allowable values are:
///
///   * `none` - OSC 4/10/11 queries receive no reply
///
///   * `8-bit` - Color components are return unscaled, e.g. `rr/gg/bb`
///
///   * `16-bit` - Color components are returned scaled, e.g. `rrrr/gggg/bbbb`
///
/// The default value is `16-bit`.
@"osc-color-report-format": OSCColorReportFormat = .@"16-bit",

/// If true, allows the "KAM" mode (ANSI mode 2) to be used within
/// the terminal. KAM disables keyboard input at the request of the
/// application. This is not a common feature and is not recommended
/// to be enabled. This will not be documented further because
/// if you know you need KAM, you know. If you don't know if you
/// need KAM, you don't need it.
@"vt-kam-allowed": bool = false,

/// Custom shaders to run after the default shaders. This is a file path
/// to a GLSL-syntax shader for all platforms.
///
/// Warning: Invalid shaders can cause Ghostty to become unusable such as by
/// causing the window to be completely black. If this happens, you can
/// unset this configuration to disable the shader.
///
/// Custom shader support is based on and compatible with the Shadertoy shaders.
/// Shaders should specify a `mainImage` function and the available uniforms
/// largely match Shadertoy, with some caveats and Ghostty-specific extensions.
///
/// The uniform values available to shaders are as follows:
///
///  * `sampler2D iChannel0` - Input texture.
///
///    A texture containing the current terminal screen. If multiple custom
///    shaders are specified, the output of previous shaders is written to
///    this texture, to allow combining multiple effects.
///
///  * `vec3 iResolution` - Output texture size, `[width, height, 1]` (in px).
///
///  * `float iTime` - Time in seconds since first frame was rendered.
///
///  * `float iTimeDelta` - Time in seconds since previous frame was rendered.
///
///  * `float iFrameRate` - Average framerate. (NOT CURRENTLY SUPPORTED)
///
///  * `int iFrame` - Number of frames that have been rendered so far.
///
///  * `float iChannelTime[4]` - Current time for video or sound input. (N/A)
///
///  * `vec3 iChannelResolution[4]` - Resolutions of the 4 input samplers.
///
///    Currently only `iChannel0` exists, and `iChannelResolution[0]` is
///    identical to `iResolution`.
///
///  * `vec4 iMouse` - Mouse input info. (NOT CURRENTLY SUPPORTED)
///
///  * `vec4 iDate` - Date/time info. (NOT CURRENTLY SUPPORTED)
///
///  * `float iSampleRate` - Sample rate for audio. (N/A)
///
/// Ghostty-specific extensions:
///
///  * `vec4 iCurrentCursor` - Info about the terminal cursor.
///
///    - `iCurrentCursor.xy` is the -X, +Y corner of the current cursor.
///    - `iCurrentCursor.zw` is the width and height of the current cursor.
///
///  * `vec4 iPreviousCursor` - Info about the previous terminal cursor.
///
///  * `vec4 iCurrentCursorColor` - Color of the terminal cursor.
///
///  * `vec4 iPreviousCursorColor` - Color of the previous terminal cursor.
///
///  * `float iTimeCursorChange` - Timestamp of terminal cursor change.
///
///    When the terminal cursor changes position or color, this is set to
///    the same time as the `iTime` uniform, allowing you to compute the
///    time since the change by subtracting this from `iTime`.
///
/// If the shader fails to compile, the shader will be ignored. Any errors
/// related to shader compilation will not show up as configuration errors
/// and only show up in the log, since shader compilation happens after
/// configuration loading on the dedicated render thread.  For interactive
/// development, use [shadertoy.com](https://shadertoy.com).
///
/// This can be repeated multiple times to load multiple shaders. The shaders
/// will be run in the order they are specified.
///
/// This can be changed at runtime and will affect all open terminals.
@"custom-shader": RepeatablePath = .{},

/// If `true` (default), the focused terminal surface will run an animation
/// loop when custom shaders are used. This uses slightly more CPU (generally
/// less than 10%) but allows the shader to animate. This only runs if there
/// are custom shaders and the terminal is focused.
///
/// If this is set to `false`, the terminal and custom shader will only render
/// when the terminal is updated. This is more efficient but the shader will
/// not animate.
///
/// This can also be set to `always`, which will always run the animation
/// loop regardless of whether the terminal is focused or not. The animation
/// loop will still only run when custom shaders are used. Note that this
/// will use more CPU per terminal surface and can become quite expensive
/// depending on the shader and your terminal usage.
///
/// This can be changed at runtime and will affect all open terminals.
@"custom-shader-animation": CustomShaderAnimation = .true,

/// Bell features to enable if bell support is available in your runtime. Not
/// all features are available on all runtimes. The format of this is a list of
/// features to enable separated by commas. If you prefix a feature with `no-`
/// then it is disabled. If you omit a feature, its default value is used.
///
/// Valid values are:
///
///  * `system`
///
///    Instruct the system to notify the user using built-in system functions.
///    This could result in an audiovisual effect, a notification, or something
///    else entirely. Changing these effects require altering system settings:
///    for instance under the "Sound > Alert Sound" setting in GNOME,
///    or the "Accessibility > System Bell" settings in KDE Plasma. (GTK only)
///
///  * `audio`
///
///    Play a custom sound. (GTK only)
///
///  * `attention` *(enabled by default)*
///
///    Request the user's attention when Ghostty is unfocused, until it has
///    received focus again. On macOS, this will bounce the app icon in the
///    dock once. On Linux, the behavior depends on the desktop environment
///    and/or the window manager/compositor:
///
///    - On KDE, the background of the desktop icon in the task bar would be
///      highlighted;
///
///    - On GNOME, you may receive a notification that, when clicked, would
///      bring the Ghostty window into focus;
///
///    - On Sway, the window may be decorated with a distinctly colored border;
///
///    - On other systems this may have no effect at all.
///
///  * `title` *(enabled by default)*
///
///    Prepend a bell emoji (🔔) to the title of the alerted surface until the
///    terminal is re-focused or interacted with (such as on keyboard input).
///
///  * `border`
///
///    Display a border around the alerted surface until the terminal is
///    re-focused or interacted with (such as on keyboard input).
///
///    GTK only.
///
/// Example: `audio`, `no-audio`, `system`, `no-system`
///
/// Available since: 1.2.0
@"bell-features": BellFeatures = .{},

/// If `audio` is an enabled bell feature, this is a path to an audio file. If
/// the path is not absolute, it is considered relative to the directory of the
/// configuration file that it is referenced from, or from the current working
/// directory if this is used as a CLI flag. The path may be prefixed with `~/`
/// to reference the user's home directory. (GTK only)
///
/// Available since: 1.2.0
@"bell-audio-path": ?Path = null,

/// If `audio` is an enabled bell feature, this is the volume to play the audio
/// file at (relative to the system volume). This is a floating point number
/// ranging from 0.0 (silence) to 1.0 (as loud as possible). The default is 0.5.
/// (GTK only)
///
/// Available since: 1.2.0
@"bell-audio-volume": f64 = 0.5,

/// Control the in-app notifications that Ghostty shows.
///
/// On Linux (GTK), in-app notifications show up as toasts. Toasts appear
/// overlaid on top of the terminal window. They are used to show information
/// that is not critical but may be important.
///
/// Possible notifications are:
///
///   - `clipboard-copy` (default: true) - Show a notification when text is copied
///     to the clipboard.
///   - `config-reload` (default: true) - Show a notification when
///     the configuration is reloaded.
///
/// To specify a notification to enable, specify the name of the notification.
/// To specify a notification to disable, prefix the name with `no-`. For
/// example, to disable `clipboard-copy`, set this configuration to
/// `no-clipboard-copy`. To enable it, set this configuration to `clipboard-copy`.
///
/// Multiple notifications can be enabled or disabled by separating them
/// with a comma.
///
/// A value of "false" will disable all notifications. A value of "true" will
/// enable all notifications.
///
/// This configuration only applies to GTK.
///
/// Available since: 1.1.0
@"app-notifications": AppNotifications = .{},

/// If anything other than false, fullscreen mode on macOS will not use the
/// native fullscreen, but make the window fullscreen without animations and
/// using a new space. It's faster than the native fullscreen mode since it
/// doesn't use animations.
///
/// Important: tabs DO NOT WORK in this mode. Non-native fullscreen removes
/// the titlebar and macOS native tabs require the titlebar. If you use tabs,
/// you should not use this mode.
///
/// If you fullscreen a window with tabs, the currently focused tab will
/// become fullscreen while the others will remain in a separate window in
/// the background. You can switch to that window using normal window-switching
/// keybindings such as command+tilde. When you exit fullscreen, the window
/// will return to the tabbed state it was in before.
///
/// Allowable values are:
///
///   * `true` - Use non-native macOS fullscreen, hide the menu bar
///   * `false` - Use native macOS fullscreen
///   * `visible-menu` - Use non-native macOS fullscreen, keep the menu bar
///     visible
///   * `padded-notch` - Use non-native macOS fullscreen, hide the menu bar,
///     but ensure the window is not obscured by the notch on applicable
///     devices. The area around the notch will remain transparent currently,
///     but in the future we may fill it with the window background color.
///
/// Changing this option at runtime works, but will only apply to the next
/// time the window is made fullscreen. If a window is already fullscreen,
/// it will retain the previous setting until fullscreen is exited.
@"macos-non-native-fullscreen": NonNativeFullscreen = .false,

/// Whether the window buttons in the macOS titlebar are visible. The window
/// buttons are the colored buttons in the upper left corner of most macOS apps,
/// also known as the traffic lights, that allow you to close, miniaturize, and
/// zoom the window.
///
/// This setting has no effect when `window-decoration = false` or
/// `macos-titlebar-style = hidden`, as the window buttons are always hidden in
/// these modes.
///
/// Valid values are:
///
///   * `visible` - Show the window buttons.
///   * `hidden` - Hide the window buttons.
///
/// The default value is `visible`.
///
/// Changing this option at runtime only applies to new windows.
///
/// Available since: 1.2.0
@"macos-window-buttons": MacWindowButtons = .visible,

/// The style of the macOS titlebar. Available values are: "native",
/// "transparent", "tabs", and "hidden".
///
/// The "native" style uses the native macOS titlebar with zero customization.
/// The titlebar will match your window theme (see `window-theme`).
///
/// The "transparent" style is the same as "native" but the titlebar will
/// be transparent and allow your window background color to come through.
/// This makes a more seamless window appearance but looks a little less
/// typical for a macOS application and may not work well with all themes.
///
/// The "transparent" style will also update in real-time to dynamic
/// changes to the window background color, e.g. via OSC 11. To make this
/// more aesthetically pleasing, this only happens if the terminal is
/// a window, tab, or split that borders the top of the window. This
/// avoids a disjointed appearance where the titlebar color changes
/// but all the topmost terminals don't match.
///
/// The "tabs" style is a completely custom titlebar that integrates the
/// tab bar into the titlebar. This titlebar always matches the background
/// color of the terminal. There are some limitations to this style:
/// On macOS 13 and below, saved window state will not restore tabs correctly.
/// macOS 14 does not have this issue and any other macOS version has not
/// been tested.
///
/// The "hidden" style hides the titlebar. Unlike `window-decoration = false`,
/// however, it does not remove the frame from the window or cause it to have
/// squared corners. Changing to or from this option at run-time may affect
/// existing windows in buggy ways.
///
/// When "hidden", the top titlebar area can no longer be used for dragging
/// the window. To drag the window, you can use option+click on the resizable
/// areas of the frame to drag the window. This is a standard macOS behavior
/// and not something Ghostty enables.
///
/// The default value is "transparent". This is an opinionated choice
/// but its one I think is the most aesthetically pleasing and works in
/// most cases.
///
/// Changing this option at runtime only applies to new windows.
@"macos-titlebar-style": MacTitlebarStyle = .transparent,

/// Whether the proxy icon in the macOS titlebar is visible. The proxy icon
/// is the icon that represents the folder of the current working directory.
/// You can see this very clearly in the macOS built-in Terminal.app
/// titlebar.
///
/// The proxy icon is only visible with the native macOS titlebar style.
///
/// Valid values are:
///
///   * `visible` - Show the proxy icon.
///   * `hidden` - Hide the proxy icon.
///
/// The default value is `visible`.
///
/// This setting can be changed at runtime and will affect all currently
/// open windows but only after their working directory changes again.
/// Therefore, to make this work after changing the setting, you must
/// usually `cd` to a different directory, open a different file in an
/// editor, etc.
@"macos-titlebar-proxy-icon": MacTitlebarProxyIcon = .visible,

/// Controls the windowing behavior when dropping a file or folder
/// onto the Ghostty icon in the macOS dock.
///
/// Valid values are:
///
///   * `new-tab` - Create a new tab in the current window, or open
///     a new window if none exist.
///   * `window` - Create a new window unconditionally.
///
/// The default value is `new-tab`.
///
/// This setting is only supported on macOS and has no effect on other
/// platforms.
@"macos-dock-drop-behavior": MacOSDockDropBehavior = .@"new-tab",

/// macOS doesn't have a distinct "alt" key and instead has the "option"
/// key which behaves slightly differently. On macOS by default, the
/// option key plus a character will sometimes produce a Unicode character.
/// For example, on US standard layouts option-b produces "∫". This may be
/// undesirable if you want to use "option" as an "alt" key for keybindings
/// in terminal programs or shells.
///
/// This configuration lets you change the behavior so that option is treated
/// as alt.
///
/// The default behavior (unset) will depend on your active keyboard
/// layout. If your keyboard layout is one of the keyboard layouts listed
/// below, then the default value is "true". Otherwise, the default
/// value is "false". Keyboard layouts with a default value of "true" are:
///
///   - U.S. Standard
///   - U.S. International
///
/// Note that if an *Option*-sequence doesn't produce a printable character, it
/// will be treated as *Alt* regardless of this setting. (e.g. `alt+ctrl+a`).
///
/// Explicit values that can be set:
///
/// If `true`, the *Option* key will be treated as *Alt*. This makes terminal
/// sequences expecting *Alt* to work properly, but will break Unicode input
/// sequences on macOS if you use them via the *Alt* key.
///
/// You may set this to `false` to restore the macOS *Alt* key unicode
/// sequences but this will break terminal sequences expecting *Alt* to work.
///
/// The values `left` or `right` enable this for the left or right *Option*
/// key, respectively.
@"macos-option-as-alt": ?OptionAsAlt = null,

/// Whether to enable the macOS window shadow. The default value is true.
/// With some window managers and window transparency settings, you may
/// find false more visually appealing.
@"macos-window-shadow": bool = true,

/// If true, the macOS icon in the dock and app switcher will be hidden. This is
/// mainly intended for those primarily using the quick-terminal mode.
///
/// Note that setting this to true means that keyboard layout changes
/// will no longer be automatic.
///
/// Control whether macOS app is excluded from the dock and app switcher,
/// a "hidden" state. This is mainly intended for those primarily using
/// quick-terminal mode, but is a general configuration for any use
/// case.
///
/// Available values:
///
///   * `never` - The macOS app is never hidden.
///   * `always` - The macOS app is always hidden.
///
/// Note: When the macOS application is hidden, keyboard layout changes
/// will no longer be automatic. This is a limitation of macOS.
///
/// Available since: 1.2.0
@"macos-hidden": MacHidden = .never,

/// If true, Ghostty on macOS will automatically enable the "Secure Input"
/// feature when it detects that a password prompt is being displayed.
///
/// "Secure Input" is a macOS security feature that prevents applications from
/// reading keyboard events. This can always be enabled manually using the
/// `Ghostty > Secure Keyboard Entry` menu item.
///
/// Note that automatic password prompt detection is based on heuristics
/// and may not always work as expected. Specifically, it does not work
/// over SSH connections, but there may be other cases where it also
/// doesn't work.
///
/// A reason to disable this feature is if you find that it is interfering
/// with legitimate accessibility software (or software that uses the
/// accessibility APIs), since secure input prevents any application from
/// reading keyboard events.
@"macos-auto-secure-input": bool = true,

/// If true, Ghostty will show a graphical indication when secure input is
/// enabled. This indication is generally recommended to know when secure input
/// is enabled.
///
/// Normally, secure input is only active when a password prompt is displayed
/// or it is manually (and typically temporarily) enabled. However, if you
/// always have secure input enabled, the indication can be distracting and
/// you may want to disable it.
@"macos-secure-input-indication": bool = true,

/// Customize the macOS app icon.
///
/// This only affects the icon that appears in the dock, application
/// switcher, etc. This does not affect the icon in Finder because
/// that is controlled by a hardcoded value in the signed application
/// bundle and can't be changed at runtime. For more details on what
/// exactly is affected, see the `NSApplication.icon` Apple documentation;
/// that is the API that is being used to set the icon.
///
/// Valid values:
///
///  * `official` - Use the official Ghostty icon.
///  * `blueprint`, `chalkboard`, `microchip`, `glass`, `holographic`,
///    `paper`, `retro`, `xray` - Official variants of the Ghostty icon
///    hand-created by artists (no AI).
///  * `custom` - Use a completely custom icon. The location must be specified
///    using the additional `macos-custom-icon` configuration
///  * `custom-style` - Use the official Ghostty icon but with custom
///    styles applied to various layers. The custom styles must be
///    specified using the additional `macos-icon`-prefixed configurations.
///    The `macos-icon-ghost-color` and `macos-icon-screen-color`
///    configurations are required for this style.
///
/// WARNING: The `custom-style` option is _experimental_. We may change
/// the format of the custom styles in the future. We're still finalizing
/// the exact layers and customization options that will be available.
///
/// Other caveats:
///
///   * The icon in the update dialog will always be the official icon.
///     This is because the update dialog is managed through a
///     separate framework and cannot be customized without significant
///     effort.
@"macos-icon": MacAppIcon = .official,

/// The absolute path to the custom icon file.
/// Supported formats include PNG, JPEG, and ICNS.
///
/// Defaults to `~/.config/ghostty/Ghostty.icns`
///
/// Note: This configuration is required when `macos-icon` is set to
/// `custom`
@"macos-custom-icon": ?[]const u8 = null,

/// The material to use for the frame of the macOS app icon.
///
/// Valid values:
///
///  * `aluminum` - A brushed aluminum frame. This is the default.
///  * `beige` - A classic 90's computer beige frame.
///  * `plastic` - A glossy, dark plastic frame.
///  * `chrome` - A shiny chrome frame.
///
/// Note: This configuration is required when `macos-icon` is set to
/// `custom-style`.
@"macos-icon-frame": MacAppIconFrame = .aluminum,

/// The color of the ghost in the macOS app icon.
///
/// Note: This configuration is required when `macos-icon` is set to
/// `custom-style`.
///
/// Specified as either hex (`#RRGGBB` or `RRGGBB`) or a named X11 color.
@"macos-icon-ghost-color": ?Color = null,

/// The color of the screen in the macOS app icon.
///
/// The screen is a linear gradient so you can specify multiple colors
/// that make up the gradient. Up to 64 comma-separated colors may be
/// specified as either hex (`#RRGGBB` or `RRGGBB`) or as named X11
/// colors. The first color is the bottom of the gradient and the last
/// color is the top of the gradient.
///
/// Note: This configuration is required when `macos-icon` is set to
/// `custom-style`.
@"macos-icon-screen-color": ?ColorList = null,

/// Whether macOS Shortcuts are allowed to control Ghostty.
///
/// Ghostty exposes a number of actions that allow Shortcuts to
/// control and interact with Ghostty. This includes creating new
/// terminals, sending text to terminals, running commands, invoking
/// any keybind action, etc.
///
/// This is a powerful feature but can be a security risk if a malicious
/// shortcut is able to be installed and executed. Therefore, this
/// configuration allows you to disable this feature.
///
/// Valid values are:
///
/// * `ask` - Ask the user whether for permission. Ghostty will remember
///   this choice and never ask again. This is similar to other macOS
///   permissions such as microphone access, camera access, etc.
///
/// * `allow` - Allow Shortcuts to control Ghostty without asking.
///
/// * `deny` - Deny Shortcuts from controlling Ghostty.
///
/// Available since: 1.2.0
@"macos-shortcuts": MacShortcuts = .ask,

/// Put every surface (tab, split, window) into a dedicated Linux cgroup.
///
/// This makes it so that resource management can be done on a per-surface
/// granularity. For example, if a shell program is using too much memory,
/// only that shell will be killed by the oom monitor instead of the entire
/// Ghostty process. Similarly, if a shell program is using too much CPU,
/// only that surface will be CPU-throttled.
///
/// This will cause startup times to be slower (a hundred milliseconds or so),
/// so the default value is "single-instance." In single-instance mode, only
/// one instance of Ghostty is running (see gtk-single-instance) so the startup
/// time is a one-time cost. Additionally, single instance Ghostty is much
/// more likely to have many windows, tabs, etc. so cgroup isolation is a
/// big benefit.
///
/// This feature requires systemd. If systemd is unavailable, cgroup
/// initialization will fail. By default, this will not prevent Ghostty
/// from working (see linux-cgroup-hard-fail).
///
/// Valid values are:
///
///   * `never` - Never use cgroups.
///   * `always` - Always use cgroups.
///   * `single-instance` - Enable cgroups only for Ghostty instances launched
///     as single-instance applications (see gtk-single-instance).
@"linux-cgroup": LinuxCgroup = if (builtin.os.tag == .linux)
    .@"single-instance"
else
    .never,

/// Memory limit for any individual terminal process (tab, split, window,
/// etc.) in bytes. If this is unset then no memory limit will be set.
///
/// Note that this sets the "memory.high" configuration for the memory
/// controller, which is a soft limit. You should configure something like
/// systemd-oom to handle killing processes that have too much memory
/// pressure.
@"linux-cgroup-memory-limit": ?u64 = null,

/// Number of processes limit for any individual terminal process (tab, split,
/// window, etc.). If this is unset then no limit will be set.
///
/// Note that this sets the "pids.max" configuration for the process number
/// controller, which is a hard limit.
@"linux-cgroup-processes-limit": ?u64 = null,

/// If this is false, then any cgroup initialization (for linux-cgroup)
/// will be allowed to fail and the failure is ignored. This is useful if
/// you view cgroup isolation as a "nice to have" and not a critical resource
/// management feature, because Ghostty startup will not fail if cgroup APIs
/// fail.
///
/// If this is true, then any cgroup initialization failure will cause
/// Ghostty to exit or new surfaces to not be created.
///
/// Note: This currently only affects cgroup initialization. Subprocesses
/// must always be able to move themselves into an isolated cgroup.
@"linux-cgroup-hard-fail": bool = false,

/// Enable or disable GTK's OpenGL debugging logs. The default is `true` for
/// debug builds, `false` for all others.
///
/// Available since: 1.1.0
@"gtk-opengl-debug": bool = builtin.mode == .Debug,

/// If `true`, the Ghostty GTK application will run in single-instance mode:
/// each new `ghostty` process launched will result in a new window if there is
/// already a running process.
///
/// If `false`, each new ghostty process will launch a separate application.
///
/// If `detect`, Ghostty will assume true (single instance) unless one of
/// the following scenarios is found:
///
/// 1. TERM_PROGRAM environment variable is a non-empty value. In this
/// case, we assume Ghostty is being launched from a graphical terminal
/// session and you want a dedicated instance.
///
/// 2. Any CLI arguments exist. In this case, we assume you are passing
/// custom Ghostty configuration. Single instance mode inherits the
/// configuration from when it was launched, so we must disable single
/// instance to load the new configuration.
///
/// If either of these scenarios is producing a false positive, you can
/// set this configuration explicitly to the behavior you want.
///
/// The pre-1.2 option `desktop` has been deprecated. Please replace
/// this with `detect`.
///
/// The default value is `detect`.
///
/// Note that debug builds of Ghostty have a separate single-instance ID
/// so you can test single instance without conflicting with release builds.
@"gtk-single-instance": GtkSingleInstance = .default,

/// When enabled, the full GTK titlebar is displayed instead of your window
/// manager's simple titlebar. The behavior of this option will vary with your
/// window manager.
///
/// This option does nothing when `window-decoration` is false or when running
/// under macOS.
@"gtk-titlebar": bool = true,

/// Determines the side of the screen that the GTK tab bar will stick to.
/// Top, bottom, and hidden are supported. The default is top.
///
/// When `hidden` is set, a tab button displaying the number of tabs will appear
/// in the title bar. It has the ability to open a tab overview for displaying
/// tabs. Alternatively, you can use the `toggle_tab_overview` action in a
/// keybind if your window doesn't have a title bar, or you can switch tabs
/// with keybinds.
@"gtk-tabs-location": GtkTabsLocation = .top,

/// If this is `true`, the titlebar will be hidden when the window is maximized,
/// and shown when the titlebar is unmaximized. GTK only.
///
/// Available since: 1.1.0
@"gtk-titlebar-hide-when-maximized": bool = false,

/// Determines the appearance of the top and bottom bars tab bar.
///
/// Valid values are:
///
///  * `flat` - Top and bottom bars are flat with the terminal window.
///  * `raised` - Top and bottom bars cast a shadow on the terminal area.
///  * `raised-border` - Similar to `raised` but the shadow is replaced with a
///    more subtle border.
@"gtk-toolbar-style": GtkToolbarStyle = .raised,

/// The style of the GTK titlbar. Available values are `native` and `tabs`.
///
/// The `native` titlebar style is a traditional titlebar with a title, a few
/// buttons and window controls. A separate tab bar will show up below the
/// titlebar if you have multiple tabs open in the window.
///
/// The `tabs` titlebar merges the tab bar and the traditional titlebar.
/// This frees up vertical space on your screen if you use multiple tabs. One
/// limitation of the `tabs` titlebar is that you cannot drag the titlebar
/// by the titles any longer (as they are tab titles now). Other areas of the
/// `tabs` title bar can be used to drag the window around.
///
/// The default style is `native`.
@"gtk-titlebar-style": GtkTitlebarStyle = .native,

/// If `true` (default), then the Ghostty GTK tabs will be "wide." Wide tabs
/// are the new typical Gnome style where tabs fill their available space.
/// If you set this to `false` then tabs will only take up space they need,
/// which is the old style.
@"gtk-wide-tabs": bool = true,

/// Custom CSS files to be loaded.
///
/// GTK CSS documentation can be found at the following links:
///
///   * https://docs.gtk.org/gtk4/css-overview.html - An overview of GTK CSS.
///   * https://docs.gtk.org/gtk4/css-properties.html - A comprehensive list
///     of supported CSS properties.
///
/// Launch Ghostty with `env GTK_DEBUG=interactive ghostty` to tweak Ghostty's
/// CSS in real time using the GTK Inspector. Errors in your CSS files would
/// also be reported in the terminal you started Ghostty from. See
/// https://developer.gnome.org/documentation/tools/inspector.html for more
/// information about the GTK Inspector.
///
/// This configuration can be repeated multiple times to load multiple files.
/// Prepend a ? character to the file path to suppress errors if the file does
/// not exist. If you want to include a file that begins with a literal ?
/// character, surround the file path in double quotes (").
/// The file size limit for a single stylesheet is 5MiB.
///
/// Available since: 1.1.0
@"gtk-custom-css": RepeatablePath = .{},

/// If `true` (default), applications running in the terminal can show desktop
/// notifications using certain escape sequences such as OSC 9 or OSC 777.
@"desktop-notifications": bool = true,

/// Modifies the color used for bold text in the terminal.
///
/// This can be set to a specific color, using the same format as
/// `background` or `foreground` (e.g. `#RRGGBB` but other formats
/// are also supported; see the aforementioned documentation). If a
/// specific color is set, this color will always be used for the default
/// bold text color. It will set the rest of the bold colors to `bright`.
///
/// This can also be set to `bright`, which uses the bright color palette
/// for bold text. For example, if the text is red, then the bold will
/// use the bright red color. The terminal palette is set with `palette`
/// but can also be overridden by the terminal application itself using
/// escape sequences such as OSC 4. (Since Ghostty 1.2.0, the previous
/// configuration `bold-is-bright` is deprecated and replaced by this
/// usage).
///
/// Available since Ghostty 1.2.0.
@"bold-color": ?BoldColor = null,

/// The opacity level (opposite of transparency) of the faint text. A value of
/// 1 is fully opaque and a value of 0 is fully transparent. A value less than 0
/// or greater than 1 will be clamped to the nearest valid value.
///
/// Available since Ghostty 1.2.0.
@"faint-opacity": f64 = 0.5,

/// This will be used to set the `TERM` environment variable.
/// HACK: We set this with an `xterm` prefix because vim uses that to enable key
/// protocols (specifically this will enable `modifyOtherKeys`), among other
/// features. An option exists in vim to modify this: `:set
/// keyprotocol=ghostty:kitty`, however a bug in the implementation prevents it
/// from working properly. https://github.com/vim/vim/pull/13211 fixes this.
term: []const u8 = "xterm-ghostty",

/// String to send when we receive `ENQ` (`0x05`) from the command that we are
/// running. Defaults to an empty string if not set.
@"enquiry-response": []const u8 = "",

/// Configures the low-level API to use for async IO, eventing, etc.
///
/// Most users should leave this set to `auto`. This will automatically detect
/// scenarios where APIs may not be available (for example `io_uring` on
/// certain hardened kernels) and fall back to a different API. However, if
/// you want to force a specific backend for any reason, you can set this
/// here.
///
/// Based on various benchmarks, we haven't found a statistically significant
/// difference between the backends with regards to memory, CPU, or latency.
/// The choice of backend is more about compatibility and features.
///
/// Available options:
///
///   * `auto` - Automatically choose the best backend for the platform
///     based on available options.
///   * `epoll` - Use the `epoll` API
///   * `io_uring` - Use the `io_uring` API
///
/// If the selected backend is not available on the platform, Ghostty will
/// fall back to an automatically chosen backend that is available.
///
/// Changing this value requires a full application restart to take effect.
///
/// This is only supported on Linux, since this is the only platform
/// where we have multiple options. On macOS, we always use `kqueue`.
///
/// Available since: 1.2.0
@"async-backend": AsyncBackend = .auto,

/// Control the auto-update functionality of Ghostty. This is only supported
/// on macOS currently, since Linux builds are distributed via package
/// managers that are not centrally controlled by Ghostty.
///
/// Checking or downloading an update does not send any information to
/// the project beyond standard network information mandated by the
/// underlying protocols. To put it another way: Ghostty doesn't explicitly
/// add any tracking to the update process. The update process works by
/// downloading information about the latest version and comparing it
/// client-side to the current version.
///
/// Valid values are:
///
///  * `off` - Disable auto-updates.
///  * `check` - Check for updates and notify the user if an update is
///    available, but do not automatically download or install the update.
///  * `download` - Check for updates, automatically download the update,
///    notify the user, but do not automatically install the update.
///
/// If unset, we defer to Sparkle's default behavior, which respects the
/// preference stored in the standard user defaults (`defaults(1)`).
///
/// Changing this value at runtime works after a small delay.
@"auto-update": ?AutoUpdate = null,

/// The release channel to use for auto-updates.
///
/// The default value of this matches the release channel of the currently
/// running Ghostty version. If you download a pre-release version of Ghostty
/// then this will be set to `tip` and you will receive pre-release updates.
/// If you download a stable version of Ghostty then this will be set to
/// `stable` and you will receive stable updates.
///
/// Valid values are:
///
///  * `stable` - Stable, tagged releases such as "1.0.0".
///  * `tip` - Pre-release versions generated from each commit to the
///    main branch. This is the version that was in use during private
///    beta testing by thousands of people. It is generally stable but
///    will likely have more bugs than the stable channel.
///
/// Changing this configuration requires a full restart of
/// Ghostty to take effect.
///
/// This only works on macOS since only macOS has an auto-update feature.
@"auto-update-channel": ?build_config.ReleaseChannel = null,

/// This is set by the CLI parser for deinit.
_arena: ?ArenaAllocator = null,

/// List of diagnostics that were generated during the loading of
/// the configuration.
_diagnostics: cli.DiagnosticList = .{},

/// The conditional truths for the configuration. This is used to
/// determine if a conditional configuration matches or not.
_conditional_state: conditional.State = .{},

/// The conditional keys that are used at any point during the configuration
/// loading. This is used to speed up the conditional evaluation process.
_conditional_set: std.EnumSet(conditional.Key) = .{},

/// The steps we can use to reload the configuration after it has been loaded
/// without reopening the files. This is used in very specific cases such
/// as loadTheme which has more details on why.
_replay_steps: std.ArrayListUnmanaged(Replay.Step) = .{},

/// Set to true if Ghostty was executed as xdg-terminal-exec on Linux.
@"_xdg-terminal-exec": bool = false,

/// Record which settings have been changed from the default. We can't use an
/// std.EnumSet(Settings) because that would cause circular references. We'll
/// use an enum constructed in a separate step to index them by using the
/// backing integer.
_set: std.StaticBitSet(numberOfSettings) = .initEmpty(),

/// The number of settings in Config. This must be updated when new settings
/// are added/removed. The test below should keep us honest.
const numberOfSettings = 182;

// Ensure that the number of settings doesn't get out of sync.
test "check number of settings" {
    const info = @typeInfo(Config);
    var size: usize = 0;
    inline for (info.@"struct".fields) |field| {
        if (!std.mem.startsWith(u8, field.name, "_")) size += 1;
    }
    try std.testing.expectEqual(numberOfSettings, size);
}

/// Construct an enum with all of the non-"_"-prefixed fields in the config.
/// This will be used to index the bitset declared above using the backing
/// integer.
pub const Setting = setting: {
    @setEvalBranchQuota(5000);

    const info = @typeInfo(Config).@"struct";

    var count = 0;
    for (info.fields) |field| {
        if (!std.mem.startsWith(u8, field.name, "_")) count += 1;
    }

    assert(count == numberOfSettings);

    var fields: [count]std.builtin.Type.EnumField = undefined;
    var index = 0;
    for (info.fields) |field| {
        if (std.mem.startsWith(u8, field.name, "_")) continue;

        fields[index] = .{
            .name = field.name,
            .value = index,
        };
        index += 1;
    }

    break :setting @Type(
        .{
            .@"enum" = .{
                .tag_type = std.math.IntFittingRange(0, fields.len - 1),
                .fields = &fields,
                .decls = &.{},
                .is_exhaustive = true,
            },
        },
    );
};

/// Check to see if a particular setting has been changed from the default.
pub fn isSet(self: *const Config, setting: Setting) bool {
    return self._set.isSet(@intFromEnum(setting));
}

// By default all settings should be set to the default.
test "isSet" {
    var cfg: Config = .{};

    inline for (std.meta.fields(Setting)) |field| {
        try std.testing.expect(!cfg.isSet(@enumFromInt(field.value)));
    }
}

/// Mark a setting as having been changed from the default.
pub fn set(self: *Config, setting: Setting) void {
    self._set.set(@intFromEnum(setting));
}

/// Mark a setting as having been reset to the default.
pub fn unset(self: *Config, setting: Setting) void {
    self._set.unset(@intFromEnum(setting));
}

test "set/unset" {
    var cfg: Config = .{};

    inline for (std.meta.fields(Setting)) |field| {
        const setting: Setting = @enumFromInt(field.value);
        try std.testing.expect(!cfg.isSet(setting));
        cfg.set(setting);
        try std.testing.expect(cfg.isSet(setting));
        cfg.unset(setting);
        try std.testing.expect(!cfg.isSet(setting));
    }
    inline for (std.meta.fields(Setting)) |field| {
        try std.testing.expect(!cfg.isSet(@enumFromInt(field.value)));
    }
}

pub fn deinit(self: *Config) void {
    if (self._arena) |arena| arena.deinit();
    self.* = undefined;
}

/// Load the configuration according to the default rules:
///
///   1. Defaults
///   2. XDG config dir
///   3. "Application Support" directory (macOS only)
///   4. CLI flags
///   5. Recursively defined configuration files
///
pub fn load(alloc_gpa: Allocator) !Config {
    var result = try default(alloc_gpa);
    errdefer result.deinit();

    // If we have a configuration file in our home directory, parse that first.
    try result.loadDefaultFiles(alloc_gpa);

    // Parse the config from the CLI args.
    try result.loadCliArgs(alloc_gpa);

    // Parse the config files that were added from our file and CLI args.
    try result.loadRecursiveFiles(alloc_gpa);
    try result.finalize();

    return result;
}

pub fn default(alloc_gpa: Allocator) Allocator.Error!Config {
    // Build up our basic config
    var result: Config = .{
        ._arena = .init(alloc_gpa),
    };
    errdefer result.deinit();
    const alloc = result._arena.?.allocator();

    // Add our default keybindings
    try result.keybind.init(alloc);

    // Add our default command palette entries
    try result.@"command-palette-entry".init(alloc);

    // Add our default link for URL detection
    try result.link.links.append(alloc, .{
        .regex = url.regex,
        .action = .{ .open = {} },
        .highlight = .{ .hover_mods = inputpkg.ctrlOrSuper(.{}) },
    });

    return result;
}

/// Load configuration from an iterator that yields values that look like
/// command-line arguments, i.e. `--key=value`.
pub fn loadIter(
    self: *Config,
    alloc: Allocator,
    iter: anytype,
) !void {
    try cli.args.parse(Config, alloc, self, iter);
}

/// Load configuration from the target config file at `path`.
///
/// `path` must be resolved and absolute.
pub fn loadFile(self: *Config, alloc: Allocator, path: []const u8) !void {
    assert(std.fs.path.isAbsolute(path));
    var file = openFile(path) catch |err| switch (err) {
        error.NotAFile => {
            log.warn(
                "config-file {s}: not reading because it is not a file",
                .{path},
            );
            return;
        },

        else => return err,
    };
    defer file.close();

    std.log.info("reading configuration file path={s}", .{path});
    var buf_reader = std.io.bufferedReader(file.reader());
    const reader = buf_reader.reader();
    const Iter = cli.args.LineIterator(@TypeOf(reader));
    var iter: Iter = .{ .r = reader, .filepath = path };
    try self.loadIter(alloc, &iter);
    try self.expandPaths(std.fs.path.dirname(path).?);
}

pub const OptionalFileAction = enum { loaded, not_found, @"error" };

/// Load optional configuration file from `path`. All errors are ignored.
///
/// Returns the action that was taken.
pub fn loadOptionalFile(
    self: *Config,
    alloc: Allocator,
    path: []const u8,
) OptionalFileAction {
    if (self.loadFile(alloc, path)) {
        return .loaded;
    } else |err| switch (err) {
        error.FileNotFound => return .not_found,
        else => {
            std.log.warn(
                "error reading optional config file, not loading err={} path={s}",
                .{ err, path },
            );

            return .@"error";
        },
    }
}

fn writeConfigTemplate(path: []const u8) !void {
    log.info("creating template config file: path={s}", .{path});
    if (std.fs.path.dirname(path)) |dir_path| {
        try std.fs.makeDirAbsolute(dir_path);
    }
    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try std.fmt.format(
        file.writer(),
        @embedFile("./config-template"),
        .{ .path = path },
    );
}

/// Load configurations from the default configuration files. The default
/// configuration file is at `$XDG_CONFIG_HOME/ghostty/config`.
///
/// On macOS, `$HOME/Library/Application Support/$CFBundleIdentifier/config`
/// is also loaded.
pub fn loadDefaultFiles(self: *Config, alloc: Allocator) !void {
    // Load XDG first
    const xdg_path = try defaultXdgPath(alloc);
    defer alloc.free(xdg_path);
    const xdg_action = self.loadOptionalFile(alloc, xdg_path);

    // On macOS load the app support directory as well
    if (comptime builtin.os.tag == .macos) {
        const app_support_path = try defaultAppSupportPath(alloc);
        defer alloc.free(app_support_path);
        const app_support_action = self.loadOptionalFile(alloc, app_support_path);

        // If both files are not found, then we create a template file.
        // For macOS, we only create the template file in the app support
        if (app_support_action == .not_found and xdg_action == .not_found) {
            writeConfigTemplate(app_support_path) catch |err| {
                log.warn("error creating template config file err={}", .{err});
            };
        }
    } else {
        if (xdg_action == .not_found) {
            writeConfigTemplate(xdg_path) catch |err| {
                log.warn("error creating template config file err={}", .{err});
            };
        }
    }
}

/// Default path for the XDG home configuration file. Returned value
/// must be freed by the caller.
fn defaultXdgPath(alloc: Allocator) ![]const u8 {
    return try internal_os.xdg.config(
        alloc,
        .{ .subdir = "ghostty/config" },
    );
}

/// Default path for the macOS Application Support configuration file.
/// Returned value must be freed by the caller.
fn defaultAppSupportPath(alloc: Allocator) ![]const u8 {
    return try internal_os.macos.appSupportDir(alloc, "config");
}

/// Returns the path to the preferred default configuration file.
/// This is the file where users should place their configuration.
///
/// This doesn't create or populate the file with any default
/// contents; downstream callers must handle this.
///
/// The returned value must be freed by the caller.
pub fn preferredDefaultFilePath(alloc: Allocator) ![]const u8 {
    switch (builtin.os.tag) {
        .macos => {
            // macOS prefers the Application Support directory
            // if it exists.
            const app_support_path = try defaultAppSupportPath(alloc);
            if (openFile(app_support_path)) |f| {
                f.close();
                return app_support_path;
            } else |_| {}

            // Try the XDG path if it exists
            const xdg_path = try defaultXdgPath(alloc);
            if (openFile(xdg_path)) |f| {
                f.close();
                alloc.free(app_support_path);
                return xdg_path;
            } else |_| {}
            defer alloc.free(xdg_path);

            // Neither exist, use app support
            return app_support_path;
        },

        // All other platforms use XDG only
        else => return try defaultXdgPath(alloc),
    }
}

const OpenFileError = error{
    FileNotFound,
    FileIsEmpty,
    FileOpenFailed,
    NotAFile,
};

/// Opens the file at the given path and returns the file handle
/// if it exists and is non-empty. This also constrains the possible
/// errors to a smaller set that we can explicitly handle.
fn openFile(path: []const u8) OpenFileError!std.fs.File {
    assert(std.fs.path.isAbsolute(path));

    var file = std.fs.openFileAbsolute(
        path,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return OpenFileError.FileNotFound,
        else => {
            log.warn("unexpected file open error path={s} err={}", .{
                path,
                err,
            });
            return OpenFileError.FileOpenFailed;
        },
    };
    errdefer file.close();

    const stat = file.stat() catch |err| {
        log.warn("error getting file stat path={s} err={}", .{
            path,
            err,
        });
        return OpenFileError.FileOpenFailed;
    };
    switch (stat.kind) {
        .file => {},
        else => return OpenFileError.NotAFile,
    }

    if (stat.size == 0) return OpenFileError.FileIsEmpty;

    return file;
}

/// Load and parse the CLI args.
pub fn loadCliArgs(self: *Config, alloc_gpa: Allocator) !void {
    switch (builtin.os.tag) {
        .windows => {},

        // Fast-path if we are Linux/BSD and have no args.
        .linux, .freebsd => if (std.os.argv.len <= 1) return,

        // Everything else we have to at least try because it may
        // not use std.os.argv.
        else => {},
    }

    // On Linux, we have a special case where if the executing
    // program is "xdg-terminal-exec" then we treat all CLI
    // args as if they are a command to execute.
    //
    // In this mode, we also behave slightly differently:
    //
    //   - The initial window title is set to the full command. This
    //     can be used with window managers to modify positioning,
    //     styling, etc. based on the command.
    //
    // See: https://github.com/Vladimir-csp/xdg-terminal-exec
    if ((comptime builtin.os.tag == .linux) or (comptime builtin.os.tag == .freebsd)) {
        if (internal_os.xdg.parseTerminalExec(std.os.argv)) |args| {
            const arena_alloc = self._arena.?.allocator();

            // First, we add an artificial "-e" so that if we
            // replay the inputs to rebuild the config (i.e. if
            // a theme is set) then we will get the same behavior.
            try self._replay_steps.append(arena_alloc, .@"-e");

            // Next, take all remaining args and use that to build up
            // a command to execute.
            var builder = std.ArrayList([:0]const u8).init(arena_alloc);
            errdefer builder.deinit();
            for (args) |arg_raw| {
                const arg = std.mem.sliceTo(arg_raw, 0);
                const copy = try arena_alloc.dupeZ(u8, arg);
                try self._replay_steps.append(arena_alloc, .{ .arg = copy });
                try builder.append(copy);
            }

            self.@"_xdg-terminal-exec" = true;
            self.@"initial-command" = .{ .direct = try builder.toOwnedSlice() };
            return;
        }
    }

    // We set config-default-files to true here because this
    // should always be reset so we can detect if it is set
    // in the CLI since it is documented as having no affect
    // from files.
    self.@"config-default-files" = true;

    // Keep track of the replay steps up to this point so we
    // can replay if we are discarding the default files.
    const replay_len_start = self._replay_steps.items.len;

    // font-family settings set via the CLI overwrite any prior values
    // rather than append. This avoids a UX oddity where you have to
    // specify `font-family=""` to clear the font families.
    const fields = &[_][]const u8{
        "font-family",
        "font-family-bold",
        "font-family-italic",
        "font-family-bold-italic",
    };
    inline for (fields) |field| @field(self, field).overwrite_next = true;
    defer {
        inline for (fields) |field| @field(self, field).overwrite_next = false;
    }

    // Initialize our CLI iterator.
    var iter = try cli.args.argsIterator(alloc_gpa);
    defer iter.deinit();
    try self.loadIter(alloc_gpa, &iter);

    // If we are not loading the default files, then we need to
    // replay the steps up to this point so that we can rebuild
    // the config without it.
    if (!self.@"config-default-files") reload: {
        const replay_len_end = self._replay_steps.items.len;
        if (replay_len_end == replay_len_start) break :reload;
        log.info("config-default-files unset, discarding configuration from default files", .{});

        var new_config = try self.cloneEmpty(alloc_gpa);
        errdefer new_config.deinit();
        var it = Replay.iterator(
            self._replay_steps.items[replay_len_start..replay_len_end],
            &new_config,
        );
        try new_config.loadIter(alloc_gpa, &it);
        self.deinit();
        self.* = new_config;
    }

    // Any paths referenced from the CLI are relative to the current working
    // directory.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try self.expandPaths(try std.fs.cwd().realpath(".", &buf));
}

/// Load and parse the config files that were added in the "config-file" key.
pub fn loadRecursiveFiles(self: *Config, alloc_gpa: Allocator) !void {
    if (self.@"config-file".value.items.len == 0) return;
    const arena_alloc = self._arena.?.allocator();

    // Keeps track of loaded files to prevent cycles.
    var loaded = std.StringHashMap(void).init(alloc_gpa);
    defer loaded.deinit();

    // We need to insert all of our loaded config-file values
    // PRIOR to the "-e" in our replay steps, since everything
    // after "-e" becomes an "initial-command". To do this, we
    // dupe the values if we find it.
    var replay_suffix = std.ArrayList(Replay.Step).init(alloc_gpa);
    defer replay_suffix.deinit();
    for (self._replay_steps.items, 0..) |step, i| if (step == .@"-e") {
        // We don't need to clone the steps because they should
        // all be allocated in our arena and we're keeping our
        // arena.
        try replay_suffix.appendSlice(self._replay_steps.items[i..]);

        // Remove our old values. Again, don't need to free any
        // memory here because its all part of our arena.
        self._replay_steps.shrinkRetainingCapacity(i);
        break;
    };

    // We must use a while below and not a for(items) because we
    // may add items to the list while iterating for recursive
    // config-file entries.
    var i: usize = 0;
    while (i < self.@"config-file".value.items.len) : (i += 1) {
        const path, const optional = switch (self.@"config-file".value.items[i]) {
            .optional => |path| .{ path, true },
            .required => |path| .{ path, false },
        };

        // Error paths
        if (path.len == 0) continue;

        // All paths should already be absolute at this point because
        // they're fixed up after each load.
        assert(std.fs.path.isAbsolute(path));

        // We must only load a unique file once
        if (try loaded.fetchPut(path, {}) != null) {
            const diag: cli.Diagnostic = .{
                .message = try std.fmt.allocPrintZ(
                    arena_alloc,
                    "config-file {s}: cycle detected",
                    .{path},
                ),
            };

            try self._diagnostics.append(arena_alloc, diag);
            try self._replay_steps.append(arena_alloc, .{ .diagnostic = diag });
            continue;
        }

        var file = std.fs.openFileAbsolute(path, .{}) catch |err| {
            if (err != error.FileNotFound or !optional) {
                const diag: cli.Diagnostic = .{
                    .message = try std.fmt.allocPrintZ(
                        arena_alloc,
                        "error opening config-file {s}: {}",
                        .{ path, err },
                    ),
                };

                try self._diagnostics.append(arena_alloc, diag);
                try self._replay_steps.append(arena_alloc, .{ .diagnostic = diag });
            }
            continue;
        };
        defer file.close();

        const stat = try file.stat();
        switch (stat.kind) {
            .file => {},
            else => |kind| {
                const diag: cli.Diagnostic = .{
                    .message = try std.fmt.allocPrintZ(
                        arena_alloc,
                        "config-file {s}: not reading because file type is {s}",
                        .{ path, @tagName(kind) },
                    ),
                };

                try self._diagnostics.append(arena_alloc, diag);
                try self._replay_steps.append(arena_alloc, .{ .diagnostic = diag });
                continue;
            },
        }

        log.info("loading config-file path={s}", .{path});
        var buf_reader = std.io.bufferedReader(file.reader());
        const reader = buf_reader.reader();
        const Iter = cli.args.LineIterator(@TypeOf(reader));
        var iter: Iter = .{ .r = reader, .filepath = path };
        try self.loadIter(alloc_gpa, &iter);
        try self.expandPaths(std.fs.path.dirname(path).?);
    }

    // If we have a suffix, add that back.
    if (replay_suffix.items.len > 0) {
        try self._replay_steps.appendSlice(
            arena_alloc,
            replay_suffix.items,
        );
    }
}

/// Get the arena allocator associated with the configuration.
pub fn arenaAlloc(self: *Config) Allocator {
    return self._arena.?.allocator();
}

/// Change the state of conditionals and reload the configuration
/// based on the new state. This returns a new configuration based
/// on the new state. The caller must free the old configuration if they
/// wish.
///
/// This returns null if the conditional state would result in no changes
/// to the configuration. In this case, the caller can continue to use
/// the existing configuration or clone if they want a copy.
///
/// This doesn't re-read any files, it just re-applies the same
/// configuration with the new conditional state. Importantly, this means
/// that if you change the conditional state and the user in the interim
/// deleted a file that was referenced in the configuration, then the
/// configuration can still be reloaded.
pub fn changeConditionalState(
    self: *const Config,
    new: conditional.State,
) !?Config {
    // If the conditional state between the old and new is the same,
    // then we don't need to do anything.
    relevant: {
        inline for (@typeInfo(conditional.Key).@"enum".fields) |field| {
            const key: conditional.Key = @field(conditional.Key, field.name);

            // Conditional set contains the keys that this config uses. So we
            // only continue if we use this key.
            if (self._conditional_set.contains(key) and !equalField(
                @TypeOf(@field(self._conditional_state, field.name)),
                @field(self._conditional_state, field.name),
                @field(new, field.name),
            )) {
                break :relevant;
            }
        }

        // If we got here, then we didn't find any differences between
        // the old and new conditional state that would affect the
        // configuration.
        return null;
    }

    // Create our new configuration
    const alloc_gpa = self._arena.?.child_allocator;
    var new_config = try self.cloneEmpty(alloc_gpa);
    errdefer new_config.deinit();

    // Set our conditional state so the replay below can use it
    new_config._conditional_state = new;

    // Replay all of our steps to rebuild the configuration
    var it = Replay.iterator(self._replay_steps.items, &new_config);
    try new_config.loadIter(alloc_gpa, &it);
    try new_config.finalize();

    return new_config;
}

/// Expand the relative paths in config-files to be absolute paths
/// relative to the base directory.
fn expandPaths(self: *Config, base: []const u8) !void {
    const arena_alloc = self._arena.?.allocator();

    // Keep track of this step for replays
    try self._replay_steps.append(
        arena_alloc,
        .{ .expand = try arena_alloc.dupe(u8, base) },
    );

    // Expand all of our paths
    inline for (@typeInfo(Config).@"struct".fields) |field| {
        switch (field.type) {
            RepeatablePath, Path => {
                try @field(self, field.name).expand(
                    arena_alloc,
                    base,
                    &self._diagnostics,
                );
            },
            ?RepeatablePath, ?Path => {
                if (@field(self, field.name)) |*path| {
                    try path.expand(
                        arena_alloc,
                        base,
                        &self._diagnostics,
                    );
                }
            },
            else => {},
        }
    }
}

fn loadTheme(self: *Config, theme: Theme) !void {
    // Load the correct theme depending on the conditional state.
    // Dark/light themes were programmed prior to conditional configuration
    // so when we introduce that we probably want to replace this.
    const name: []const u8 = switch (self._conditional_state.theme) {
        .light => theme.light,
        .dark => theme.dark,
    };

    // Find our theme file and open it. See the open function for details.
    const themefile = (try themepkg.open(
        self._arena.?.allocator(),
        name,
        &self._diagnostics,
    )) orelse return;
    const path = themefile.path;
    const file = themefile.file;
    defer file.close();

    // From this point onwards, we load the theme and do a bit of a dance
    // to achieve two separate goals:
    //
    //   (1) We want the theme to be loaded and our existing config to
    //       override the theme. So we need to load the theme and apply
    //       our config on top of it.
    //
    //   (2) We want to free existing memory that we aren't using anymore
    //       as a result of reloading the configuration.
    //
    // Point 2 is strictly a result of aur approach to point 1, but it is
    // a nice property to have to limit memory bloat as much as possible.

    // Load into a new configuration so that we can free the existing memory.
    const alloc_gpa = self._arena.?.child_allocator;
    var new_config = try self.cloneEmpty(alloc_gpa);
    errdefer new_config.deinit();

    // Load our theme
    var buf_reader = std.io.bufferedReader(file.reader());
    const reader = buf_reader.reader();
    const Iter = cli.args.LineIterator(@TypeOf(reader));
    var iter: Iter = .{ .r = reader, .filepath = path };
    try new_config.loadIter(alloc_gpa, &iter);

    // Setup our replay to be conditional.
    conditional: for (new_config._replay_steps.items) |*item| {
        switch (item.*) {
            .expand, .diagnostic => {},

            // If we see "-e" then we do NOT make the following arguments
            // conditional since they are supposed to be part of the
            // initial command.
            .@"-e" => break :conditional,

            // Change our arg to be conditional on our theme.
            .arg => |v| {
                const alloc_arena = new_config._arena.?.allocator();
                const conds = try alloc_arena.alloc(Conditional, 1);
                conds[0] = .{
                    .key = .theme,
                    .op = .eq,
                    .value = @tagName(self._conditional_state.theme),
                };
                item.* = .{ .conditional_arg = .{
                    .conditions = conds,
                    .arg = v,
                } };
            },

            .conditional_arg => |v| {
                const alloc_arena = new_config._arena.?.allocator();
                const conds = try alloc_arena.alloc(Conditional, v.conditions.len + 1);
                conds[0] = .{
                    .key = .theme,
                    .op = .eq,
                    .value = @tagName(self._conditional_state.theme),
                };
                @memcpy(conds[1..], v.conditions);
                item.* = .{ .conditional_arg = .{
                    .conditions = conds,
                    .arg = v.arg,
                } };
            },
        }
    }

    // Replay our previous inputs so that we can override values
    // from the theme.
    var slice_it = Replay.iterator(self._replay_steps.items, &new_config);
    try new_config.loadIter(alloc_gpa, &slice_it);

    // Success, swap our new config in and free the old.
    self.deinit();
    self.* = new_config;
}

/// Call this once after you are done setting configuration. This
/// is idempotent but will waste memory if called multiple times.
pub fn finalize(self: *Config) !void {
    // We always load the theme first because it may set other fields
    // in our config.
    if (self.theme) |theme| {
        const different = !std.mem.eql(u8, theme.light, theme.dark);

        // Warning: loadTheme will deinit our existing config and replace
        // it so all memory from self prior to this point will be freed.
        try self.loadTheme(theme);

        // If we have different light vs dark mode themes, disable
        // window-theme = auto since that breaks it.
        if (different) {
            // This setting doesn't make sense with different light/dark themes
            // because it'll force the theme based on the Ghostty theme.
            if (self.@"window-theme" == .auto) self.@"window-theme" = .system;

            // Mark that we use a conditional theme
            self._conditional_set.insert(.theme);
        }
    }

    const alloc = self._arena.?.allocator();

    // Used for a variety of defaults. See the function docs as well the
    // specific variable use sites for more details.
    const probable_cli = probableCliEnvironment();

    // If we have a font-family set and don't set the others, default
    // the others to the font family. This way, if someone does
    // --font-family=foo, then we try to get the stylized versions of
    // "foo" as well.
    if (self.@"font-family".count() > 0) {
        const fields = &[_][]const u8{
            "font-family-bold",
            "font-family-italic",
            "font-family-bold-italic",
        };
        inline for (fields) |field| {
            if (@field(self, field).count() == 0) {
                @field(self, field) = try self.@"font-family".clone(alloc);
            }
        }
    }

    // Prevent setting TERM to an empty string
    if (self.term.len == 0) {
        // HACK: See comment above at definition
        self.term = "xterm-ghostty";
    }

    // The default for the working directory depends on the system.
    const wd = self.@"working-directory" orelse if (probable_cli)
        // From the CLI, we want to inherit where we were launched from.
        "inherit"
    else
        // Otherwise we typically just want the home directory because
        // our pwd is probably a runtime state dir or root or something
        // (launchers and desktop environments typically do this).
        "home";

    // If we are missing either a command or home directory, we need
    // to look up defaults which is kind of expensive. We only do this
    // on desktop.
    const wd_home = std.mem.eql(u8, "home", wd);
    if ((comptime !builtin.target.cpu.arch.isWasm()) and
        (comptime !builtin.is_test))
    {
        if (self.command == null or wd_home) command: {
            // First look up the command using the SHELL env var if needed.
            // We don't do this in flatpak because SHELL in Flatpak is always
            // set to /bin/sh.
            if (self.command) |cmd|
                log.info("shell src=config value={}", .{cmd})
            else shell_env: {
                // Flatpak always gets its shell from outside the sandbox
                if (internal_os.isFlatpak()) break :shell_env;

                // If we were launched from the desktop, our SHELL env var
                // will represent our SHELL at login time. We only want to
                // read from SHELL if we're in a probable CLI environment.
                if (!probable_cli) break :shell_env;

                if (std.process.getEnvVarOwned(alloc, "SHELL")) |value| {
                    log.info("default shell source=env value={s}", .{value});

                    const copy = try alloc.dupeZ(u8, value);
                    self.command = .{ .shell = copy };

                    // If we don't need the working directory, then we can exit now.
                    if (!wd_home) break :command;
                } else |_| {}
            }

            switch (builtin.os.tag) {
                .windows => {
                    if (self.command == null) {
                        log.warn("no default shell found, will default to using cmd", .{});
                        self.command = .{ .shell = "cmd.exe" };
                    }

                    if (wd_home) {
                        var buf: [std.fs.max_path_bytes]u8 = undefined;
                        if (try internal_os.home(&buf)) |home| {
                            self.@"working-directory" = try alloc.dupe(u8, home);
                        }
                    }
                },

                else => {
                    // We need the passwd entry for the remainder
                    const pw = try internal_os.passwd.get(alloc);
                    if (self.command == null) {
                        if (pw.shell) |sh| {
                            log.info("default shell src=passwd value={s}", .{sh});
                            self.command = .{ .shell = sh };
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
                },
            }
        }
    }

    // Apprt-specific defaults
    switch (build_config.app_runtime) {
        .none => {},
        .gtk => {
            switch (self.@"gtk-single-instance") {
                .true, .false => {},

                // For detection, we assume single instance unless we're
                // in a CLI environment, then we disable single instance.
                .detect => self.@"gtk-single-instance" = if (probable_cli)
                    .false
                else
                    .true,
            }
        },
    }

    // If we have the special value "inherit" then set it to null which
    // does the same. In the future we should change to a tagged union.
    if (std.mem.eql(u8, wd, "inherit")) self.@"working-directory" = null;

    // Default our click interval
    if (self.@"click-repeat-interval" == 0 and
        (comptime !builtin.is_test))
    {
        self.@"click-repeat-interval" = internal_os.clickInterval() orelse 500;
    }

    // Clamp our mouse scroll multiplier
    self.@"mouse-scroll-multiplier" = @min(10_000.0, @max(0.01, self.@"mouse-scroll-multiplier"));

    // Clamp our split opacity
    self.@"unfocused-split-opacity" = @min(1.0, @max(0.15, self.@"unfocused-split-opacity"));

    // Clamp our contrast
    self.@"minimum-contrast" = @min(21, @max(1, self.@"minimum-contrast"));

    // Minimmum window size
    if (self.@"window-width" > 0) self.@"window-width" = @max(10, self.@"window-width");
    if (self.@"window-height" > 0) self.@"window-height" = @max(4, self.@"window-height");

    // If URLs are disabled, cut off the first link. The first link is
    // always the URL matcher.
    if (!self.@"link-url") self.link.links.items = self.link.links.items[1..];

    // We warn when the quit-after-last-window-closed-delay is set to a very
    // short value because it can cause Ghostty to quit before the first
    // window is even shown.
    if (self.@"quit-after-last-window-closed-delay") |duration| {
        if (duration.duration < 5 * std.time.ns_per_s) {
            log.warn(
                "quit-after-last-window-closed-delay is set to a very short value ({}), which might cause problems",
                .{duration},
            );
        }
    }

    // We can't set this as a struct default because our config is
    // loaded in environments where a build config isn't available.
    if (self.@"auto-update-channel" == null) {
        self.@"auto-update-channel" = build_config.release_channel;
    }

    self.@"faint-opacity" = std.math.clamp(self.@"faint-opacity", 0.0, 1.0);
}

/// Callback for src/cli/args.zig to allow us to handle special cases
/// like `--help` or `-e`. Returns "false" if the CLI parsing should halt.
pub fn parseManuallyHook(
    self: *Config,
    alloc: Allocator,
    arg: []const u8,
    iter: anytype,
) !bool {
    if (std.mem.eql(u8, arg, "-e")) {
        // Add the special -e marker. This prevents:
        // (1) config-file from adding args to the end (see #2908)
        // (2) dark/light theme from making this conditional
        try self._replay_steps.append(alloc, .@"-e");

        // Build up the command. We don't clean this up because we take
        // ownership in our allocator.
        var command: std.ArrayList([:0]const u8) = .init(alloc);
        errdefer command.deinit();

        while (iter.next()) |param| {
            const copy = try alloc.dupeZ(u8, param);
            try self._replay_steps.append(alloc, .{ .arg = copy });
            try command.append(copy);
        }

        if (command.items.len == 0) {
            try self._diagnostics.append(alloc, .{
                .location = try cli.Location.fromIter(iter, alloc),
                .message = try std.fmt.allocPrintZ(
                    alloc,
                    "missing command after {s}",
                    .{arg},
                ),
            });

            return false;
        }

        // See "command" docs for the implied configurations and why.
        self.@"initial-command" = .{ .direct = command.items };
        self.@"gtk-single-instance" = .false;
        self.@"quit-after-last-window-closed" = true;
        self.@"quit-after-last-window-closed-delay" = null;
        if (self.@"shell-integration" != .none) {
            self.@"shell-integration" = .detect;
        }

        // Do not continue, we consumed everything.
        return false;
    }

    // Keep track of our input args for replay
    try self._replay_steps.append(
        alloc,
        .{ .arg = try alloc.dupeZ(u8, arg) },
    );

    // If we didn't find a special case, continue parsing normally
    return true;
}

fn compatGtkTabsLocation(
    self: *Config,
    alloc: Allocator,
    key: []const u8,
    value: ?[]const u8,
) bool {
    _ = alloc;
    assert(std.mem.eql(u8, key, "gtk-tabs-location"));

    if (std.mem.eql(u8, value orelse "", "hidden")) {
        self.@"window-show-tab-bar" = .never;
        return true;
    }

    return false;
}

fn compatGtkSingleInstance(
    self: *Config,
    alloc: Allocator,
    key: []const u8,
    value: ?[]const u8,
) bool {
    _ = alloc;
    assert(std.mem.eql(u8, key, "gtk-single-instance"));

    if (std.mem.eql(u8, value orelse "", "desktop")) {
        self.@"gtk-single-instance" = .detect;
        return true;
    }

    return false;
}

fn compatCursorInvertFgBg(
    self: *Config,
    alloc: Allocator,
    key: []const u8,
    value_: ?[]const u8,
) bool {
    _ = alloc;
    assert(std.mem.eql(u8, key, "cursor-invert-fg-bg"));

    // We don't do anything if the value is unset, which is technically
    // not EXACTLY the same as prior behavior since it would fallback
    // to doing whatever cursor-color/cursor-text were set to, but
    // I don't want to store what that is separately so this is close
    // enough.
    //
    // Realistically, these fields were mutually exclusive so anyone
    // relying on that behavior should just upgrade to the new
    // cursor-color/cursor-text fields.
    const isset = cli.args.parseBool(value_ orelse "t") catch return false;
    if (isset) {
        self.@"cursor-color" = .@"cell-foreground";
        self.@"cursor-text" = .@"cell-background";
    }

    return true;
}

fn compatSelectionInvertFgBg(
    self: *Config,
    alloc: Allocator,
    key: []const u8,
    value_: ?[]const u8,
) bool {
    _ = alloc;
    assert(std.mem.eql(u8, key, "selection-invert-fg-bg"));

    const isset = cli.args.parseBool(value_ orelse "t") catch return false;
    if (isset) {
        self.@"selection-foreground" = .@"cell-background";
        self.@"selection-background" = .@"cell-foreground";
    }

    return true;
}

fn compatBoldIsBright(
    self: *Config,
    alloc: Allocator,
    key: []const u8,
    value_: ?[]const u8,
) bool {
    _ = alloc;
    assert(std.mem.eql(u8, key, "bold-is-bright"));

    const isset = cli.args.parseBool(value_ orelse "t") catch return false;
    if (isset) {
        self.@"bold-color" = .bright;
    }

    return true;
}

/// Add a diagnostic message to the config with the given string.
/// This is always added with a location of "none".
pub fn addDiagnosticFmt(
    self: *Config,
    comptime fmt: []const u8,
    args: anytype,
) Allocator.Error!void {
    const alloc = self._arena.?.allocator();
    try self._diagnostics.append(alloc, .{
        .message = try std.fmt.allocPrintZ(
            alloc,
            fmt,
            args,
        ),
    });
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
    result._arena = .init(alloc_gpa);
    return result;
}

/// Create a copy of the metadata of this configuration but without
/// the actual values. Metadata includes conditional state.
pub fn cloneEmpty(
    self: *const Config,
    alloc_gpa: Allocator,
) Allocator.Error!Config {
    var result = try default(alloc_gpa);
    result._conditional_state = self._conditional_state;
    return result;
}

/// Create a copy of this configuration.
///
/// This will not re-read referenced configuration files and operates
/// purely in-memory.
pub fn clone(
    self: *const Config,
    alloc_gpa: Allocator,
) Allocator.Error!Config {
    // Start with an empty config
    var result = try self.cloneEmpty(alloc_gpa);
    errdefer result.deinit();
    const alloc_arena = result._arena.?.allocator();

    // Copy our values
    inline for (@typeInfo(Config).@"struct".fields) |field| {
        if (!@hasField(Key, field.name)) continue;
        @field(result, field.name) = try cloneValue(
            alloc_arena,
            field.type,
            @field(self, field.name),
        );
    }

    // Copy our diagnostics
    result._diagnostics = try self._diagnostics.clone(alloc_arena);

    // Preserve our replay steps. We copy them exactly to also preserve
    // the exact conditionals required for some steps.
    try result._replay_steps.ensureTotalCapacity(
        alloc_arena,
        self._replay_steps.items.len,
    );
    for (self._replay_steps.items) |item| {
        result._replay_steps.appendAssumeCapacity(
            try item.clone(alloc_arena),
        );
    }
    assert(result._replay_steps.items.len == self._replay_steps.items.len);

    // Copy the conditional set
    result._conditional_set = self._conditional_set;

    return result;
}

fn cloneValue(
    alloc: Allocator,
    comptime T: type,
    src: T,
) Allocator.Error!T {
    // Do known named types first
    switch (T) {
        []const u8 => return try alloc.dupe(u8, src),
        [:0]const u8 => return try alloc.dupeZ(u8, src),

        else => {},
    }

    // If we're a type that can have decls and we have clone, then
    // call clone and be done.
    const t = @typeInfo(T);
    if (t == .@"struct" or t == .@"enum" or t == .@"union") {
        if (@hasDecl(T, "clone")) return try src.clone(alloc);
    }

    // Back into types of types
    switch (t) {
        inline .bool,
        .int,
        .float,
        .@"enum",
        .@"union",
        => return src,

        .optional => |info| return try cloneValue(
            alloc,
            info.child,
            src orelse return null,
        ),

        .@"struct" => |info| {
            // Packed structs we can return directly as copies.
            assert(info.layout == .@"packed");
            return src;
        },

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

        []const [:0]const u8,
        => {
            if (old.len != new.len) return false;
            for (old, new) |a, b| {
                if (!std.mem.eql(u8, a, b)) return false;
            }

            return true;
        },

        else => {},
    }

    // Back into types of types
    switch (@typeInfo(T)) {
        .void => return true,

        inline .bool,
        .int,
        .float,
        .@"enum",
        => return old == new,

        .optional => |info| {
            if (old == null and new == null) return true;
            if (old == null or new == null) return false;
            return equalField(info.child, old.?, new.?);
        },

        .@"struct" => |info| {
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

        .@"union" => |info| {
            if (@hasDecl(T, "equal")) return old.equal(new);

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

/// This runs a heuristic to determine if we are likely running
/// Ghostty in a CLI environment. We need this to change some behaviors.
/// We should keep the set of behaviors that depend on this as small
/// as possible because magic sucks, but each place is well documented.
fn probableCliEnvironment() bool {
    switch (builtin.os.tag) {
        // Windows has its own problems, just ignore it for now since
        // its not a real supported target and GTK via WSL2 assuming
        // single instance is probably fine.
        .windows => return false,

        // On macOS, we don't want to detect `open` calls as CLI envs.
        // Our desktop detection on macOS is very accurate due to how
        // processes are launched on macOS, so if we detect we're launched
        // from the app bundle then we're not in a CLI environment.
        .macos => if (internal_os.launchedFromDesktop()) return false,

        else => {},
    }

    // If we have TERM_PROGRAM set to a non-empty value, we assume
    // a graphical terminal environment.
    if (std.posix.getenv("TERM_PROGRAM")) |v| {
        if (v.len > 0) return true;
    }

    // CLI arguments makes things probable
    if (std.os.argv.len > 1) return true;

    // Unlikely CLI environment
    return false;
}

/// This is used to "replay" the configuration. See loadTheme for details.
const Replay = struct {
    const Step = union(enum) {
        /// An argument to parse as if it came from the CLI or file.
        arg: [:0]const u8,

        /// A base path to expand relative paths against.
        expand: []const u8,

        /// A conditional argument. This arg is parsed only if all
        /// conditions match (an "AND"). An "OR" can be achieved by
        /// having multiple conditional arg entries.
        conditional_arg: struct {
            conditions: []const Conditional,
            arg: []const u8,
        },

        /// A diagnostic to be added to the new configuration when
        /// replayed. This should only be used for diagnostics that won't
        /// be reproduced during playback. For example, `config-file`
        /// errors are not reloaded so they should be added here.
        ///
        /// Diagnostics cannot be conditional. They are always present
        /// even if the conditionals don't match. This helps users find
        /// errors in their configuration.
        diagnostic: cli.Diagnostic,

        /// The start of a "-e" argument. This marks the end of
        /// traditional configuration and the beginning of the
        /// "-e" initial command magic. This is separate from "arg"
        /// because there are some behaviors unique to this (i.e.
        /// we want to keep this at the end for config-file).
        ///
        /// Note: when "-e" is used, ONLY this is present and
        /// not an additional "arg" with "-e" value.
        @"-e",

        fn clone(
            self: Step,
            alloc: Allocator,
        ) Allocator.Error!Step {
            return switch (self) {
                .@"-e" => self,
                .diagnostic => |v| .{ .diagnostic = try v.clone(alloc) },
                .arg => |v| .{ .arg = try alloc.dupeZ(u8, v) },
                .expand => |v| .{ .expand = try alloc.dupe(u8, v) },
                .conditional_arg => |v| conditional: {
                    var conds = try alloc.alloc(Conditional, v.conditions.len);
                    for (v.conditions, 0..) |cond, i| conds[i] = try cond.clone(alloc);
                    break :conditional .{ .conditional_arg = .{
                        .conditions = conds,
                        .arg = try alloc.dupe(u8, v.arg),
                    } };
                },
            };
        }
    };

    const Iterator = struct {
        const Self = @This();

        config: *Config,
        slice: []const Replay.Step,
        idx: usize = 0,

        pub fn next(self: *Self) ?[]const u8 {
            while (true) {
                if (self.idx >= self.slice.len) return null;
                defer self.idx += 1;
                switch (self.slice[self.idx]) {
                    .expand => |base| self.config.expandPaths(base) catch |err| {
                        // This shouldn't happen because to reach this step
                        // means that it succeeded before. Its possible since
                        // expanding paths is a side effect process that the
                        // world state changed and we can't expand anymore.
                        // In that really unfortunate case, we log a warning.
                        log.warn("error expanding paths err={}", .{err});
                    },

                    .diagnostic => |diag| diag: {
                        // Best effort to clone and append the diagnostic.
                        // If it fails we log a warning and continue.
                        const arena_alloc = self.config._arena.?.allocator();
                        const cloned = diag.clone(arena_alloc) catch |err| {
                            log.warn("error cloning diagnostic err={}", .{err});
                            break :diag;
                        };
                        self.config._diagnostics.append(arena_alloc, cloned) catch |err| {
                            log.warn("error appending diagnostic err={}", .{err});
                            break :diag;
                        };
                    },

                    .conditional_arg => |v| conditional: {
                        // All conditions must match.
                        for (v.conditions) |cond| {
                            if (!self.config._conditional_state.match(cond)) {
                                break :conditional;
                            }
                        }

                        return v.arg;
                    },

                    .arg => |arg| return arg,
                    .@"-e" => return "-e",
                }
            }
        }
    };

    /// Construct a Replay iterator from a slice of replay elements.
    /// This can be used with args.parse and handles intermediate
    /// steps such as expanding relative paths.
    fn iterator(slice: []const Replay.Step, dst: *Config) Iterator {
        return .{ .slice = slice, .config = dst };
    }
};

/// Valid values for confirm-close-surface
/// c_int because it needs to be extern compatible
/// If this is changed, you must also update ghostty.h
pub const ConfirmCloseSurface = enum(c_int) {
    false,
    true,
    always,
};

/// Valid values for custom-shader-animation
/// c_int because it needs to be extern compatible
/// If this is changed, you must also update ghostty.h
pub const CustomShaderAnimation = enum(c_int) {
    false,
    true,
    always,
};

/// Valid values for macos-non-native-fullscreen
/// c_int because it needs to be extern compatible
/// If this is changed, you must also update ghostty.h
pub const NonNativeFullscreen = enum(c_int) {
    false,
    true,
    @"visible-menu",
    @"padded-notch",
};

/// Valid values for macos-option-as-alt.
pub const OptionAsAlt = enum {
    false,
    true,
    left,
    right,
};

pub const WindowPaddingColor = enum {
    background,
    extend,
    @"extend-always",
};

pub const WindowSubtitle = enum {
    false,
    @"working-directory",
};

pub const LinkPreviews = enum {
    false,
    true,
    osc8,
};

/// Color represents a color using RGB.
///
/// This is a packed struct so that the C API to read color values just
/// works by setting it to a C integer.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    /// ghostty_config_color_s
    pub const C = extern struct {
        r: u8,
        g: u8,
        b: u8,
    };

    pub fn cval(self: Color) Color.C {
        return .{ .r = self.r, .g = self.g, .b = self.b };
    }

    /// Convert this to the terminal RGB struct
    pub fn toTerminalRGB(self: Color) terminal.color.RGB {
        return .{ .r = self.r, .g = self.g, .b = self.b };
    }

    pub fn parseCLI(input_: ?[]const u8) !Color {
        const input = input_ orelse return error.ValueRequired;
        // Trim any whitespace before processing
        const trimmed = std.mem.trim(u8, input, " \t");

        if (terminal.x11_color.map.get(trimmed)) |rgb| return .{
            .r = rgb.r,
            .g = rgb.g,
            .b = rgb.b,
        };

        return fromHex(trimmed);
    }

    /// Deep copy of the struct. Required by Config.
    pub fn clone(self: Color, _: Allocator) error{}!Color {
        return self;
    }

    /// Compare if two of our value are requal. Required by Config.
    pub fn equal(self: Color, other: Color) bool {
        return std.meta.eql(self, other);
    }

    /// Used by Formatter
    pub fn formatEntry(self: Color, formatter: anytype) !void {
        var buf: [128]u8 = undefined;
        try formatter.formatEntry(
            []const u8,
            try self.formatBuf(&buf),
        );
    }

    /// Format the color as a string.
    pub fn formatBuf(self: Color, buf: []u8) Allocator.Error![]const u8 {
        return std.fmt.bufPrint(
            buf,
            "#{x:0>2}{x:0>2}{x:0>2}",
            .{ self.r, self.g, self.b },
        ) catch error.OutOfMemory;
    }

    /// fromHex parses a color from a hex value such as #RRGGBB. The "#"
    /// is optional.
    pub fn fromHex(input: []const u8) !Color {
        // Trim the beginning '#' if it exists
        const trimmed = if (input.len != 0 and input[0] == '#') input[1..] else input;
        if (trimmed.len != 6 and trimmed.len != 3) return error.InvalidValue;

        // Expand short hex values to full hex values
        const rgb: []const u8 = if (trimmed.len == 3) &.{
            trimmed[0], trimmed[0],
            trimmed[1], trimmed[1],
            trimmed[2], trimmed[2],
        } else trimmed;

        // Parse the colors two at a time.
        var result: Color = undefined;
        comptime var i: usize = 0;
        inline while (i < 6) : (i += 2) {
            const v: u8 =
                ((try std.fmt.charToDigit(rgb[i], 16)) * 16) +
                try std.fmt.charToDigit(rgb[i + 1], 16);

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
        try testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255 }, try Color.fromHex("FFF"));
        try testing.expectEqual(Color{ .r = 51, .g = 68, .b = 85 }, try Color.fromHex("#345"));
    }

    test "parseCLI from name" {
        try std.testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0 }, try Color.parseCLI("black"));
    }

    test "formatConfig" {
        const testing = std.testing;
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        var color: Color = .{ .r = 10, .g = 11, .b = 12 };
        try color.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
        try std.testing.expectEqualSlices(u8, "a = #0a0b0c\n", buf.items);
    }

    test "parseCLI with whitespace" {
        const testing = std.testing;
        try testing.expectEqual(
            Color{ .r = 0xAA, .g = 0xBB, .b = 0xCC },
            try Color.parseCLI(" #AABBCC   "),
        );
        try testing.expectEqual(
            Color{ .r = 0, .g = 0, .b = 0 },
            try Color.parseCLI("  black "),
        );
    }
};

/// Represents color values that can also reference special color
/// values such as "cell-foreground" or "cell-background".
pub const TerminalColor = union(enum) {
    color: Color,
    @"cell-foreground",
    @"cell-background",

    pub fn parseCLI(input_: ?[]const u8) !TerminalColor {
        const input = input_ orelse return error.ValueRequired;
        if (std.mem.eql(u8, input, "cell-foreground")) return .@"cell-foreground";
        if (std.mem.eql(u8, input, "cell-background")) return .@"cell-background";
        return .{ .color = try Color.parseCLI(input) };
    }

    /// Used by Formatter
    pub fn formatEntry(self: TerminalColor, formatter: anytype) !void {
        switch (self) {
            .color => try self.color.formatEntry(formatter),

            .@"cell-foreground",
            .@"cell-background",
            => try formatter.formatEntry([:0]const u8, @tagName(self)),
        }
    }

    test "parseCLI" {
        const testing = std.testing;

        try testing.expectEqual(
            TerminalColor{ .color = Color{ .r = 78, .g = 42, .b = 132 } },
            try TerminalColor.parseCLI("#4e2a84"),
        );
        try testing.expectEqual(
            TerminalColor{ .color = Color{ .r = 0, .g = 0, .b = 0 } },
            try TerminalColor.parseCLI("black"),
        );
        try testing.expectEqual(
            TerminalColor.@"cell-foreground",
            try TerminalColor.parseCLI("cell-foreground"),
        );
        try testing.expectEqual(
            TerminalColor.@"cell-background",
            try TerminalColor.parseCLI("cell-background"),
        );

        try testing.expectError(error.InvalidValue, TerminalColor.parseCLI("a"));
    }

    test "formatConfig" {
        const testing = std.testing;
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        var sc: TerminalColor = .@"cell-foreground";
        try sc.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
        try testing.expectEqualSlices(u8, "a = cell-foreground\n", buf.items);
    }
};

/// Represents color values that can be used for bold. See `bold-color`.
pub const BoldColor = union(enum) {
    color: Color,
    bright,

    pub fn parseCLI(input_: ?[]const u8) !BoldColor {
        const input = input_ orelse return error.ValueRequired;
        if (std.mem.eql(u8, input, "bright")) return .bright;
        return .{ .color = try Color.parseCLI(input) };
    }

    /// Used by Formatter
    pub fn formatEntry(self: BoldColor, formatter: anytype) !void {
        switch (self) {
            .color => try self.color.formatEntry(formatter),
            .bright => try formatter.formatEntry(
                [:0]const u8,
                @tagName(self),
            ),
        }
    }

    test "parseCLI" {
        const testing = std.testing;

        try testing.expectEqual(
            BoldColor{ .color = Color{ .r = 78, .g = 42, .b = 132 } },
            try BoldColor.parseCLI("#4e2a84"),
        );
        try testing.expectEqual(
            BoldColor{ .color = Color{ .r = 0, .g = 0, .b = 0 } },
            try BoldColor.parseCLI("black"),
        );
        try testing.expectEqual(
            BoldColor.bright,
            try BoldColor.parseCLI("bright"),
        );

        try testing.expectError(error.InvalidValue, BoldColor.parseCLI("a"));
    }

    test "formatConfig" {
        const testing = std.testing;
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        var sc: BoldColor = .bright;
        try sc.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
        try testing.expectEqualSlices(u8, "a = bright\n", buf.items);
    }
};

pub const ColorList = struct {
    const Self = @This();

    colors: std.ArrayListUnmanaged(Color) = .{},
    colors_c: std.ArrayListUnmanaged(Color.C) = .{},

    /// ghostty_config_color_list_s
    pub const C = extern struct {
        colors: [*]Color.C,
        len: usize,
    };

    pub fn cval(self: *const Self) C {
        return .{
            .colors = self.colors_c.items.ptr,
            .len = self.colors_c.items.len,
        };
    }

    pub fn parseCLI(
        self: *Self,
        alloc: Allocator,
        input_: ?[]const u8,
    ) !void {
        const input = input_ orelse return error.ValueRequired;
        if (input.len == 0) return error.ValueRequired;

        // Always reset on parse
        self.* = .{};

        // Split the input by commas and parse each color
        var it = std.mem.tokenizeScalar(u8, input, ',');
        var count: usize = 0;
        while (it.next()) |raw| {
            count += 1;
            if (count > 64) return error.InvalidValue;

            // Trim whitespace from each color value
            const trimmed = std.mem.trim(u8, raw, " \t");
            const color = try Color.parseCLI(trimmed);
            try self.colors.append(alloc, color);
            try self.colors_c.append(alloc, color.cval());
        }

        // If no colors were parsed, we need to return an error
        if (self.colors.items.len == 0) return error.InvalidValue;

        assert(self.colors.items.len == self.colors_c.items.len);
    }

    pub fn clone(
        self: *const Self,
        alloc: Allocator,
    ) Allocator.Error!Self {
        return .{
            .colors = try self.colors.clone(alloc),
        };
    }

    /// Compare if two of our value are requal. Required by Config.
    pub fn equal(self: Self, other: Self) bool {
        const itemsA = self.colors.items;
        const itemsB = other.colors.items;
        if (itemsA.len != itemsB.len) return false;
        for (itemsA, itemsB) |a, b| {
            if (!a.equal(b)) return false;
        } else return true;
    }

    /// Used by Formatter
    pub fn formatEntry(
        self: Self,
        formatter: anytype,
    ) !void {
        // If no items, we want to render an empty field.
        if (self.colors.items.len == 0) {
            try formatter.formatEntry(void, {});
            return;
        }

        // Build up the value of our config. Our buffer size should be
        // sized to contain all possible maximum values.
        var buf: [1024]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        var writer = fbs.writer();
        for (self.colors.items, 0..) |color, i| {
            var color_buf: [128]u8 = undefined;
            const color_str = try color.formatBuf(&color_buf);
            if (i != 0) writer.writeByte(',') catch return error.OutOfMemory;
            writer.writeAll(color_str) catch return error.OutOfMemory;
        }

        try formatter.formatEntry(
            []const u8,
            fbs.getWritten(),
        );
    }

    test "parseCLI" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var p: Self = .{};
        try p.parseCLI(alloc, "black,white");
        try testing.expectEqual(2, p.colors.items.len);

        // Test whitespace handling
        try p.parseCLI(alloc, "black, white"); // space after comma
        try testing.expectEqual(2, p.colors.items.len);
        try p.parseCLI(alloc, "black , white"); // spaces around comma
        try testing.expectEqual(2, p.colors.items.len);
        try p.parseCLI(alloc, " black , white "); // extra spaces at ends
        try testing.expectEqual(2, p.colors.items.len);

        // Error cases
        try testing.expectError(error.ValueRequired, p.parseCLI(alloc, null));
        try testing.expectError(error.InvalidValue, p.parseCLI(alloc, " "));
    }

    test "format" {
        const testing = std.testing;
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var p: Self = .{};
        try p.parseCLI(alloc, "black,white");
        try p.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
        try std.testing.expectEqualSlices(u8, "a = #000000,#ffffff\n", buf.items);
    }
};

/// Palette is the 256 color palette for 256-color mode. This is still
/// used by many terminal applications.
pub const Palette = struct {
    const Self = @This();

    /// The actual value that is updated as we parse.
    value: terminal.color.Palette = terminal.color.default,

    /// ghostty_config_palette_s
    pub const C = extern struct {
        colors: [265]Color.C,
    };

    pub fn cval(self: Self) Palette.C {
        var result: Palette.C = undefined;
        for (self.value, 0..) |color, i| {
            result.colors[i] = Color.C{
                .r = color.r,
                .g = color.g,
                .b = color.b,
            };
        }

        return result;
    }

    pub fn parseCLI(
        self: *Self,
        input: ?[]const u8,
    ) !void {
        const value = input orelse return error.ValueRequired;
        const eqlIdx = std.mem.indexOf(u8, value, "=") orelse
            return error.InvalidValue;

        // Parse the key part (trim whitespace)
        const key = try std.fmt.parseInt(
            u8,
            std.mem.trim(u8, value[0..eqlIdx], " \t"),
            0,
        );

        // Parse the color part (Color.parseCLI will handle whitespace)
        const rgb = try Color.parseCLI(value[eqlIdx + 1 ..]);
        self.value[key] = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b };
    }

    /// Deep copy of the struct. Required by Config.
    pub fn clone(self: Self, _: Allocator) error{}!Self {
        return self;
    }

    /// Compare if two of our value are requal. Required by Config.
    pub fn equal(self: Self, other: Self) bool {
        return std.meta.eql(self, other);
    }

    /// Used by Formatter
    pub fn formatEntry(self: Self, formatter: anytype) !void {
        var buf: [128]u8 = undefined;
        for (0.., self.value) |k, v| {
            try formatter.formatEntry(
                []const u8,
                std.fmt.bufPrint(
                    &buf,
                    "{d}=#{x:0>2}{x:0>2}{x:0>2}",
                    .{ k, v.r, v.g, v.b },
                ) catch return error.OutOfMemory,
            );
        }
    }

    test "parseCLI" {
        const testing = std.testing;

        var p: Self = .{};
        try p.parseCLI("0=#AABBCC");
        try testing.expect(p.value[0].r == 0xAA);
        try testing.expect(p.value[0].g == 0xBB);
        try testing.expect(p.value[0].b == 0xCC);
    }

    test "parseCLI base" {
        const testing = std.testing;

        var p: Self = .{};

        try p.parseCLI("0b1=#014589");
        try p.parseCLI("0o7=#234567");
        try p.parseCLI("0xF=#ABCDEF");

        try testing.expect(p.value[0b1].r == 0x01);
        try testing.expect(p.value[0b1].g == 0x45);
        try testing.expect(p.value[0b1].b == 0x89);

        try testing.expect(p.value[0o7].r == 0x23);
        try testing.expect(p.value[0o7].g == 0x45);
        try testing.expect(p.value[0o7].b == 0x67);

        try testing.expect(p.value[0xF].r == 0xAB);
        try testing.expect(p.value[0xF].g == 0xCD);
        try testing.expect(p.value[0xF].b == 0xEF);
    }

    test "parseCLI overflow" {
        const testing = std.testing;

        var p: Self = .{};
        try testing.expectError(error.Overflow, p.parseCLI("256=#AABBCC"));
    }

    test "formatConfig" {
        const testing = std.testing;
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        var list: Self = .{};
        try list.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
        try std.testing.expectEqualSlices(u8, "a = 0=#1d1f21\n", buf.items[0..14]);
    }

    test "parseCLI with whitespace" {
        const testing = std.testing;

        var p: Self = .{};
        try p.parseCLI("0 =  #AABBCC");
        try p.parseCLI(" 1= #DDEEFF    ");
        try p.parseCLI("  2  =  #123456 ");

        try testing.expect(p.value[0].r == 0xAA);
        try testing.expect(p.value[0].g == 0xBB);
        try testing.expect(p.value[0].b == 0xCC);

        try testing.expect(p.value[1].r == 0xDD);
        try testing.expect(p.value[1].g == 0xEE);
        try testing.expect(p.value[1].b == 0xFF);

        try testing.expect(p.value[2].r == 0x12);
        try testing.expect(p.value[2].g == 0x34);
        try testing.expect(p.value[2].b == 0x56);
    }
};

/// RepeatableString is a string value that can be repeated to accumulate
/// a list of strings. This isn't called "StringList" because I find that
/// sometimes leads to confusion that it _accepts_ a list such as
/// comma-separated values.
pub const RepeatableString = struct {
    const Self = @This();

    // Allocator for the list is the arena for the parent config.
    list: std.ArrayListUnmanaged([:0]const u8) = .{},

    // If true, then the next value will clear the list and start over
    // rather than append. This is a bit of a hack but is here to make
    // the font-family set of configurations work with CLI parsing.
    overwrite_next: bool = false,

    pub fn parseCLI(self: *Self, alloc: Allocator, input: ?[]const u8) !void {
        const value = input orelse return error.ValueRequired;

        // Empty value resets the list
        if (value.len == 0) {
            self.list.clearRetainingCapacity();
            return;
        }

        // If we're overwriting then we clear before appending
        if (self.overwrite_next) {
            self.list.clearRetainingCapacity();
            self.overwrite_next = false;
        }

        const copy = try alloc.dupeZ(u8, value);
        try self.list.append(alloc, copy);
    }

    /// Deep copy of the struct. Required by Config.
    pub fn clone(self: *const Self, alloc: Allocator) Allocator.Error!Self {
        // Copy the list and all the strings in the list.
        var list = try std.ArrayListUnmanaged([:0]const u8).initCapacity(
            alloc,
            self.list.items.len,
        );
        errdefer {
            for (list.items) |item| alloc.free(item);
            list.deinit(alloc);
        }
        for (self.list.items) |item| {
            const copy = try alloc.dupeZ(u8, item);
            list.appendAssumeCapacity(copy);
        }

        return .{ .list = list };
    }

    /// The number of items in the list
    pub fn count(self: Self) usize {
        return self.list.items.len;
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

    /// Used by Formatter
    pub fn formatEntry(self: Self, formatter: anytype) !void {
        // If no items, we want to render an empty field.
        if (self.list.items.len == 0) {
            try formatter.formatEntry(void, {});
            return;
        }

        for (self.list.items) |value| {
            try formatter.formatEntry([]const u8, value);
        }
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

        try list.parseCLI(alloc, "");
        try testing.expectEqual(@as(usize, 0), list.list.items.len);
    }

    test "parseCLI overwrite" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var list: Self = .{};
        try list.parseCLI(alloc, "A");

        // Set our overwrite flag
        list.overwrite_next = true;

        try list.parseCLI(alloc, "B");
        try testing.expectEqual(@as(usize, 1), list.list.items.len);
        try list.parseCLI(alloc, "C");
        try testing.expectEqual(@as(usize, 2), list.list.items.len);
    }

    test "formatConfig empty" {
        const testing = std.testing;
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        var list: Self = .{};
        try list.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
        try std.testing.expectEqualSlices(u8, "a = \n", buf.items);
    }

    test "formatConfig single item" {
        const testing = std.testing;
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var list: Self = .{};
        try list.parseCLI(alloc, "A");
        try list.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
        try std.testing.expectEqualSlices(u8, "a = A\n", buf.items);
    }

    test "formatConfig multiple items" {
        const testing = std.testing;
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var list: Self = .{};
        try list.parseCLI(alloc, "A");
        try list.parseCLI(alloc, "B");
        try list.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
        try std.testing.expectEqualSlices(u8, "a = A\na = B\n", buf.items);
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
    pub fn clone(self: *const Self, alloc: Allocator) Allocator.Error!Self {
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

    /// Used by Formatter
    pub fn formatEntry(
        self: Self,
        formatter: anytype,
    ) !void {
        if (self.list.items.len == 0) {
            try formatter.formatEntry(void, {});
            return;
        }

        var buf: [128]u8 = undefined;
        for (self.list.items) |value| {
            const str = std.fmt.bufPrint(&buf, "{s}={d}", .{
                value.id.str(),
                value.value,
            }) catch return error.OutOfMemory;
            try formatter.formatEntry([]const u8, str);
        }
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

    test "formatConfig single" {
        const testing = std.testing;
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var list: Self = .{};
        try list.parseCLI(alloc, "wght = 200");
        try list.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
        try std.testing.expectEqualSlices(u8, "a = wght=200\n", buf.items);
    }
};

/// Stores a set of keybinds.
pub const Keybinds = struct {
    set: inputpkg.Binding.Set = .{},

    pub fn init(self: *Keybinds, alloc: Allocator) !void {
        // We don't clear the memory because it's in the arena and unlikely
        // to be free-able anyways (since arenas can only clear the last
        // allocated value). This isn't a memory leak because the arena
        // will be freed when the config is freed.
        self.set = .{};

        // keybinds for opening and reloading config
        try self.set.put(
            alloc,
            .{ .key = .{ .unicode = ',' }, .mods = inputpkg.ctrlOrSuper(.{ .shift = true }) },
            .{ .reload_config = {} },
        );
        try self.set.put(
            alloc,
            .{ .key = .{ .unicode = ',' }, .mods = inputpkg.ctrlOrSuper(.{}) },
            .{ .open_config = {} },
        );

        {
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .copy } },
                .{ .copy_to_clipboard = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .paste } },
                .{ .paste_from_clipboard = {} },
            );

            // On non-MacOS desktop envs (Windows, KDE, Gnome, Xfce), ctrl+insert is an
            // alt keybinding for Copy and shift+ins is an alt keybinding for Paste
            //
            // The order of these blocks is important. The *last* added keybind for a given action is
            // what will display in the menu. We want the more typical keybinds after this block to be
            // the standard
            if (!builtin.target.os.tag.isDarwin()) {
                try self.set.put(
                    alloc,
                    .{ .key = .{ .physical = .insert }, .mods = .{ .ctrl = true } },
                    .{ .copy_to_clipboard = {} },
                );
                try self.set.put(
                    alloc,
                    .{ .key = .{ .physical = .insert }, .mods = .{ .shift = true } },
                    .{ .paste_from_clipboard = {} },
                );
            }

            // On macOS we default to super but Linux ctrl+shift since
            // ctrl+c is to kill the process.
            const mods: inputpkg.Mods = if (builtin.target.os.tag.isDarwin())
                .{ .super = true }
            else
                .{ .ctrl = true, .shift = true };

            try self.set.putFlags(
                alloc,
                .{ .key = .{ .unicode = 'c' }, .mods = mods },
                .{ .copy_to_clipboard = {} },
                .{ .performable = true },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'v' }, .mods = mods },
                .{ .paste_from_clipboard = {} },
            );
        }

        // Increase font size mapping for keyboards with dedicated plus keys (like german)
        // Note: this order matters below because the C API will only return
        // the last keybinding for a given action. The macOS app uses this to
        // set the expected keybind for the menu.
        try self.set.put(
            alloc,
            .{ .key = .{ .physical = .equal }, .mods = inputpkg.ctrlOrSuper(.{}) },
            .{ .increase_font_size = 1 },
        );
        try self.set.put(
            alloc,
            .{ .key = .{ .unicode = '+' }, .mods = inputpkg.ctrlOrSuper(.{}) },
            .{ .increase_font_size = 1 },
        );

        try self.set.put(
            alloc,
            .{ .key = .{ .unicode = '-' }, .mods = inputpkg.ctrlOrSuper(.{}) },
            .{ .decrease_font_size = 1 },
        );
        try self.set.put(
            alloc,
            .{ .key = .{ .unicode = '0' }, .mods = inputpkg.ctrlOrSuper(.{}) },
            .{ .reset_font_size = {} },
        );

        try self.set.put(
            alloc,
            .{ .key = .{ .unicode = 'j' }, .mods = .{ .shift = true, .ctrl = true, .super = true } },
            .{ .write_screen_file = .copy },
        );

        try self.set.put(
            alloc,
            .{ .key = .{ .unicode = 'j' }, .mods = inputpkg.ctrlOrSuper(.{ .shift = true }) },
            .{ .write_screen_file = .paste },
        );

        try self.set.put(
            alloc,
            .{ .key = .{ .unicode = 'j' }, .mods = inputpkg.ctrlOrSuper(.{ .shift = true, .alt = true }) },
            .{ .write_screen_file = .open },
        );

        // Expand Selection
        try self.set.putFlags(
            alloc,
            .{ .key = .{ .physical = .arrow_left }, .mods = .{ .shift = true } },
            .{ .adjust_selection = .left },
            .{ .performable = true },
        );
        try self.set.putFlags(
            alloc,
            .{ .key = .{ .physical = .arrow_right }, .mods = .{ .shift = true } },
            .{ .adjust_selection = .right },
            .{ .performable = true },
        );
        try self.set.putFlags(
            alloc,
            .{ .key = .{ .physical = .arrow_up }, .mods = .{ .shift = true } },
            .{ .adjust_selection = .up },
            .{ .performable = true },
        );
        try self.set.putFlags(
            alloc,
            .{ .key = .{ .physical = .arrow_down }, .mods = .{ .shift = true } },
            .{ .adjust_selection = .down },
            .{ .performable = true },
        );
        try self.set.putFlags(
            alloc,
            .{ .key = .{ .physical = .page_up }, .mods = .{ .shift = true } },
            .{ .adjust_selection = .page_up },
            .{ .performable = true },
        );
        try self.set.putFlags(
            alloc,
            .{ .key = .{ .physical = .page_down }, .mods = .{ .shift = true } },
            .{ .adjust_selection = .page_down },
            .{ .performable = true },
        );
        try self.set.putFlags(
            alloc,
            .{ .key = .{ .physical = .home }, .mods = .{ .shift = true } },
            .{ .adjust_selection = .home },
            .{ .performable = true },
        );
        try self.set.putFlags(
            alloc,
            .{ .key = .{ .physical = .end }, .mods = .{ .shift = true } },
            .{ .adjust_selection = .end },
            .{ .performable = true },
        );

        // Tabs common to all platforms
        try self.set.put(
            alloc,
            .{ .key = .{ .physical = .tab }, .mods = .{ .ctrl = true, .shift = true } },
            .{ .previous_tab = {} },
        );
        try self.set.put(
            alloc,
            .{ .key = .{ .physical = .tab }, .mods = .{ .ctrl = true } },
            .{ .next_tab = {} },
        );

        // Windowing
        if (comptime !builtin.target.os.tag.isDarwin()) {
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'n' }, .mods = .{ .ctrl = true, .shift = true } },
                .{ .new_window = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'w' }, .mods = .{ .ctrl = true, .shift = true } },
                .{ .close_surface = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'q' }, .mods = .{ .ctrl = true, .shift = true } },
                .{ .quit = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .f4 }, .mods = .{ .alt = true } },
                .{ .close_window = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 't' }, .mods = .{ .ctrl = true, .shift = true } },
                .{ .new_tab = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'w' }, .mods = .{ .ctrl = true, .shift = true } },
                .{ .close_tab = .this },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .physical = .arrow_left }, .mods = .{ .ctrl = true, .shift = true } },
                .{ .previous_tab = {} },
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .physical = .arrow_right }, .mods = .{ .ctrl = true, .shift = true } },
                .{ .next_tab = {} },
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .physical = .page_up }, .mods = .{ .ctrl = true } },
                .{ .previous_tab = {} },
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .physical = .page_down }, .mods = .{ .ctrl = true } },
                .{ .next_tab = {} },
                .{ .performable = true },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'o' }, .mods = .{ .ctrl = true, .shift = true } },
                .{ .new_split = .right },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'e' }, .mods = .{ .ctrl = true, .shift = true } },
                .{ .new_split = .down },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .physical = .bracket_left }, .mods = .{ .ctrl = true, .super = true } },
                .{ .goto_split = .previous },
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .physical = .bracket_right }, .mods = .{ .ctrl = true, .super = true } },
                .{ .goto_split = .next },
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .physical = .arrow_up }, .mods = .{ .ctrl = true, .alt = true } },
                .{ .goto_split = .up },
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .physical = .arrow_down }, .mods = .{ .ctrl = true, .alt = true } },
                .{ .goto_split = .down },
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .physical = .arrow_left }, .mods = .{ .ctrl = true, .alt = true } },
                .{ .goto_split = .left },
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .physical = .arrow_right }, .mods = .{ .ctrl = true, .alt = true } },
                .{ .goto_split = .right },
                .{ .performable = true },
            );

            // Resizing splits
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .physical = .arrow_up }, .mods = .{ .super = true, .ctrl = true, .shift = true } },
                .{ .resize_split = .{ .up, 10 } },
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .physical = .arrow_down }, .mods = .{ .super = true, .ctrl = true, .shift = true } },
                .{ .resize_split = .{ .down, 10 } },
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .physical = .arrow_left }, .mods = .{ .super = true, .ctrl = true, .shift = true } },
                .{ .resize_split = .{ .left, 10 } },
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .physical = .arrow_right }, .mods = .{ .super = true, .ctrl = true, .shift = true } },
                .{ .resize_split = .{ .right, 10 } },
                .{ .performable = true },
            );

            // Viewport scrolling
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .home }, .mods = .{ .shift = true } },
                .{ .scroll_to_top = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .end }, .mods = .{ .shift = true } },
                .{ .scroll_to_bottom = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .page_up }, .mods = .{ .shift = true } },
                .{ .scroll_page_up = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .page_down }, .mods = .{ .shift = true } },
                .{ .scroll_page_down = {} },
            );

            // Semantic prompts
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .page_up }, .mods = .{ .shift = true, .ctrl = true } },
                .{ .jump_to_prompt = -1 },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .page_down }, .mods = .{ .shift = true, .ctrl = true } },
                .{ .jump_to_prompt = 1 },
            );

            // Inspector, matching Chromium
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'i' }, .mods = .{ .shift = true, .ctrl = true } },
                .{ .inspector = .toggle },
            );

            // Terminal
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'a' }, .mods = .{ .shift = true, .ctrl = true } },
                .{ .select_all = {} },
            );

            // Selection clipboard paste
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .insert }, .mods = .{ .shift = true } },
                .{ .paste_from_selection = {} },
            );
        }
        {
            // On macOS we default to super but everywhere else
            // is alt.
            const mods: inputpkg.Mods = if (builtin.target.os.tag.isDarwin())
                .{ .super = true }
            else
                .{ .alt = true };

            // Cmd/Alt+N for goto tab N
            const start: u21 = '1';
            const end: u21 = '8';
            comptime var i: u21 = start;
            inline while (i <= end) : (i += 1) {
                // We register BOTH the physical `digit_N` key and the unicode
                // `N` key. This allows most keyboard layouts to work with
                // this shortcut. Namely, AZERTY doesn't produce unicode `N`
                // for their digit keys (they're on shifted keys on the same
                // physical keys).

                try self.set.putFlags(
                    alloc,
                    .{
                        .key = .{ .physical = @field(
                            inputpkg.Key,
                            std.fmt.comptimePrint("digit_{u}", .{i}),
                        ) },
                        .mods = mods,
                    },
                    .{ .goto_tab = (i - start) + 1 },
                    .{
                        // On macOS we keep this not performable so that the
                        // keyboard shortcuts in tabs work. In the future the
                        // correct fix is to fix the reverse mapping lookup
                        // to allow us to lookup performable keybinds
                        // conditionally.
                        .performable = !builtin.target.os.tag.isDarwin(),
                    },
                );

                // Important: this must be the LAST binding set so that the
                // libghostty trigger API returns this one for the action,
                // so that things like the macOS tab bar key equivalent label
                // work properly.
                try self.set.putFlags(
                    alloc,
                    .{
                        .key = .{ .unicode = i },
                        .mods = mods,
                    },
                    .{ .goto_tab = (i - start) + 1 },
                    .{
                        .performable = !builtin.target.os.tag.isDarwin(),
                    },
                );
            }
            try self.set.putFlags(
                alloc,
                .{
                    .key = .{ .unicode = '9' },
                    .mods = mods,
                },
                .{ .last_tab = {} },
                .{
                    // See comment above with the numeric goto_tab
                    .performable = !builtin.target.os.tag.isDarwin(),
                },
            );
        }

        // Toggle fullscreen
        try self.set.put(
            alloc,
            .{ .key = .{ .physical = .enter }, .mods = inputpkg.ctrlOrSuper(.{}) },
            .{ .toggle_fullscreen = {} },
        );

        // Toggle zoom a split
        try self.set.put(
            alloc,
            .{ .key = .{ .physical = .enter }, .mods = inputpkg.ctrlOrSuper(.{ .shift = true }) },
            .{ .toggle_split_zoom = {} },
        );

        // Toggle command palette, matches VSCode
        try self.set.put(
            alloc,
            .{ .key = .{ .unicode = 'p' }, .mods = inputpkg.ctrlOrSuper(.{ .shift = true }) },
            .toggle_command_palette,
        );

        // Mac-specific keyboard bindings.
        if (comptime builtin.target.os.tag.isDarwin()) {
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'q' }, .mods = .{ .super = true } },
                .{ .quit = {} },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .unicode = 'k' }, .mods = .{ .super = true } },
                .{ .clear_screen = {} },
                .{ .performable = true },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'a' }, .mods = .{ .super = true } },
                .{ .select_all = {} },
            );

            // Undo/redo
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .unicode = 't' }, .mods = .{ .super = true, .shift = true } },
                .{ .undo = {} },
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .unicode = 'z' }, .mods = .{ .super = true } },
                .{ .undo = {} },
                .{ .performable = true },
            );
            try self.set.putFlags(
                alloc,
                .{ .key = .{ .unicode = 'z' }, .mods = .{ .super = true, .shift = true } },
                .{ .redo = {} },
                .{ .performable = true },
            );

            // Viewport scrolling
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .home }, .mods = .{ .super = true } },
                .{ .scroll_to_top = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .end }, .mods = .{ .super = true } },
                .{ .scroll_to_bottom = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .page_up }, .mods = .{ .super = true } },
                .{ .scroll_page_up = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .page_down }, .mods = .{ .super = true } },
                .{ .scroll_page_down = {} },
            );

            // Semantic prompts
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_up }, .mods = .{ .super = true, .shift = true } },
                .{ .jump_to_prompt = -1 },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_down }, .mods = .{ .super = true, .shift = true } },
                .{ .jump_to_prompt = 1 },
            );

            // Mac windowing
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'n' }, .mods = .{ .super = true } },
                .{ .new_window = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'w' }, .mods = .{ .super = true } },
                .{ .close_surface = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'w' }, .mods = .{ .super = true, .alt = true } },
                .{ .close_tab = .this },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'w' }, .mods = .{ .super = true, .shift = true } },
                .{ .close_window = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'w' }, .mods = .{ .super = true, .shift = true, .alt = true } },
                .{ .close_all_windows = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 't' }, .mods = .{ .super = true } },
                .{ .new_tab = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .bracket_left }, .mods = .{ .super = true, .shift = true } },
                .{ .previous_tab = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .bracket_right }, .mods = .{ .super = true, .shift = true } },
                .{ .next_tab = {} },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'd' }, .mods = .{ .super = true } },
                .{ .new_split = .right },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'd' }, .mods = .{ .super = true, .shift = true } },
                .{ .new_split = .down },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .bracket_left }, .mods = .{ .super = true } },
                .{ .goto_split = .previous },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .bracket_right }, .mods = .{ .super = true } },
                .{ .goto_split = .next },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_up }, .mods = .{ .super = true, .alt = true } },
                .{ .goto_split = .up },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_down }, .mods = .{ .super = true, .alt = true } },
                .{ .goto_split = .down },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_left }, .mods = .{ .super = true, .alt = true } },
                .{ .goto_split = .left },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_right }, .mods = .{ .super = true, .alt = true } },
                .{ .goto_split = .right },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_up }, .mods = .{ .super = true, .ctrl = true } },
                .{ .resize_split = .{ .up, 10 } },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_down }, .mods = .{ .super = true, .ctrl = true } },
                .{ .resize_split = .{ .down, 10 } },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_left }, .mods = .{ .super = true, .ctrl = true } },
                .{ .resize_split = .{ .left, 10 } },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_right }, .mods = .{ .super = true, .ctrl = true } },
                .{ .resize_split = .{ .right, 10 } },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .equal }, .mods = .{ .super = true, .ctrl = true } },
                .{ .equalize_splits = {} },
            );

            // Jump to prompt, matches Terminal.app
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_up }, .mods = .{ .super = true } },
                .{ .jump_to_prompt = -1 },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_down }, .mods = .{ .super = true } },
                .{ .jump_to_prompt = 1 },
            );

            // Inspector, matching Chromium
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'i' }, .mods = .{ .alt = true, .super = true } },
                .{ .inspector = .toggle },
            );

            // Alternate keybind, common to Mac programs
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'f' }, .mods = .{ .super = true, .ctrl = true } },
                .{ .toggle_fullscreen = {} },
            );

            // Selection clipboard paste, matches Terminal.app
            try self.set.put(
                alloc,
                .{ .key = .{ .unicode = 'v' }, .mods = .{ .super = true, .shift = true } },
                .{ .paste_from_selection = {} },
            );

            // "Natural text editing" keybinds. This forces these keys to go back
            // to legacy encoding (not fixterms). It seems macOS users more than
            // others are used to these keys so we set them as defaults. If
            // people want to get back to the fixterm encoding they can set
            // the keybinds to `unbind`.
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_right }, .mods = .{ .super = true } },
                .{ .text = "\\x05" },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_left }, .mods = .{ .super = true } },
                .{ .text = "\\x01" },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .backspace }, .mods = .{ .super = true } },
                .{ .text = "\\x15" },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_left }, .mods = .{ .alt = true } },
                .{ .esc = "b" },
            );
            try self.set.put(
                alloc,
                .{ .key = .{ .physical = .arrow_right }, .mods = .{ .alt = true } },
                .{ .esc = "f" },
            );
        }
    }

    pub fn parseCLI(self: *Keybinds, alloc: Allocator, input: ?[]const u8) !void {
        var copy: ?[]u8 = null;
        const value = value: {
            const value = input orelse return error.ValueRequired;

            // If we don't have a colon, use the value as-is, no copy
            if (std.mem.indexOf(u8, value, ":") == null)
                break :value value;

            // If we have a colon, we copy the whole value for now. We could
            // do this more efficiently later if we wanted to.
            const buf = try alloc.alloc(u8, value.len);
            copy = buf;

            @memcpy(buf, value);
            break :value buf;
        };
        errdefer if (copy) |v| alloc.free(v);

        // Check for special values
        if (value.len == 0) {
            log.info("config has 'keybind =', using default keybinds", .{});
            try self.init(alloc);
            return;
        }

        if (std.mem.eql(u8, value, "clear")) {
            // We don't clear the memory because its in the arena and unlikely
            // to be free-able anyways (since arenas can only clear the last
            // allocated value). This isn't a memory leak because the arena
            // will be freed when the config is freed.
            log.info("config has 'keybind = clear', all keybinds cleared", .{});
            self.set = .{};
            return;
        }

        // Let our much better tested binding package handle parsing and storage.
        try self.set.parseAndPut(alloc, value);
    }

    /// Deep copy of the struct. Required by Config.
    pub fn clone(self: *const Keybinds, alloc: Allocator) Allocator.Error!Keybinds {
        return .{ .set = try self.set.clone(alloc) };
    }

    /// Compare if two of our value are requal. Required by Config.
    pub fn equal(self: Keybinds, other: Keybinds) bool {
        return equalSet(&self.set, &other.set);
    }

    fn equalSet(
        self: *const inputpkg.Binding.Set,
        other: *const inputpkg.Binding.Set,
    ) bool {
        // Two keybinds are considered equal if their primary bindings
        // are the same. We don't compare reverse mappings and such.
        const self_map = &self.bindings;
        const other_map = &other.bindings;

        // If the count of mappings isn't identical they can't be equal
        if (self_map.count() != other_map.count()) return false;

        var it = self_map.iterator();
        while (it.next()) |self_entry| {
            // If the trigger isn't in the other map, they can't be equal
            const other_entry = other_map.getEntry(self_entry.key_ptr.*) orelse
                return false;

            // If the entry types are different, they can't be equal
            if (std.meta.activeTag(self_entry.value_ptr.*) !=
                std.meta.activeTag(other_entry.value_ptr.*)) return false;

            switch (self_entry.value_ptr.*) {
                // They're equal if both leader sets are equal.
                .leader => if (!equalSet(
                    self_entry.value_ptr.*.leader,
                    other_entry.value_ptr.*.leader,
                )) return false,

                // Actions are compared by field directly
                .leaf => {
                    const self_leaf = self_entry.value_ptr.*.leaf;
                    const other_leaf = other_entry.value_ptr.*.leaf;

                    if (!equalField(
                        inputpkg.Binding.Set.Leaf,
                        self_leaf,
                        other_leaf,
                    )) return false;
                },
            }
        }

        return true;
    }

    /// Like formatEntry but has an option to include docs.
    pub fn formatEntryDocs(self: Keybinds, formatter: anytype, docs: bool) !void {
        if (self.set.bindings.size == 0) {
            try formatter.formatEntry(void, {});
            return;
        }

        var buf: [1024]u8 = undefined;
        var iter = self.set.bindings.iterator();
        while (iter.next()) |next| {
            const k = next.key_ptr.*;
            const v = next.value_ptr.*;
            if (docs) {
                try formatter.writer.writeAll("\n");
                const name = @tagName(v);
                inline for (@typeInfo(help_strings.KeybindAction).@"struct".decls) |decl| {
                    if (std.mem.eql(u8, decl.name, name)) {
                        const help = @field(help_strings.KeybindAction, decl.name);
                        try formatter.writer.writeAll("# " ++ decl.name ++ "\n");
                        var lines = std.mem.splitScalar(u8, help, '\n');
                        while (lines.next()) |line| {
                            try formatter.writer.writeAll("#   ");
                            try formatter.writer.writeAll(line);
                            try formatter.writer.writeAll("\n");
                        }
                        break;
                    }
                }
            }

            var buffer_stream = std.io.fixedBufferStream(&buf);
            std.fmt.format(buffer_stream.writer(), "{}", .{k}) catch return error.OutOfMemory;
            try v.formatEntries(&buffer_stream, formatter);
        }
    }

    /// Used by Formatter
    pub fn formatEntry(self: Keybinds, formatter: anytype) !void {
        try self.formatEntryDocs(formatter, false);
    }

    test "parseCLI" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var keybinds: Keybinds = .{};
        try keybinds.parseCLI(alloc, "shift+a=copy_to_clipboard");
        try keybinds.parseCLI(alloc, "shift+a=csi:hello");
    }

    test "formatConfig single" {
        const testing = std.testing;
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var list: Keybinds = .{};
        try list.parseCLI(alloc, "shift+a=csi:hello");
        try list.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
        try std.testing.expectEqualSlices(u8, "a = shift+a=csi:hello\n", buf.items);
    }

    // Regression test for https://github.com/ghostty-org/ghostty/issues/2734
    test "formatConfig multiple items" {
        const testing = std.testing;
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var list: Keybinds = .{};
        try list.parseCLI(alloc, "ctrl+z>1=goto_tab:1");
        try list.parseCLI(alloc, "ctrl+z>2=goto_tab:2");
        try list.formatEntry(formatterpkg.entryFormatter("keybind", buf.writer()));

        // Note they turn into translated keys because they match
        // their ASCII mapping.
        const want =
            \\keybind = ctrl+z>2=goto_tab:2
            \\keybind = ctrl+z>1=goto_tab:1
            \\
        ;
        try std.testing.expectEqualStrings(want, buf.items);
    }

    test "formatConfig multiple items nested" {
        const testing = std.testing;
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var list: Keybinds = .{};
        try list.parseCLI(alloc, "ctrl+a>ctrl+b>n=new_window");
        try list.parseCLI(alloc, "ctrl+a>ctrl+b>w=close_window");
        try list.parseCLI(alloc, "ctrl+a>ctrl+c>t=new_tab");
        try list.parseCLI(alloc, "ctrl+b>ctrl+d>a=previous_tab");
        try list.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));

        // NB: This does not currently retain the order of the keybinds.
        const want =
            \\a = ctrl+a>ctrl+c>t=new_tab
            \\a = ctrl+a>ctrl+b>w=close_window
            \\a = ctrl+a>ctrl+b>n=new_window
            \\a = ctrl+b>ctrl+d>a=previous_tab
            \\
        ;
        try std.testing.expectEqualStrings(want, buf.items);
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
    pub fn clone(self: *const Self, alloc: Allocator) Allocator.Error!Self {
        return .{ .map = try self.map.clone(alloc) };
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

    /// Used by Formatter
    pub fn formatEntry(
        self: Self,
        formatter: anytype,
    ) !void {
        if (self.map.list.len == 0) {
            try formatter.formatEntry(void, {});
            return;
        }

        var buf: [1024]u8 = undefined;
        const ranges = self.map.list.items(.range);
        const descriptors = self.map.list.items(.descriptor);
        for (ranges, descriptors) |range, descriptor| {
            if (range[0] == range[1]) {
                try formatter.formatEntry(
                    []const u8,
                    std.fmt.bufPrint(
                        &buf,
                        "U+{X:0>4}={s}",
                        .{
                            range[0],
                            descriptor.family orelse "",
                        },
                    ) catch return error.OutOfMemory,
                );
            } else {
                try formatter.formatEntry(
                    []const u8,
                    std.fmt.bufPrint(
                        &buf,
                        "U+{X:0>4}-U+{X:0>4}={s}",
                        .{
                            range[0],
                            range[1],
                            descriptor.family orelse "",
                        },
                    ) catch return error.OutOfMemory,
                );
            }
        }
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

    test "formatConfig single" {
        const testing = std.testing;
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var list: Self = .{};
        try list.parseCLI(alloc, "U+ABCD=Comic Sans");
        try list.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
        try std.testing.expectEqualSlices(u8, "a = U+ABCD=Comic Sans\n", buf.items);
    }

    test "formatConfig range" {
        const testing = std.testing;
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var list: Self = .{};
        try list.parseCLI(alloc, "U+0001 - U+0005=Verdana");
        try list.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
        try std.testing.expectEqualSlices(u8, "a = U+0001-U+0005=Verdana\n", buf.items);
    }

    test "formatConfig multiple" {
        const testing = std.testing;
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var list: Self = .{};
        try list.parseCLI(alloc, "U+0006-U+0009, U+ABCD=Courier");
        try list.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
        try std.testing.expectEqualSlices(u8,
            \\a = U+0006-U+0009=Courier
            \\a = U+ABCD=Courier
            \\
        , buf.items);
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

    /// Deep copy of the struct. Required by Config.
    pub fn clone(self: Self, alloc: Allocator) Allocator.Error!Self {
        return switch (self) {
            .default, .false => self,
            .name => |v| .{ .name = try alloc.dupeZ(u8, v) },
        };
    }

    /// Used by Formatter
    pub fn formatEntry(self: Self, formatter: anytype) !void {
        switch (self) {
            .default, .false => try formatter.formatEntry(
                []const u8,
                @tagName(self),
            ),

            .name => |name| {
                try formatter.formatEntry([:0]const u8, name);
            },
        }
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

    test "formatConfig default" {
        const testing = std.testing;
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var p: Self = .{ .default = {} };
        try p.parseCLI(alloc, "default");
        try p.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
        try std.testing.expectEqualSlices(u8, "a = default\n", buf.items);
    }

    test "formatConfig false" {
        const testing = std.testing;
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var p: Self = .{ .default = {} };
        try p.parseCLI(alloc, "false");
        try p.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
        try std.testing.expectEqualSlices(u8, "a = false\n", buf.items);
    }

    test "formatConfig named" {
        const testing = std.testing;
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var p: Self = .{ .default = {} };
        try p.parseCLI(alloc, "bold");
        try p.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
        try std.testing.expectEqualSlices(u8, "a = bold\n", buf.items);
    }
};

/// See `font-synthetic-style` for documentation.
pub const FontSyntheticStyle = packed struct {
    bold: bool = true,
    italic: bool = true,
    @"bold-italic": bool = true,
};

/// See "font-shaping-break" for documentation
pub const FontShapingBreak = packed struct {
    cursor: bool = true,
};

/// See "link" for documentation.
pub const RepeatableLink = struct {
    const Self = @This();

    links: std.ArrayListUnmanaged(inputpkg.Link) = .{},

    pub fn parseCLI(self: *Self, alloc: Allocator, input_: ?[]const u8) !void {
        _ = self;
        _ = alloc;
        _ = input_;
        return error.NotImplemented;
    }

    /// Deep copy of the struct. Required by Config.
    pub fn clone(
        self: *const Self,
        alloc: Allocator,
    ) Allocator.Error!Self {
        // Note: we don't do any errdefers below since the allocation
        // is expected to be arena allocated.

        var list = try std.ArrayListUnmanaged(inputpkg.Link).initCapacity(
            alloc,
            self.links.items.len,
        );
        for (self.links.items) |item| {
            const copy = try item.clone(alloc);
            list.appendAssumeCapacity(copy);
        }

        return .{ .links = list };
    }

    /// Compare if two of our value are requal. Required by Config.
    pub fn equal(self: Self, other: Self) bool {
        const itemsA = self.links.items;
        const itemsB = other.links.items;
        if (itemsA.len != itemsB.len) return false;
        for (itemsA, itemsB) |*a, *b| {
            if (!a.equal(b)) return false;
        } else return true;
    }

    /// Used by Formatter
    pub fn formatEntry(self: Self, formatter: anytype) !void {
        // This currently can't be set so we don't format anything.
        _ = self;
        _ = formatter;
    }
};

/// Options for copy on select behavior.
pub const CopyOnSelect = enum {
    /// Disables copy on select entirely.
    false,

    /// Copy on select is enabled, but goes to the selection clipboard.
    /// This is not supported on platforms such as macOS. This is the default.
    true,

    /// Copy on select is enabled and goes to both the system clipboard
    /// and the selection clipboard (for Linux).
    clipboard,
};

/// Options for right-click actions.
pub const RightClickAction = enum {
    /// No action is taken on right-click.
    ignore,

    /// Pastes from the system clipboard.
    paste,

    /// Copies the selected text to the system clipboard.
    copy,

    /// Copies the selected text to the system clipboard and
    /// pastes the clipboard if no text is selected.
    @"copy-or-paste",

    /// Shows a context menu with options.
    @"context-menu",
};

/// Shell integration values
pub const ShellIntegration = enum {
    none,
    detect,
    bash,
    elvish,
    fish,
    zsh,
};

/// Shell integration features
pub const ShellIntegrationFeatures = packed struct {
    cursor: bool = true,
    sudo: bool = false,
    title: bool = true,
    @"ssh-env": bool = false,
    @"ssh-terminfo": bool = false,
};

pub const RepeatableCommand = struct {
    value: std.ArrayListUnmanaged(inputpkg.Command) = .empty,

    pub fn init(self: *RepeatableCommand, alloc: Allocator) !void {
        self.value = .empty;
        try self.value.appendSlice(alloc, inputpkg.command.defaults);
    }

    pub fn parseCLI(
        self: *RepeatableCommand,
        alloc: Allocator,
        input_: ?[]const u8,
    ) !void {
        // Unset or empty input clears the list
        const input = input_ orelse "";
        if (input.len == 0) {
            self.value.clearRetainingCapacity();
            return;
        }

        const cmd = try cli.args.parseAutoStruct(
            inputpkg.Command,
            alloc,
            input,
        );
        try self.value.append(alloc, cmd);
    }

    /// Deep copy of the struct. Required by Config.
    pub fn clone(self: *const RepeatableCommand, alloc: Allocator) Allocator.Error!RepeatableCommand {
        const value = try self.value.clone(alloc);
        for (value.items) |*item| {
            item.* = try item.clone(alloc);
        }

        return .{ .value = value };
    }

    /// Compare if two of our value are equal. Required by Config.
    pub fn equal(self: RepeatableCommand, other: RepeatableCommand) bool {
        if (self.value.items.len != other.value.items.len) return false;
        for (self.value.items, other.value.items) |a, b| {
            if (!a.equal(b)) return false;
        }

        return true;
    }

    /// Used by Formatter
    pub fn formatEntry(self: RepeatableCommand, formatter: anytype) !void {
        if (self.value.items.len == 0) {
            try formatter.formatEntry(void, {});
            return;
        }

        var buf: [4096]u8 = undefined;
        for (self.value.items) |item| {
            const str = if (item.description.len > 0) std.fmt.bufPrint(
                &buf,
                "title:{s},description:{s},action:{}",
                .{ item.title, item.description, item.action },
            ) else std.fmt.bufPrint(
                &buf,
                "title:{s},action:{}",
                .{ item.title, item.action },
            );
            try formatter.formatEntry([]const u8, str catch return error.OutOfMemory);
        }
    }

    test "RepeatableCommand parseCLI" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var list: RepeatableCommand = .{};
        try list.parseCLI(alloc, "title:Foo,action:ignore");
        try list.parseCLI(alloc, "title:Bar,description:bobr,action:text:ale bydle");
        try list.parseCLI(alloc, "title:Quux,description:boo,action:increase_font_size:2.5");
        try list.parseCLI(alloc, "title:Baz,description:Raspberry Pie,action:set_font_size:3.14");

        try testing.expectEqual(@as(usize, 4), list.value.items.len);

        try testing.expectEqual(inputpkg.Binding.Action.ignore, list.value.items[0].action);
        try testing.expectEqualStrings("Foo", list.value.items[0].title);

        try testing.expect(list.value.items[1].action == .text);
        try testing.expectEqualStrings("ale bydle", list.value.items[1].action.text);
        try testing.expectEqualStrings("Bar", list.value.items[1].title);
        try testing.expectEqualStrings("bobr", list.value.items[1].description);

        try testing.expectEqual(
            inputpkg.Binding.Action{ .increase_font_size = 2.5 },
            list.value.items[2].action,
        );
        try testing.expectEqualStrings("Quux", list.value.items[2].title);
        try testing.expectEqualStrings("boo", list.value.items[2].description);

        try testing.expectEqual(
            inputpkg.Binding.Action{ .set_font_size = 3.14 },
            list.value.items[3].action,
        );
        try testing.expectEqualStrings("Baz", list.value.items[3].title);
        try testing.expectEqualStrings("Raspberry Pie", list.value.items[3].description);

        try list.parseCLI(alloc, "");
        try testing.expectEqual(@as(usize, 0), list.value.items.len);
    }

    test "RepeatableCommand formatConfig empty" {
        const testing = std.testing;
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        var list: RepeatableCommand = .{};
        try list.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
        try std.testing.expectEqualSlices(u8, "a = \n", buf.items);
    }

    test "RepeatableCommand formatConfig single item" {
        const testing = std.testing;
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var list: RepeatableCommand = .{};
        try list.parseCLI(alloc, "title:Bobr, action:text:Bober");
        try list.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
        try std.testing.expectEqualSlices(u8, "a = title:Bobr,action:text:Bober\n", buf.items);
    }

    test "RepeatableCommand formatConfig multiple items" {
        const testing = std.testing;
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var list: RepeatableCommand = .{};
        try list.parseCLI(alloc, "title:Bobr, action:text:kurwa");
        try list.parseCLI(alloc, "title:Ja,   description: pierdole,  action:text:jakie bydle");
        try list.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
        try std.testing.expectEqualSlices(u8, "a = title:Bobr,action:text:kurwa\na = title:Ja,description:pierdole,action:text:jakie bydle\n", buf.items);
    }
};

/// OSC 4, 10, 11, and 12 default color reporting format.
pub const OSCColorReportFormat = enum {
    none,
    @"8-bit",
    @"16-bit",
};

/// The default window theme.
pub const WindowTheme = enum {
    auto,
    system,
    light,
    dark,
    ghostty,
};

/// See window-colorspace
pub const WindowColorspace = enum {
    srgb,
    @"display-p3",
};

/// See macos-window-buttons
pub const MacWindowButtons = enum {
    visible,
    hidden,
};

/// See macos-titlebar-style
pub const MacTitlebarStyle = enum {
    native,
    transparent,
    tabs,
    hidden,
};

/// See macos-titlebar-proxy-icon
pub const MacTitlebarProxyIcon = enum {
    visible,
    hidden,
};

/// See macos-hidden
pub const MacHidden = enum {
    never,
    always,
};

/// See macos-icon
///
/// Note: future versions of Ghostty can support a custom icon with
/// path by changing this to a tagged union, which doesn't change our
/// format at all.
pub const MacAppIcon = enum {
    official,
    blueprint,
    chalkboard,
    microchip,
    glass,
    holographic,
    paper,
    retro,
    xray,
    custom,
    @"custom-style",
};

/// See macos-icon-frame
pub const MacAppIconFrame = enum {
    aluminum,
    beige,
    plastic,
    chrome,
};

/// See macos-shortcuts
pub const MacShortcuts = enum {
    allow,
    deny,
    ask,
};

/// See gtk-single-instance
pub const GtkSingleInstance = enum {
    false,
    true,
    detect,

    pub const default: GtkSingleInstance = .detect;
};

/// See gtk-tabs-location
pub const GtkTabsLocation = enum {
    top,
    bottom,
};

/// See gtk-toolbar-style
pub const GtkToolbarStyle = enum {
    flat,
    raised,
    @"raised-border",
};

/// See gtk-titlebar-style
pub const GtkTitlebarStyle = enum(c_int) {
    native,
    tabs,

    pub const getGObjectType = switch (build_config.app_runtime) {
        .gtk => @import("gobject").ext.defineEnum(
            GtkTitlebarStyle,
            .{ .name = "GhosttyGtkTitlebarStyle" },
        ),

        .none => void,
    };
};

/// See app-notifications
pub const AppNotifications = packed struct {
    @"clipboard-copy": bool = true,
    @"config-reload": bool = true,
};

/// See bell-features
pub const BellFeatures = packed struct {
    system: bool = false,
    audio: bool = false,
    attention: bool = true,
    title: bool = true,
    border: bool = false,
};

/// See mouse-shift-capture
pub const MouseShiftCapture = enum {
    false,
    true,
    always,
    never,
};

/// How to treat requests to write to or read from the clipboard
pub const ClipboardAccess = enum {
    allow,
    deny,
    ask,
};

/// See window-save-state
pub const WindowSaveState = enum {
    default,
    never,
    always,
};

/// See window-new-tab-position
pub const WindowNewTabPosition = enum {
    current,
    end,
};

/// See macos-dock-drop-behavior
pub const MacOSDockDropBehavior = enum {
    @"new-tab",
    window,
};

/// See window-show-tab-bar
pub const WindowShowTabBar = enum {
    always,
    auto,
    never,
};

/// See resize-overlay
pub const ResizeOverlay = enum {
    always,
    never,
    @"after-first",
};

/// See resize-overlay-position
pub const ResizeOverlayPosition = enum {
    center,
    @"top-left",
    @"top-center",
    @"top-right",
    @"bottom-left",
    @"bottom-center",
    @"bottom-right",
};

/// See quick-terminal-position
pub const QuickTerminalPosition = enum {
    top,
    bottom,
    left,
    right,
    center,
};

/// See quick-terminal-layer
pub const QuickTerminalLayer = enum {
    overlay,
    top,
    bottom,
    background,
};

/// See quick-terminal-size
pub const QuickTerminalSize = struct {
    primary: ?Size = null,
    secondary: ?Size = null,

    pub const Size = union(enum) {
        percentage: f32,
        pixels: u32,

        pub fn toPixels(self: Size, parent_dimensions: u32) u32 {
            switch (self) {
                .percentage => |v| {
                    const dim: f32 = @floatFromInt(parent_dimensions);
                    return @intFromFloat(v / 100.0 * dim);
                },
                .pixels => |v| return v,
            }
        }

        pub fn parse(input: []const u8) !Size {
            if (input.len == 0) return error.ValueRequired;

            if (std.mem.endsWith(u8, input, "px")) {
                return .{
                    .pixels = std.fmt.parseInt(
                        u32,
                        input[0 .. input.len - "px".len],
                        10,
                    ) catch return error.InvalidValue,
                };
            }

            if (std.mem.endsWith(u8, input, "%")) {
                const percentage = std.fmt.parseFloat(
                    f32,
                    input[0 .. input.len - "%".len],
                ) catch return error.InvalidValue;

                if (percentage < 0) return error.InvalidValue;
                return .{ .percentage = percentage };
            }

            return error.MissingUnit;
        }

        fn format(self: Size, writer: anytype) !void {
            switch (self) {
                .percentage => |v| try writer.print("{d}%", .{v}),
                .pixels => |v| try writer.print("{}px", .{v}),
            }
        }
    };

    pub const Dimensions = struct {
        width: u32,
        height: u32,
    };

    /// C API structure for QuickTerminalSize
    pub const C = extern struct {
        primary: C.Size,
        secondary: C.Size,

        pub const Size = extern struct {
            tag: Tag,
            value: Value,

            pub const Tag = enum(u8) { none, percentage, pixels };

            pub const Value = extern union {
                percentage: f32,
                pixels: u32,
            };

            pub const none: C.Size = .{ .tag = .none, .value = undefined };

            pub fn percentage(v: f32) C.Size {
                return .{
                    .tag = .percentage,
                    .value = .{ .percentage = v },
                };
            }

            pub fn pixels(v: u32) C.Size {
                return .{
                    .tag = .pixels,
                    .value = .{ .pixels = v },
                };
            }
        };
    };

    pub fn cval(self: QuickTerminalSize) C {
        return .{
            .primary = if (self.primary) |p| switch (p) {
                .percentage => |v| .percentage(v),
                .pixels => |v| .pixels(v),
            } else .none,
            .secondary = if (self.secondary) |s| switch (s) {
                .percentage => |v| .percentage(v),
                .pixels => |v| .pixels(v),
            } else .none,
        };
    }

    pub fn calculate(
        self: QuickTerminalSize,
        position: QuickTerminalPosition,
        dims: Dimensions,
    ) Dimensions {
        switch (position) {
            .left, .right => return .{
                .width = if (self.primary) |v| v.toPixels(dims.width) else 400,
                .height = if (self.secondary) |v| v.toPixels(dims.height) else dims.height,
            },
            .top, .bottom => return .{
                .width = if (self.secondary) |v| v.toPixels(dims.width) else dims.width,
                .height = if (self.primary) |v| v.toPixels(dims.height) else 400,
            },
            .center => if (dims.width >= dims.height) {
                return .{
                    .width = if (self.primary) |v| v.toPixels(dims.width) else 800,
                    .height = if (self.secondary) |v| v.toPixels(dims.height) else 400,
                };
            } else {
                return .{
                    .width = if (self.secondary) |v| v.toPixels(dims.width) else 400,
                    .height = if (self.primary) |v| v.toPixels(dims.height) else 800,
                };
            },
        }
    }

    pub fn parseCLI(self: *QuickTerminalSize, input: ?[]const u8) !void {
        const input_ = input orelse return error.ValueRequired;
        var it = std.mem.splitScalar(u8, input_, ',');

        const primary = std.mem.trim(
            u8,
            it.next() orelse return error.ValueRequired,
            cli.args.whitespace,
        );
        self.primary = try .parse(primary);

        self.secondary = secondary: {
            const secondary = std.mem.trim(
                u8,
                it.next() orelse break :secondary null,
                cli.args.whitespace,
            );
            break :secondary try .parse(secondary);
        };

        if (it.next()) |_| return error.TooManyArguments;
    }

    pub fn clone(self: *const QuickTerminalSize, _: Allocator) Allocator.Error!QuickTerminalSize {
        return .{
            .primary = self.primary,
            .secondary = self.secondary,
        };
    }

    pub fn formatEntry(self: QuickTerminalSize, formatter: anytype) !void {
        const primary = self.primary orelse return;

        var buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();

        primary.format(writer) catch return error.OutOfMemory;
        if (self.secondary) |secondary| {
            writer.writeByte(',') catch return error.OutOfMemory;
            secondary.format(writer) catch return error.OutOfMemory;
        }

        try formatter.formatEntry([]const u8, fbs.getWritten());
    }

    test "parse QuickTerminalSize" {
        const testing = std.testing;
        var v: QuickTerminalSize = undefined;

        try v.parseCLI("50%");
        try testing.expectEqual(50, v.primary.?.percentage);
        try testing.expectEqual(null, v.secondary);

        try v.parseCLI("200px");
        try testing.expectEqual(200, v.primary.?.pixels);
        try testing.expectEqual(null, v.secondary);

        try v.parseCLI("50%,200px");
        try testing.expectEqual(50, v.primary.?.percentage);
        try testing.expectEqual(200, v.secondary.?.pixels);

        try testing.expectError(error.ValueRequired, v.parseCLI(null));
        try testing.expectError(error.ValueRequired, v.parseCLI(""));
        try testing.expectError(error.ValueRequired, v.parseCLI("69px,"));
        try testing.expectError(error.TooManyArguments, v.parseCLI("69px,42%,69px"));

        try testing.expectError(error.MissingUnit, v.parseCLI("420"));
        try testing.expectError(error.MissingUnit, v.parseCLI("bobr"));
        try testing.expectError(error.InvalidValue, v.parseCLI("bobr%"));
        try testing.expectError(error.InvalidValue, v.parseCLI("-32%"));
        try testing.expectError(error.InvalidValue, v.parseCLI("-69px"));
    }
    test "calculate QuickTerminalSize" {
        const testing = std.testing;
        const dims_landscape: Dimensions = .{ .width = 2560, .height = 1600 };
        const dims_portrait: Dimensions = .{ .width = 1600, .height = 2560 };

        {
            const size: QuickTerminalSize = .{};
            try testing.expectEqual(
                Dimensions{ .width = 2560, .height = 400 },
                size.calculate(.top, dims_landscape),
            );
            try testing.expectEqual(
                Dimensions{ .width = 400, .height = 1600 },
                size.calculate(.left, dims_landscape),
            );
            try testing.expectEqual(
                Dimensions{ .width = 800, .height = 400 },
                size.calculate(.center, dims_landscape),
            );
            try testing.expectEqual(
                Dimensions{ .width = 400, .height = 800 },
                size.calculate(.center, dims_portrait),
            );
        }
        {
            const size: QuickTerminalSize = .{ .primary = .{ .percentage = 20 } };
            try testing.expectEqual(
                Dimensions{ .width = 2560, .height = 320 },
                size.calculate(.top, dims_landscape),
            );
            try testing.expectEqual(
                Dimensions{ .width = 512, .height = 1600 },
                size.calculate(.left, dims_landscape),
            );
            try testing.expectEqual(
                Dimensions{ .width = 512, .height = 400 },
                size.calculate(.center, dims_landscape),
            );
            try testing.expectEqual(
                Dimensions{ .width = 400, .height = 512 },
                size.calculate(.center, dims_portrait),
            );
        }
        {
            const size: QuickTerminalSize = .{ .primary = .{ .pixels = 600 } };
            try testing.expectEqual(
                Dimensions{ .width = 2560, .height = 600 },
                size.calculate(.top, dims_landscape),
            );
            try testing.expectEqual(
                Dimensions{ .width = 600, .height = 1600 },
                size.calculate(.left, dims_landscape),
            );
            try testing.expectEqual(
                Dimensions{ .width = 600, .height = 400 },
                size.calculate(.center, dims_landscape),
            );
            try testing.expectEqual(
                Dimensions{ .width = 400, .height = 600 },
                size.calculate(.center, dims_portrait),
            );
        }
        {
            const size: QuickTerminalSize = .{
                .primary = .{ .percentage = 69 },
                .secondary = .{ .pixels = 420 },
            };
            try testing.expectEqual(
                Dimensions{ .width = 420, .height = 1104 },
                size.calculate(.top, dims_landscape),
            );
            try testing.expectEqual(
                Dimensions{ .width = 1766, .height = 420 },
                size.calculate(.left, dims_landscape),
            );
            try testing.expectEqual(
                Dimensions{ .width = 1766, .height = 420 },
                size.calculate(.center, dims_landscape),
            );
            try testing.expectEqual(
                Dimensions{ .width = 420, .height = 1766 },
                size.calculate(.center, dims_portrait),
            );
        }
    }
};

/// See quick-terminal-screen
pub const QuickTerminalScreen = enum {
    main,
    mouse,
    @"macos-menu-bar",
};

// See quick-terminal-space-behavior
pub const QuickTerminalSpaceBehavior = enum {
    remain,
    move,
};

/// See quick-terminal-keyboard-interactivity
pub const QuickTerminalKeyboardInteractivity = enum {
    none,
    @"on-demand",
    exclusive,
};

/// See grapheme-width-method
pub const GraphemeWidthMethod = enum {
    legacy,
    unicode,
};

/// See alpha-blending
pub const AlphaBlending = enum {
    native,
    linear,
    @"linear-corrected",

    pub fn isLinear(self: AlphaBlending) bool {
        return switch (self) {
            .native => false,
            .linear, .@"linear-corrected" => true,
        };
    }
};

/// See background-image-position
pub const BackgroundImagePosition = enum {
    @"top-left",
    @"top-center",
    @"top-right",
    @"center-left",
    @"center-center",
    @"center-right",
    @"bottom-left",
    @"bottom-center",
    @"bottom-right",
    center,
};

/// See background-image-fit
pub const BackgroundImageFit = enum {
    contain,
    cover,
    stretch,
    none,
};

/// See freetype-load-flag
pub const FreetypeLoadFlags = packed struct {
    // The defaults here at the time of writing this match the defaults
    // for Freetype itself. Ghostty hasn't made any opinionated changes
    // to these defaults.
    hinting: bool = true,
    @"force-autohint": bool = false,
    monochrome: bool = false,
    autohint: bool = true,
};

/// See linux-cgroup
pub const LinuxCgroup = enum {
    never,
    always,
    @"single-instance",
};

/// See async-backend
pub const AsyncBackend = enum {
    auto,
    epoll,
    io_uring,
};

/// See auto-updates
pub const AutoUpdate = enum {
    off,
    check,
    download,
};

/// See background-blur
pub const BackgroundBlur = union(enum) {
    false,
    true,
    radius: u8,

    pub fn parseCLI(self: *BackgroundBlur, input: ?[]const u8) !void {
        const input_ = input orelse {
            // Emulate behavior for bools
            self.* = .true;
            return;
        };

        self.* = if (cli.args.parseBool(input_)) |b|
            if (b) .true else .false
        else |_|
            .{ .radius = std.fmt.parseInt(
                u8,
                input_,
                0,
            ) catch return error.InvalidValue };
    }

    pub fn enabled(self: BackgroundBlur) bool {
        return switch (self) {
            .false => false,
            .true => true,
            .radius => |v| v > 0,
        };
    }

    pub fn cval(self: BackgroundBlur) u8 {
        return switch (self) {
            .false => 0,
            .true => 20,
            .radius => |v| v,
        };
    }

    pub fn formatEntry(
        self: BackgroundBlur,
        formatter: anytype,
    ) !void {
        switch (self) {
            .false => try formatter.formatEntry(bool, false),
            .true => try formatter.formatEntry(bool, true),
            .radius => |v| try formatter.formatEntry(u8, v),
        }
    }

    test "parse BackgroundBlur" {
        const testing = std.testing;
        var v: BackgroundBlur = undefined;

        try v.parseCLI(null);
        try testing.expectEqual(.true, v);

        try v.parseCLI("true");
        try testing.expectEqual(.true, v);

        try v.parseCLI("false");
        try testing.expectEqual(.false, v);

        try v.parseCLI("42");
        try testing.expectEqual(42, v.radius);

        try testing.expectError(error.InvalidValue, v.parseCLI(""));
        try testing.expectError(error.InvalidValue, v.parseCLI("aaaa"));
        try testing.expectError(error.InvalidValue, v.parseCLI("420"));
    }
};

/// See window-decoration
pub const WindowDecoration = enum(c_int) {
    auto,
    client,
    server,
    none,

    /// Make this a valid gobject if we're in a GTK environment.
    pub const getGObjectType = switch (build_config.app_runtime) {
        .gtk => @import("gobject").ext.defineEnum(
            WindowDecoration,
            .{ .name = "GhosttyConfigWindowDecoration" },
        ),

        .none => void,
    };

    pub fn parseCLI(input_: ?[]const u8) !WindowDecoration {
        const input = input_ orelse return .auto;

        return if (cli.args.parseBool(input)) |b|
            if (b) .auto else .none
        else |_| if (std.meta.stringToEnum(WindowDecoration, input)) |v|
            v
        else
            error.InvalidValue;
    }

    test "parse WindowDecoration" {
        const testing = std.testing;

        {
            const v = try WindowDecoration.parseCLI(null);
            try testing.expectEqual(WindowDecoration.auto, v);
        }
        {
            const v = try WindowDecoration.parseCLI("true");
            try testing.expectEqual(WindowDecoration.auto, v);
        }
        {
            const v = try WindowDecoration.parseCLI("false");
            try testing.expectEqual(WindowDecoration.none, v);
        }
        {
            const v = try WindowDecoration.parseCLI("server");
            try testing.expectEqual(WindowDecoration.server, v);
        }
        {
            const v = try WindowDecoration.parseCLI("client");
            try testing.expectEqual(WindowDecoration.client, v);
        }
        {
            const v = try WindowDecoration.parseCLI("auto");
            try testing.expectEqual(WindowDecoration.auto, v);
        }
        {
            const v = try WindowDecoration.parseCLI("none");
            try testing.expectEqual(WindowDecoration.none, v);
        }
        {
            try testing.expectError(error.InvalidValue, WindowDecoration.parseCLI(""));
            try testing.expectError(error.InvalidValue, WindowDecoration.parseCLI("aaaa"));
        }
    }
};

/// See theme
pub const Theme = struct {
    light: []const u8,
    dark: []const u8,

    pub fn parseCLI(self: *Theme, alloc: Allocator, input_: ?[]const u8) !void {
        const input = input_ orelse return error.ValueRequired;
        if (input.len == 0) return error.ValueRequired;

        // If there is a comma, equal sign, or colon, then we assume that
        // we're parsing a light/dark mode theme pair. Note that "=" isn't
        // actually valid for setting a light/dark mode pair but I anticipate
        // it'll be a common typo.
        if (std.mem.indexOf(u8, input, ",") != null or
            std.mem.indexOf(u8, input, "=") != null or
            std.mem.indexOf(u8, input, ":") != null)
        {
            self.* = try cli.args.parseAutoStruct(
                Theme,
                alloc,
                input,
            );
            return;
        }

        // Trim our value
        const trimmed = std.mem.trim(u8, input, cli.args.whitespace);

        // Set the value to the specified value directly.
        self.* = .{
            .light = try alloc.dupeZ(u8, trimmed),
            .dark = self.light,
        };
    }

    /// Deep copy of the struct. Required by Config.
    pub fn clone(self: *const Theme, alloc: Allocator) Allocator.Error!Theme {
        return .{
            .light = try alloc.dupeZ(u8, self.light),
            .dark = try alloc.dupeZ(u8, self.dark),
        };
    }

    /// Used by Formatter
    pub fn formatEntry(
        self: Theme,
        formatter: anytype,
    ) !void {
        var buf: [4096]u8 = undefined;
        if (std.mem.eql(u8, self.light, self.dark)) {
            try formatter.formatEntry([]const u8, self.light);
            return;
        }

        const str = std.fmt.bufPrint(&buf, "light:{s},dark:{s}", .{
            self.light,
            self.dark,
        }) catch return error.OutOfMemory;
        try formatter.formatEntry([]const u8, str);
    }

    test "parse Theme" {
        const testing = std.testing;
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        // Single
        {
            var v: Theme = undefined;
            try v.parseCLI(alloc, "foo");
            try testing.expectEqualStrings("foo", v.light);
            try testing.expectEqualStrings("foo", v.dark);
        }

        // Single whitespace
        {
            var v: Theme = undefined;
            try v.parseCLI(alloc, "  foo  ");
            try testing.expectEqualStrings("foo", v.light);
            try testing.expectEqualStrings("foo", v.dark);
        }

        // Light/dark
        {
            var v: Theme = undefined;
            try v.parseCLI(alloc, " light:foo,  dark : bar  ");
            try testing.expectEqualStrings("foo", v.light);
            try testing.expectEqualStrings("bar", v.dark);
        }

        var v: Theme = undefined;
        try testing.expectError(error.ValueRequired, v.parseCLI(alloc, null));
        try testing.expectError(error.ValueRequired, v.parseCLI(alloc, ""));
        try testing.expectError(error.InvalidValue, v.parseCLI(alloc, "light:foo"));
        try testing.expectError(error.InvalidValue, v.parseCLI(alloc, "dark:foo"));
    }
};

pub const Duration = struct {
    /// Duration in nanoseconds
    duration: u64 = 0,

    const units = [_]struct {
        name: []const u8,
        factor: u64,
    }{
        // The order is important as the first factor that matches will be the
        // default unit that is used for formatting.
        .{ .name = "y", .factor = 365 * std.time.ns_per_day },
        .{ .name = "w", .factor = std.time.ns_per_week },
        .{ .name = "d", .factor = std.time.ns_per_day },
        .{ .name = "h", .factor = std.time.ns_per_hour },
        .{ .name = "m", .factor = std.time.ns_per_min },
        .{ .name = "s", .factor = std.time.ns_per_s },
        .{ .name = "ms", .factor = std.time.ns_per_ms },
        .{ .name = "µs", .factor = std.time.ns_per_us },
        .{ .name = "us", .factor = std.time.ns_per_us },
        .{ .name = "ns", .factor = 1 },
    };

    pub fn clone(self: *const Duration, _: Allocator) error{}!Duration {
        return .{ .duration = self.duration };
    }

    pub fn equal(self: Duration, other: Duration) bool {
        return self.duration == other.duration;
    }

    pub fn round(self: Duration, to: u64) Duration {
        return .{ .duration = self.duration / to * to };
    }

    pub fn parseCLI(input: ?[]const u8) !Duration {
        var remaining = input orelse return error.ValueRequired;

        var value: ?u64 = null;
        while (remaining.len > 0) {
            // Skip over whitespace before the number
            while (remaining.len > 0 and std.ascii.isWhitespace(remaining[0])) {
                remaining = remaining[1..];
            }

            // There was whitespace at the end, that's OK
            if (remaining.len == 0) break;

            // Find the longest number
            const number: u64 = number: {
                var prev_number: ?u64 = null;
                var prev_remaining: ?[]const u8 = null;
                for (1..remaining.len + 1) |index| {
                    prev_number = std.fmt.parseUnsigned(u64, remaining[0..index], 10) catch {
                        if (prev_remaining) |prev| remaining = prev;
                        break :number prev_number;
                    };
                    prev_remaining = remaining[index..];
                }
                if (prev_remaining) |prev| remaining = prev;
                break :number prev_number;
            } orelse return error.InvalidValue;

            // A number without a unit is invalid unless the number is
            // exactly zero. In that case, the unit is unambiguous since
            // its all the same.
            if (remaining.len == 0) {
                if (number == 0) {
                    value = 0;
                    break;
                }

                return error.InvalidValue;
            }

            // Find the longest matching unit. Needs to be the longest matching
            // to distinguish 'm' from 'ms'.
            const factor = factor: {
                var prev_factor: ?u64 = null;
                var prev_index: ?usize = null;
                for (1..remaining.len + 1) |index| {
                    const next_factor = next: {
                        for (units) |unit| {
                            if (std.mem.eql(u8, unit.name, remaining[0..index])) {
                                break :next unit.factor;
                            }
                        }
                        break :next null;
                    };
                    if (next_factor) |next| {
                        prev_factor = next;
                        prev_index = index;
                    }
                }
                if (prev_index) |index| {
                    remaining = remaining[index..];
                }
                break :factor prev_factor;
            } orelse return error.InvalidValue;

            // Add our time value to the total. Avoid overflow with saturating math.
            const diff = std.math.mul(u64, number, factor) catch std.math.maxInt(u64);
            value = (value orelse 0) +| diff;
        }

        return if (value) |v| .{ .duration = v } else error.ValueRequired;
    }

    pub fn formatEntry(self: Duration, formatter: anytype) !void {
        var buf: [64]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const writer = fbs.writer();
        try self.format("", .{}, writer);
        try formatter.formatEntry([]const u8, fbs.getWritten());
    }

    pub fn format(self: Duration, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        var value = self.duration;
        var i: usize = 0;
        for (units) |unit| {
            if (value >= unit.factor) {
                if (i > 0) writer.writeAll(" ") catch unreachable;
                const remainder = value % unit.factor;
                const quotient = (value - remainder) / unit.factor;
                writer.print("{d}{s}", .{ quotient, unit.name }) catch unreachable;
                value = remainder;
                i += 1;
            }
        }
    }

    pub fn cval(self: Duration) usize {
        return @intCast(self.asMilliseconds());
    }

    /// Convenience function to convert to milliseconds since many OS and
    /// library timing functions operate on that timescale.
    pub fn asMilliseconds(self: Duration) c_uint {
        const ms: u64 = std.math.divTrunc(
            u64,
            self.duration,
            std.time.ns_per_ms,
        ) catch std.math.maxInt(c_uint);
        return std.math.cast(c_uint, ms) orelse std.math.maxInt(c_uint);
    }
};

pub const WindowPadding = struct {
    const Self = @This();

    top_left: u32 = 0,
    bottom_right: u32 = 0,

    pub fn clone(self: Self, _: Allocator) error{}!Self {
        return self;
    }

    pub fn equal(self: Self, other: Self) bool {
        return std.meta.eql(self, other);
    }

    pub fn parseCLI(input_: ?[]const u8) !WindowPadding {
        const input = input_ orelse return error.ValueRequired;
        const whitespace = " \t";

        if (std.mem.indexOf(u8, input, ",")) |idx| {
            const input_left = std.mem.trim(u8, input[0..idx], whitespace);
            const input_right = std.mem.trim(u8, input[idx + 1 ..], whitespace);
            const left = std.fmt.parseInt(u32, input_left, 10) catch
                return error.InvalidValue;
            const right = std.fmt.parseInt(u32, input_right, 10) catch
                return error.InvalidValue;
            return .{ .top_left = left, .bottom_right = right };
        } else {
            const value = std.fmt.parseInt(
                u32,
                std.mem.trim(u8, input, whitespace),
                10,
            ) catch return error.InvalidValue;
            return .{ .top_left = value, .bottom_right = value };
        }
    }

    pub fn formatEntry(self: Self, formatter: anytype) !void {
        var buf: [128]u8 = undefined;
        if (self.top_left == self.bottom_right) {
            try formatter.formatEntry(
                []const u8,
                std.fmt.bufPrint(
                    &buf,
                    "{}",
                    .{self.top_left},
                ) catch return error.OutOfMemory,
            );
        } else {
            try formatter.formatEntry(
                []const u8,
                std.fmt.bufPrint(
                    &buf,
                    "{},{}",
                    .{ self.top_left, self.bottom_right },
                ) catch return error.OutOfMemory,
            );
        }
    }

    test "parse WindowPadding" {
        const testing = std.testing;

        {
            const v = try WindowPadding.parseCLI("100");
            try testing.expectEqual(WindowPadding{
                .top_left = 100,
                .bottom_right = 100,
            }, v);
        }

        {
            const v = try WindowPadding.parseCLI("100,200");
            try testing.expectEqual(WindowPadding{
                .top_left = 100,
                .bottom_right = 200,
            }, v);
        }

        // Trim whitespace
        {
            const v = try WindowPadding.parseCLI(" 100 , 200 ");
            try testing.expectEqual(WindowPadding{
                .top_left = 100,
                .bottom_right = 200,
            }, v);
        }

        try testing.expectError(error.ValueRequired, WindowPadding.parseCLI(null));
        try testing.expectError(error.InvalidValue, WindowPadding.parseCLI(""));
        try testing.expectError(error.InvalidValue, WindowPadding.parseCLI("a"));
    }
};

/// See scroll-to-bottom
pub const ScrollToBottom = packed struct {
    keystroke: bool = true,
    output: bool = false,

    pub const default: ScrollToBottom = .{};
};

test "parse duration" {
    inline for (Duration.units) |unit| {
        var buf: [16]u8 = undefined;
        const t = try std.fmt.bufPrint(&buf, "0{s}", .{unit.name});
        const d = try Duration.parseCLI(t);
        try std.testing.expectEqual(@as(u64, 0), d.duration);
    }

    inline for (Duration.units) |unit| {
        var buf: [16]u8 = undefined;
        const t = try std.fmt.bufPrint(&buf, "1{s}", .{unit.name});
        const d = try Duration.parseCLI(t);
        try std.testing.expectEqual(unit.factor, d.duration);
    }

    {
        const d = try Duration.parseCLI("0");
        try std.testing.expectEqual(@as(u64, 0), d.duration);
    }

    {
        const d = try Duration.parseCLI("100ns");
        try std.testing.expectEqual(@as(u64, 100), d.duration);
    }

    {
        const d = try Duration.parseCLI("1µs");
        try std.testing.expectEqual(@as(u64, 1000), d.duration);
    }

    {
        const d = try Duration.parseCLI("1µs1ns");
        try std.testing.expectEqual(@as(u64, 1001), d.duration);
    }

    {
        const d = try Duration.parseCLI("1µs 1ns");
        try std.testing.expectEqual(@as(u64, 1001), d.duration);
    }

    {
        const d = try Duration.parseCLI(" 1µs1ns");
        try std.testing.expectEqual(@as(u64, 1001), d.duration);
    }

    {
        const d = try Duration.parseCLI("1µs1ns ");
        try std.testing.expectEqual(@as(u64, 1001), d.duration);
    }

    {
        const d = try Duration.parseCLI("30s");
        try std.testing.expectEqual(@as(u64, 30 * std.time.ns_per_s), d.duration);
    }

    {
        const d = try Duration.parseCLI("584y 49w 23h 34m 33s 709ms 551µs 615ns");
        try std.testing.expectEqual(std.math.maxInt(u64), d.duration);
    }

    // Overflow
    {
        const d = try Duration.parseCLI("600y");
        try std.testing.expectEqual(std.math.maxInt(u64), d.duration);
    }

    // Repeated units
    {
        const d = try Duration.parseCLI("100ns100ns");
        try std.testing.expectEqual(@as(u64, 200), d.duration);
    }

    try std.testing.expectError(error.ValueRequired, Duration.parseCLI(null));
    try std.testing.expectError(error.ValueRequired, Duration.parseCLI(""));
    try std.testing.expectError(error.InvalidValue, Duration.parseCLI("1"));
    try std.testing.expectError(error.InvalidValue, Duration.parseCLI("s"));
    try std.testing.expectError(error.InvalidValue, Duration.parseCLI("1x"));
    try std.testing.expectError(error.InvalidValue, Duration.parseCLI("1 "));
}

test "test format" {
    inline for (Duration.units) |unit| {
        const d: Duration = .{ .duration = unit.factor };
        var actual_buf: [16]u8 = undefined;
        const actual = try std.fmt.bufPrint(&actual_buf, "{}", .{d});
        var expected_buf: [16]u8 = undefined;
        const expected = if (!std.mem.eql(u8, unit.name, "us"))
            try std.fmt.bufPrint(&expected_buf, "1{s}", .{unit.name})
        else
            "1µs";
        try std.testing.expectEqualSlices(u8, expected, actual);
    }
}

test "test entryFormatter" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    var p: Duration = .{ .duration = std.math.maxInt(u64) };
    try p.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
    try std.testing.expectEqualStrings("a = 584y 49w 23h 34m 33s 709ms 551µs 615ns\n", buf.items);
}

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

    const cmd = cfg.@"initial-command".?;
    try testing.expect(cmd == .direct);
    try testing.expectEqual(cmd.direct.len, 1);
    try testing.expectEqualStrings(cmd.direct[0], "foo");
}

test "parse e: command and args" {
    const testing = std.testing;
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();
    const alloc = cfg._arena.?.allocator();

    var it: TestIterator = .{ .data = &.{ "echo", "foo", "bar baz" } };
    try testing.expect(!try cfg.parseManuallyHook(alloc, "-e", &it));

    const cmd = cfg.@"initial-command".?;
    try testing.expect(cmd == .direct);
    try testing.expectEqual(cmd.direct.len, 3);
    try testing.expectEqualStrings(cmd.direct[0], "echo");
    try testing.expectEqualStrings(cmd.direct[1], "foo");
    try testing.expectEqualStrings(cmd.direct[2], "bar baz");
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

test "clone preserves conditional state" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var a = try Config.default(alloc);
    defer a.deinit();
    a._conditional_state.theme = .dark;
    try testing.expectEqual(.dark, a._conditional_state.theme);
    var dest = try a.clone(alloc);
    defer dest.deinit();

    // Should have no changes
    var it = a.changeIterator(&dest);
    try testing.expectEqual(@as(?Key, null), it.next());

    // Should have the same conditional state
    try testing.expectEqual(.dark, dest._conditional_state.theme);
}

test "clone can then change conditional state" {
    // This tests a particular bug sequence where:
    //   1. Load light
    //   2. Convert to dark
    //   3. Clone dark
    //   4. Convert to light
    //   5. Config is still dark (bug)
    const testing = std.testing;
    const alloc = testing.allocator;
    var arena = ArenaAllocator.init(alloc);
    defer arena.deinit();
    const alloc_arena = arena.allocator();

    // Setup our test theme
    var td = try internal_os.TempDir.init();
    defer td.deinit();
    {
        var file = try td.dir.createFile("theme_light", .{});
        defer file.close();
        try file.writer().writeAll(@embedFile("testdata/theme_light"));
    }
    {
        var file = try td.dir.createFile("theme_dark", .{});
        defer file.close();
        try file.writer().writeAll(@embedFile("testdata/theme_dark"));
    }
    var light_buf: [std.fs.max_path_bytes]u8 = undefined;
    const light = try td.dir.realpath("theme_light", &light_buf);
    var dark_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dark = try td.dir.realpath("theme_dark", &dark_buf);

    var cfg_light = try Config.default(alloc);
    defer cfg_light.deinit();
    var it: TestIterator = .{ .data = &.{
        try std.fmt.allocPrint(
            alloc_arena,
            "--theme=light:{s},dark:{s}",
            .{ light, dark },
        ),
    } };
    try cfg_light.loadIter(alloc, &it);
    try cfg_light.finalize();

    var cfg_dark = (try cfg_light.changeConditionalState(.{ .theme = .dark })).?;
    defer cfg_dark.deinit();

    try testing.expectEqual(Color{
        .r = 0xEE,
        .g = 0xEE,
        .b = 0xEE,
    }, cfg_dark.background);

    var cfg_clone = try cfg_dark.clone(alloc);
    defer cfg_clone.deinit();
    try testing.expectEqual(Color{
        .r = 0xEE,
        .g = 0xEE,
        .b = 0xEE,
    }, cfg_clone.background);

    var cfg_light2 = (try cfg_clone.changeConditionalState(.{ .theme = .light })).?;
    defer cfg_light2.deinit();
    try testing.expectEqual(Color{
        .r = 0xFF,
        .g = 0xFF,
        .b = 0xFF,
    }, cfg_light2.background);
}

test "clone preserves conditional set" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    var it: TestIterator = .{ .data = &.{
        "--theme=light:foo,dark:bar",
        "--window-theme=auto",
    } };
    try cfg.loadIter(alloc, &it);
    try cfg.finalize();

    var clone1 = try cfg.clone(alloc);
    defer clone1.deinit();

    try testing.expect(clone1._conditional_set.contains(.theme));
}

test "changed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var source = try Config.default(alloc);
    defer source.deinit();
    var dest = try source.clone(alloc);
    defer dest.deinit();
    dest.@"font-thicken" = true;

    try testing.expect(source.changed(&dest, .@"font-thicken"));
    try testing.expect(!source.changed(&dest, .@"font-size"));
}

test "changeConditionalState ignores irrelevant changes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    {
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        var it: TestIterator = .{ .data = &.{
            "--theme=foo",
        } };
        try cfg.loadIter(alloc, &it);
        try cfg.finalize();

        try testing.expect(try cfg.changeConditionalState(
            .{ .theme = .dark },
        ) == null);
    }
}

test "changeConditionalState applies relevant changes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    {
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        var it: TestIterator = .{ .data = &.{
            "--theme=light:foo,dark:bar",
        } };
        try cfg.loadIter(alloc, &it);
        try cfg.finalize();

        var cfg2 = (try cfg.changeConditionalState(.{ .theme = .dark })).?;
        defer cfg2.deinit();

        try testing.expect(cfg2._conditional_set.contains(.theme));
    }
}
test "theme loading" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var arena = ArenaAllocator.init(alloc);
    defer arena.deinit();
    const alloc_arena = arena.allocator();

    // Setup our test theme
    var td = try internal_os.TempDir.init();
    defer td.deinit();
    {
        var file = try td.dir.createFile("theme", .{});
        defer file.close();
        try file.writer().writeAll(@embedFile("testdata/theme_simple"));
    }
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try td.dir.realpath("theme", &path_buf);

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    var it: TestIterator = .{ .data = &.{
        try std.fmt.allocPrint(alloc_arena, "--theme={s}", .{path}),
    } };
    try cfg.loadIter(alloc, &it);
    try cfg.finalize();

    try testing.expectEqual(Color{
        .r = 0x12,
        .g = 0x3A,
        .b = 0xBC,
    }, cfg.background);

    // Not a conditional theme
    try testing.expect(!cfg._conditional_set.contains(.theme));
}

test "theme loading preserves conditional state" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var arena = ArenaAllocator.init(alloc);
    defer arena.deinit();
    const alloc_arena = arena.allocator();

    // Setup our test theme
    var td = try internal_os.TempDir.init();
    defer td.deinit();
    {
        var file = try td.dir.createFile("theme", .{});
        defer file.close();
        try file.writer().writeAll(@embedFile("testdata/theme_simple"));
    }
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try td.dir.realpath("theme", &path_buf);

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg._conditional_state = .{ .theme = .dark };
    var it: TestIterator = .{ .data = &.{
        try std.fmt.allocPrint(alloc_arena, "--theme={s}", .{path}),
    } };
    try cfg.loadIter(alloc, &it);
    try cfg.finalize();

    try testing.expect(cfg._conditional_state.theme == .dark);
}

test "theme priority is lower than config" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var arena = ArenaAllocator.init(alloc);
    defer arena.deinit();
    const alloc_arena = arena.allocator();

    // Setup our test theme
    var td = try internal_os.TempDir.init();
    defer td.deinit();
    {
        var file = try td.dir.createFile("theme", .{});
        defer file.close();
        try file.writer().writeAll(@embedFile("testdata/theme_simple"));
    }
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try td.dir.realpath("theme", &path_buf);

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    var it: TestIterator = .{ .data = &.{
        "--background=#ABCDEF",
        try std.fmt.allocPrint(alloc_arena, "--theme={s}", .{path}),
    } };
    try cfg.loadIter(alloc, &it);
    try cfg.finalize();

    try testing.expectEqual(Color{
        .r = 0xAB,
        .g = 0xCD,
        .b = 0xEF,
    }, cfg.background);
}

test "theme loading correct light/dark" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var arena = ArenaAllocator.init(alloc);
    defer arena.deinit();
    const alloc_arena = arena.allocator();

    // Setup our test theme
    var td = try internal_os.TempDir.init();
    defer td.deinit();
    {
        var file = try td.dir.createFile("theme_light", .{});
        defer file.close();
        try file.writer().writeAll(@embedFile("testdata/theme_light"));
    }
    {
        var file = try td.dir.createFile("theme_dark", .{});
        defer file.close();
        try file.writer().writeAll(@embedFile("testdata/theme_dark"));
    }
    var light_buf: [std.fs.max_path_bytes]u8 = undefined;
    const light = try td.dir.realpath("theme_light", &light_buf);
    var dark_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dark = try td.dir.realpath("theme_dark", &dark_buf);

    // Light
    {
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        var it: TestIterator = .{ .data = &.{
            try std.fmt.allocPrint(
                alloc_arena,
                "--theme=light:{s},dark:{s}",
                .{ light, dark },
            ),
        } };
        try cfg.loadIter(alloc, &it);
        try cfg.finalize();

        try testing.expectEqual(Color{
            .r = 0xFF,
            .g = 0xFF,
            .b = 0xFF,
        }, cfg.background);
    }

    // Dark
    {
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        cfg._conditional_state = .{ .theme = .dark };
        var it: TestIterator = .{ .data = &.{
            try std.fmt.allocPrint(
                alloc_arena,
                "--theme=light:{s},dark:{s}",
                .{ light, dark },
            ),
        } };
        try cfg.loadIter(alloc, &it);
        try cfg.finalize();

        try testing.expectEqual(Color{
            .r = 0xEE,
            .g = 0xEE,
            .b = 0xEE,
        }, cfg.background);
    }

    // Light to Dark
    {
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        var it: TestIterator = .{ .data = &.{
            try std.fmt.allocPrint(
                alloc_arena,
                "--theme=light:{s},dark:{s}",
                .{ light, dark },
            ),
        } };
        try cfg.loadIter(alloc, &it);
        try cfg.finalize();

        var new = (try cfg.changeConditionalState(.{ .theme = .dark })).?;
        defer new.deinit();
        try testing.expectEqual(Color{
            .r = 0xEE,
            .g = 0xEE,
            .b = 0xEE,
        }, new.background);
    }
}

test "theme specifying light/dark changes window-theme from auto" {
    const testing = std.testing;
    const alloc = testing.allocator;

    {
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        var it: TestIterator = .{ .data = &.{
            "--theme=light:foo,dark:bar",
            "--window-theme=auto",
        } };
        try cfg.loadIter(alloc, &it);
        try cfg.finalize();

        try testing.expect(cfg.@"window-theme" == .system);
    }
}

test "theme specifying light/dark sets theme usage in conditional state" {
    const testing = std.testing;
    const alloc = testing.allocator;

    {
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        var it: TestIterator = .{ .data = &.{
            "--theme=light:foo,dark:bar",
            "--window-theme=auto",
        } };
        try cfg.loadIter(alloc, &it);
        try cfg.finalize();

        try testing.expect(cfg.@"window-theme" == .system);
        try testing.expect(cfg._conditional_set.contains(.theme));
    }
}

test "compatibility: gtk-single-instance desktop" {
    const testing = std.testing;
    const alloc = testing.allocator;

    {
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        var it: TestIterator = .{ .data = &.{
            "--gtk-single-instance=desktop",
        } };
        try cfg.loadIter(alloc, &it);

        // We need to test this BEFORE finalize, because finalize will
        // convert our detect to a real value.
        try testing.expectEqual(
            GtkSingleInstance.detect,
            cfg.@"gtk-single-instance",
        );
    }
}

test "compatibility: removed cursor-invert-fg-bg" {
    const testing = std.testing;
    const alloc = testing.allocator;

    {
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        var it: TestIterator = .{ .data = &.{
            "--cursor-invert-fg-bg",
        } };
        try cfg.loadIter(alloc, &it);
        try cfg.finalize();

        try testing.expectEqual(
            TerminalColor.@"cell-foreground",
            cfg.@"cursor-color",
        );
        try testing.expectEqual(
            TerminalColor.@"cell-background",
            cfg.@"cursor-text",
        );
    }
}

test "compatibility: removed selection-invert-fg-bg" {
    const testing = std.testing;
    const alloc = testing.allocator;

    {
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        var it: TestIterator = .{ .data = &.{
            "--selection-invert-fg-bg",
        } };
        try cfg.loadIter(alloc, &it);
        try cfg.finalize();

        try testing.expectEqual(
            TerminalColor.@"cell-background",
            cfg.@"selection-foreground",
        );
        try testing.expectEqual(
            TerminalColor.@"cell-foreground",
            cfg.@"selection-background",
        );
    }
}

test "compatibility: removed bold-is-bright" {
    const testing = std.testing;
    const alloc = testing.allocator;

    {
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        var it: TestIterator = .{ .data = &.{
            "--bold-is-bright",
        } };
        try cfg.loadIter(alloc, &it);
        try cfg.finalize();

        try testing.expectEqual(
            BoldColor.bright,
            cfg.@"bold-color",
        );
    }
}
