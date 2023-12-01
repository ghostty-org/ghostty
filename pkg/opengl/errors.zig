const std = @import("std");
const c = @import("c.zig");
const glad = @import("glad.zig");

pub const Error = error{
    InvalidEnum,
    InvalidValue,
    InvalidOperation,
    InvalidFramebufferOperation,
    OutOfMemory,

    Unknown,
};

/// getError returns the error (if any) from the last OpenGL operation.
pub fn getError() Error!void {
    return switch (glad.context.GetError.?()) {
        c.GL_NO_ERROR => {},
        c.GL_INVALID_ENUM => Error.InvalidEnum,
        c.GL_INVALID_VALUE => Error.InvalidValue,
        c.GL_INVALID_OPERATION => Error.InvalidOperation,
        c.GL_INVALID_FRAMEBUFFER_OPERATION => Error.InvalidFramebufferOperation,
        c.GL_OUT_OF_MEMORY => Error.OutOfMemory,
        else => Error.Unknown,
    };
}

/// mustError just calls getError but always results in an error being returned.
/// If getError has no error, then Unknown is returned.
pub fn mustError() Error!void {
    try getError();
    return Error.Unknown;
}
