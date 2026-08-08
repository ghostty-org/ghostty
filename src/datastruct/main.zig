//! The datastruct package contains data structures or anything closely
//! related to data structures.

const array_list_collection = @import("array_list_collection.zig");
const blocking_queue = @import("blocking_queue.zig");
const cache_table = @import("cache_table.zig");
const comparison = @import("comparison.zig");
const circ_buf = @import("circ_buf.zig");
const intrusive_linked_list = @import("intrusive_linked_list.zig");
const segmented_list = @import("segmented_list.zig");
const split_tree = @import("split_tree.zig");

pub const ArrayListCollection = array_list_collection.ArrayListCollection;
pub const BlockingQueue = blocking_queue.BlockingQueue;
pub const CacheTable = cache_table.CacheTable;
pub const CircBuf = circ_buf.CircBuf;
pub const IntrusiveDoublyLinkedList = intrusive_linked_list.DoublyLinkedList;
pub const LimitedAllocator = @import("limited_allocator.zig").LimitedAllocator;
pub const MessageData = @import("message_data.zig").MessageData;
pub const SegmentedList = segmented_list.SegmentedList;
pub const SplitTree = split_tree.SplitTree;
pub const deepEqual = comparison.deepEqual;
pub const expectApproxEqual = comparison.expectApproxEqual;

test {
    @import("std").testing.refAllDecls(@This());
}
