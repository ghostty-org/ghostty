//! Application runtime for the embedded version of Ghostty. The embedded
//! version is when Ghostty is embedded within a parent host application,
//! rather than owning the application lifecycle itself. This is used for
//! example for the macOS build of Ghostty so that we can use a native
//! Swift+XCode-based application.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const objc = @import("objc");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const input = @import("../input.zig");
const internal_os = @import("../os/main.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const CoreApp = @import("../App.zig");
const CoreInspector = @import("../inspector/main.zig").Inspector;
const CoreSurface = @import("../Surface.zig");
const configpkg = @import("../config.zig");
const Config = configpkg.Config;

const log = std.log.scoped(.embedded_window);

pub const App = struct {
    /// Because we only expect the embedding API to be used in embedded
    /// environments, the options are extern so that we can expose it
    /// directly to a C callconv and not pay for any translation costs.
    ///
    /// C type: ghostty_runtime_config_s
    pub const Options = extern struct {
        /// These are just aliases to make the function signatures below
        /// more obvious what values will be sent.
        const AppUD = ?*anyopaque;
        const SurfaceUD = ?*anyopaque;

        /// Userdata that is passed to all the callbacks.
        userdata: AppUD = null,

        /// True if the selection clipboard is supported.
        supports_selection_clipboard: bool = false,

        /// Callback called to wakeup the event loop. This should trigger
        /// a full tick of the app loop.
        wakeup: *const fn (AppUD) callconv(.C) void,

        /// Callback called to handle an action.
        action: *const fn (*App, apprt.Target.C, apprt.Action.C) callconv(.C) bool,

        /// Read the clipboard value. The return value must be preserved
        /// by the host until the next call. If there is no valid clipboard
        /// value then this should return null.
        read_clipboard: *const fn (SurfaceUD, c_int, *apprt.ClipboardRequest) callconv(.C) void,

        /// This may be called after a read clipboard call to request
        /// confirmation that the clipboard value is safe to read. The embedder
        /// must call complete_clipboard_request with the given request.
        confirm_read_clipboard: *const fn (
            SurfaceUD,
            [*:0]const u8,
            *apprt.ClipboardRequest,
            apprt.ClipboardRequestType,
        ) callconv(.C) void,

        /// Write the clipboard value.
        write_clipboard: *const fn (SurfaceUD, [*:0]const u8, c_int, bool) callconv(.C) void,

        /// Close the current surface given by this function.
        close_surface: ?*const fn (SurfaceUD, bool) callconv(.C) void = null,
    };

    /// This is the key event sent for ghostty_surface_key and
    /// ghostty_app_key.
    pub const KeyEvent = struct {
        /// The three below are absolutely required.
        action: input.Action,
        mods: input.Mods,
        keycode: u32,

        /// Optionally, the embedder can handle text translation and send
        /// the text value here. If text is non-nil, it is assumed that the
        /// embedder also handles dead key states and sets composing as necessary.
        text: ?[:0]const u8,
        composing: bool,
    };

    core_app: *CoreApp,
    opts: Options,
    keymap: input.Keymap,

    /// The configuration for the app. This is owned by this structure.
    config: Config,

    /// The keymap state is used for global keybinds only. Each surface
    /// also has its own keymap state for focused keybinds.
    keymap_state: input.Keymap.State,

    pub fn init(
        core_app: *CoreApp,
        config: *const Config,
        opts: Options,
    ) !App {
        // We have to clone the config.
        const alloc = core_app.alloc;
        var config_clone = try config.clone(alloc);
        errdefer config_clone.deinit();

        var keymap = try input.Keymap.init();
        errdefer keymap.deinit();

        return .{
            .core_app = core_app,
            .config = config_clone,
            .opts = opts,
            .keymap = keymap,
            .keymap_state = .{},
        };
    }

    pub fn terminate(self: *App) void {
        self.keymap.deinit();
        self.config.deinit();
    }

    /// Returns true if there are any global keybinds in the configuration.
    pub fn hasGlobalKeybinds(self: *const App) bool {
        var it = self.config.keybind.set.bindings.iterator();
        while (it.next()) |entry| {
            switch (entry.value_ptr.*) {
                .leader => {},
                .leaf => |leaf| if (leaf.flags.global) return true,
            }
        }

        return false;
    }

    /// The target of a key event. This is used to determine some subtly
    /// different behavior between app and surface key events.
    pub const KeyTarget = union(enum) {
        app,
        surface: *Surface,
    };

    /// See CoreApp.focusEvent
    pub fn focusEvent(self: *App, focused: bool) void {
        self.core_app.focusEvent(focused);
    }

    /// Convert a C key event into a Zig key event.
    fn coreKeyEvent(
        self: *App,
        target: KeyTarget,
        event: KeyEvent,
    ) !?input.KeyEvent {
        const action = event.action;
        const keycode = event.keycode;
        const mods = event.mods;

        // True if this is a key down event
        const is_down = action == .press or action == .repeat;

        // If we're on macOS and we have macos-option-as-alt enabled,
        // then we strip the alt modifier from the mods for translation.
        const translate_mods = translate_mods: {
            var translate_mods = mods;
            if ((comptime builtin.target.isDarwin()) and translate_mods.alt) {
                // Note: the keyboardLayout() function is not super cheap
                // so we only want to run it if alt is already pressed hence
                // the above condition.
                const option_as_alt: configpkg.OptionAsAlt =
                    self.config.@"macos-option-as-alt" orelse
                    self.keyboardLayout().detectOptionAsAlt();

                const strip = switch (option_as_alt) {
                    .false => false,
                    .true => mods.alt,
                    .left => mods.sides.alt == .left,
                    .right => mods.sides.alt == .right,
                };
                if (strip) translate_mods.alt = false;
            }

            // We strip super on macOS because its not used for translation
            // it results in a bad translation.
            if (comptime builtin.target.isDarwin()) {
                translate_mods.super = false;
            }

            break :translate_mods translate_mods;
        };

        const event_text: ?[]const u8 = event_text: {
            // This logic only applies to macOS.
            if (comptime builtin.os.tag != .macos) break :event_text event.text;

            // If we're in a preedit state then we allow it through. This
            // allows ctrl sequences that affect IME to work. For example,
            // Ctrl+H deletes a character with Japanese input.
            if (event.composing) break :event_text event.text;

            // If the modifiers are ONLY "control" then we never process
            // the event text because we want to do our own translation so
            // we can handle ctrl+c, ctrl+z, etc.
            //
            // This is specifically because on macOS using the
            // "Dvorak - QWERTY ⌘" keyboard layout, ctrl+z is translated as
            // "/" (the physical key that is z on a qwerty keyboard). But on
            // other layouts, ctrl+<char> is not translated by AppKit. So,
            // we just avoid this by never allowing AppKit to translate
            // ctrl+<char> and instead do it ourselves.
            const ctrl_only = comptime (input.Mods{ .ctrl = true }).int();
            break :event_text if (mods.binding().int() == ctrl_only) null else event.text;
        };

        // Translate our key using the keymap for our localized keyboard layout.
        // We only translate for keydown events. Otherwise, we only care about
        // the raw keycode.
        var buf: [128]u8 = undefined;
        const result: input.Keymap.Translation = if (is_down) translate: {
            // If the event provided us with text, then we use this as a result
            // and do not do manual translation.
            const result: input.Keymap.Translation = if (event_text) |text| .{
                .text = text,
                .composing = event.composing,
                .mods = translate_mods,
            } else try self.keymap.translate(
                &buf,
                switch (target) {
                    .app => &self.keymap_state,
                    .surface => |surface| &surface.keymap_state,
                },
                @intCast(keycode),
                translate_mods,
            );

            // TODO(mitchellh): I think we can get rid of the above keymap
            // translation code completely and defer to AppKit/Swift
            // (for macOS) for handling all translations. The translation
            // within libghostty is an artifact of an earlier design and
            // it is buggy (see #5558). We should move closer to a GTK-style
            // model of tracking composing states and preedit in the apprt
            // and not in libghostty.

            // If this is a dead key, then we're composing a character and
            // we need to set our proper preedit state if we're targeting a
            // surface.
            if (result.composing) {
                switch (target) {
                    .app => {},
                    .surface => |surface| surface.core_surface.preeditCallback(
                        result.text,
                    ) catch |err| {
                        log.err("error in preedit callback err={}", .{err});
                        return null;
                    },
                }
            } else {
                switch (target) {
                    .app => {},
                    .surface => |surface| surface.core_surface.preeditCallback(null) catch |err| {
                        log.err("error in preedit callback err={}", .{err});
                        return null;
                    },
                }

                // If the text is just a single non-printable ASCII character
                // then we clear the text. We handle non-printables in the
                // key encoder manual (such as tab, ctrl+c, etc.)
                if (result.text.len == 1 and result.text[0] < 0x20) {
                    break :translate .{};
                }
            }

            break :translate result;
        } else .{};

        // We need to always do a translation with no modifiers at all in
        // order to get the "unshifted_codepoint" for the key event.
        const unshifted_codepoint: u21 = unshifted: {
            var nomod_buf: [128]u8 = undefined;
            var nomod_state: input.Keymap.State = .{};
            const nomod = try self.keymap.translate(
                &nomod_buf,
                &nomod_state,
                @intCast(keycode),
                .{},
            );

            const view = std.unicode.Utf8View.init(nomod.text) catch |err| {
                log.warn("cannot build utf8 view over text: {}", .{err});
                break :unshifted 0;
            };
            var it = view.iterator();
            break :unshifted it.nextCodepoint() orelse 0;
        };

        // log.warn("TRANSLATE: action={} keycode={x} dead={} key_len={} key={any} key_str={s} mods={}", .{
        //     action,
        //     keycode,
        //     result.composing,
        //     result.text.len,
        //     result.text,
        //     result.text,
        //     mods,
        // });

        // We want to get the physical unmapped key to process keybinds.
        const physical_key = keycode: for (input.keycodes.entries) |entry| {
            if (entry.native == keycode) break :keycode entry.key;
        } else .invalid;

        // If the resulting text has length 1 then we can take its key
        // and attempt to translate it to a key enum and call the key callback.
        // If the length is greater than 1 then we're going to call the
        // charCallback.
        //
        // We also only do key translation if this is not a dead key.
        const key = if (!result.composing) key: {
            // If our physical key is a keypad key, we use that.
            if (physical_key.keypad()) break :key physical_key;

            // A completed key. If the length of the key is one then we can
            // attempt to translate it to a key enum and call the key
            // callback. First try plain ASCII.
            if (result.text.len > 0) {
                if (input.Key.fromASCII(result.text[0])) |key| {
                    break :key key;
                }
            }

            // If the above doesn't work, we use the unmodified value.
            if (std.math.cast(u8, unshifted_codepoint)) |ascii| {
                if (input.Key.fromASCII(ascii)) |key| {
                    break :key key;
                }
            }

            break :key physical_key;
        } else .invalid;

        // Build our final key event
        return .{
            .action = action,
            .key = key,
            .physical_key = physical_key,
            .mods = mods,
            .consumed_mods = result.mods,
            .composing = result.composing,
            .utf8 = result.text,
            .unshifted_codepoint = unshifted_codepoint,
        };
    }

    /// See CoreApp.keyEvent.
    pub fn keyEvent(
        self: *App,
        target: KeyTarget,
        event: KeyEvent,
    ) !bool {
        // Convert our C key event into a Zig one.
        const input_event: input.KeyEvent = (try self.coreKeyEvent(
            target,
            event,
        )) orelse return false;

        // Invoke the core Ghostty logic to handle this input.
        const effect: CoreSurface.InputEffect = switch (target) {
            .app => if (self.core_app.keyEvent(
                self,
                input_event,
            )) .consumed else .ignored,

            .surface => |surface| try surface.core_surface.keyCallback(
                input_event,
            ),
        };

        return switch (effect) {
            .closed => true,
            .ignored => false,
            .consumed => consumed: {
                const is_down = input_event.action == .press or
                    input_event.action == .repeat;

                if (is_down) {
                    // If we consume the key then we want to reset the dead
                    // key state.
                    self.keymap_state = .{};

                    switch (target) {
                        .app => {},
                        .surface => |surface| surface.core_surface.preeditCallback(null) catch {},
                    }
                }

                break :consumed true;
            },
        };
    }

    /// This should be called whenever the keyboard layout was changed.
    pub fn reloadKeymap(self: *App) !void {
        // Reload the keymap
        try self.keymap.reload();

        // Clear the dead key state since we changed the keymap, any
        // dead key state is just forgotten. i.e. if you type ' on us-intl
        // and then switch to us and type a, you'll get a rather than á.
        for (self.core_app.surfaces.items) |surface| {
            surface.keymap_state = .{};
        }
    }

    /// Loads the keyboard layout.
    ///
    /// Kind of expensive so this should be avoided if possible. When I say
    /// "kind of expensive" I mean that its not something you probably want
    /// to run on every keypress.
    pub fn keyboardLayout(self: *const App) input.KeyboardLayout {
        // We only support keyboard layout detection on macOS.
        if (comptime builtin.os.tag != .macos) return .unknown;

        // Any layout larger than this is not something we can handle.
        var buf: [256]u8 = undefined;
        const id = self.keymap.sourceId(&buf) catch |err| {
            comptime assert(@TypeOf(err) == error{OutOfMemory});
            return .unknown;
        };

        return input.KeyboardLayout.mapAppleId(id) orelse .unknown;
    }

    pub fn wakeup(self: *const App) void {
        self.opts.wakeup(self.opts.userdata);
    }

    pub fn wait(self: *const App) !void {
        _ = self;
    }

    /// Create a new surface for the app.
    fn newSurface(self: *App, opts: Surface.Options) !*Surface {
        // Grab a surface allocation because we're going to need it.
        var surface = try self.core_app.alloc.create(Surface);
        errdefer self.core_app.alloc.destroy(surface);

        // Create the surface -- because windows are surfaces for glfw.
        try surface.init(self, opts);
        errdefer surface.deinit();

        return surface;
    }

    /// Close the given surface.
    pub fn closeSurface(self: *App, surface: *Surface) void {
        surface.deinit();
        self.core_app.alloc.destroy(surface);
    }

    pub fn redrawSurface(self: *App, surface: *Surface) void {
        _ = self;
        _ = surface;
        // No-op, we use a threaded interface so we're constantly drawing.
    }

    pub fn redrawInspector(self: *App, surface: *Surface) void {
        _ = self;
        surface.queueInspectorRender();
    }

    /// Perform a given action. Returns `true` if the action was able to be
    /// performed, `false` otherwise.
    pub fn performAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !bool {
        // Special case certain actions before they are sent to the
        // embedded apprt.
        self.performPreAction(target, action, value);

        log.debug("dispatching action target={s} action={} value={}", .{
            @tagName(target),
            action,
            value,
        });
        return self.opts.action(
            self,
            target.cval(),
            @unionInit(apprt.Action, @tagName(action), value).cval(),
        );
    }

    fn performPreAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) void {
        // Special case certain actions before they are sent to the embedder
        switch (action) {
            .set_title => switch (target) {
                .app => {},
                .surface => |surface| {
                    // Dupe the title so that we can store it. If we get an allocation
                    // error we just ignore it, since this only breaks a few minor things.
                    const alloc = self.core_app.alloc;
                    if (surface.rt_surface.title) |v| alloc.free(v);
                    surface.rt_surface.title = alloc.dupeZ(u8, value.title) catch null;
                },
            },

            .config_change => switch (target) {
                .surface => {},

                // For app updates, we update our core config. We need to
                // clone it because the caller owns the param.
                .app => if (value.config.clone(self.core_app.alloc)) |config| {
                    self.config.deinit();
                    self.config = config;
                } else |err| {
                    log.err("error updating app config err={}", .{err});
                },
            },

            else => {},
        }
    }
};

/// Platform-specific configuration for libghostty.
pub const Platform = union(PlatformTag) {
    macos: MacOS,
    ios: IOS,

    // If our build target for libghostty is not darwin then we do
    // not include macos support at all.
    pub const MacOS = if (builtin.target.isDarwin()) struct {
        /// The view to render the surface on.
        nsview: objc.Object,
    } else void;

    pub const IOS = if (builtin.target.isDarwin()) struct {
        /// The view to render the surface on.
        uiview: objc.Object,
    } else void;

    // The C ABI compatible version of this union. The tag is expected
    // to be stored elsewhere.
    pub const C = extern union {
        macos: extern struct {
            nsview: ?*anyopaque,
        },

        ios: extern struct {
            uiview: ?*anyopaque,
        },
    };

    /// Initialize a Platform a tag and configuration from the C ABI.
    pub fn init(tag_int: c_int, c_platform: C) !Platform {
        const tag = try std.meta.intToEnum(PlatformTag, tag_int);
        return switch (tag) {
            .macos => if (MacOS != void) macos: {
                const config = c_platform.macos;
                const nsview = objc.Object.fromId(config.nsview orelse
                    break :macos error.NSViewMustBeSet);
                break :macos .{ .macos = .{ .nsview = nsview } };
            } else error.UnsupportedPlatform,

            .ios => if (IOS != void) ios: {
                const config = c_platform.ios;
                const uiview = objc.Object.fromId(config.uiview orelse
                    break :ios error.UIViewMustBeSet);
                break :ios .{ .ios = .{ .uiview = uiview } };
            } else error.UnsupportedPlatform,
        };
    }
};

pub const PlatformTag = enum(c_int) {
    // "0" is reserved for invalid so we can detect unset values
    // from the C API.

    macos = 1,
    ios = 2,
};

pub const Surface = struct {
    app: *App,
    platform: Platform,
    userdata: ?*anyopaque = null,
    core_surface: CoreSurface,
    content_scale: apprt.ContentScale,
    size: apprt.SurfaceSize,
    cursor_pos: apprt.CursorPos,
    keymap_state: input.Keymap.State,
    inspector: ?*Inspector = null,

    /// The current title of the surface. The embedded apprt saves this so
    /// that getTitle works without the implementer needing to save it.
    title: ?[:0]const u8 = null,

    /// Surface initialization options.
    pub const Options = extern struct {
        /// The platform that this surface is being initialized for and
        /// the associated platform-specific configuration.
        platform_tag: c_int = 0,
        platform: Platform.C = undefined,

        /// Userdata passed to some of the callbacks.
        userdata: ?*anyopaque = null,

        /// The scale factor of the screen.
        scale_factor: f64 = 1,

        /// The font size to inherit. If 0, default font size will be used.
        font_size: f32 = 0,

        /// The working directory to load into.
        working_directory: [*:0]const u8 = "",

        /// The command to run in the new surface. If this is set then
        /// the "wait-after-command" option is also automatically set to true,
        /// since this is used for scripting.
        command: [*:0]const u8 = "",
    };

    pub fn init(self: *Surface, app: *App, opts: Options) !void {
        self.* = .{
            .app = app,
            .platform = try Platform.init(opts.platform_tag, opts.platform),
            .userdata = opts.userdata,
            .core_surface = undefined,
            .content_scale = .{
                .x = @floatCast(opts.scale_factor),
                .y = @floatCast(opts.scale_factor),
            },
            .size = .{ .width = 800, .height = 600 },
            .cursor_pos = .{ .x = -1, .y = -1 },
            .keymap_state = .{},
        };

        // Add ourselves to the list of surfaces on the app.
        try app.core_app.addSurface(self);
        errdefer app.core_app.deleteSurface(self);

        // Shallow copy the config so that we can modify it.
        var config = try apprt.surface.newConfig(app.core_app, &app.config);
        defer config.deinit();

        // If we have a working directory from the options then we set it.
        const wd = std.mem.sliceTo(opts.working_directory, 0);
        if (wd.len > 0) wd: {
            var dir = std.fs.openDirAbsolute(wd, .{}) catch |err| {
                log.warn(
                    "error opening requested working directory dir={s} err={}",
                    .{ wd, err },
                );
                break :wd;
            };
            defer dir.close();

            const stat = dir.stat() catch |err| {
                log.warn(
                    "failed to stat requested working directory dir={s} err={}",
                    .{ wd, err },
                );
                break :wd;
            };

            if (stat.kind != .directory) {
                log.warn(
                    "requested working directory is not a directory dir={s}",
                    .{wd},
                );
                break :wd;
            }

            config.@"working-directory" = wd;
        }

        // If we have a command from the options then we set it.
        const cmd = std.mem.sliceTo(opts.command, 0);
        if (cmd.len > 0) {
            config.command = cmd;
            config.@"wait-after-command" = true;
        }

        // Initialize our surface right away. We're given a view that is
        // ready to use.
        try self.core_surface.init(
            app.core_app.alloc,
            &config,
            app.core_app,
            app,
            self,
        );
        errdefer self.core_surface.deinit();

        // If our options requested a specific font-size, set that.
        if (opts.font_size != 0) {
            var font_size = self.core_surface.font_size;
            font_size.points = opts.font_size;
            try self.core_surface.setFontSize(font_size);
        }
    }

    pub fn deinit(self: *Surface) void {
        // Shut down our inspector
        self.freeInspector();

        // Free our title
        if (self.title) |v| self.app.core_app.alloc.free(v);

        // Remove ourselves from the list of known surfaces in the app.
        self.app.core_app.deleteSurface(self);

        // Clean up our core surface so that all the rendering and IO stop.
        self.core_surface.deinit();
    }

    /// Initialize the inspector instance. A surface can only have one
    /// inspector at any given time, so this will return the previous inspector
    /// if it was already initialized.
    pub fn initInspector(self: *Surface) !*Inspector {
        if (self.inspector) |v| return v;

        const alloc = self.app.core_app.alloc;
        const inspector = try alloc.create(Inspector);
        errdefer alloc.destroy(inspector);
        inspector.* = try Inspector.init(self);
        self.inspector = inspector;
        return inspector;
    }

    pub fn freeInspector(self: *Surface) void {
        if (self.inspector) |v| {
            v.deinit();
            self.app.core_app.alloc.destroy(v);
            self.inspector = null;
        }
    }

    pub fn close(self: *const Surface, process_alive: bool) void {
        const func = self.app.opts.close_surface orelse {
            log.info("runtime embedder does not support closing a surface", .{});
            return;
        };

        func(self.userdata, process_alive);
    }

    pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
        return self.content_scale;
    }

    pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
        return self.size;
    }

    pub fn getTitle(self: *Surface) ?[:0]const u8 {
        return self.title;
    }

    pub fn supportsClipboard(
        self: *const Surface,
        clipboard_type: apprt.Clipboard,
    ) bool {
        return switch (clipboard_type) {
            .standard => true,
            .selection, .primary => self.app.opts.supports_selection_clipboard,
        };
    }

    pub fn clipboardRequest(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        state: apprt.ClipboardRequest,
    ) !void {
        // We need to allocate to get a pointer to store our clipboard request
        // so that it is stable until the read_clipboard callback and call
        // complete_clipboard_request. This sucks but clipboard requests aren't
        // high throughput so it's probably fine.
        const alloc = self.app.core_app.alloc;
        const state_ptr = try alloc.create(apprt.ClipboardRequest);
        errdefer alloc.destroy(state_ptr);
        state_ptr.* = state;

        self.app.opts.read_clipboard(
            self.userdata,
            @intCast(@intFromEnum(clipboard_type)),
            state_ptr,
        );
    }

    fn completeClipboardRequest(
        self: *Surface,
        str: [:0]const u8,
        state: *apprt.ClipboardRequest,
        confirmed: bool,
    ) void {
        const alloc = self.app.core_app.alloc;

        // Attempt to complete the request, but we may request
        // confirmation.
        self.core_surface.completeClipboardRequest(
            state.*,
            str,
            confirmed,
        ) catch |err| switch (err) {
            error.UnsafePaste,
            error.UnauthorizedPaste,
            => {
                self.app.opts.confirm_read_clipboard(
                    self.userdata,
                    str.ptr,
                    state,
                    state.*,
                );

                return;
            },

            else => log.err("error completing clipboard request err={}", .{err}),
        };

        // We don't defer this because the clipboard confirmation route
        // preserves the clipboard request.
        alloc.destroy(state);
    }

    pub fn setClipboardString(
        self: *const Surface,
        val: [:0]const u8,
        clipboard_type: apprt.Clipboard,
        confirm: bool,
    ) !void {
        self.app.opts.write_clipboard(
            self.userdata,
            val.ptr,
            @intCast(@intFromEnum(clipboard_type)),
            confirm,
        );
    }

    pub fn setShouldClose(self: *Surface) void {
        _ = self;
    }

    pub fn shouldClose(self: *const Surface) bool {
        _ = self;
        return false;
    }

    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
        return self.cursor_pos;
    }

    pub fn refresh(self: *Surface) void {
        self.core_surface.refreshCallback() catch |err| {
            log.err("error in refresh callback err={}", .{err});
            return;
        };
    }

    pub fn draw(self: *Surface) void {
        self.core_surface.draw() catch |err| {
            log.err("error in draw err={}", .{err});
            return;
        };
    }

    pub fn updateContentScale(self: *Surface, x: f64, y: f64) void {
        // We are an embedded API so the caller can send us all sorts of
        // garbage. We want to make sure that the float values are valid
        // and we don't want to support fractional scaling below 1.
        const x_scaled = @max(1, if (std.math.isNan(x)) 1 else x);
        const y_scaled = @max(1, if (std.math.isNan(y)) 1 else y);

        self.content_scale = .{
            .x = @floatCast(x_scaled),
            .y = @floatCast(y_scaled),
        };

        self.core_surface.contentScaleCallback(self.content_scale) catch |err| {
            log.err("error in content scale callback err={}", .{err});
            return;
        };
    }

    pub fn updateSize(self: *Surface, width: u32, height: u32) void {
        // Runtimes sometimes generate superfluous resize events even
        // if the size did not actually change (SwiftUI). We check
        // that the size actually changed from what we last recorded
        // since resizes are expensive.
        if (self.size.width == width and self.size.height == height) return;

        self.size = .{
            .width = width,
            .height = height,
        };

        // Call the primary callback.
        self.core_surface.sizeCallback(self.size) catch |err| {
            log.err("error in size callback err={}", .{err});
            return;
        };
    }

    pub fn colorSchemeCallback(self: *Surface, scheme: apprt.ColorScheme) void {
        self.core_surface.colorSchemeCallback(scheme) catch |err| {
            log.err("error setting color scheme err={}", .{err});
            return;
        };
    }

    pub fn mouseButtonCallback(
        self: *Surface,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: input.Mods,
    ) bool {
        return self.core_surface.mouseButtonCallback(action, button, mods) catch |err| {
            log.err("error in mouse button callback err={}", .{err});
            return false;
        };
    }

    pub fn mousePressureCallback(
        self: *Surface,
        stage: input.MousePressureStage,
        pressure: f64,
    ) void {
        self.core_surface.mousePressureCallback(stage, pressure) catch |err| {
            log.err("error in mouse pressure callback err={}", .{err});
            return;
        };
    }

    pub fn scrollCallback(
        self: *Surface,
        xoff: f64,
        yoff: f64,
        mods: input.ScrollMods,
    ) void {
        self.core_surface.scrollCallback(xoff, yoff, mods) catch |err| {
            log.err("error in scroll callback err={}", .{err});
            return;
        };
    }

    pub fn cursorPosCallback(
        self: *Surface,
        x: f64,
        y: f64,
        mods: input.Mods,
    ) void {
        // Convert our unscaled x/y to scaled.
        self.cursor_pos = self.cursorPosToPixels(.{
            .x = @floatCast(x),
            .y = @floatCast(y),
        }) catch |err| {
            log.err(
                "error converting cursor pos to scaled pixels in cursor pos callback err={}",
                .{err},
            );
            return;
        };

        self.core_surface.cursorPosCallback(self.cursor_pos, mods) catch |err| {
            log.err("error in cursor pos callback err={}", .{err});
            return;
        };
    }

    pub fn textCallback(self: *Surface, text: []const u8) void {
        _ = self.core_surface.textCallback(text) catch |err| {
            log.err("error in key callback err={}", .{err});
            return;
        };
    }

    pub fn focusCallback(self: *Surface, focused: bool) void {
        self.core_surface.focusCallback(focused) catch |err| {
            log.err("error in focus callback err={}", .{err});
            return;
        };
    }

    pub fn occlusionCallback(self: *Surface, visible: bool) void {
        self.core_surface.occlusionCallback(visible) catch |err| {
            log.err("error in occlusion callback err={}", .{err});
            return;
        };
    }

    fn queueInspectorRender(self: *Surface) void {
        _ = self.app.performAction(
            .{ .surface = &self.core_surface },
            .render_inspector,
            {},
        ) catch |err| {
            log.err("error rendering the inspector err={}", .{err});
            return;
        };
    }

    pub fn newSurfaceOptions(self: *const Surface) apprt.Surface.Options {
        const font_size: f32 = font_size: {
            if (!self.app.config.@"window-inherit-font-size") break :font_size 0;
            break :font_size self.core_surface.font_size.points;
        };

        return .{
            .font_size = font_size,
        };
    }

    pub fn defaultTermioEnv(self: *const Surface) !std.process.EnvMap {
        const alloc = self.app.core_app.alloc;
        var env = try internal_os.getEnvMap(alloc);
        errdefer env.deinit();

        if (comptime builtin.target.isDarwin()) {
            if (env.get("__XCODE_BUILT_PRODUCTS_DIR_PATHS") != null) {
                env.remove("__XCODE_BUILT_PRODUCTS_DIR_PATHS");
                env.remove("__XPC_DYLD_LIBRARY_PATH");
                env.remove("DYLD_FRAMEWORK_PATH");
                env.remove("DYLD_INSERT_LIBRARIES");
                env.remove("DYLD_LIBRARY_PATH");
                env.remove("LD_LIBRARY_PATH");
                env.remove("SECURITYSESSIONID");
                env.remove("XPC_SERVICE_NAME");
            }

            // Remove this so that running `ghostty` within Ghostty works.
            env.remove("GHOSTTY_MAC_APP");
        }

        return env;
    }

    /// The cursor position from the host directly is in screen coordinates but
    /// all our interface works in pixels.
    fn cursorPosToPixels(self: *const Surface, pos: apprt.CursorPos) !apprt.CursorPos {
        const scale = try self.getContentScale();
        return .{ .x = pos.x * scale.x, .y = pos.y * scale.y };
    }
};

/// Inspector is the state required for the terminal inspector. A terminal
/// inspector is 1:1 with a Surface.
pub const Inspector = struct {
    const cimgui = @import("cimgui");

    surface: *Surface,
    ig_ctx: *cimgui.c.ImGuiContext,
    backend: ?Backend = null,
    keymap_state: input.Keymap.State = .{},
    content_scale: f64 = 1,

    /// Our previous instant used to calculate delta time for animations.
    instant: ?std.time.Instant = null,

    const Backend = enum {
        metal,

        pub fn deinit(self: Backend) void {
            switch (self) {
                .metal => if (builtin.target.isDarwin()) cimgui.ImGui_ImplMetal_Shutdown(),
            }
        }
    };

    pub fn init(surface: *Surface) !Inspector {
        const ig_ctx = cimgui.c.igCreateContext(null) orelse return error.OutOfMemory;
        errdefer cimgui.c.igDestroyContext(ig_ctx);
        cimgui.c.igSetCurrentContext(ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();
        io.BackendPlatformName = "ghostty_embedded";

        // Setup our core inspector
        CoreInspector.setup();
        surface.core_surface.activateInspector() catch |err| {
            log.err("failed to activate inspector err={}", .{err});
        };

        return .{
            .surface = surface,
            .ig_ctx = ig_ctx,
        };
    }

    pub fn deinit(self: *Inspector) void {
        self.surface.core_surface.deactivateInspector();
        cimgui.c.igSetCurrentContext(self.ig_ctx);
        if (self.backend) |v| v.deinit();
        cimgui.c.igDestroyContext(self.ig_ctx);
    }

    /// Queue a render for the next frame.
    pub fn queueRender(self: *Inspector) void {
        self.surface.queueInspectorRender();
    }

    /// Initialize the inspector for a metal backend.
    pub fn initMetal(self: *Inspector, device: objc.Object) bool {
        defer device.msgSend(void, objc.sel("release"), .{});
        cimgui.c.igSetCurrentContext(self.ig_ctx);

        if (self.backend) |v| {
            v.deinit();
            self.backend = null;
        }

        if (!cimgui.ImGui_ImplMetal_Init(device.value)) {
            log.warn("failed to initialize metal backend", .{});
            return false;
        }
        self.backend = .metal;

        log.debug("initialized metal backend", .{});
        return true;
    }

    pub fn renderMetal(
        self: *Inspector,
        command_buffer: objc.Object,
        desc: objc.Object,
    ) !void {
        defer {
            command_buffer.msgSend(void, objc.sel("release"), .{});
            desc.msgSend(void, objc.sel("release"), .{});
        }
        assert(self.backend == .metal);
        //log.debug("render", .{});

        // Setup our imgui frame. We need to render multiple frames to ensure
        // ImGui completes all its state processing. I don't know how to fix
        // this.
        for (0..2) |_| {
            cimgui.ImGui_ImplMetal_NewFrame(desc.value);
            try self.newFrame();
            cimgui.c.igNewFrame();

            // Build our UI
            render: {
                const surface = &self.surface.core_surface;
                const inspector = surface.inspector orelse break :render;
                inspector.render();
            }

            // Render
            cimgui.c.igRender();
        }

        // MTLRenderCommandEncoder
        const encoder = command_buffer.msgSend(
            objc.Object,
            objc.sel("renderCommandEncoderWithDescriptor:"),
            .{desc.value},
        );
        defer encoder.msgSend(void, objc.sel("endEncoding"), .{});
        cimgui.ImGui_ImplMetal_RenderDrawData(
            cimgui.c.igGetDrawData(),
            command_buffer.value,
            encoder.value,
        );
    }

    pub fn updateContentScale(self: *Inspector, x: f64, y: f64) void {
        _ = y;
        cimgui.c.igSetCurrentContext(self.ig_ctx);

        // Cache our scale because we use it for cursor position calculations.
        self.content_scale = x;

        // Setup a new style and scale it appropriately.
        const style = cimgui.c.ImGuiStyle_ImGuiStyle();
        defer cimgui.c.ImGuiStyle_destroy(style);
        cimgui.c.ImGuiStyle_ScaleAllSizes(style, @floatCast(x));
        const active_style = cimgui.c.igGetStyle();
        active_style.* = style.*;
    }

    pub fn updateSize(self: *Inspector, width: u32, height: u32) void {
        cimgui.c.igSetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();
        io.DisplaySize = .{ .x = @floatFromInt(width), .y = @floatFromInt(height) };
    }

    pub fn mouseButtonCallback(
        self: *Inspector,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: input.Mods,
    ) void {
        _ = mods;

        self.queueRender();
        cimgui.c.igSetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();

        const imgui_button = switch (button) {
            .left => cimgui.c.ImGuiMouseButton_Left,
            .middle => cimgui.c.ImGuiMouseButton_Middle,
            .right => cimgui.c.ImGuiMouseButton_Right,
            else => return, // unsupported
        };

        cimgui.c.ImGuiIO_AddMouseButtonEvent(io, imgui_button, action == .press);
    }

    pub fn scrollCallback(
        self: *Inspector,
        xoff: f64,
        yoff: f64,
        mods: input.ScrollMods,
    ) void {
        _ = mods;

        self.queueRender();
        cimgui.c.igSetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();
        cimgui.c.ImGuiIO_AddMouseWheelEvent(
            io,
            @floatCast(xoff),
            @floatCast(yoff),
        );
    }

    pub fn cursorPosCallback(self: *Inspector, x: f64, y: f64) void {
        self.queueRender();
        cimgui.c.igSetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();
        cimgui.c.ImGuiIO_AddMousePosEvent(
            io,
            @floatCast(x * self.content_scale),
            @floatCast(y * self.content_scale),
        );
    }

    pub fn focusCallback(self: *Inspector, focused: bool) void {
        self.queueRender();
        cimgui.c.igSetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();
        cimgui.c.ImGuiIO_AddFocusEvent(io, focused);
    }

    pub fn textCallback(self: *Inspector, text: [:0]const u8) void {
        self.queueRender();
        cimgui.c.igSetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();
        cimgui.c.ImGuiIO_AddInputCharactersUTF8(io, text.ptr);
    }

    pub fn keyCallback(
        self: *Inspector,
        action: input.Action,
        key: input.Key,
        mods: input.Mods,
    ) !void {
        self.queueRender();
        cimgui.c.igSetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();

        // Update all our modifiers
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftShift, mods.shift);
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftCtrl, mods.ctrl);
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftAlt, mods.alt);
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftSuper, mods.super);

        // Send our keypress
        if (key.imguiKey()) |imgui_key| {
            cimgui.c.ImGuiIO_AddKeyEvent(
                io,
                imgui_key,
                action == .press or action == .repeat,
            );
        }
    }

    fn newFrame(self: *Inspector) !void {
        const io: *cimgui.c.ImGuiIO = cimgui.c.igGetIO();

        // Determine our delta time
        const now = try std.time.Instant.now();
        io.DeltaTime = if (self.instant) |prev| delta: {
            const since_ns = now.since(prev);
            const since_s: f32 = @floatFromInt(since_ns / std.time.ns_per_s);
            break :delta @max(0.00001, since_s);
        } else (1 / 60);
        self.instant = now;
    }
};

// C API
pub const CAPI = struct {
    const global = &@import("../global.zig").state;

    /// This is the same as Surface.KeyEvent but this is the raw C API version.
    const KeyEvent = extern struct {
        action: input.Action,
        mods: c_int,
        keycode: u32,
        text: ?[*:0]const u8,
        composing: bool,

        /// Convert to surface key event.
        fn keyEvent(self: KeyEvent) App.KeyEvent {
            return .{
                .action = self.action,
                .mods = @bitCast(@as(
                    input.Mods.Backing,
                    @truncate(@as(c_uint, @bitCast(self.mods))),
                )),
                .keycode = self.keycode,
                .text = if (self.text) |ptr| std.mem.sliceTo(ptr, 0) else null,
                .composing = self.composing,
            };
        }
    };

    const Selection = extern struct {
        tl_x_px: f64,
        tl_y_px: f64,
        offset_start: u32,
        offset_len: u32,
    };

    const SurfaceSize = extern struct {
        columns: u16,
        rows: u16,
        width_px: u32,
        height_px: u32,
        cell_width_px: u32,
        cell_height_px: u32,
    };

    // Reference the conditional exports based on target platform
    // so they're included in the C API.
    comptime {
        if (builtin.target.isDarwin()) {
            _ = Darwin;
        }
    }

    /// Create a new app.
    export fn ghostty_app_new(
        opts: *const apprt.runtime.App.Options,
        config: *const Config,
    ) ?*App {
        return app_new_(opts, config) catch |err| {
            log.err("error initializing app err={}", .{err});
            return null;
        };
    }

    fn app_new_(
        opts: *const apprt.runtime.App.Options,
        config: *const Config,
    ) !*App {
        var core_app = try CoreApp.create(global.alloc);
        errdefer core_app.destroy();

        // Create our runtime app
        var app = try global.alloc.create(App);
        errdefer global.alloc.destroy(app);
        app.* = try App.init(core_app, config, opts.*);
        errdefer app.terminate();

        return app;
    }

    /// Tick the event loop. This should be called whenever the "wakeup"
    /// callback is invoked for the runtime.
    export fn ghostty_app_tick(v: *App) void {
        v.core_app.tick(v) catch |err| {
            log.err("error app tick err={}", .{err});
        };
    }

    /// Return the userdata associated with the app.
    export fn ghostty_app_userdata(v: *App) ?*anyopaque {
        return v.opts.userdata;
    }

    export fn ghostty_app_free(v: *App) void {
        const core_app = v.core_app;
        v.terminate();
        global.alloc.destroy(v);
        core_app.destroy();
    }

    /// Update the focused state of the app.
    export fn ghostty_app_set_focus(
        app: *App,
        focused: bool,
    ) void {
        app.focusEvent(focused);
    }

    /// Notify the app of a global keypress capture. This will return
    /// true if the key was captured by the app, in which case the caller
    /// should not process the key.
    export fn ghostty_app_key(
        app: *App,
        event: KeyEvent,
    ) bool {
        return app.keyEvent(.app, event.keyEvent()) catch |err| {
            log.warn("error processing key event err={}", .{err});
            return false;
        };
    }

    /// Returns true if the given key event would trigger a binding
    /// if it were sent to the surface right now. The "right now"
    /// is important because things like trigger sequences are only
    /// valid until the next key event.
    export fn ghostty_app_key_is_binding(
        app: *App,
        event: KeyEvent,
    ) bool {
        const core_event = app.coreKeyEvent(
            .app,
            event.keyEvent(),
        ) catch |err| {
            log.warn("error processing key event err={}", .{err});
            return false;
        } orelse {
            log.warn("error processing key event", .{});
            return false;
        };

        return app.core_app.keyEventIsBinding(app, core_event);
    }

    /// Notify the app that the keyboard was changed. This causes the
    /// keyboard layout to be reloaded from the OS.
    export fn ghostty_app_keyboard_changed(v: *App) void {
        v.reloadKeymap() catch |err| {
            log.err("error reloading keyboard map err={}", .{err});
            return;
        };
    }

    /// Open the configuration.
    export fn ghostty_app_open_config(v: *App) void {
        _ = v.performAction(.app, .open_config, {}) catch |err| {
            log.err("error reloading config err={}", .{err});
            return;
        };
    }

    /// Update the configuration to the provided config. This will propagate
    /// to all surfaces as well.
    export fn ghostty_app_update_config(
        v: *App,
        config: *const Config,
    ) void {
        v.core_app.updateConfig(v, config) catch |err| {
            log.err("error updating config err={}", .{err});
            return;
        };
    }

    /// Returns true if the app needs to confirm quitting.
    export fn ghostty_app_needs_confirm_quit(v: *App) bool {
        return v.core_app.needsConfirmQuit();
    }

    /// Returns true if the app has global keybinds.
    export fn ghostty_app_has_global_keybinds(v: *App) bool {
        return v.hasGlobalKeybinds();
    }

    /// Update the color scheme of the app.
    export fn ghostty_app_set_color_scheme(v: *App, scheme_raw: c_int) void {
        const scheme = std.meta.intToEnum(apprt.ColorScheme, scheme_raw) catch {
            log.warn(
                "invalid color scheme to ghostty_surface_set_color_scheme value={}",
                .{scheme_raw},
            );
            return;
        };

        v.core_app.colorSchemeEvent(v, scheme) catch |err| {
            log.err("error setting color scheme err={}", .{err});
            return;
        };
    }

    /// Returns initial surface options.
    export fn ghostty_surface_config_new() apprt.Surface.Options {
        return .{};
    }

    /// Create a new surface as part of an app.
    export fn ghostty_surface_new(
        app: *App,
        opts: *const apprt.Surface.Options,
    ) ?*Surface {
        return surface_new_(app, opts) catch |err| {
            log.err("error initializing surface err={}", .{err});
            return null;
        };
    }

    fn surface_new_(
        app: *App,
        opts: *const apprt.Surface.Options,
    ) !*Surface {
        return try app.newSurface(opts.*);
    }

    export fn ghostty_surface_free(ptr: *Surface) void {
        ptr.app.closeSurface(ptr);
    }

    /// Returns the userdata associated with the surface.
    export fn ghostty_surface_userdata(surface: *Surface) ?*anyopaque {
        return surface.userdata;
    }

    /// Returns the app associated with a surface.
    export fn ghostty_surface_app(surface: *Surface) *App {
        return surface.app;
    }

    /// Returns the config to use for surfaces that inherit from this one.
    export fn ghostty_surface_inherited_config(surface: *Surface) Surface.Options {
        return surface.newSurfaceOptions();
    }

    /// Update the configuration to the provided config for only this surface.
    export fn ghostty_surface_update_config(
        surface: *Surface,
        config: *const Config,
    ) void {
        surface.core_surface.updateConfig(config) catch |err| {
            log.err("error updating config err={}", .{err});
            return;
        };
    }

    /// Returns true if the surface needs to confirm quitting.
    export fn ghostty_surface_needs_confirm_quit(surface: *Surface) bool {
        return surface.core_surface.needsConfirmQuit();
    }

    /// Returns true if the surface has a selection.
    export fn ghostty_surface_has_selection(surface: *Surface) bool {
        return surface.core_surface.hasSelection();
    }

    /// Copies the surface selection text into the provided buffer and
    /// returns the copied size. If the buffer is too small, there is no
    /// selection, or there is an error, then 0 is returned.
    export fn ghostty_surface_selection(surface: *Surface, buf: [*]u8, cap: usize) usize {
        const selection_ = surface.core_surface.selectionString(global.alloc) catch |err| {
            log.warn("error getting selection err={}", .{err});
            return 0;
        };
        const selection = selection_ orelse return 0;
        defer global.alloc.free(selection);

        // If the buffer is too small, return no selection.
        if (selection.len > cap) return 0;

        // Copy into the buffer and return the length
        @memcpy(buf[0..selection.len], selection);
        return selection.len;
    }

    /// Tell the surface that it needs to schedule a render
    export fn ghostty_surface_refresh(surface: *Surface) void {
        surface.refresh();
    }

    /// Tell the surface that it needs to schedule a render
    /// call as soon as possible (NOW if possible).
    export fn ghostty_surface_draw(surface: *Surface) void {
        surface.draw();
    }

    /// Update the size of a surface. This will trigger resize notifications
    /// to the pty and the renderer.
    export fn ghostty_surface_set_size(surface: *Surface, w: u32, h: u32) void {
        surface.updateSize(w, h);
    }

    /// Return the size information a surface has.
    export fn ghostty_surface_size(surface: *Surface) SurfaceSize {
        const grid_size = surface.core_surface.size.grid();
        return .{
            .columns = grid_size.columns,
            .rows = grid_size.rows,
            .width_px = surface.core_surface.size.screen.width,
            .height_px = surface.core_surface.size.screen.height,
            .cell_width_px = surface.core_surface.size.cell.width,
            .cell_height_px = surface.core_surface.size.cell.height,
        };
    }

    /// Update the color scheme of the surface.
    export fn ghostty_surface_set_color_scheme(surface: *Surface, scheme_raw: c_int) void {
        const scheme = std.meta.intToEnum(apprt.ColorScheme, scheme_raw) catch {
            log.warn(
                "invalid color scheme to ghostty_surface_set_color_scheme value={}",
                .{scheme_raw},
            );
            return;
        };

        surface.colorSchemeCallback(scheme);
    }

    /// Update the content scale of the surface.
    export fn ghostty_surface_set_content_scale(surface: *Surface, x: f64, y: f64) void {
        surface.updateContentScale(x, y);
    }

    /// Update the focused state of a surface.
    export fn ghostty_surface_set_focus(surface: *Surface, focused: bool) void {
        surface.focusCallback(focused);
    }

    /// Update the occlusion state of a surface.
    export fn ghostty_surface_set_occlusion(surface: *Surface, visible: bool) void {
        surface.occlusionCallback(visible);
    }

    /// Filter the mods if necessary. This handles settings such as
    /// `macos-option-as-alt`. The filtered mods should be used for
    /// key translation but should NOT be sent back via the `_key`
    /// function -- the original mods should be used for that.
    export fn ghostty_surface_key_translation_mods(
        surface: *Surface,
        mods_raw: c_int,
    ) c_int {
        const mods: input.Mods = @bitCast(@as(
            input.Mods.Backing,
            @truncate(@as(c_uint, @bitCast(mods_raw))),
        ));
        const result = mods.translation(
            surface.core_surface.config.macos_option_as_alt orelse
                surface.app.keyboardLayout().detectOptionAsAlt(),
        );
        return @intCast(@as(input.Mods.Backing, @bitCast(result)));
    }

    /// Send this for raw keypresses (i.e. the keyDown event on macOS).
    /// This will handle the keymap translation and send the appropriate
    /// key and char events.
    export fn ghostty_surface_key(
        surface: *Surface,
        event: KeyEvent,
    ) bool {
        return surface.app.keyEvent(
            .{ .surface = surface },
            event.keyEvent(),
        ) catch |err| {
            log.warn("error processing key event err={}", .{err});
            return false;
        };
    }

    /// Returns true if the given key event would trigger a binding
    /// if it were sent to the surface right now. The "right now"
    /// is important because things like trigger sequences are only
    /// valid until the next key event.
    export fn ghostty_surface_key_is_binding(
        surface: *Surface,
        event: KeyEvent,
    ) bool {
        const core_event = surface.app.coreKeyEvent(
            // Note: this "app" target here looks like a bug, but it is
            // intentional. coreKeyEvent uses the target only as a way to
            // trigger preedit callbacks for keymap translation and we don't
            // want to trigger that here. See the todo item in coreKeyEvent
            // for a long term solution to this and removing target altogether.
            .app,
            event.keyEvent(),
        ) catch |err| {
            log.warn("error processing key event err={}", .{err});
            return false;
        } orelse {
            log.warn("error processing key event", .{});
            return false;
        };

        return surface.core_surface.keyEventIsBinding(core_event);
    }

    /// Send raw text to the terminal. This is treated like a paste
    /// so this isn't useful for sending escape sequences. For that,
    /// individual key input should be used.
    export fn ghostty_surface_text(
        surface: *Surface,
        ptr: [*]const u8,
        len: usize,
    ) void {
        surface.textCallback(ptr[0..len]);
    }

    /// Returns true if the surface currently has mouse capturing
    /// enabled.
    export fn ghostty_surface_mouse_captured(surface: *Surface) bool {
        return surface.core_surface.mouseCaptured();
    }

    /// Tell the surface that it needs to schedule a render
    export fn ghostty_surface_mouse_button(
        surface: *Surface,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: c_int,
    ) bool {
        return surface.mouseButtonCallback(
            action,
            button,
            @bitCast(@as(
                input.Mods.Backing,
                @truncate(@as(c_uint, @bitCast(mods))),
            )),
        );
    }

    /// Update the mouse position within the view.
    export fn ghostty_surface_mouse_pos(
        surface: *Surface,
        x: f64,
        y: f64,
        mods: c_int,
    ) void {
        surface.cursorPosCallback(
            x,
            y,
            @bitCast(@as(
                input.Mods.Backing,
                @truncate(@as(c_uint, @bitCast(mods))),
            )),
        );
    }

    export fn ghostty_surface_mouse_scroll(
        surface: *Surface,
        x: f64,
        y: f64,
        scroll_mods: c_int,
    ) void {
        surface.scrollCallback(
            x,
            y,
            @bitCast(@as(u8, @truncate(@as(c_uint, @bitCast(scroll_mods))))),
        );
    }

    export fn ghostty_surface_mouse_pressure(
        surface: *Surface,
        stage_raw: u32,
        pressure: f64,
    ) void {
        const stage = std.meta.intToEnum(
            input.MousePressureStage,
            stage_raw,
        ) catch {
            log.warn(
                "invalid mouse pressure stage value={}",
                .{stage_raw},
            );
            return;
        };

        surface.mousePressureCallback(stage, pressure);
    }

    export fn ghostty_surface_ime_point(surface: *Surface, x: *f64, y: *f64) void {
        const pos = surface.core_surface.imePoint();
        x.* = pos.x;
        y.* = pos.y;
    }

    /// Request that the surface become closed. This will go through the
    /// normal trigger process that a close surface input binding would.
    export fn ghostty_surface_request_close(ptr: *Surface) void {
        ptr.core_surface.close();
    }

    /// Request that the surface split in the given direction.
    export fn ghostty_surface_split(ptr: *Surface, direction: apprt.action.SplitDirection) void {
        _ = ptr.app.performAction(
            .{ .surface = &ptr.core_surface },
            .new_split,
            direction,
        ) catch |err| {
            log.err("error creating new split err={}", .{err});
            return;
        };
    }

    /// Focus on the next split (if any).
    export fn ghostty_surface_split_focus(
        ptr: *Surface,
        direction: apprt.action.GotoSplit,
    ) void {
        _ = ptr.app.performAction(
            .{ .surface = &ptr.core_surface },
            .goto_split,
            direction,
        ) catch |err| {
            log.err("error creating new split err={}", .{err});
            return;
        };
    }

    /// Resize the current split by moving the split divider in the given
    /// direction. `direction` specifies which direction the split divider will
    /// move relative to the focused split. `amount` is a fractional value
    /// between 0 and 1 that specifies by how much the divider will move.
    export fn ghostty_surface_split_resize(
        ptr: *Surface,
        direction: apprt.action.ResizeSplit.Direction,
        amount: u16,
    ) void {
        _ = ptr.app.performAction(
            .{ .surface = &ptr.core_surface },
            .resize_split,
            .{ .direction = direction, .amount = amount },
        ) catch |err| {
            log.err("error resizing split err={}", .{err});
            return;
        };
    }

    /// Equalize the size of all splits in the current window.
    export fn ghostty_surface_split_equalize(ptr: *Surface) void {
        _ = ptr.app.performAction(
            .{ .surface = &ptr.core_surface },
            .equalize_splits,
            {},
        ) catch |err| {
            log.err("error equalizing splits err={}", .{err});
            return;
        };
    }

    /// Invoke an action on the surface.
    export fn ghostty_surface_binding_action(
        ptr: *Surface,
        action_ptr: [*]const u8,
        action_len: usize,
    ) bool {
        const action_str = action_ptr[0..action_len];
        const action = input.Binding.Action.parse(action_str) catch |err| {
            log.err("error parsing binding action action={s} err={}", .{ action_str, err });
            return false;
        };

        _ = ptr.core_surface.performBindingAction(action) catch |err| {
            log.err("error performing binding action action={} err={}", .{ action, err });
            return false;
        };

        return true;
    }

    /// Complete a clipboard read request started via the read callback.
    /// This can only be called once for a given request. Once it is called
    /// with a request the request pointer will be invalidated.
    export fn ghostty_surface_complete_clipboard_request(
        ptr: *Surface,
        str: [*:0]const u8,
        state: *apprt.ClipboardRequest,
        confirmed: bool,
    ) void {
        ptr.completeClipboardRequest(
            std.mem.sliceTo(str, 0),
            state,
            confirmed,
        );
    }

    export fn ghostty_surface_inspector(ptr: *Surface) ?*Inspector {
        return ptr.initInspector() catch |err| {
            log.err("error initializing inspector err={}", .{err});
            return null;
        };
    }

    export fn ghostty_inspector_free(ptr: *Surface) void {
        ptr.freeInspector();
    }

    export fn ghostty_inspector_set_size(ptr: *Inspector, w: u32, h: u32) void {
        ptr.updateSize(w, h);
    }

    export fn ghostty_inspector_set_content_scale(ptr: *Inspector, x: f64, y: f64) void {
        ptr.updateContentScale(x, y);
    }

    export fn ghostty_inspector_mouse_button(
        ptr: *Inspector,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: c_int,
    ) void {
        ptr.mouseButtonCallback(
            action,
            button,
            @bitCast(@as(
                input.Mods.Backing,
                @truncate(@as(c_uint, @bitCast(mods))),
            )),
        );
    }

    export fn ghostty_inspector_mouse_pos(ptr: *Inspector, x: f64, y: f64) void {
        ptr.cursorPosCallback(x, y);
    }

    export fn ghostty_inspector_mouse_scroll(
        ptr: *Inspector,
        x: f64,
        y: f64,
        scroll_mods: c_int,
    ) void {
        ptr.scrollCallback(
            x,
            y,
            @bitCast(@as(u8, @truncate(@as(c_uint, @bitCast(scroll_mods))))),
        );
    }

    export fn ghostty_inspector_key(
        ptr: *Inspector,
        action: input.Action,
        key: input.Key,
        c_mods: c_int,
    ) void {
        ptr.keyCallback(
            action,
            key,
            @bitCast(@as(
                input.Mods.Backing,
                @truncate(@as(c_uint, @bitCast(c_mods))),
            )),
        ) catch |err| {
            log.err("error processing key event err={}", .{err});
            return;
        };
    }

    export fn ghostty_inspector_text(
        ptr: *Inspector,
        str: [*:0]const u8,
    ) void {
        ptr.textCallback(std.mem.sliceTo(str, 0));
    }

    export fn ghostty_inspector_set_focus(ptr: *Inspector, focused: bool) void {
        ptr.focusCallback(focused);
    }

    /// Sets the window background blur on macOS to the desired value.
    /// I do this in Zig as an extern function because I don't know how to
    /// call these functions in Swift.
    ///
    /// This uses an undocumented, non-public API because this is what
    /// every terminal appears to use, including Terminal.app.
    export fn ghostty_set_window_background_blur(
        app: *App,
        window: *anyopaque,
    ) void {
        // This is only supported on macOS
        if (comptime builtin.target.os.tag != .macos) return;

        const config = &app.config;

        // Do nothing if we don't have background transparency enabled
        if (config.@"background-opacity" >= 1.0) return;

        const nswindow = objc.Object.fromId(window);
        _ = CGSSetWindowBackgroundBlurRadius(
            CGSDefaultConnectionForThread(),
            nswindow.msgSend(usize, objc.sel("windowNumber"), .{}),
            @intCast(config.@"background-blur".cval()),
        );
    }

    /// See ghostty_set_window_background_blur
    extern "c" fn CGSSetWindowBackgroundBlurRadius(*anyopaque, usize, c_int) i32;
    extern "c" fn CGSDefaultConnectionForThread() *anyopaque;

    // Darwin-only C APIs.
    const Darwin = struct {
        export fn ghostty_surface_set_display_id(ptr: *Surface, display_id: u32) void {
            const surface = &ptr.core_surface;
            _ = surface.renderer_thread.mailbox.push(
                .{ .macos_display_id = display_id },
                .{ .forever = {} },
            );
            surface.renderer_thread.wakeup.notify() catch {};
        }

        /// This returns a CTFontRef that should be used for quicklook
        /// highlighted text. This is always the primary font in use
        /// regardless of the selected text. If coretext is not in use
        /// then this will return nothing.
        export fn ghostty_surface_quicklook_font(ptr: *Surface) ?*anyopaque {
            // For non-CoreText we just return null.
            if (comptime font.options.backend != .coretext) {
                return null;
            }

            // We'll need content scale so fail early if we can't get it.
            const content_scale = ptr.getContentScale() catch return null;

            // Get the shared font grid. We acquire a read lock to
            // read the font face. It should not be deferred since
            // we're loading the primary face.
            const grid = ptr.core_surface.renderer.font_grid;
            grid.lock.lockShared();
            defer grid.lock.unlockShared();

            const collection = &grid.resolver.collection;
            const face = collection.getFace(.{}) catch return null;

            // We need to unscale the content scale. We apply the
            // content scale to our font stack because we are rendering
            // at 1x but callers of this should be using scaled or apply
            // scale themselves.
            const size: f32 = size: {
                const num = face.font.copyAttribute(.size) orelse
                    break :size 12;
                defer num.release();
                var v: f32 = 12;
                _ = num.getValue(.float, &v);
                break :size v;
            };

            const copy = face.font.copyWithAttributes(
                size / content_scale.y,
                null,
                null,
            ) catch return null;

            return copy;
        }

        /// This returns the selected word for quicklook. This will populate
        /// the buffer with the word under the cursor and the selection
        /// info so that quicklook can be rendered.
        ///
        /// This does not modify the selection active on the surface (if any).
        export fn ghostty_surface_quicklook_word(
            ptr: *Surface,
            buf: [*]u8,
            cap: usize,
            info: *Selection,
        ) usize {
            const surface = &ptr.core_surface;
            surface.renderer_state.mutex.lock();
            defer surface.renderer_state.mutex.unlock();

            // To make everything in this function easier, we modify the
            // selection to be the word under the cursor and call normal APIs.
            // We restore the old selection so it isn't ever changed. Since we hold
            // the renderer mutex it'll never show up in a frame.
            const prev = surface.io.terminal.screen.selection;
            defer surface.io.terminal.screen.selection = prev;

            // Get our word selection
            const sel = sel: {
                const screen = &surface.renderer_state.terminal.screen;
                const pos = try ptr.getCursorPos();
                const pt_viewport = surface.posToViewport(pos.x, pos.y);
                const pin = screen.pages.pin(.{
                    .viewport = .{
                        .x = pt_viewport.x,
                        .y = pt_viewport.y,
                    },
                }) orelse {
                    if (comptime std.debug.runtime_safety) unreachable;
                    return 0;
                };
                break :sel surface.io.terminal.screen.selectWord(pin) orelse return 0;
            };

            // Set the selection
            surface.io.terminal.screen.selection = sel;

            // No we call normal functions. These require that the lock
            // is unlocked. This may cause a frame flicker with the fake
            // selection but I think the lack of new complexity is worth it
            // for now.
            {
                surface.renderer_state.mutex.unlock();
                defer surface.renderer_state.mutex.lock();
                const len = ghostty_surface_selection(ptr, buf, cap);
                if (!ghostty_surface_selection_info(ptr, info)) return 0;
                return len;
            }
        }

        /// This returns the selection metadata for the current selection.
        /// This will return false if there is no selection or the
        /// selection is not fully contained in the viewport (since the
        /// metadata is all about that).
        export fn ghostty_surface_selection_info(
            ptr: *Surface,
            info: *Selection,
        ) bool {
            const sel = ptr.core_surface.selectionInfo() orelse
                return false;

            info.* = .{
                .tl_x_px = sel.tl_x_px,
                .tl_y_px = sel.tl_y_px,
                .offset_start = sel.offset_start,
                .offset_len = sel.offset_len,
            };
            return true;
        }

        export fn ghostty_inspector_metal_init(ptr: *Inspector, device: objc.c.id) bool {
            return ptr.initMetal(objc.Object.fromId(device));
        }

        export fn ghostty_inspector_metal_render(
            ptr: *Inspector,
            command_buffer: objc.c.id,
            descriptor: objc.c.id,
        ) void {
            return ptr.renderMetal(
                objc.Object.fromId(command_buffer),
                objc.Object.fromId(descriptor),
            ) catch |err| {
                log.err("error rendering inspector err={}", .{err});
                return;
            };
        }

        export fn ghostty_inspector_metal_shutdown(ptr: *Inspector) void {
            if (ptr.backend) |v| {
                v.deinit();
                ptr.backend = null;
            }
        }
    };
};
