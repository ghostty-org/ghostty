/// Determines the macOS option key behavior. See the config
/// `macos-option-as-alt` for a lot more details.
pub const OptionAsAlt = enum(c_int) {
    false,
    true,
    left,
    right,
};
