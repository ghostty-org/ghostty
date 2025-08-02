const std = @import("std");
const Allocator = std.mem.Allocator;

const apprt = @import("../apprt.zig");
const build_config = @import("../build_config.zig");
const App = @import("../App.zig");
const Surface = @import("../Surface.zig");
const renderer = @import("../renderer.zig");
const termio = @import("../termio.zig");
const terminal = @import("../terminal/main.zig");
const Config = @import("../config.zig").Config;

/// The message types that can be sent to a single surface.
pub const Message = union(enum) {
    /// Represents a write request. Magic number comes from the max size
    /// we want this union to be.
    pub const WriteReq = termio.MessageData(u8, 255);

    /// Set the title of the surface.
    /// TODO: we should change this to a "WriteReq" style structure in
    /// the termio message so that we can more efficiently send strings
    /// of any length
    set_title: [256]u8,

    /// Report the window title back to the terminal
    report_title: ReportTitleStyle,

    /// Set the mouse shape.
    set_mouse_shape: terminal.MouseShape,

    /// Read the clipboard and write to the pty.
    clipboard_read: apprt.Clipboard,

    /// Write the clipboard contents.
    clipboard_write: struct {
        clipboard_type: apprt.Clipboard,
        req: WriteReq,
    },

    /// Change the configuration to the given configuration. The pointer is
    /// not valid after receiving this message so any config must be used
    /// and derived immediately.
    change_config: *const Config,

    /// Close the surface. This will only close the current surface that
    /// receives this, not the full application.
    close: void,

    /// The child process running in the surface has exited. This may trigger
    /// a surface close, it may not. Additional details about the child
    /// command are given in the `ChildExited` struct.
    child_exited: ChildExited,

    /// Show a desktop notification.
    desktop_notification: struct {
        /// Desktop notification title.
        title: [63:0]u8,

        /// Desktop notification body.
        body: [255:0]u8,
    },

    /// Health status change for the renderer.
    renderer_health: renderer.Health,

    /// Report the color scheme. The bool parameter is whether to force or not.
    /// If force is true, the color scheme should be reported even if mode
    /// 2031 is not set.
    report_color_scheme: bool,

    /// Tell the surface to present itself to the user. This may require raising
    /// a window and switching tabs.
    present_surface: void,

    /// Notifies the surface that password input has started within
    /// the terminal. This should always be followed by a false value
    /// unless the surface exits.
    password_input: bool,

    /// A terminal color was changed using OSC sequences.
    color_change: struct {
        kind: terminal.osc.Command.ColorOperation.Kind,
        color: terminal.color.RGB,
    },

    /// Notifies the surface that a tick of the timer that is timing
    /// out selection scrolling has occurred. "selection scrolling"
    /// is when the user has clicked and dragged the mouse outside
    /// the viewport of the terminal and the terminal is scrolling
    /// the viewport to follow the mouse cursor.
    selection_scroll_tick: bool,

    /// The terminal has reported a change in the working directory.
    pwd_change: WriteReq,

    /// The terminal encountered a bell character.
    ring_bell,

    /// Report the progress of an action using a GUI element
    progress_report: terminal.osc.Command.ProgressReport,

    pub const ReportTitleStyle = enum {
        csi_21_t,

        // This enum is a placeholder for future title styles.
    };

    pub const ChildExited = extern struct {
        exit_code: u32,
        runtime_ms: u64,

        /// Make this a valid gobject if we're in a GTK environment.
        pub const getGObjectType = switch (build_config.app_runtime) {
            .gtk,
            .@"gtk-ng",
            => @import("gobject").ext.defineBoxed(
                ChildExited,
                .{ .name = "GhosttyApprtChildExited" },
            ),

            .none => void,
        };
    };
};

/// A surface mailbox.
pub const Mailbox = struct {
    surface: *Surface,
    app: App.Mailbox,

    /// Send a message to the surface.
    pub fn push(
        self: Mailbox,
        msg: Message,
        timeout: App.Mailbox.Queue.Timeout,
    ) App.Mailbox.Queue.Size {
        // Surface message sending is actually implemented on the app
        // thread, so we have to rewrap the message with our surface
        // pointer and send it to the app thread.
        return self.app.push(.{
            .surface_message = .{
                .surface = self.surface,
                .message = msg,
            },
        }, timeout);
    }
};

/// Context for new surface creation to determine inheritance behavior
pub const NewSurfaceContext = enum {
    tab,
    window,
    split,
};

/// Returns a new config for a surface for the given app that should be
/// used for any new surfaces. The resulting config should be deinitialized
/// after the surface is initialized.
pub fn newConfig(
    app: *const App,
    config: *const Config,
    context: NewSurfaceContext,
    parent: ?*const Surface,
) Allocator.Error!Config {
    // Create a shallow clone
    var copy = config.shallowClone(app.alloc);

    // Our allocator is our config's arena
    const alloc = copy._arena.?.allocator();

    // Use the parent surface if provided, otherwise fall back to focused surface
    const inherit_from = parent orelse app.focusedSurface();
    
    if (inherit_from) |p| {
        // Determine if we should inherit working directory based on context
        const should_inherit = switch (context) {
            .tab => config.@"tab-inherit-working-directory",
            .window => config.@"window-inherit-working-directory",
            .split => config.@"split-inherit-working-directory",
        };
        
        if (should_inherit) {
            if (try p.pwd(alloc)) |pwd| {
                copy.@"working-directory" = pwd;
            }
        }
    }

    return copy;
}

// Tests

const testing = std.testing;

test "newConfig: tab inherits working directory when enabled" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Create a test config with tab inheritance enabled
    var base_config = try Config.default(testing.allocator);
    defer base_config.deinit();
    base_config.@"window-inherit-working-directory" = false;
    base_config.@"tab-inherit-working-directory" = true;
    base_config.@"working-directory" = "/default";

    // Create a mock app with no focused surface
    const MockApp = struct {
        alloc: Allocator,
        
        pub fn focusedSurface(self: *const @This()) ?*const Surface {
            _ = self;
            return null;
        }
    };
    
    var mock_app = MockApp{ .alloc = alloc };

    // Create a mock parent surface with a current working directory
    const MockSurface = struct {
        current_pwd: []const u8,
        
        pub fn pwd(self: *const @This(), allocator: Allocator) !?[]const u8 {
            return try allocator.dupe(u8, self.current_pwd);
        }
    };
    
    var parent_surface = MockSurface{ .current_pwd = "/parent/directory" };

    // Test tab creation - should inherit from parent
    {
        var config = try newConfig(&mock_app, &base_config, .tab, &parent_surface);
        defer config.deinit();
        
        try testing.expect(config.@"working-directory" != null);
        try testing.expectEqualStrings("/parent/directory", config.@"working-directory".?);
    }

    // Test window creation - should NOT inherit (window inheritance disabled)
    {
        var config = try newConfig(&mock_app, &base_config, .window, &parent_surface);
        defer config.deinit();
        
        // Should use the default working directory since window inheritance is disabled
        try testing.expectEqualStrings("/default", config.@"working-directory".?);
    }
}

test "newConfig: window inherits working directory when enabled" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Create a test config with window inheritance enabled, tab inheritance disabled
    var base_config = try Config.default(testing.allocator);
    defer base_config.deinit();
    base_config.@"window-inherit-working-directory" = true;
    base_config.@"tab-inherit-working-directory" = false;
    base_config.@"working-directory" = "/default";

    // Create a mock app with no focused surface
    const MockApp = struct {
        alloc: Allocator,
        
        pub fn focusedSurface(self: *const @This()) ?*const Surface {
            _ = self;
            return null;
        }
    };
    
    var mock_app = MockApp{ .alloc = alloc };

    // Create a mock parent surface with a current working directory
    const MockSurface = struct {
        current_pwd: []const u8,
        
        pub fn pwd(self: *const @This(), allocator: Allocator) !?[]const u8 {
            return try allocator.dupe(u8, self.current_pwd);
        }
    };
    
    var parent_surface = MockSurface{ .current_pwd = "/parent/directory" };

    // Test window creation - should inherit from parent
    {
        var config = try newConfig(&mock_app, &base_config, .window, &parent_surface);
        defer config.deinit();
        
        try testing.expect(config.@"working-directory" != null);
        try testing.expectEqualStrings("/parent/directory", config.@"working-directory".?);
    }

    // Test tab creation - should NOT inherit (tab inheritance disabled)
    {
        var config = try newConfig(&mock_app, &base_config, .tab, &parent_surface);
        defer config.deinit();
        
        // Should use the default working directory since tab inheritance is disabled
        try testing.expectEqualStrings("/default", config.@"working-directory".?);
    }
}

test "newConfig: no inheritance when both disabled" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Create a test config with both inheritance settings disabled
    var base_config = try Config.default(testing.allocator);
    defer base_config.deinit();
    base_config.@"window-inherit-working-directory" = false;
    base_config.@"tab-inherit-working-directory" = false;
    base_config.@"working-directory" = "/default";

    // Create a mock app with no focused surface
    const MockApp = struct {
        alloc: Allocator,
        
        pub fn focusedSurface(self: *const @This()) ?*const Surface {
            _ = self;
            return null;
        }
    };
    
    var mock_app = MockApp{ .alloc = alloc };

    // Create a mock parent surface with a current working directory
    const MockSurface = struct {
        current_pwd: []const u8,
        
        pub fn pwd(self: *const @This(), allocator: Allocator) !?[]const u8 {
            return try allocator.dupe(u8, self.current_pwd);
        }
    };
    
    var parent_surface = MockSurface{ .current_pwd = "/parent/directory" };

    // Test both tab and window creation - neither should inherit
    {
        var tab_config = try newConfig(&mock_app, &base_config, .tab, &parent_surface);
        defer tab_config.deinit();
        
        var window_config = try newConfig(&mock_app, &base_config, .window, &parent_surface);
        defer window_config.deinit();
        
        // Both should use the default working directory
        try testing.expectEqualStrings("/default", tab_config.@"working-directory".?);
        try testing.expectEqualStrings("/default", window_config.@"working-directory".?);
    }
}

test "newConfig: no parent surface uses default directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Create a test config with inheritance enabled
    var base_config = try Config.default(testing.allocator);
    defer base_config.deinit();
    base_config.@"window-inherit-working-directory" = true;
    base_config.@"tab-inherit-working-directory" = true;
    base_config.@"working-directory" = "/default";

    // Create a mock app with no focused surface
    const MockApp = struct {
        alloc: Allocator,
        
        pub fn focusedSurface(self: *const @This()) ?*const Surface {
            _ = self;
            return null;
        }
    };
    
    var mock_app = MockApp{ .alloc = alloc };

    // Test with no parent surface provided
    {
        var tab_config = try newConfig(&mock_app, &base_config, .tab, null);
        defer tab_config.deinit();
        
        var window_config = try newConfig(&mock_app, &base_config, .window, null);
        defer window_config.deinit();
        
        // Both should use the default working directory since there's no parent to inherit from
        try testing.expectEqualStrings("/default", tab_config.@"working-directory".?);
        try testing.expectEqualStrings("/default", window_config.@"working-directory".?);
    }
}

test "newConfig: split inherits working directory when enabled" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Create a test config with split inheritance enabled
    var base_config = try Config.default(testing.allocator);
    defer base_config.deinit();
    base_config.@"window-inherit-working-directory" = false;
    base_config.@"tab-inherit-working-directory" = false;
    base_config.@"split-inherit-working-directory" = true;
    base_config.@"working-directory" = "/default";

    // Create a mock app with no focused surface
    const MockApp = struct {
        alloc: Allocator,
        
        pub fn focusedSurface(self: *const @This()) ?*const Surface {
            _ = self;
            return null;
        }
    };
    
    var mock_app = MockApp{ .alloc = alloc };

    // Create a mock parent surface with a current working directory
    const MockSurface = struct {
        current_pwd: []const u8,
        
        pub fn pwd(self: *const @This(), allocator: Allocator) !?[]const u8 {
            return try allocator.dupe(u8, self.current_pwd);
        }
    };
    
    var parent_surface = MockSurface{ .current_pwd = "/parent/directory" };

    // Test split creation - should inherit from parent
    {
        var config = try newConfig(&mock_app, &base_config, .split, &parent_surface);
        defer config.deinit();
        
        try testing.expect(config.@"working-directory" != null);
        try testing.expectEqualStrings("/parent/directory", config.@"working-directory".?);
    }

    // Test window creation - should NOT inherit (window inheritance disabled)
    {
        var config = try newConfig(&mock_app, &base_config, .window, &parent_surface);
        defer config.deinit();
        
        // Should use the default working directory since window inheritance is disabled
        try testing.expectEqualStrings("/default", config.@"working-directory".?);
    }

    // Test tab creation - should NOT inherit (tab inheritance disabled)
    {
        var config = try newConfig(&mock_app, &base_config, .tab, &parent_surface);
        defer config.deinit();
        
        // Should use the default working directory since tab inheritance is disabled
        try testing.expectEqualStrings("/default", config.@"working-directory".?);
    }
}
