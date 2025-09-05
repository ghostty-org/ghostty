const std = @import("std");
const Allocator = std.mem.Allocator;

const adw = @import("adw");
const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");

const input = @import("../../../input.zig");
const gresource = @import("../build/gresource.zig");
const key = @import("../key.zig");
const Common = @import("../class.zig").Common;
const Surface = @import("surface.zig").Surface;

const log = std.log.scoped(.gtk_ghostty_search_bar);

/// SearchBar widget for finding text in terminal scrollback.
/// This creates a search interface that appears when users press Ctrl+F.
/// It contains a text input field where users can type what they want to find,
/// navigation buttons to go between results, and a label showing result count.
/// The search bar integrates with the terminal's SearchManager to actually
/// perform the searching through terminal history.
pub const SearchBar = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    
    // Define this as a GTK widget class using GObject system.
    // This makes the search bar work properly with GTK's widget system
    // and allows it to be embedded in other GTK containers.
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySearchBar",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    // Properties that can be set from outside this widget.
    // These allow parent widgets to configure the search bar behavior.
    pub const properties = struct {
        pub const surface = struct {
            pub const name = "surface";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface,
                .{
                    .accessor = C.privateObjFieldAccessor("surface"),
                },
            );
        };
    };

    // Signals that this widget can send to notify other parts of the app.
    // These are like events that other code can listen to and respond to.
    pub const signals = struct {
        /// Sent when user types text in the search box.
        /// The text parameter contains what the user typed.
        pub const search_text_changed = struct {
            pub const name = "search-text-changed";
            const impl = gobject.ext.defineSignal(name, Self, void, .{
                .params = .{[]const u8},
            });
        };

        /// Sent when user wants to close the search bar (presses Escape).
        /// This tells the parent widget to hide the search interface.
        pub const search_closed = struct {
            pub const name = "search-closed";
            const impl = gobject.ext.defineSignal(name, Self, void, .{});
        };
    };

    // Private data that each instance of this widget stores.
    // This contains the actual GTK widgets that make up the search interface
    // and the connection to the terminal surface for searching.
    const Private = struct {
        var offset: c_int = 0;

        // The terminal surface that we're searching in.
        // This connects the search bar to a specific terminal window/tab.
        surface: ?*Surface = null,

        // The text input box where users type their search terms.
        // This is the main interactive element of the search bar.
        search_entry: *gtk.Entry = undefined,

        // Button to go to the previous search result.
        // Shows an up arrow and moves backwards through search results.
        prev_button: *gtk.Button = undefined,

        // Button to go to the next search result.  
        // Shows a down arrow and moves forwards through search results.
        next_button: *gtk.Button = undefined,

        // Label that shows "X of Y matches" to inform users about results.
        // Updates automatically as user types and search finds matches.
        results_label: *gtk.Label = undefined,

        // Button to close the search bar.
        // Shows an X icon and hides the search interface when clicked.
        close_button: *gtk.Button = undefined,
    };

    // Get access to the private data for this widget instance.
    // This is a GTK/GObject pattern for accessing widget-specific data.
    fn private(self: *Self) *Private {
        return gobject.ext.impl_helpers.getPrivate(self, Private, Private.offset);
    }

    // Initialize a new search bar instance.
    // This sets up all the GTK widgets and connects them together into
    // a complete search interface that users can interact with.
    fn init(self: *Self) callconv(.C) void {
        // Get our private data storage
        const priv = self.private();
        
        // Set up the main container as a horizontal box.
        // This arranges all search controls in a row from left to right.
        self.parent_instance.setOrientation(gtk.Orientation.horizontal);
        self.parent_instance.setSpacing(6); // Add small gaps between widgets
        self.parent_instance.addCssClass("search-bar"); // For styling with CSS

        // Create the search text input field.
        // This is where users type what they want to find in terminal history.
        priv.search_entry = gtk.Entry.new();
        priv.search_entry.setPlaceholderText("Search in terminal...");
        priv.search_entry.setMaxWidth(300); // Don't let it get too wide
        
        // Create navigation buttons for moving between search results.
        // These have arrow icons to show direction and tooltips to help users.
        priv.prev_button = gtk.Button.new();
        priv.prev_button.setIconName("go-up-symbolic");
        priv.prev_button.setTooltipText("Previous result (Shift+F3)");
        priv.prev_button.addCssClass("circular"); // Round button style
        
        priv.next_button = gtk.Button.new();
        priv.next_button.setIconName("go-down-symbolic");  
        priv.next_button.setTooltipText("Next result (F3)");
        priv.next_button.addCssClass("circular"); // Round button style

        // Create the results counter label.
        // This shows users how many matches were found and which one is current.
        priv.results_label = gtk.Label.new("No results");
        priv.results_label.addCssClass("caption"); // Smaller text style

        // Create the close button to hide the search bar.
        // This gives users a clear way to exit search mode and return to normal.
        priv.close_button = gtk.Button.new();
        priv.close_button.setIconName("window-close-symbolic");
        priv.close_button.setTooltipText("Close search (Escape)");
        priv.close_button.addCssClass("circular"); // Round button style

        // Add all the widgets to the horizontal box container.
        // The order here determines the visual layout from left to right.
        self.parent_instance.append(priv.search_entry.as(gtk.Widget));
        self.parent_instance.append(priv.prev_button.as(gtk.Widget));
        self.parent_instance.append(priv.next_button.as(gtk.Widget));
        self.parent_instance.append(priv.results_label.as(gtk.Widget));
        self.parent_instance.append(priv.close_button.as(gtk.Widget));

        // Connect button click events to their handler functions.
        // This makes the buttons actually do something when users click them.
        _ = priv.prev_button.connectClicked(&onPrevClicked, self, .{});
        _ = priv.next_button.connectClicked(&onNextClicked, self, .{});
        _ = priv.close_button.connectClicked(&onCloseClicked, self, .{});

        // Connect text input events to handle user typing.
        // This triggers search as users type in the search box.
        _ = priv.search_entry.connectChanged(&onSearchChanged, self, .{});
        
        // Connect keyboard events for the search entry.
        // This handles special keys like Enter and Escape in the search box.
        const key_controller = gtk.EventController.controllerKey.new();
        _ = key_controller.connectKeyPressed(&onKeyPressed, self, .{});
        priv.search_entry.addController(key_controller);

        // Initially disable navigation buttons since there are no results yet.
        // These will be enabled when a search finds matches.
        priv.prev_button.setSensitive(false);
        priv.next_button.setSensitive(false);
    }

    // Called when user clicks the "previous result" button.
    // This tells the connected terminal surface to move to the previous search match.
    fn onPrevClicked(self: *Self, _: *gtk.Button) callconv(.C) void {
        const priv = self.private();
        if (priv.surface) |surface| {
            // Send the search_previous action to the terminal.
            // This will highlight the previous match and scroll to show it.
            surface.performAction(.search_previous) catch |err| {
                log.warn("failed to perform search_previous action: {}", .{err});
            };
        }
    }

    // Called when user clicks the "next result" button.
    // This tells the connected terminal surface to move to the next search match.
    fn onNextClicked(self: *Self, _: *gtk.Button) callconv(.C) void {
        const priv = self.private();
        if (priv.surface) |surface| {
            // Send the search_next action to the terminal.
            // This will highlight the next match and scroll to show it.
            surface.performAction(.search_next) catch |err| {
                log.warn("failed to perform search_next action: {}", .{err});
            };
        }
    }

    // Called when user clicks the close button or wants to exit search.
    // This hides the search bar and returns the terminal to normal mode.
    fn onCloseClicked(self: *Self, _: *gtk.Button) callconv(.C) void {
        // Send a signal that the search bar should be closed.
        // The parent window will listen for this and hide the search interface.
        gobject.ext.impl_helpers.emitSignal(
            self,
            signals.search_closed.name,
            .{},
        );
    }

    // Called when user types text in the search input box.
    // This triggers a new search with the updated text every time they type.
    fn onSearchChanged(self: *Self, _: *gtk.Entry) callconv(.C) void {
        const priv = self.private();
        
        // Get the current text from the search input box.
        // This is what the user has typed so far.
        const search_text = priv.search_entry.getText();
        
        // If we have a connected terminal surface, start searching.
        // The surface will use its SearchManager to find matches in history.
        if (priv.surface) |surface| {
            surface.startSearch(search_text) catch |err| {
                log.warn("failed to start search: {}", .{err});
            };
        }

        // Send a signal with the new search text.
        // Other parts of the app can listen for this and respond.
        gobject.ext.impl_helpers.emitSignal(
            self,
            signals.search_text_changed.name,
            .{search_text},
        );
    }

    // Called when user presses keys while focused on the search input.
    // This handles special keys like Enter (next result) and Escape (close search).
    fn onKeyPressed(
        self: *Self,
        keyval: c_uint,
        keycode: c_uint,
        state: gtk.ModifierType,
        _: *gtk.EventController,
    ) callconv(.C) bool {
        _ = keycode; // Not used but required by GTK
        
        const priv = self.private();
        
        // Check which key was pressed and handle accordingly
        switch (keyval) {
            // Enter key moves to next search result (like pressing F3)
            gtk.KEY_Return, gtk.KEY_KP_Enter => {
                if (priv.surface) |surface| {
                    surface.performAction(.search_next) catch |err| {
                        log.warn("failed to perform search_next action: {}", .{err});
                    };
                }
                return true; // We handled this key press
            },
            
            // Escape key closes the search bar and returns to normal mode
            gtk.KEY_Escape => {
                gobject.ext.impl_helpers.emitSignal(
                    self,
                    signals.search_closed.name,
                    .{},
                );
                return true; // We handled this key press
            },
            
            // F3 key moves to next result, Shift+F3 moves to previous
            gtk.KEY_F3 => {
                if (priv.surface) |surface| {
                    if (state.contains(gtk.ModifierType.shift_mask)) {
                        surface.performAction(.search_previous) catch |err| {
                            log.warn("failed to perform search_previous action: {}", .{err});
                        };
                    } else {
                        surface.performAction(.search_next) catch |err| {
                            log.warn("failed to perform search_next action: {}", .{err});
                        };
                    }
                }
                return true; // We handled this key press
            },
            
            else => return false, // Let GTK handle other keys normally
        }
    }

    // Update the search results display based on current search state.
    // This is called when the search finds new matches or user navigates results.
    // It updates the counter label and enables/disables navigation buttons.
    pub fn updateResults(self: *Self, current: usize, total: usize) void {
        const priv = self.private();
        
        // Update the results counter label text
        if (total == 0) {
            priv.results_label.setText("No results");
            // Disable navigation buttons when there are no results
            priv.prev_button.setSensitive(false);
            priv.next_button.setSensitive(false);
        } else {
            // Show "X of Y" format like "3 of 15 matches"
            var buf: [64]u8 = undefined;
            const text = std.fmt.bufPrint(buf[0..], "{} of {} matches", .{ current, total }) catch "Error";
            priv.results_label.setText(text.ptr);
            
            // Enable navigation buttons when there are results to navigate
            priv.prev_button.setSensitive(true);
            priv.next_button.setSensitive(true);
        }
    }

    // Focus the search input box so users can start typing immediately.
    // This is called when the search bar is first shown to make it ready to use.
    pub fn focusSearchEntry(self: *Self) void {
        const priv = self.private();
        priv.search_entry.grabFocus();
    }

    // Clear the search text and reset the interface to its initial state.
    // This is useful when starting a new search or switching between terminals.
    pub fn clearSearch(self: *Self) void {
        const priv = self.private();
        priv.search_entry.setText("");
        self.updateResults(0, 0); // Reset to "No results"
    }

    // Set which terminal surface this search bar should search in.
    // This connects the search bar to a specific terminal window/tab.
    pub fn setSurface(self: *Self, surface: ?*Surface) void {
        const priv = self.private();
        priv.surface = surface;
        
        // Clear any existing search when switching surfaces
        if (surface != null) {
            self.clearSearch();
        }
    }

    // Standard GTK/GObject class initialization.
    // This sets up the widget class structure that GTK needs.
    const Class = struct {
        var parent: *gtk.Box.Class = undefined;
        
        fn init(class: *Self.Class) callconv(.C) void {
            // Set up parent class and basic widget properties
            gobject.Object.Class.bindTemplateCallbacks(class, &[_]gobject.ext.TemplateCallback{});
            
            // Install our custom properties so they can be set from outside
            properties.surface.impl.install(class);
            
            // Install our custom signals so other widgets can listen to them
            signals.search_text_changed.impl.install(class);
            signals.search_closed.impl.install(class);
        }
    };

    // C-compatible helper functions for GObject integration
    const C = struct {
        // Helper to access private fields from property getters/setters
        fn privateObjFieldAccessor(comptime field: []const u8) type {
            return gobject.ext.impl_helpers.PrivateObjFieldAccessor(Self, Private, field);
        }
    };
};