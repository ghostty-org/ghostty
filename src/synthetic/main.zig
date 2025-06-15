//! The synthetic package contains an abstraction for generating
//! synthetic data. The motivating use case for this package is to
//! generate synthetic data for benchmarking, but it may also expand
//! to other use cases such as fuzzing (e.g. to generate a corpus
//! rather than directly fuzzing).
//!
//! The generators in this package are typically not performant
//! enough to be streamed in real time. They should instead be
//! used to generate a large amount of data in a single go
//! and then streamed from there.
//!
//! The generators are aimed for terminal emulation, but the package
//! is not limited to that and we may want to extract this to a
//! standalone package one day.

pub const Generator = @import("Generator.zig");
pub const Bytes = @import("Bytes.zig");
pub const Utf8 = @import("Utf8.zig");
pub const Osc = @import("Osc.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
