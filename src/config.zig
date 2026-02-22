const builtin = @import("builtin");

const file_load = @import("config/file_load.zig");
const formatter = @import("config/formatter.zig");
pub const Config = @import("config/Config.zig");
pub const ConfigOverrides = @import("config/ConfigOverrides.zig");
pub const conditional = @import("config/conditional.zig");
pub const io = @import("config/io.zig");
pub const string = @import("config/string.zig");
pub const edit = @import("config/edit.zig");
pub const url = @import("config/url.zig");

pub const ConditionalState = conditional.State;
pub const FileFormatter = formatter.FileFormatter;
pub const entryFormatter = formatter.entryFormatter;
pub const formatEntry = formatter.formatEntry;
pub const preferredDefaultFilePath = file_load.preferredDefaultFilePath;

// Field types
pub const BoldColor = Config.BoldColor;
pub const ClipboardAccess = Config.ClipboardAccess;
pub const Command = Config.Command;
pub const ConfirmCloseSurface = Config.ConfirmCloseSurface;
pub const CopyOnSelect = Config.CopyOnSelect;
pub const RightClickAction = Config.RightClickAction;
pub const CustomShaderAnimation = Config.CustomShaderAnimation;
pub const FontSyntheticStyle = Config.FontSyntheticStyle;
pub const FontShapingBreak = Config.FontShapingBreak;
pub const FontStyle = Config.FontStyle;
pub const FreetypeLoadFlags = Config.FreetypeLoadFlags;
pub const Keybinds = Config.Keybinds;
pub const MouseShiftCapture = Config.MouseShiftCapture;
pub const MouseScrollMultiplier = Config.MouseScrollMultiplier;
pub const NonNativeFullscreen = Config.NonNativeFullscreen;
pub const Fullscreen = Config.Fullscreen;
pub const RepeatableCodepointMap = Config.RepeatableCodepointMap;
pub const RepeatableFontVariation = Config.RepeatableFontVariation;
pub const RepeatableString = Config.RepeatableString;
pub const RepeatableStringMap = @import("config/RepeatableStringMap.zig");
pub const RepeatablePath = Config.RepeatablePath;
pub const Path = Config.Path;
pub const ShellIntegrationFeatures = Config.ShellIntegrationFeatures;
pub const WindowDecoration = Config.WindowDecoration;
pub const WindowPaddingColor = Config.WindowPaddingColor;
pub const BackgroundImagePosition = Config.BackgroundImagePosition;
pub const BackgroundImageFit = Config.BackgroundImageFit;
pub const LinkPreviews = Config.LinkPreviews;

// Alternate APIs
pub const CApi = @import("config/CApi.zig");
pub const Wasm = if (!builtin.target.cpu.arch.isWasm()) struct {} else @import("config/Wasm.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
