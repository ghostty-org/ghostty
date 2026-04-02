const std = @import("std");
const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const apprt = @import("../../../apprt.zig");
const gresource = @import("../build/gresource.zig");
const i18n = @import("../../../os/main.zig").i18n;
const paste_homoglyph = @import("../../../input/paste_homoglyph.zig");
const adw_version = @import("../adw_version.zig");
const Common = @import("../class.zig").Common;
const Dialog = @import("dialog.zig").Dialog;

const log = std.log.scoped(.gtk_ghostty_clipboard_confirmation);

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

        pub const @"clipboard-contents" = struct {
            pub const name = "clipboard-contents";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*gtk.TextBuffer,
                .{
                    .accessor = C.privateObjFieldAccessor("clipboard_contents"),
                },
            );
        };

        pub const @"confirm-reason" = struct {
            pub const name = "confirm-reason";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                apprt.ClipboardConfirmReason,
                .{
                    .default = .none,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "confirm_reason",
                    ),
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

        /// The clipboard contents being read/written.
        clipboard_contents: ?*gtk.TextBuffer = null,

        /// Whether the contents should be blurred.
        blur: bool = false,

        /// Whether the user can remember the choice.
        can_remember: bool = false,

        confirm_reason: apprt.ClipboardConfirmReason = .none,

        // Template bindings
        text_view_scroll: *gtk.ScrolledWindow,
        text_view: *gtk.TextView,
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
        self.propConfirmReason(undefined, null);
    }

    fn setPasteConfirmationLabels(self: *Self, reason: apprt.ClipboardConfirmReason) void {
        switch (reason) {
            .mixed_script_url => {
                self.as(Dialog.Parent).setHeading(
                    i18n._("Warning: Potentially Dangerous URL"),
                );
                self.as(Dialog.Parent).setBody(
                    i18n._("The URL below contains suspicious characters that may be trying to impersonate a trusted domain. We suggest you verify the resource at the linked URL before proceeding."),
                );
            },
            .none => {
                self.as(Dialog.Parent).setHeading(i18n._("Warning: Potentially Unsafe Paste"));
                self.as(Dialog.Parent).setBody(
                    i18n._("Pasting this text into the terminal may be dangerous as it looks like some commands may be executed."),
                );
            },
        }
    }

    pub fn present(self: *Self, parent: ?*gtk.Widget) void {
        self.as(Dialog).present(parent);
    }

    const homoglyph_tag_name: [:0]const u8 = "ghostty-homoglyph";

    /// Underlines suspicious letters in the first risky URL only (full buffer still shown below).
    pub fn applyMixedScriptHomoglyphHighlights(self: *Self, full_utf8: [:0]const u8) void {
        const buf = self.getClipboardContents() orelse return;

        var stack: [paste_homoglyph.first_mixed_script_url_report_max_spans]paste_homoglyph.Utf8Span = undefined;
        const rep = paste_homoglyph.firstMixedScriptUrlReport(full_utf8, &stack) orelse return;
        if (rep.total_spans == 0) return;

        const table = buf.getTagTable();
        const tag = table.lookup(homoglyph_tag_name) orelse blk: {
            const t = gtk.TextTag.new(homoglyph_tag_name);
            {
                var v = gobject.ext.Value.newFrom(@as(c_int, 1));
                defer v.unset();
                gobject.Object.setProperty(t.as(gobject.Object), "underline", &v);
            }
            {
                var v = gobject.ext.Value.newFrom(@as([:0]const u8, "#b71c1c"));
                defer v.unset();
                gobject.Object.setProperty(t.as(gobject.Object), "foreground", &v);
            }
            _ = table.add(t);
            break :blk t;
        };

        var i: usize = 0;
        while (i < rep.written) : (i += 1) {
            const span = stack[i];
            const start_char: c_int = @intCast(paste_homoglyph.utf8ByteOffsetToCharIndex(full_utf8, span.start));
            const end_char: c_int = @intCast(paste_homoglyph.utf8ByteOffsetToCharIndex(full_utf8, span.end));
            var start_iter: gtk.TextIter = undefined;
            var end_iter: gtk.TextIter = undefined;
            buf.getIterAtOffset(&start_iter, start_char);
            buf.getIterAtOffset(&end_iter, end_char);
            buf.applyTag(tag, &start_iter, &end_iter);
        }
    }

    /// Get the clipboard request without copying.
    pub fn getRequest(self: *Self) ?*apprt.ClipboardRequest {
        return self.private().request;
    }

    /// Get the clipboard contents without copying.
    pub fn getClipboardContents(self: *Self) ?*gtk.TextBuffer {
        return self.private().clipboard_contents;
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
            priv.text_view_scroll.as(gtk.Widget).setSensitive(@intFromBool(false));
            priv.text_view.as(gtk.Widget).addCssClass("blurred");
            priv.reveal_button.as(gtk.Widget).setVisible(@intFromBool(true));
            priv.hide_button.as(gtk.Widget).setVisible(@intFromBool(false));
        } else {
            priv.text_view_scroll.as(gtk.Widget).setSensitive(@intFromBool(true));
            priv.text_view.as(gtk.Widget).removeCssClass("blurred");
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
            .osc_52_write => {
                self.as(Dialog.Parent).setHeading(i18n._("Authorize Clipboard Access"));
                self.as(Dialog.Parent).setBody(i18n._("An application is attempting to write to the clipboard. The current clipboard contents are shown below."));
            },
            .osc_52_read => {
                self.as(Dialog.Parent).setHeading(i18n._("Authorize Clipboard Access"));
                self.as(Dialog.Parent).setBody(i18n._("An application is attempting to read from the clipboard. The current clipboard contents are shown below."));
            },
            .paste => {
                self.setPasteConfirmationLabels(priv.confirm_reason);
            },
        }
    }

    fn propConfirmReason(
        self: *Self,
        _: *gobject.ParamSpec,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const priv = self.private();
        const req = priv.request orelse return;
        if (req.* != .paste) return;
        self.setPasteConfirmationLabels(priv.confirm_reason);
    }

    fn revealButtonClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.text_view_scroll.as(gtk.Widget).setSensitive(@intFromBool(true));
        priv.text_view.as(gtk.Widget).removeCssClass("blurred");
        priv.hide_button.as(gtk.Widget).setVisible(@intFromBool(true));
        priv.reveal_button.as(gtk.Widget).setVisible(@intFromBool(false));
    }

    fn hideButtonClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.text_view_scroll.as(gtk.Widget).setSensitive(@intFromBool(false));
        priv.text_view.as(gtk.Widget).addCssClass("blurred");
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
            class.bindTemplateChildPrivate("text_view_scroll", .{});
            class.bindTemplateChildPrivate("text_view", .{});
            class.bindTemplateChildPrivate("hide_button", .{});
            class.bindTemplateChildPrivate("reveal_button", .{});
            if (comptime can_remember) {
                class.bindTemplateChildPrivate("remember_choice", .{});
            }

            // Template Callbacks
            class.bindTemplateCallback("reveal_clicked", &revealButtonClicked);
            class.bindTemplateCallback("hide_clicked", &hideButtonClicked);
            class.bindTemplateCallback("notify_blur", &propBlur);
            class.bindTemplateCallback("notify_request", &propRequest);
            class.bindTemplateCallback("notify_confirm_reason", &propConfirmReason);

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.blur.impl,
                properties.@"can-remember".impl,
                properties.@"clipboard-contents".impl,
                properties.request.impl,
                properties.@"confirm-reason".impl,
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
