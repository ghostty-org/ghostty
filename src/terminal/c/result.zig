/// C: GhosttyResult
pub const Result = enum(c_int) {
    success = 0,
    out_of_memory = -1,
    invalid_value = -2,
    out_of_space = -3,
    no_value = -4,
    io_error = -5,
    limit_exceeded = -6,
    rejected = -7,
};
