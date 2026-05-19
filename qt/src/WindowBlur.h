#pragma once

class QWidget;

// Enable or disable KWin's "blur behind" effect for `window`, honoring
// the `background-blur` config. Works on KDE/KWin via the native
// compositor protocols — `org_kde_kwin_blur` on Wayland and the
// `_KDE_NET_WM_BLUR_BEHIND_REGION` property on X11 — and is a harmless
// no-op on compositors that do not advertise blur support.
//
// The whole window is blurred; only the terminal's translucent pixels
// actually show the effect, so no per-region calculation is needed.
void applyWindowBlur(QWidget *window, bool enabled);
