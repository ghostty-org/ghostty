//! Represents the URL hover widgets that show the hovered URL.
//!
//! To explain a bit how this all works since its split across a few places:
//! We create a left/right pair of labels. The left label is shown by default,
//! and the right label is hidden. When the mouse enters the left label, we
//! show the right label. When the mouse leaves the left label, we hide the
//! right label.
//!
//! The hover and styling is done with a combination of GTK event controllers
//! and CSS in style.css.
const URLWidget = @This();

const gtk = @import("gtk");

/// The label that appears on the bottom left.
left: *gtk.Label,

/// The label that appears on the bottom right.
right: *gtk.Label,

pub fn init(
    /// The overlay that we will attach our labels to.
    overlay: *gtk.Overlay,
    /// The URL to display.
    str: [:0]const u8,
) URLWidget {
    // Create the left
    const left = left: {
        const left = gtk.Label.new(str.ptr);
        left.setEllipsize(.middle);
        const widget = left.as(gtk.Widget);
        widget.addCssClass("view");
        widget.addCssClass("url-overlay");
        widget.addCssClass("left");
        widget.setHalign(.start);
        widget.setValign(.end);
        break :left left;
    };

    // Create the right
    const right = right: {
        const right = gtk.Label.new(str.ptr);
        right.setEllipsize(.middle);
        const widget = right.as(gtk.Widget);
        widget.addCssClass("hidden");
        widget.addCssClass("view");
        widget.addCssClass("url-overlay");
        widget.addCssClass("right");
        widget.setHalign(.end);
        widget.setValign(.end);
        break :right right;
    };

    // Setup our mouse hover event controller for the left label.
    const ec_motion = gtk.EventControllerMotion.new();
    errdefer ec_motion.unref();

    left.as(gtk.Widget).addController(ec_motion.as(gtk.EventController));

    _ = gtk.EventControllerMotion.signals.enter.connect(
        ec_motion,
        *gtk.Label,
        gtkLeftEnter,
        right,
        .{},
    );
    _ = gtk.EventControllerMotion.signals.leave.connect(
        ec_motion,
        *gtk.Label,
        gtkLeftLeave,
        right,
        .{},
    );

    // Show it
    overlay.addOverlay(left.as(gtk.Widget));
    overlay.addOverlay(right.as(gtk.Widget));

    return .{
        .left = left,
        .right = right,
    };
}

/// Remove our labels from the overlay.
pub fn deinit(self: *URLWidget, overlay: *gtk.Overlay) void {
    overlay.removeOverlay(self.left.as(gtk.Widget));
    overlay.removeOverlay(self.right.as(gtk.Widget));
}

/// Change the URL that is displayed.
pub fn setText(self: *const URLWidget, str: [:0]const u8) void {
    self.left.setText(str.ptr);
    self.right.setText(str.ptr);
}

/// Callback for when the mouse enters the left label. That means that we should
/// show the right label. CSS will handle hiding the left label.
fn gtkLeftEnter(
    _: *gtk.EventControllerMotion,
    _: f64,
    _: f64,
    right: *gtk.Label,
) callconv(.c) void {
    right.as(gtk.Widget).removeCssClass("hidden");
}

/// Callback for when the mouse leaves the left label. That means that we should
/// hide the right label. CSS will handle showing the left label.
fn gtkLeftLeave(
    _: *gtk.EventControllerMotion,
    right: *gtk.Label,
) callconv(.c) void {
    right.as(gtk.Widget).addCssClass("hidden");
}
