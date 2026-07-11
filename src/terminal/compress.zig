//! Compression primitives used by the terminal.
//!
//! This namespace contains only the representation and codecs. Policy about
//! which pages to compress, when to decommit their resident memory, and when
//! to restore them belongs to `PageList`.

/// The raw LZ4 block codec used for terminal page memory.
pub const lz4 = @import("compress/lz4.zig");

/// A compressed terminal page which retains its original virtual mapping.
pub const Page = @import("compress/Page.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
