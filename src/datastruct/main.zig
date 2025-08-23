//! The datastruct package contains data structures or anything closely
//! related to data structures.

const blocking_queue = @import("blocking_queue.zig");
const cache_table = @import("cache_table.zig");
const circ_buf = @import("circ_buf.zig");
const intrusive_linked_list = @import("intrusive_linked_list.zig");
const segmented_pool = @import("segmented_pool.zig");
const split_tree = @import("split_tree.zig");

pub const lru = @import("lru.zig");
pub const BlockingQueue = blocking_queue.BlockingQueue;
pub const CacheTable = cache_table.CacheTable;
pub const CircBuf = circ_buf.CircBuf;
pub const IntrusiveDoublyLinkedList = intrusive_linked_list.DoublyLinkedList;
pub const SegmentedPool = segmented_pool.SegmentedPool;
pub const SplitTree = split_tree.SplitTree;

test {
    @import("std").testing.refAllDecls(@This());
}
