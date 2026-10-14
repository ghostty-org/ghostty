const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const apprt = @import("../../../apprt.zig");
const gresource = @import("../build/gresource.zig");
const i18n = @import("../../../os/main.zig").i18n;
const adw_version = @import("../adw_version.zig");
const Application = @import("application.zig").Application;
const Common = @import("../class.zig").Common;
const Dialog = @import("dialog.zig").Dialog;

const log = std.log.scoped(.gtk_ghostty_clipboard_confirmation);

/// The height of the preview area, matching the `height-request` the
/// template gives the stack. An image preview is clamped to it so that
/// the image's own size can't decide how tall the dialog is.
const preview_height = 200;

/// Whether we're able to have the remember switch
const can_remember = adw_version.supportsSwitchRow();

pub const ClipboardConfirmationDialog = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = Dialog;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyClipboardConfirmationDialog",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const @"can-remember" = struct {
            pub const name = "can-remember";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "can_remember",
                    ),
                },
            );
        };

        pub const request = struct {
            pub const name = "request";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*apprt.ClipboardRequest,
                .{
                    .accessor = C.privateBoxedFieldAccessor("request"),
                },
            );
        };

        pub const blur = struct {
            pub const name = "blur";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "blur",
                    ),
                },
            );
        };
    };

    pub const signals = struct {
        pub const deny = struct {
            pub const name = "deny";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{bool},
                void,
            );
        };

        pub const confirm = struct {
            pub const name = "confirm";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{bool},
                void,
            );
        };
    };

    const Private = struct {
        /// The request that this dialog is for.
        request: ?*apprt.ClipboardRequest = null,

        /// The buffer holding the first text representation, which is
        /// what a confirmed request that carries one value sends.
        clipboard_contents: ?*gtk.TextBuffer = null,

        /// Whether the contents should be blurred.
        blur: bool = false,

        /// Whether the user can remember the choice.
        can_remember: bool = false,

        // Template bindings
        parts_stack: *gtk.Stack,
        parts_dropdown: *gtk.DropDown,
        reveal_button: *gtk.Button,
        hide_button: *gtk.Button,
        remember_choice: if (can_remember) *adw.SwitchRow else void,

        pub var offset: c_int = 0;
    };

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // Trigger initial values
        self.propBlur(undefined, null);
        self.propRequest(undefined, null);
    }

    pub fn present(self: *Self, parent: ?*gtk.Widget) void {
        self.as(Dialog).present(parent);
    }

    /// Get the clipboard request without copying.
    pub fn getRequest(self: *Self) ?*apprt.ClipboardRequest {
        return self.private().request;
    }

    /// Get the clipboard contents without copying.
    pub fn getClipboardContents(self: *Self) ?*gtk.TextBuffer {
        return self.private().clipboard_contents;
    }

    /// Fill the preview with one page per clipboard representation, so
    /// that a multipart payload can be inspected in full rather than
    /// through whichever single representation we happened to pick.
    /// The pages are named by MIME type and the dropdown above them
    /// is shown only when there's more than one.
    ///
    /// The first text representation is kept as the dialog contents,
    /// since that's the one value a confirmed OSC 52 write or unsafe
    /// paste sends on.
    ///
    /// Everything is copied into widgets here, so the contents need
    /// only live for this call.
    ///
    /// The contents are anytype because the callers hold different
    /// element types with the same field shape: write requests carry
    /// []const apprt.ClipboardContent (sentinel-terminated so they can
    /// cross the C apprt boundary) while reads gather []const
    /// terminal.clipboard.Content. Only the mime and data fields are
    /// read, so comptime duck typing avoids copying one representation
    /// into the other.
    pub fn setParts(self: *Self, contents: anytype) void {
        const priv = self.private();
        const alloc = Application.default().allocator();

        var count: usize = 0;
        for (contents, 0..) |content, i| {
            const part = previewPart(alloc, content.mime, content.data);

            // The page name only addresses the page; the title is what
            // the dropdown shows.
            var name_buf: [32]u8 = undefined;
            const name = std.fmt.bufPrintZ(&name_buf, "part-{d}", .{i}) catch continue;

            var title_buf: [256]u8 = undefined;
            const title = truncateZ(&title_buf, content.mime);

            _ = priv.parts_stack.addTitled(part.widget, name, title);
            count += 1;

            log.debug(
                "clipboard confirmation preview mime={s} bytes={d} shown as {t}",
                .{ title, content.data.len, part.kind },
            );

            // The value a confirmed single-value request sends.
            if (priv.clipboard_contents == null) {
                if (part.buffer) |buffer| {
                    buffer.ref();
                    priv.clipboard_contents = buffer;
                }
            }
        }

        priv.parts_dropdown.as(gtk.Widget).setVisible(@intFromBool(count > 1));

        log.debug(
            "clipboard confirmation preview parts={d} text={}",
            .{ count, priv.clipboard_contents != null },
        );
    }

    /// One representation's preview page.
    const Part = struct {
        widget: *gtk.Widget,

        /// What the page shows, which is only as much as we could make
        /// of the representation.
        kind: enum { image, text, none },

        /// The buffer behind the page when the representation is shown
        /// as text, so the dialog can hand that text back on confirm.
        buffer: ?*gtk.TextBuffer = null,
    };

    /// The preview for one representation: the image if it decodes,
    /// the text if it can be read as text, and otherwise a note that
    /// it can't be previewed.
    ///
    /// Every representation gets a page, an empty one included: an
    /// empty representation is how a write clears the clipboard, and
    /// its page is the empty text the request would send.
    fn previewPart(
        alloc: std.mem.Allocator,
        mime: []const u8,
        data: []const u8,
    ) Part {
        if (std.mem.startsWith(u8, mime, "image/")) {
            if (imagePart(data)) |part| return part;
        }

        if (textPart(alloc, data)) |part| return part;

        return unpreviewablePart(data.len);
    }

    /// A picture of the representation, if the data decodes as an
    /// image.
    fn imagePart(data: []const u8) ?Part {
        const bytes = glib.Bytes.new(data.ptr, data.len);
        defer bytes.unref();

        // TODO: use glycin directly here so untrusted image data
        // is decoded in its sandboxed decoder rather than by
        // GTK's in-process decoders.
        var gerr: ?*glib.Error = null;
        const texture = gdk.Texture.newFromBytes(bytes, &gerr) orelse {
            if (gerr) |err| {
                defer err.free();
                log.debug(
                    "failed to decode clipboard image preview err={s}",
                    .{err.f_message orelse "(no message)"},
                );
            }
            return null;
        };
        defer texture.unref();

        const picture = gtk.Picture.newForPaintable(texture.as(gdk.Paintable));
        picture.setCanShrink(@intFromBool(true));
        picture.setContentFit(.contain);
        picture.as(gtk.Widget).addCssClass("clipboard-image");

        // A picture asks for the image's own size: `can-shrink` lowers
        // the minimum to nothing but leaves the natural size at the
        // full resolution, and the stack passes that on. The dialog
        // caps the width itself, so without this a tall image drags
        // the preview to whatever height the window allows -- measured
        // at 942px for an 800x6000 image in a 2400x1408 window, where
        // the same dialog showing text is 184px.
        const clamp: *adw.Clamp = .new();
        clamp.as(gtk.Orientable).setOrientation(.vertical);
        clamp.setMaximumSize(preview_height);
        clamp.setTighteningThreshold(preview_height);
        clamp.setChild(picture.as(gtk.Widget));
        return .{ .widget = clamp.as(gtk.Widget), .kind = .image };
    }

    /// A scrollable view of the representation, if it can be shown as
    /// text at all. A MIME type we don't recognize still gets shown
    /// when its data is readable, which is more use to someone
    /// deciding whether to allow the request than the type name alone.
    ///
    /// GTK text buffers hold UTF-8 and nothing else, so that is the
    /// whole of the test.
    fn textPart(
        alloc: std.mem.Allocator,
        data: []const u8,
    ) ?Part {
        if (!std.unicode.utf8ValidateSlice(data)) return null;

        // The buffer wants a sentinel-terminated string, which the
        // representations crossing the apprt boundary have and the
        // ones gathered from the clipboard don't.
        const text = alloc.dupeZ(u8, data) catch return null;
        defer alloc.free(text);

        const text_view: *gtk.TextView = .new();
        text_view.setCursorVisible(@intFromBool(false));
        text_view.setEditable(@intFromBool(false));
        text_view.setMonospace(@intFromBool(true));
        text_view.getBuffer().setText(text, @intCast(text.len));

        const scroll: *gtk.ScrolledWindow = .new();
        scroll.setChild(text_view.as(gtk.Widget));
        return .{
            .widget = scroll.as(gtk.Widget),
            .kind = .text,
            .buffer = text_view.getBuffer(),
        };
    }

    /// A note standing in for a representation we can't show, with its
    /// size so the user knows how much data is involved.
    fn unpreviewablePart(len: usize) Part {
        const box: *gtk.Box = .new(.vertical, 6);
        box.as(gtk.Widget).setValign(.center);

        // TODO: mark this string for translation with i18n._() and
        // regenerate the translation files.
        const label: *gtk.Label = .new("No preview available");
        box.append(label.as(gtk.Widget));

        const size = glib.formatSize(len);
        defer glib.free(size);
        const size_label: *gtk.Label = .new(size);
        size_label.as(gtk.Widget).addCssClass("dim-label");
        box.append(size_label.as(gtk.Widget));

        return .{ .widget = box.as(gtk.Widget), .kind = .none };
    }

    /// Copy `str` into `buf` as a sentinel-terminated string, cutting
    /// it short if it doesn't fit.
    fn truncateZ(buf: []u8, str: []const u8) [:0]const u8 {
        const len = @min(str.len, buf.len - 1);
        @memcpy(buf[0..len], str[0..len]);
        buf[len] = 0;
        return buf[0..len :0];
    }

    //---------------------------------------------------------------
    // Signal Handlers

    fn propBlur(
        self: *Self,
        _: *gobject.ParamSpec,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.blur) {
            priv.parts_stack.as(gtk.Widget).setSensitive(@intFromBool(false));
            priv.parts_stack.as(gtk.Widget).addCssClass("blurred");
            priv.reveal_button.as(gtk.Widget).setVisible(@intFromBool(true));
            priv.hide_button.as(gtk.Widget).setVisible(@intFromBool(false));
        } else {
            priv.parts_stack.as(gtk.Widget).setSensitive(@intFromBool(true));
            priv.parts_stack.as(gtk.Widget).removeCssClass("blurred");
            priv.reveal_button.as(gtk.Widget).setVisible(@intFromBool(false));
            priv.hide_button.as(gtk.Widget).setVisible(@intFromBool(false));
        }
    }

    fn propRequest(
        self: *Self,
        _: *gobject.ParamSpec,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const priv = self.private();
        const req = priv.request orelse return;
        switch (req.*) {
            .osc_52_write, .kitty_write => {
                self.as(Dialog.Parent).setHeading(i18n._("Authorize Clipboard Access"));
                self.as(Dialog.Parent).setBody(i18n._("An application is attempting to write to the clipboard. The current clipboard contents are shown below."));
            },
            .osc_52_read, .kitty_read => {
                self.as(Dialog.Parent).setHeading(i18n._("Authorize Clipboard Access"));
                self.as(Dialog.Parent).setBody(i18n._("An application is attempting to read from the clipboard. The current clipboard contents are shown below."));
            },
            .paste => {
                self.as(Dialog.Parent).setHeading(i18n._("Warning: Potentially Unsafe Paste"));
                self.as(Dialog.Parent).setBody(i18n._("Pasting this text into the terminal may be dangerous as it looks like some commands may be executed."));
            },
            .list => unreachable,
        }

        // The remember switch means different things for different
        // request types: OSC 52 remembers by changing the configured
        // policy, while Kitty clipboard protocol requests record a
        // session grant for the password supplied by the program.
        if (comptime can_remember) switch (req.*) {
            .kitty_read, .kitty_write => {
                // TODO: mark these strings for translation with
                // i18n._() and regenerate the translation files.
                priv.remember_choice.as(adw.PreferencesRow).setTitle(
                    "Remember choice for this terminal session",
                );
                priv.remember_choice.as(adw.ActionRow).setSubtitle(
                    "Future requests with the same token will be allowed",
                );
            },
            .osc_52_read, .osc_52_write, .paste => {},
            .list => unreachable,
        };
    }

    /// Show the representation picked from the dropdown. Its model is
    /// the stack's own page list, so the selection is a `gtk.StackPage`.
    fn partsSelected(
        dropdown: *gtk.DropDown,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const item = dropdown.getSelectedItem() orelse return;
        const page = gobject.ext.cast(gtk.StackPage, item) orelse return;
        self.private().parts_stack.setVisibleChild(page.getChild());
    }

    fn revealButtonClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.parts_stack.as(gtk.Widget).setSensitive(@intFromBool(true));
        priv.parts_stack.as(gtk.Widget).removeCssClass("blurred");
        priv.hide_button.as(gtk.Widget).setVisible(@intFromBool(true));
        priv.reveal_button.as(gtk.Widget).setVisible(@intFromBool(false));
    }

    fn hideButtonClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.parts_stack.as(gtk.Widget).setSensitive(@intFromBool(false));
        priv.parts_stack.as(gtk.Widget).addCssClass("blurred");
        priv.hide_button.as(gtk.Widget).setVisible(@intFromBool(false));
        priv.reveal_button.as(gtk.Widget).setVisible(@intFromBool(true));
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn response(
        self: *Self,
        response_id: [*:0]const u8,
    ) callconv(.c) void {
        const remember: bool = if (comptime can_remember) remember: {
            const priv = self.private();
            break :remember priv.remember_choice.getActive() != 0;
        } else false;

        if (std.mem.orderZ(u8, response_id, "cancel") == .eq) {
            signals.deny.impl.emit(
                self,
                null,
                .{remember},
                null,
            );
        } else if (std.mem.orderZ(u8, response_id, "ok") == .eq) {
            signals.confirm.impl.emit(
                self,
                null,
                .{remember},
                null,
            );
        }
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.clipboard_contents) |v| {
            v.unref();
            priv.clipboard_contents = null;
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
        if (priv.request) |v| {
            glib.ext.destroy(v);
            priv.request = null;
        }

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
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
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                if (comptime adw_version.atLeast(1, 4, 0))
                    comptime gresource.blueprint(.{
                        .major = 1,
                        .minor = 4,
                        .name = "clipboard-confirmation-dialog",
                    })
                else
                    comptime gresource.blueprint(.{
                        .major = 1,
                        .minor = 0,
                        .name = "clipboard-confirmation-dialog",
                    }),
            );

            // Bindings
            class.bindTemplateChildPrivate("parts_stack", .{});
            class.bindTemplateChildPrivate("parts_dropdown", .{});
            class.bindTemplateChildPrivate("hide_button", .{});
            class.bindTemplateChildPrivate("reveal_button", .{});
            if (comptime can_remember) {
                class.bindTemplateChildPrivate("remember_choice", .{});
            }

            // Template Callbacks
            class.bindTemplateCallback("parts_selected", &partsSelected);
            class.bindTemplateCallback("reveal_clicked", &revealButtonClicked);
            class.bindTemplateCallback("hide_clicked", &hideButtonClicked);
            class.bindTemplateCallback("notify_blur", &propBlur);
            class.bindTemplateCallback("notify_request", &propRequest);

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.blur.impl,
                properties.@"can-remember".impl,
                properties.request.impl,
            });

            // Signals
            signals.confirm.impl.register(.{});
            signals.deny.impl.register(.{});

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
            Dialog.virtual_methods.response.implement(class, &response);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
