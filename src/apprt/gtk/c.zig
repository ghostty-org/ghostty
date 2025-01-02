const build_options = @import("build_options");

/// Imported C API directly from header files
pub const c = @cImport({
    @cInclude("gtk/gtk.h");
    if (build_options.adwaita) {
        @cInclude("libadwaita-1/adwaita.h");
    }

    if (build_options.x11) {
        // Add in X11-specific GDK backend which we use for specific things
        // (e.g. X11 window class).
        @cInclude("gdk/x11/gdkx.h");
        // Xkb for X11 state handling
        @cInclude("X11/XKBlib.h");
    }
    if (build_options.wayland) {
        @cInclude("gdk/wayland/gdkwayland.h");
    }

    // generated header files
    @cInclude("ghostty_resources.h");

    // compatibility
    @cInclude("ghostty_gtk_compat.h");
});
