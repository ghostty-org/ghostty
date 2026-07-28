/// The clipboard destination for a write.
pub const Location = enum(c_int) {
    standard = 0,
    selection = 1,
    primary = 2,
    _,
};

/// A single representation of clipboard data.
///
/// The MIME type and data are borrowed and only valid for the duration of a
/// clipboard write callback. Data is binary-safe.
pub const Content = struct {
    mime: []const u8,
    data: []const u8,
};

/// One atomic clipboard write.
///
/// Contents are borrowed and only valid for the duration of a clipboard write
/// callback. An empty contents slice clears the destination.
pub const Write = struct {
    location: Location,
    contents: []const Content,
};

/// The result of a clipboard write.
pub const WriteResult = enum(c_int) {
    success = 0,
    denied = 1,
    unsupported = 2,
    busy = 3,
    invalid_data = 4,
    io_error = 5,
    _,
};
