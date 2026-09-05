//! The datastruct package contains data structures or anything closely
//! related to data structures.

const blocking_queue = @import("blocking_queue.zig");
const cache_table = @import("cache_table.zig");
const circ_buf = @import("circ_buf.zig");
const intrusive_linked_list = @import("intrusive_linked_list.zig");
const split_tree = @import("split_tree.zig");

pub const BlockingQueue = blocking_queue.BlockingQueue;
pub const CacheTable = cache_table.CacheTable;
pub const CircBuf = circ_buf.CircBuf;
pub const IntrusiveDoublyLinkedList = intrusive_linked_list.DoublyLinkedList;
pub const LimitedAllocator = @import("limited_allocator.zig").LimitedAllocator;
pub const MessageData = @import("message_data.zig").MessageData;
pub const SplitTree = split_tree.SplitTree;
pub const UntouchedPool = @import("untouched_pool.zig").UntouchedPool;
pub const WasmPagePool = @import("wasm_page_pool.zig").WasmPagePool;

test {
    @import("std").testing.refAllDecls(@This());

    _ = @import("comparison.zig");
}
