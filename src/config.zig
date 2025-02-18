const builtin = @import("builtin");

const formatter = @import("config/formatter.zig");
pub const Config = @import("config/Config.zig");
pub const conditional = @import("config/conditional.zig");
pub const string = @import("config/string.zig");
pub const edit = @import("config/edit.zig");
pub const url = @import("config/url.zig");

pub const ConditionalState = conditional.State;
pub const FileFormatter = formatter.FileFormatter;
pub const entryFormatter = formatter.entryFormatter;
pub const formatEntry = formatter.formatEntry;

// Field types
pub const ClipboardAccess = Config.ClipboardAccess;
pub const ConfirmCloseSurface = Config.ConfirmCloseSurface;
pub const CopyOnSelect = Config.CopyOnSelect;
pub const CustomShaderAnimation = Config.CustomShaderAnimation;
pub const FontSyntheticStyle = Config.FontSyntheticStyle;
pub const FontStyle = Config.FontStyle;
pub const FreetypeLoadFlags = Config.FreetypeLoadFlags;
pub const Keybinds = Config.Keybinds;
pub const MouseShiftCapture = Config.MouseShiftCapture;
pub const NonNativeFullscreen = Config.NonNativeFullscreen;
pub const OptionAsAlt = Config.OptionAsAlt;
pub const RepeatableCodepointMap = Config.RepeatableCodepointMap;
pub const RepeatableFontVariation = Config.RepeatableFontVariation;
pub const RepeatableString = Config.RepeatableString;
pub const RepeatableStringMap = @import("config/RepeatableStringMap.zig");
pub const RepeatablePath = Config.RepeatablePath;
pub const ShellIntegrationFeatures = Config.ShellIntegrationFeatures;
pub const WindowPaddingColor = Config.WindowPaddingColor;

// Alternate APIs
pub const CAPI = @import("config/CAPI.zig");
pub const Wasm = if (!builtin.target.isWasm()) struct {} else @import("config/Wasm.zig");

test {
    @import("std").testing.refAllDecls(@This());

    // Vim syntax file, not used at runtime but we want to keep it tested.
    _ = @import("config/vim.zig");
}
