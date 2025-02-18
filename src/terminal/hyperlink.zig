const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const hash_map = @import("hash_map.zig");
const AutoOffsetHashMap = hash_map.AutoOffsetHashMap;
const pagepkg = @import("page.zig");
const size = @import("size.zig");
const Offset = size.Offset;
const Cell = pagepkg.Cell;
const Page = pagepkg.Page;
const RefCountedSet = @import("ref_counted_set.zig").RefCountedSet;
const Wyhash = std.hash.Wyhash;
const autoHash = std.hash.autoHash;
const autoHashStrat = std.hash.autoHashStrat;

/// The unique identifier for a hyperlink. This is at most the number of cells
/// that can fit in a single terminal page.
pub const Id = size.CellCountInt;

// The mapping of cell to hyperlink. We use an offset hash map to save space
// since its very unlikely a cell is a hyperlink, so its a waste to store
// the hyperlink ID in the cell itself.
pub const Map = AutoOffsetHashMap(Offset(Cell), Id);

/// A fully decoded hyperlink that may or may not have its
/// memory within a page. The memory location of this is dependent
/// on the context so users should check with the source of the
/// hyperlink.
pub const Hyperlink = struct {
    id: Hyperlink.Id,
    uri: []const u8,

    /// See PageEntry.Id
    pub const Id = union(enum) {
        explicit: []const u8,
        implicit: size.OffsetInt,
    };

    /// Deinit and deallocate all the pointers using the given
    /// allocator.
    ///
    /// WARNING: This should only be called if the hyperlink was
    /// heap-allocated. This DOES NOT need to be unconditionally
    /// called.
    pub fn deinit(self: *const Hyperlink, alloc: Allocator) void {
        alloc.free(self.uri);
        switch (self.id) {
            .implicit => {},
            .explicit => |v| alloc.free(v),
        }
    }

    /// Duplicate a hyperlink by allocating all values with the
    /// given allocator. The returned hyperlink should have deinit
    /// called.
    pub fn dupe(
        self: *const Hyperlink,
        alloc: Allocator,
    ) Allocator.Error!Hyperlink {
        const uri = try alloc.dupe(u8, self.uri);
        errdefer alloc.free(uri);

        const id: Hyperlink.Id = switch (self.id) {
            .implicit => self.id,
            .explicit => |v| .{ .explicit = try alloc.dupe(u8, v) },
        };
        errdefer switch (id) {
            .implicit => {},
            .explicit => |v| alloc.free(v),
        };

        return .{ .id = id, .uri = uri };
    }
};

/// A hyperlink that has been committed to page memory. This
/// is a "page entry" because while it represents a hyperlink,
/// some decoding (pointer chasing) is still necessary to get the
/// fully realized ID, URI, etc.
pub const PageEntry = struct {
    id: PageEntry.Id,
    uri: Offset(u8).Slice,

    pub const Id = union(enum) {
        /// An explicitly provided ID via the OSC8 sequence.
        explicit: Offset(u8).Slice,

        /// No ID was provided so we auto-generate the ID based on an
        /// incrementing counter attached to the screen.
        implicit: size.OffsetInt,
    };

    /// Duplicate this hyperlink from one page to another.
    pub fn dupe(
        self: *const PageEntry,
        self_page: *const Page,
        dst_page: *Page,
    ) error{OutOfMemory}!PageEntry {
        var copy = self.*;

        // If the pages are the same then we can return a shallow copy.
        if (self_page == dst_page) return copy;

        // Copy the URI
        {
            const uri = self.uri.offset.ptr(self_page.memory)[0..self.uri.len];
            const buf = try dst_page.string_alloc.alloc(u8, dst_page.memory, uri.len);
            @memcpy(buf, uri);
            copy.uri = .{
                .offset = size.getOffset(u8, dst_page.memory, &buf[0]),
                .len = uri.len,
            };
        }
        errdefer dst_page.string_alloc.free(
            dst_page.memory,
            copy.uri.offset.ptr(dst_page.memory)[0..copy.uri.len],
        );

        // Copy the ID
        switch (copy.id) {
            .implicit => {}, // Shallow is fine
            .explicit => |slice| {
                const id = slice.offset.ptr(self_page.memory)[0..slice.len];
                const buf = try dst_page.string_alloc.alloc(u8, dst_page.memory, id.len);
                @memcpy(buf, id);
                copy.id = .{ .explicit = .{
                    .offset = size.getOffset(u8, dst_page.memory, &buf[0]),
                    .len = id.len,
                } };
            },
        }
        errdefer switch (copy.id) {
            .implicit => {},
            .explicit => |v| dst_page.string_alloc.free(
                dst_page.memory,
                v.offset.ptr(dst_page.memory)[0..v.len],
            ),
        };

        return copy;
    }

    pub fn hash(self: *const PageEntry, base: anytype) u64 {
        var hasher = Wyhash.init(0);
        autoHash(&hasher, std.meta.activeTag(self.id));
        switch (self.id) {
            .implicit => |v| autoHash(&hasher, v),
            .explicit => |slice| autoHashStrat(
                &hasher,
                slice.offset.ptr(base)[0..slice.len],
                .Deep,
            ),
        }
        autoHashStrat(
            &hasher,
            self.uri.offset.ptr(base)[0..self.uri.len],
            .Deep,
        );
        return hasher.final();
    }

    pub fn eql(
        self: *const PageEntry,
        self_base: anytype,
        other: *const PageEntry,
        other_base: anytype,
    ) bool {
        if (std.meta.activeTag(self.id) != std.meta.activeTag(other.id)) return false;
        switch (self.id) {
            .implicit => if (self.id.implicit != other.id.implicit) return false,
            .explicit => {
                const self_ptr = self.id.explicit.offset.ptr(self_base);
                const other_ptr = other.id.explicit.offset.ptr(other_base);
                if (!std.mem.eql(
                    u8,
                    self_ptr[0..self.id.explicit.len],
                    other_ptr[0..other.id.explicit.len],
                )) return false;
            },
        }

        return std.mem.eql(
            u8,
            self.uri.offset.ptr(self_base)[0..self.uri.len],
            other.uri.offset.ptr(other_base)[0..other.uri.len],
        );
    }
};

/// The set of hyperlinks. This is ref-counted so that a set of cells
/// can share the same hyperlink without duplicating the data.
pub const Set = RefCountedSet(
    PageEntry,
    Id,
    size.CellCountInt,
    struct {
        /// The page which holds the strings for items in this set.
        page: ?*Page = null,

        /// The page which holds the strings for items
        /// looked up with, e.g., `add` or `lookup`,
        /// if different from the destination page.
        src_page: ?*const Page = null,

        pub fn hash(self: *const @This(), link: PageEntry) u64 {
            return link.hash((self.src_page orelse self.page.?).memory);
        }

        pub fn eql(self: *const @This(), a: PageEntry, b: PageEntry) bool {
            return a.eql(
                (self.src_page orelse self.page.?).memory,
                &b,
                self.page.?.memory,
            );
        }

        pub fn deleted(self: *const @This(), link: PageEntry) void {
            const page = self.page.?;
            const alloc = &page.string_alloc;
            switch (link.id) {
                .implicit => {},
                .explicit => |v| alloc.free(
                    page.memory,
                    v.offset.ptr(page.memory)[0..v.len],
                ),
            }
            alloc.free(
                page.memory,
                link.uri.offset.ptr(page.memory)[0..link.uri.len],
            );
        }
    },
);
