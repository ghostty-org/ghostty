#pragma once

class QWidget;

// Enable or disable KWin's "blur behind" effect for `window`, honoring
// the `background-blur` config. Works on KDE/KWin via the
// `org_kde_kwin_blur` Wayland protocol; a harmless no-op on
// compositors that do not advertise blur support.
//
// The whole window is blurred; only the terminal's translucent pixels
// actually show the effect, so no per-region calculation is needed.
void applyWindowBlur(QWidget *window, bool enabled);
