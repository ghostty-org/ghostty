const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const configpkg = @import("../config.zig");
const font = @import("../font/main.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");

/// The messages that can be sent to a renderer thread.
pub const Message = union(enum) {
    /// Purposely crash the renderer. This is used for testing and debugging.
    /// See the "crash" binding action.
    crash,

    /// A change in state in the window focus that this renderer is
    /// rendering within. This is only sent when a change is detected so
    /// the renderer is expected to handle all of these.
    focus: bool,

    /// A change in the view occlusion state. This can be used to determine
    /// if the window is visible or not. A window can be not visible (occluded)
    /// and still have focus.
    visible: bool,

    /// Reset the cursor blink by immediately showing the cursor then
    /// restarting the timer.
    reset_cursor_blink,

    /// Change the font grid. This can happen for any number of reasons
    /// including a font size change, family change, etc.
    font_grid: struct {
        grid: *font.SharedGrid,
        set: *font.SharedGridSet,

        // The key for the new grid. If adopting the new grid fails for any
        // reason, the old grid should be kept but the new key should be
        // dereferenced.
        new_key: font.SharedGridSet.Key,

        // After accepting the new grid, the old grid must be dereferenced
        // using the fields below.
        old_key: font.SharedGridSet.Key,
    },

    /// Changes the size. The screen size might change, padding, grid, etc.
    resize: renderer.Size,

    /// The derived configuration to update the renderer with.
    change_config: struct {
        alloc: Allocator,
        thread: *renderer.Thread.DerivedConfig,
        impl: *renderer.Renderer.DerivedConfig,
    },

    /// Matches for the current viewport from the search thread. These happen
    /// async so they may be off for a frame or two from the actually rendered
    /// viewport. The renderer must handle this gracefully.
    search_viewport_matches: SearchMatches,

    /// The selected match from the search thread. May be null to indicate
    /// no match currently.
    search_selected_match: ?SearchMatch,

    /// Activate or deactivate the inspector.
    inspector: bool,

    /// The macOS display ID has changed for the window.
    macos_display_id: u32,

    pub const SearchMatches = struct {
        arena: ArenaAllocator,
        matches: []const terminal.highlight.Flattened,
    };

    pub const SearchMatch = struct {
        arena: ArenaAllocator,
        match: terminal.highlight.Flattened,
    };

    /// Initialize a change_config message.
    pub fn initChangeConfig(alloc: Allocator, config: *const configpkg.Config) !Message {
        const thread_ptr = try alloc.create(renderer.Thread.DerivedConfig);
        errdefer alloc.destroy(thread_ptr);
        const config_ptr = try alloc.create(renderer.Renderer.DerivedConfig);
        errdefer alloc.destroy(config_ptr);

        thread_ptr.* = renderer.Thread.DerivedConfig.init(config);
        config_ptr.* = try renderer.Renderer.DerivedConfig.init(alloc, config);
        errdefer config_ptr.deinit();

        return .{
            .change_config = .{
                .alloc = alloc,
                .thread = thread_ptr,
                .impl = config_ptr,
            },
        };
    }

    pub fn deinit(self: *const Message) void {
        switch (self.*) {
            .change_config => |v| {
                v.impl.deinit();
                v.alloc.destroy(v.impl);
                v.alloc.destroy(v.thread);
            },

            else => {},
        }
    }
};
