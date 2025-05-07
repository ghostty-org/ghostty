//! A library represents the shared state that the underlying font
//! library implementation(s) require per-process.
const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const options = @import("main.zig").options;
const freetype = @import("freetype");
const font = @import("main.zig");

/// Library implementation for the compile options.
pub const Library = switch (options.backend) {
    // Freetype requires a state library
    .freetype,
    .fontconfig_freetype,
    .coretext_freetype,
    => FreetypeLibrary,

    // Some backends such as CT and Canvas don't have a "library"
    .coretext,
    .coretext_harfbuzz,
    .coretext_noshape,
    .web_canvas,
    => NoopLibrary,
};

pub const FreetypeLibrary = struct {
    lib: freetype.Library,

    alloc: Allocator,

    /// Mutex to be held any time the library is
    /// being used to create or destroy a face.
    mutex: *std.Thread.Mutex,

    pub const InitError = freetype.Error || Allocator.Error;

    pub fn init(alloc: Allocator) InitError!Library {
        const lib = try freetype.Library.init();
        errdefer lib.deinit();

        const mutex = try alloc.create(std.Thread.Mutex);
        mutex.* = .{};

        return Library{ .lib = lib, .alloc = alloc, .mutex = mutex };
    }

    pub fn deinit(self: *Library) void {
        self.alloc.destroy(self.mutex);
        self.lib.deinit();
    }
};

pub const NoopLibrary = struct {
    pub const InitError = error{};

    pub fn init(alloc: Allocator) InitError!Library {
        _ = alloc;
        return Library{};
    }

    pub fn deinit(self: *Library) void {
        _ = self;
    }
};
