const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const graphene = @import("graphene");
const gsk = @import("gsk");
const gtk = @import("gtk");

const configpkg = @import("../../../config.zig");
const apprt = @import("../../../apprt.zig");
const CoreSurface = @import("../../../Surface.zig");
const ext = @import("../ext.zig");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const Config = @import("config.zig").Config;
const Application = @import("application.zig").Application;
const SplitTree = @import("split_tree.zig").SplitTree;
const Surface = @import("surface.zig").Surface;
const TitleDialog = @import("title_dialog.zig").TitleDialog;
const Overrides = @import("Overrides.zig");

const log = std.log.scoped(.gtk_ghostty_window);

pub const TabColor = enum {
    none,
    blue,
    purple,
    pink,
    red,
    orange,
    yellow,
    green,
    teal,
    graphite,

    fn rgb(self: TabColor) ?[3]u8 {
        return switch (self) {
            .none => null,
            .blue => .{ 0x3b, 0x8b, 0xff },
            .purple => .{ 0xbf, 0x5a, 0xf2 },
            .pink => .{ 0xff, 0x4d, 0x7a },
            .red => .{ 0xff, 0x5a, 0x52 },
            .orange => .{ 0xff, 0x9f, 0x0a },
            .yellow => .{ 0xff, 0xd6, 0x0a },
            .green => .{ 0x30, 0xd1, 0x58 },
            .teal => .{ 0x40, 0xe0, 0xd0 },
            .graphite => .{ 0x98, 0x98, 0x9d },
        };
    }

    fn rgba(channels: [3]u8) gdk.RGBA {
        return .{
            .f_red = @as(f32, @floatFromInt(channels[0])) / 255.0,
            .f_green = @as(f32, @floatFromInt(channels[1])) / 255.0,
            .f_blue = @as(f32, @floatFromInt(channels[2])) / 255.0,
            .f_alpha = 1.0,
        };
    }

    /// Draw the swatch into `snap` as vector paths (circle, or ring+slash for none).
    /// When `selected`, draw an outer ring using the user accent color.
    pub fn appendSwatch(self: TabColor, snap: *gtk.Snapshot, size: f32, selected: bool) void {
        const mid = size / 2.0;
        const radius = size * 0.3125;
        const stroke_width = @max(1.0, size * (1.5 / 16.0));
        var center: graphene.Point = undefined;
        _ = graphene.Point.init(&center, mid, mid);

        if (self.rgb()) |channels| {
            const builder = gsk.PathBuilder.new();
            builder.addCircle(&center, radius);
            const path = builder.freeToPath();
            defer path.unref();
            const fill = rgba(channels);
            snap.appendFill(path, .winding, &fill);
        } else {
            // None: outlined circle with a slash so it reads as "no color".
            const stroke_color = rgba(.{ 0x9a, 0x9a, 0x9e });
            const stroke = gsk.Stroke.new(stroke_width);
            defer stroke.free();

            const circle_builder = gsk.PathBuilder.new();
            circle_builder.addCircle(&center, radius);
            const circle = circle_builder.freeToPath();
            defer circle.unref();
            snap.appendStroke(circle, stroke, &stroke_color);

            const inset = radius * 0.72;
            const slash_builder = gsk.PathBuilder.new();
            slash_builder.moveTo(mid - inset, mid + inset);
            slash_builder.lineTo(mid + inset, mid - inset);
            const slash = slash_builder.freeToPath();
            defer slash.unref();
            snap.appendStroke(slash, stroke, &stroke_color);
        }

        if (selected) {
            const accent = adw.StyleManager.getDefault().getAccentColorRgba();
            defer accent.free();
            const ring = gsk.Stroke.new(@max(1.5, size * (2.0 / 16.0)));
            defer ring.free();
            const ring_builder = gsk.PathBuilder.new();
            ring_builder.addCircle(&center, size * 0.45);
            const ring_path = ring_builder.freeToPath();
            defer ring_path.unref();
            snap.appendStroke(ring_path, ring, accent);
        }
    }

    /// Snapshot vector swatch at 3x (48px) so GTK can scale for HiDPI.
    pub fn createIndicatorIcon(self: TabColor) *gdk.Texture {
        const size: f32 = 48;
        const size_i: c_int = 48;

        const snap = gtk.Snapshot.new();
        self.appendSwatch(snap, size, false);
        const node = snap.freeToNode() orelse {
            const transparent: [48 * 48 * 4]u8 = @splat(0);
            const bytes = glib.Bytes.new(&transparent, transparent.len);
            defer bytes.unref();
            return gdk.MemoryTexture.new(size_i, size_i, .r8g8b8a8_premultiplied, bytes, 48 * 4).as(gdk.Texture);
        };
        defer node.unref();

        const cairo_renderer = gsk.CairoRenderer.new();
        defer cairo_renderer.unref();
        const renderer = cairo_renderer.as(gsk.Renderer);
        var err: ?*glib.Error = null;
        if (renderer.realize(null, &err) == 0) {
            if (err) |e| {
                defer e.free();
                log.warn("failed to realize swatch renderer: {s}", .{e.f_message orelse "unknown"});
            }
            const transparent: [48 * 48 * 4]u8 = @splat(0);
            const bytes = glib.Bytes.new(&transparent, transparent.len);
            defer bytes.unref();
            return gdk.MemoryTexture.new(size_i, size_i, .r8g8b8a8_premultiplied, bytes, 48 * 4).as(gdk.Texture);
        }
        defer renderer.unrealize();

        var viewport: graphene.Rect = undefined;
        _ = graphene.Rect.init(&viewport, 0, 0, size, size);
        return renderer.renderTexture(node, &viewport);
    }
};

pub const Tab = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyTab",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        /// The active surface is the surface that should be receiving all
        /// surface-targeted actions. This is usually the focused surface,
        /// but may also not be focused if the user has selected a non-surface
        /// widget.
        pub const @"active-surface" = struct {
            pub const name = "active-surface";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*Surface,
                        .{
                            .getter = Self.getActiveSurface,
                        },
                    ),
                },
            );
        };

        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Config,
                .{
                    .accessor = C.privateObjFieldAccessor("config"),
                },
            );
        };

        pub const @"split-tree" = struct {
            pub const name = "split-tree";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*SplitTree,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*SplitTree,
                        .{
                            .getter = getSplitTree,
                        },
                    ),
                },
            );
        };

        pub const @"surface-tree" = struct {
            pub const name = "surface-tree";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface.Tree,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*Surface.Tree,
                        .{
                            .getter = getSurfaceTree,
                        },
                    ),
                },
            );
        };

        pub const tooltip = struct {
            pub const name = "tooltip";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("tooltip"),
                },
            );
        };

        pub const title = struct {
            pub const name = "title";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("title"),
                },
            );
        };
        pub const @"title-override" = struct {
            pub const name = "title-override";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("title_override"),
                },
            );
        };
    };

    pub const signals = struct {
        /// Emitted whenever the tab would like to be closed.
        pub const @"close-request" = struct {
            pub const name = "close-request";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };
    };

    const Private = struct {
        /// The configuration that this surface is using.
        config: ?*Config = null,

        /// The title of this tab. This is usually bound to the active surface.
        title: ?[:0]const u8 = null,

        /// The manually overridden title.
        title_override: ?[:0]const u8 = null,

        /// The tooltip of this tab. This is usually bound to the active surface.
        tooltip: ?[:0]const u8 = null,

        /// Color chosen from the tab context menu.
        tab_color: TabColor = .none,

        // Template bindings
        split_tree: *SplitTree,

        pub var offset: c_int = 0;
    };

    /// Set the parent of this tab page. This only affects the first surface
    /// ever created for a tab. If a surface was already created this does
    /// nothing.
    pub fn setParent(self: *Self, parent: *CoreSurface) void {
        self.setParentWithContext(parent, .tab);
    }

    pub fn setParentWithContext(self: *Self, parent: *CoreSurface, context: apprt.surface.NewSurfaceContext) void {
        if (self.getActiveSurface()) |surface| {
            surface.setParent(parent, context);
        }
    }

    pub fn new(config: ?*Config, overrides: Overrides) *Self {
        const tab = gobject.ext.newInstance(Tab, .{});

        const priv: *Private = tab.private();

        if (config) |c| priv.config = c.ref();

        // If our configuration is null then we get the configuration
        // from the application.
        if (priv.config == null) {
            const app = Application.default();
            priv.config = app.getConfig();
        }

        tab.as(gobject.Object).notifyByPspec(properties.config.impl.param_spec);

        // Create our initial surface in the split tree.
        priv.split_tree.newSplit(.right, null, .{
            .command = overrides.command,
            .shell_integration = overrides.shell_integration,
            .working_directory = overrides.working_directory,
            .title = overrides.title,
        }) catch |err| switch (err) {
            error.OutOfMemory => {
                // TODO: We should make our "no surfaces" state more aesthetically
                // pleasing and show something like an "Oops, something went wrong"
                // message. For now, this is incredibly unlikely.
                @panic("oom");
            },
        };

        return tab;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // Init our actions
        self.initActionMap();
    }

    fn initActionMap(self: *Self) void {
        const s_param_type = glib.ext.VariantType.newFor([:0]const u8);
        defer s_param_type.free();

        const actions = [_]ext.actions.Action(Self){
            .init("close", actionClose, s_param_type),
            .init("ring-bell", actionRingBell, null),
            .init("next-page", actionNextPage, null),
            .init("previous-page", actionPreviousPage, null),
            .init("prompt-tab-title", actionPromptTabTitle, null),
        };

        _ = ext.actions.addAsGroup(Self, self, "tab", &actions);
    }

    //---------------------------------------------------------------
    // Properties

    /// Overridden title. This will be generally be shown over the title
    /// unless this is unset (null).
    pub fn setTitleOverride(self: *Self, title: ?[:0]const u8) void {
        const priv = self.private();
        if (priv.title_override) |v| glib.free(@ptrCast(@constCast(v)));
        priv.title_override = null;
        if (title) |v| priv.title_override = glib.ext.dupeZ(u8, v);
        self.as(gobject.Object).notifyByPspec(properties.@"title-override".impl.param_spec);
    }
    fn titleDialogSet(
        _: *TitleDialog,
        title_ptr: [*:0]const u8,
        self: *Self,
    ) callconv(.c) void {
        const title = std.mem.span(title_ptr);
        self.setTitleOverride(if (title.len == 0) null else title);
    }

    pub fn getTabColor(self: *Self) TabColor {
        return self.private().tab_color;
    }

    pub fn setTabColor(self: *Self, color: TabColor) void {
        self.private().tab_color = color;
        self.syncColorIndicator();
    }

    pub fn syncColorIndicator(self: *Self) void {
        const page = self.getTabPage() orelse return;
        const color = self.private().tab_color;
        if (color == .none) {
            page.setIndicatorIcon(null);
            return;
        }
        const texture = color.createIndicatorIcon();
        defer texture.unref();
        page.setIndicatorIcon(texture.as(gio.Icon));
    }

    pub fn promptTabTitle(self: *Self) void {
        const priv = self.private();
        const dialog = TitleDialog.new(.tab, priv.title_override orelse priv.title);
        _ = TitleDialog.signals.set.connect(
            dialog,
            *Self,
            titleDialogSet,
            self,
            .{},
        );

        dialog.present(self.as(gtk.Widget));
    }

    /// Get the currently active surface. See the "active-surface" property.
    /// This does not ref the value.
    pub fn getActiveSurface(self: *Self) ?*Surface {
        return self.getSplitTree().getActiveSurface();
    }

    /// Get the surface tree of this tab.
    pub fn getSurfaceTree(self: *Self) ?*Surface.Tree {
        const priv = self.private();
        return priv.split_tree.getTree();
    }

    /// Get the split tree widget that is in this tab.
    pub fn getSplitTree(self: *Self) *SplitTree {
        const priv = self.private();
        return priv.split_tree;
    }

    /// Returns true if this tab needs confirmation before quitting based
    /// on the various Ghostty configurations.
    pub fn getNeedsConfirmQuit(self: *Self) bool {
        const tree = self.getSplitTree();
        return tree.getNeedsConfirmQuit();
    }

    /// Get the tab view holding this tab, if any.
    fn getTabView(self: *Self) ?*adw.TabView {
        return ext.getAncestor(
            adw.TabView,
            self.as(gtk.Widget),
        );
    }

    /// Get the tab page holding this tab, if any.
    fn getTabPage(self: *Self) ?*adw.TabPage {
        const tab_view = self.getTabView() orelse return null;
        return tab_view.getPage(self.as(gtk.Widget));
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.config) |v| {
            v.unref();
            priv.config = null;
        }

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.tooltip) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.tooltip = null;
        }
        if (priv.title) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.title = null;
        }
        if (priv.title_override) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.title_override = null;
        }

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }
    //---------------------------------------------------------------
    // Signal handlers

    fn propSplitTree(
        _: *SplitTree,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.as(gobject.Object).notifyByPspec(properties.@"surface-tree".impl.param_spec);

        // If our tree is empty we close the tab.
        const tree: *const Surface.Tree = self.getSurfaceTree() orelse &.empty;
        if (tree.isEmpty()) {
            signals.@"close-request".impl.emit(
                self,
                null,
                .{},
                null,
            );
            return;
        }
    }

    fn propActiveSurface(
        _: *SplitTree,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
    }

    fn actionClose(
        _: *gio.SimpleAction,
        param_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const param = param_ orelse {
            log.warn("tab.close-tab called without a parameter", .{});
            return;
        };

        var str: ?[*:0]const u8 = null;
        param.get("&s", &str);

        const tab_view = self.getTabView() orelse return;
        const page = tab_view.getPage(self.as(gtk.Widget));

        const mode = std.meta.stringToEnum(
            apprt.action.CloseTabMode,
            std.mem.span(
                str orelse {
                    log.warn("invalid mode provided to tab.close-tab", .{});
                    return;
                },
            ),
        ) orelse {
            // Need to be defensive here since actions can be triggered externally.
            log.warn("invalid mode provided to tab.close-tab: {s}", .{str.?});
            return;
        };

        // Delegate to our parent to handle this, since this will emit
        // a close-page signal that the parent can intercept.
        switch (mode) {
            .this => tab_view.closePage(page),
            .other => tab_view.closeOtherPages(page),
            .right => tab_view.closePagesAfter(page),
        }
    }

    fn actionPromptTabTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        self.promptTabTitle();
    }

    fn actionRingBell(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        // Future note: I actually don't like this logic living here at all.
        // I think a better approach will be for the ring bell action to
        // specify its sending surface and then do all this in the window.

        // If the page is selected already we don't mark it as needing
        // attention. We only want to mark unfocused pages. This will then
        // clear when the page is selected.
        const page = self.getTabPage() orelse return;
        if (page.getSelected() != 0) return;
        page.setNeedsAttention(@intFromBool(true));
    }

    /// Select the next tab page.
    fn actionNextPage(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const tab_view = self.getTabView() orelse return;
        _ = tab_view.selectNextPage();
    }

    /// Select the previous tab page.
    fn actionPreviousPage(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const tab_view = self.getTabView() orelse return;
        _ = tab_view.selectPreviousPage();
    }

    fn closureComputedTitle(
        _: *Self,
        config_: ?*Config,
        terminal_: ?[*:0]const u8,
        surface_override_: ?[*:0]const u8,
        tab_override_: ?[*:0]const u8,
        zoomed_: c_int,
        bell_ringing_: c_int,
        _: *gobject.ParamSpec,
    ) callconv(.c) ?[*:0]const u8 {
        const zoomed = zoomed_ != 0;
        const bell_ringing = bell_ringing_ != 0;

        // Our plain title is the manually tab overridden title if it exists,
        // otherwise the overridden title if it exists, otherwise
        // the terminal title if it exists, otherwise a default string.
        const plain = plain: {
            const default = "Ghostty";
            const config_title: ?[*:0]const u8 = title: {
                const config = config_ orelse break :title null;
                break :title config.get().title orelse null;
            };

            const plain = tab_override_ orelse
                surface_override_ orelse
                terminal_ orelse
                config_title orelse
                break :plain default;
            break :plain std.mem.span(plain);
        };

        // We don't need a config in every case, but if we don't have a config
        // let's just assume something went terribly wrong and use our
        // default title. Its easier then guarding on the config existing
        // in every case for something so unlikely.
        const config = if (config_) |v| v.get() else {
            log.warn("config unavailable for computed title, likely bug", .{});
            return glib.ext.dupeZ(u8, plain);
        };

        // Use an allocator to build up our string as we write it.
        var buf: std.Io.Writer.Allocating = .init(Application.default().allocator());
        defer buf.deinit();

        // If our bell is ringing, then we prefix the bell icon to the title.
        if (bell_ringing and config.@"bell-features".title) {
            buf.writer.writeAll("🔔 ") catch {};
        }

        // If we're zoomed, prefix with the magnifying glass emoji.
        if (zoomed) {
            buf.writer.writeAll("🔍 ") catch {};
        }

        buf.writer.writeAll(plain) catch return glib.ext.dupeZ(u8, plain);
        return glib.ext.dupeZ(u8, buf.written());
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(SplitTree);
            gobject.ext.ensureType(Surface);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 0,
                    .name = "tab",
                }),
            );

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.@"active-surface".impl,
                properties.config.impl,
                properties.@"split-tree".impl,
                properties.@"surface-tree".impl,
                properties.title.impl,
                properties.@"title-override".impl,
                properties.tooltip.impl,
            });

            // Bindings
            class.bindTemplateChildPrivate("split_tree", .{});

            // Template Callbacks
            class.bindTemplateCallback("computed_title", &closureComputedTitle);
            class.bindTemplateCallback("notify_active_surface", &propActiveSurface);
            class.bindTemplateCallback("notify_tree", &propSplitTree);

            // Signals
            signals.@"close-request".impl.register(.{});

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
