/// Target for xcframework builds. This is a separate file so that
/// our runtime code doesn't need to import build code.
pub const Target = enum { native, universal };
