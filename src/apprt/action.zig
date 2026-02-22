const std = @import("std");
const build_config = @import("../build_config.zig");
const assert = @import("../quirks.zig").inlineAssert;
const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const input = @import("../input.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const CoreSurface = @import("../Surface.zig");
const lib = @import("../lib/main.zig");

/// The target for an action. This is generally the thing that had focus
/// while the action was made but the concept of "focus" is not guaranteed
/// since actions can also be triggered by timers, scripts, etc.
pub const Target = union(Key) {
    app,
    surface: *CoreSurface,

    // Sync with: ghostty_target_tag_e
    pub const Key = enum(c_int) {
        app,
        surface,
    };

    // Sync with: ghostty_target_u
    pub const CValue = extern union {
        app: void,
        surface: *apprt.Surface,
    };

    // Sync with: ghostty_target_s
    pub const C = extern struct {
        key: Key,
        value: CValue,
    };

    /// Convert to ghostty_target_s.
    pub fn cval(self: Target) C {
        return .{
            .key = @as(Key, self),
            .value = switch (self) {
                .app => .{ .app = {} },
                .surface => |v| .{ .surface = v.rt_surface },
            },
        };
    }
};

/// The possible actions an apprt has to react to. Actions are one-way
/// messages that are sent to the app runtime to trigger some behavior.
///
/// Actions are very often key binding actions but can also be triggered
/// by lifecycle events. For example, the `quit_timer` action is not bindable.
///
/// Importantly, actions are generally OPTIONAL to implement by an apprt.
/// Required functionality is called directly on the runtime structure so
/// there is a compiler error if an action is not implemented.
pub const Action = union(Key) {
    // A GUIDE TO ADDING NEW ACTIONS:
    //
    // 1. Add the action to the `Key` enum. The order of the enum matters
    //    because it maps directly to the libghostty C enum. For ABI
    //    compatibility, new actions should be added to the end of the enum.
    //
    // 2. Add the action and optional value to the Action union.
    //
    // 3. If the value type is not void, ensure the value is C ABI
    //    compatible (extern). If it is not, add a `C` decl to the value
    //    and a `cval` function to convert to the C ABI compatible value.
    //
    // 4. Update `include/ghostty.h`: add the new key, value, and union
    //    entry. If the value type is void then only the key needs to be
    //    added. Ensure the order matches exactly with the Zig code.

    /// Quit the application.
    quit,

    /// Open a new window. The target determines whether properties such
    /// as font size should be inherited.
    new_window,

    /// Open a new tab. If the target is a surface it should be opened in
    /// the same window as the surface. If the target is the app then
    /// the tab should be opened in a new window.
    new_tab,

    /// Closes the tab belonging to the currently focused split, or all other
    /// tabs, depending on the mode.
    close_tab: CloseTabMode,

    /// Create a new split. The value determines the location of the split
    /// relative to the target.
    new_split: SplitDirection,

    /// Close all open windows.
    close_all_windows,

    /// Toggle maximized window state.
    toggle_maximize,

    /// Toggle fullscreen mode.
    toggle_fullscreen: Fullscreen,

    /// Toggle tab overview.
    toggle_tab_overview,

    /// Toggle whether window directions are shown.
    toggle_window_decorations,

    /// Toggle the quick terminal in or out.
    toggle_quick_terminal,

    /// Toggle the command palette.
    toggle_command_palette,

    /// Toggle the visibility of all Ghostty terminal windows.
    toggle_visibility,

    /// Toggle the window background opacity. This only has an effect
    /// if the window started as transparent (non-opaque), and toggles
    /// it between fully opaque and the configured background opacity.
    toggle_background_opacity,

    /// Moves a tab by a relative offset.
    ///
    /// Adjusts the tab position based on `offset` (e.g., -1 for left, +1
    /// for right). If the new position is out of bounds, it wraps around
    /// cyclically within the tab range.
    move_tab: MoveTab,

    /// Jump to a specific tab. Must handle the scenario that the tab
    /// value is invalid.
    goto_tab: GotoTab,

    /// Jump to a specific split.
    goto_split: GotoSplit,

    /// Jump to next/previous window.
    goto_window: GotoWindow,

    /// Resize the split in the given direction.
    resize_split: ResizeSplit,

    /// Equalize all the splits in the target window.
    equalize_splits,

    /// Toggle whether a split is zoomed or not. A zoomed split is resized
    /// to take up the entire window.
    toggle_split_zoom,

    /// Present the target terminal whether its a tab, split, or window.
    present_terminal,

    /// Sets a size limit (in pixels) for the target terminal.
    size_limit: SizeLimit,

    /// Resets the window size to the default size. See the
    /// `reset_window_size` keybinding for more information.
    reset_window_size,

    /// Specifies the initial size of the target terminal.
    ///
    /// This may be sent once during the initialization of a surface
    /// (as part of the init call) to indicate the initial size requested
    /// for the window if it is not maximized or fullscreen.
    ///
    /// This may also be sent at any time after the surface is initialized
    /// to note the new "default size" of the window. This should in general
    /// be ignored, but may be useful if the apprt wants to support
    /// a "return to default size" action.
    initial_size: InitialSize,

    /// The cell size has changed to the given dimensions in pixels.
    cell_size: CellSize,

    /// The scrollbar is updating.
    scrollbar: terminal.Scrollbar,

    /// The target should be re-rendered. This usually has a specific
    /// surface target but if the app is targeted then all active
    /// surfaces should be redrawn.
    render,

    /// Control whether the inspector is shown or hidden.
    inspector: Inspector,

    /// Show the GTK inspector.
    show_gtk_inspector,

    /// The inspector for the given target has changes and should be
    /// rendered at the next opportunity.
    render_inspector,

    /// Show a desktop notification.
    desktop_notification: DesktopNotification,

    /// Set the title of the target to the requested value.
    set_title: SetTitle,

    /// Set the title of the target to a prompted value. It is up to
    /// the apprt to prompt. The value specifies whether to prompt for the
    /// surface title or the tab title.
    prompt_title: PromptTitle,

    /// The current working directory has changed for the target terminal.
    pwd: Pwd,

    /// Set the mouse cursor shape.
    mouse_shape: terminal.MouseShape,

    /// Set whether the mouse cursor is visible or not.
    mouse_visibility: MouseVisibility,

    /// Called when the mouse is over or recently left a link.
    mouse_over_link: MouseOverLink,

    /// The health of the renderer has changed.
    renderer_health: renderer.Health,

    /// Open the Ghostty configuration. This is platform-specific about
    /// what it means; it can mean opening a dedicated UI or just opening
    /// a file in a text editor.
    open_config,

    /// Called when there are no more surfaces and the app should quit
    /// after the configured delay.
    ///
    /// Despite the name, this is the notification that libghostty sends
    /// when there are no more surfaces regardless of if the configuration
    /// wants to quit after close, has any delay set, etc. It's up to the
    /// apprt to implement the proper logic based on the config.
    ///
    /// This can be cancelled by sending another quit_timer action with "stop".
    /// Multiple "starts" shouldn't happen and can be ignored or cause a
    /// restart it isn't that important.
    quit_timer: QuitTimer,

    /// Set the window floating state. A floating window is one that is
    /// always on top of other windows even when not focused.
    float_window: FloatWindow,

    /// Set the secure input functionality on or off. "Secure input" means
    /// that the user is currently at some sort of prompt where they may be
    /// entering a password or other sensitive information. This can be used
    /// by the app runtime to change the appearance of the cursor, setup
    /// system APIs to not log the input, etc.
    secure_input: SecureInput,

    /// A sequenced key binding has started, continued, or stopped.
    /// The UI should show some indication that the user is in a sequenced
    /// key mode because other input may be ignored.
    key_sequence: KeySequence,

    /// A key table has been activated or deactivated.
    key_table: KeyTable,

    /// A terminal color was changed programmatically through things
    /// such as OSC 10/11.
    color_change: ColorChange,

    /// A request to reload the configuration. The reload request can be
    /// from a user or for some internal reason. The reload request may
    /// request it is a soft reload or a full reload. See the struct for
    /// more documentation.
    ///
    /// The configuration should be passed to updateConfig either at the
    /// app or surface level depending on the target.
    reload_config: ReloadConfig,

    /// The configuration has changed. The value is a pointer to the new
    /// configuration. The pointer is only valid for the duration of the
    /// action and should not be stored.
    ///
    /// This should be used by apprts to update any internal state that
    /// depends on configuration for the given target (i.e. headerbar colors).
    /// The apprt should copy any data it needs since the memory lifetime
    /// is only valid for the duration of the action.
    ///
    /// This allows an apprt to have config-dependent state reactively
    /// change without having to store the entire configuration or poll
    /// for changes.
    config_change: ConfigChange,

    /// Closes the currently focused window.
    close_window,

    /// Called when the bell character is seen. The apprt should do whatever
    /// it needs to ring the bell. This is usually a sound or visual effect.
    ring_bell,

    /// Undo the last action. See the "undo" keybinding for more
    /// details on what can and cannot be undone.
    undo,

    /// Redo the last undone action.
    redo,

    check_for_updates,

    /// Open a URL using the native OS mechanisms. On macOS this might be `open`
    /// or on Linux this might be `xdg-open`. The exact mechanism is up to the
    /// apprt.
    open_url: OpenUrl,

    /// Show a native GUI notification that the child process has exited.
    show_child_exited: apprt.surface.Message.ChildExited,

    /// Show a native GUI notification about the progress of some TUI operation.
    progress_report: terminal.osc.Command.ProgressReport,

    /// Show the on-screen keyboard.
    show_on_screen_keyboard,

    /// A command has finished,
    command_finished: CommandFinished,

    /// Start the search overlay with an optional initial needle. If the
    /// search is already active and the needle is non-empty, update the
    /// current search needle and focus the search input.
    start_search: StartSearch,

    /// End the search overlay, clearing the search state and hiding it.
    end_search,

    /// The total number of matches found by the search.
    search_total: SearchTotal,

    /// The currently selected search match index (1-based).
    search_selected: SearchSelected,

    /// The readonly state of the surface has changed.
    readonly: Readonly,

    /// Copy the effective title of the surface to the clipboard.
    /// The effective title is the user-overridden title if set,
    /// otherwise the terminal-set title.
    copy_title_to_clipboard,

    /// Sync with: ghostty_action_tag_e
    pub const Key = enum(c_int) {
        quit,
        new_window,
        new_tab,
        close_tab,
        new_split,
        close_all_windows,
        toggle_maximize,
        toggle_fullscreen,
        toggle_tab_overview,
        toggle_window_decorations,
        toggle_quick_terminal,
        toggle_command_palette,
        toggle_visibility,
        toggle_background_opacity,
        move_tab,
        goto_tab,
        goto_split,
        goto_window,
        resize_split,
        equalize_splits,
        toggle_split_zoom,
        present_terminal,
        size_limit,
        reset_window_size,
        initial_size,
        cell_size,
        scrollbar,
        render,
        inspector,
        show_gtk_inspector,
        render_inspector,
        desktop_notification,
        set_title,
        prompt_title,
        pwd,
        mouse_shape,
        mouse_visibility,
        mouse_over_link,
        renderer_health,
        open_config,
        quit_timer,
        float_window,
        secure_input,
        key_sequence,
        key_table,
        color_change,
        reload_config,
        config_change,
        close_window,
        ring_bell,
        undo,
        redo,
        check_for_updates,
        open_url,
        show_child_exited,
        progress_report,
        show_on_screen_keyboard,
        command_finished,
        start_search,
        end_search,
        search_total,
        search_selected,
        readonly,
        copy_title_to_clipboard,
    };

    /// Sync with: ghostty_action_u
    pub const CValue = cvalue: {
        const key_fields = @typeInfo(Key).@"enum".fields;
        var union_fields: [key_fields.len]std.builtin.Type.UnionField = undefined;
        for (key_fields, 0..) |field, i| {
            const action = @unionInit(Action, field.name, undefined);
            const Type = t: {
                const Type = @TypeOf(@field(action, field.name));
                // Types can provide custom types for their CValue.
                if (Type != void and @hasDecl(Type, "C")) break :t Type.C;
                break :t Type;
            };

            union_fields[i] = .{
                .name = field.name,
                .type = Type,
                .alignment = @alignOf(Type),
            };
        }

        break :cvalue @Type(.{ .@"union" = .{
            .layout = .@"extern",
            .tag_type = null,
            .fields = &union_fields,
            .decls = &.{},
        } });
    };

    /// Sync with: ghostty_action_s
    pub const C = extern struct {
        key: Key,
        value: CValue,
    };

    comptime {
        // For ABI compatibility, we expect that this is our union size.
        // At the time of writing, we don't promise ABI compatibility
        // so we can change this but I want to be aware of it.
        assert(@sizeOf(CValue) == switch (@sizeOf(usize)) {
            4 => 20,
            8 => 32,
            else => unreachable,
        });
    }

    /// Returns the value type for the given key.
    pub fn Value(comptime key: Key) type {
        inline for (@typeInfo(Action).@"union".fields) |field| {
            const field_key = @field(Key, field.name);
            if (field_key == key) return field.type;
        }

        unreachable;
    }

    /// Convert to ghostty_action_s.
    pub fn cval(self: Action) C {
        const value: CValue = switch (self) {
            inline else => |v, tag| @unionInit(
                CValue,
                @tagName(tag),
                if (@TypeOf(v) != void and @hasDecl(@TypeOf(v), "cval")) v.cval() else v,
            ),
        };

        return .{
            .key = @as(Key, self),
            .value = value,
        };
    }
};

// This is made extern (c_int) to make interop easier with our embedded
// runtime. The small size cost doesn't make a difference in our union.
pub const SplitDirection = enum(c_int) {
    right,
    down,
    left,
    up,
};

// This is made extern (c_int) to make interop easier with our embedded
// runtime. The small size cost doesn't make a difference in our union.
pub const GotoSplit = enum(c_int) {
    previous,
    next,

    up,
    left,
    down,
    right,
};

// This is made extern (c_int) to make interop easier with our embedded
// runtime. The small size cost doesn't make a difference in our union.
pub const GotoWindow = enum(c_int) {
    previous,
    next,
};

/// The amount to resize the split by and the direction to resize it in.
pub const ResizeSplit = extern struct {
    amount: u16,
    direction: Direction,

    pub const Direction = enum(c_int) {
        up,
        down,
        left,
        right,
    };
};

pub const MoveTab = extern struct {
    amount: isize,
};

/// The tab to jump to. This is non-exhaustive so that integer values represent
/// the index (zero-based) of the tab to jump to. Negative values are special
/// values.
pub const GotoTab = enum(c_int) {
    previous = -1,
    next = -2,
    last = -3,
    _,
};

/// The fullscreen mode to toggle to if we're moving to fullscreen.
pub const Fullscreen = enum(c_int) {
    native,

    /// macOS has a non-native fullscreen mode that is more like a maximized
    /// window. This is much faster to enter and exit than the native mode.
    macos_non_native,
    macos_non_native_visible_menu,
    macos_non_native_padded_notch,
};

pub const FloatWindow = enum(c_int) {
    on,
    off,
    toggle,
};

pub const SecureInput = enum(c_int) {
    on,
    off,
    toggle,
};

/// The inspector mode to toggle to if we're toggling the inspector.
pub const Inspector = enum(c_int) {
    toggle,
    show,
    hide,
};

pub const QuitTimer = enum(c_int) {
    start,
    stop,
};

pub const Readonly = enum(c_int) {
    off,
    on,
};

pub const MouseVisibility = enum(c_int) {
    visible,
    hidden,
};

/// Whether to prompt for the surface title or tab title.
pub const PromptTitle = enum(c_int) {
    surface,
    tab,
};

pub const MouseOverLink = struct {
    url: [:0]const u8,

    // Sync with: ghostty_action_mouse_over_link_s
    pub const C = extern struct {
        url: [*]const u8,
        len: usize,
    };

    pub fn cval(self: MouseOverLink) C {
        return .{
            .url = self.url.ptr,
            .len = self.url.len,
        };
    }
};

pub const SizeLimit = extern struct {
    min_width: u32,
    min_height: u32,
    max_width: u32,
    max_height: u32,
};

pub const InitialSize = extern struct {
    width: u32,
    height: u32,

    /// Make this a valid gobject if we're in a GTK environment.
    pub const getGObjectType = switch (build_config.app_runtime) {
        .gtk => @import("gobject").ext.defineBoxed(
            InitialSize,
            .{ .name = "GhosttyApprtInitialSize" },
        ),

        .none => void,
    };
};

pub const CellSize = extern struct {
    width: u32,
    height: u32,
};

pub const SetTitle = struct {
    title: [:0]const u8,

    // Sync with: ghostty_action_set_title_s
    pub const C = extern struct {
        title: [*:0]const u8,
    };

    pub fn cval(self: SetTitle) C {
        return .{
            .title = self.title.ptr,
        };
    }

    pub fn format(
        value: @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print("{s}{{ {s} }}", .{ @typeName(@This()), value.title });
    }
};

pub const Pwd = struct {
    pwd: [:0]const u8,

    // Sync with: ghostty_action_set_pwd_s
    pub const C = extern struct {
        pwd: [*:0]const u8,
    };

    pub fn cval(self: Pwd) C {
        return .{
            .pwd = self.pwd.ptr,
        };
    }

    pub fn format(
        value: @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print("{s}{{ {s} }}", .{ @typeName(@This()), value.pwd });
    }
};

/// The desktop notification to show.
pub const DesktopNotification = struct {
    title: [:0]const u8,
    body: [:0]const u8,

    // Sync with: ghostty_action_desktop_notification_s
    pub const C = extern struct {
        title: [*:0]const u8,
        body: [*:0]const u8,
    };

    pub fn cval(self: DesktopNotification) C {
        return .{
            .title = self.title.ptr,
            .body = self.body.ptr,
        };
    }

    pub fn format(
        value: @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print("{s}{{ title: {s}, body: {s} }}", .{
            @typeName(@This()),
            value.title,
            value.body,
        });
    }
};

pub const KeySequence = union(enum) {
    trigger: input.Trigger,
    end,

    // Sync with: ghostty_action_key_sequence_s
    pub const C = extern struct {
        active: bool,
        trigger: input.Trigger.C,
    };

    pub fn cval(self: KeySequence) C {
        return switch (self) {
            .trigger => |t| .{ .active = true, .trigger = t.cval() },
            .end => .{ .active = false, .trigger = .{} },
        };
    }
};

pub const KeyTable = union(enum) {
    activate: []const u8,
    deactivate,
    deactivate_all,

    // Sync with: ghostty_action_key_table_tag_e
    pub const Tag = enum(c_int) {
        activate,
        deactivate,
        deactivate_all,
    };

    // Sync with: ghostty_action_key_table_u
    pub const CValue = extern union {
        activate: extern struct {
            name: [*]const u8,
            len: usize,
        },
    };

    // Sync with: ghostty_action_key_table_s
    pub const C = extern struct {
        tag: Tag,
        value: CValue,
    };

    pub fn cval(self: KeyTable) C {
        return switch (self) {
            .activate => |name| .{
                .tag = .activate,
                .value = .{ .activate = .{ .name = name.ptr, .len = name.len } },
            },
            .deactivate => .{
                .tag = .deactivate,
                .value = undefined,
            },
            .deactivate_all => .{
                .tag = .deactivate_all,
                .value = undefined,
            },
        };
    }
};

pub const ColorChange = extern struct {
    kind: ColorKind,
    r: u8,
    g: u8,
    b: u8,
};

pub const ColorKind = enum(c_int) {
    // Negative numbers indicate some named kind
    foreground = -1,
    background = -2,
    cursor = -3,

    // 0+ values indicate a palette index
    _,
};

pub const ReloadConfig = extern struct {
    /// A soft reload means that the configuration doesn't need to be
    /// read off disk, but libghostty needs the full config again so call
    /// updateConfig with it.
    soft: bool = false,
};

pub const ConfigChange = struct {
    config: *const configpkg.Config,

    // Sync with: ghostty_action_config_change_s
    pub const C = extern struct {
        config: *const configpkg.Config,
    };

    pub fn cval(self: ConfigChange) C {
        return .{
            .config = self.config,
        };
    }
};

/// Open a URL
pub const OpenUrl = struct {
    /// The type of data that the URL refers to.
    kind: Kind,

    /// The URL.
    url: []const u8,

    /// The type of the data at the URL to open. This is used as a hint to
    /// potentially open the URL in a different way.
    ///
    /// Sync with: ghostty_action_open_url_kind_e
    pub const Kind = enum(c_int) {
        /// The type is unknown. This is the default and apprts should
        /// open the URL in the most generic way possible. For example,
        /// on macOS this would be the equivalent of `open` or on Linux
        /// this would be `xdg-open`.
        unknown,

        /// The URL is known to be a text file. In this case, the apprt
        /// should try to open the URL in a text editor or viewer or
        /// some equivalent, if possible.
        text,

        /// The URL is known to contain HTML content.
        html,
    };

    // Sync with: ghostty_action_open_url_s
    pub const C = extern struct {
        kind: Kind,
        url: [*]const u8,
        len: usize,
    };

    pub fn cval(self: OpenUrl) C {
        return .{
            .kind = self.kind,
            .url = self.url.ptr,
            .len = self.url.len,
        };
    }
};

/// sync with ghostty_action_close_tab_mode_e in ghostty.h
pub const CloseTabMode = enum(c_int) {
    /// Close the current tab.
    this,
    /// Close all other tabs.
    other,
    /// Close all tabs to the right of the current tab.
    right,
};

pub const CommandFinished = struct {
    /// The command line, as reported by the shell, or null if the command line
    /// is unknown.
    command_line: ?[]const u8,
    /// The exit code, as reported by the shell. The exit code will be a number
    /// between 0 and 255  or null if no exit code was provided. 0 indicates
    /// that the command was successful. Any number from 1 to 255 indicates an
    /// application specific error code.
    exit_code: ?u8,
    /// How long the command took in nanoseconds. Despite the duration being
    /// reported in nanoseconds the accuracy is probably only within a few
    /// milliseconds.
    duration: configpkg.Config.Duration,

    /// sync with ghostty_action_command_finished_s in ghostty.h
    pub const C = extern struct {
        /// The command line, as reported by the shell, or null if the command
        /// line is unknown.
        command_line: lib.String,
        /// The exit code, as reported by the shell. The exit code will be a
        /// number between 0 and 255  or null if no exit code was provided. 0
        /// indicates that the command was successful. Any number from 1 to 255
        /// indicates an application specific error code.
        exit_code: i16,
        // How long the command took in nanoseconds. Despite the duration being
        // reported in nanoseconds the accuracy is probably only within a few
        // milliseconds.
        duration: u64,
    };

    pub fn cval(self: CommandFinished) C {
        return .{
            .command_line = .init(self.command_line orelse ""),
            .exit_code = self.exit_code orelse -1,
            .duration = self.duration.duration,
        };
    }
};

pub const StartSearch = struct {
    needle: [:0]const u8,

    // Sync with: ghostty_action_start_search_s
    pub const C = extern struct {
        needle: [*:0]const u8,
    };

    pub fn cval(self: StartSearch) C {
        return .{
            .needle = self.needle.ptr,
        };
    }
};

pub const SearchTotal = struct {
    total: ?usize,

    // Sync with: ghostty_action_search_total_s
    pub const C = extern struct {
        total: isize,
    };

    pub fn cval(self: SearchTotal) C {
        return .{
            .total = if (self.total) |t| @intCast(t) else -1,
        };
    }
};

pub const SearchSelected = struct {
    selected: ?usize,

    // Sync with: ghostty_action_search_selected_s
    pub const C = extern struct {
        selected: isize,
    };

    pub fn cval(self: SearchSelected) C {
        return .{
            .selected = if (self.selected) |s| @intCast(s) else -1,
        };
    }
};
