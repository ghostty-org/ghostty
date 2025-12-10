/// The target for ABI generation. The detection of this is left to the
/// caller since there are multiple ways to do that.
pub const Target = union(enum) {
    c,
    zig,
};
