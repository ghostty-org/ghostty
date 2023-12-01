const c = @cImport({
    @cInclude("gtk/gtk.h");
    if (@import("build_options").libadwaita) @cInclude("libadwaita-1/adwaita.h");

    // Add in X11-specific GDK backend which we use for specific things (e.g.
    // X11 window class).
    @cInclude("gdk/x11/gdkx.h");
});

pub usingnamespace c;

/// Compatibility with gobject < 2.74
pub usingnamespace if (@hasDecl(c, "G_CONNECT_DEFAULT")) struct {} else struct {
    pub const G_CONNECT_DEFAULT = 0;
    pub const G_APPLICATION_DEFAULT_FLAGS = c.G_APPLICATION_FLAGS_NONE;
};
