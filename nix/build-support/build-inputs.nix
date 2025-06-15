{
  pkgs,
  lib,
  stdenv,
  enableX11 ? true,
  enableWayland ? true,
}:
[
  pkgs.libGL
]
++ lib.optionals stdenv.hostPlatform.isLinux [
  pkgs.bzip2
  pkgs.expat
  pkgs.fontconfig
  pkgs.freetype
  pkgs.harfbuzz
  pkgs.libpng
  pkgs.libxml2
  pkgs.oniguruma
  pkgs.simdutf
  pkgs.zlib

  pkgs.glslang
  pkgs.spirv-cross

  pkgs.libxkbcommon

  pkgs.glib
  pkgs.gobject-introspection
  pkgs.gsettings-desktop-schemas
  pkgs.gst_all_1.gst-plugins-base
  pkgs.gst_all_1.gst-plugins-good
  pkgs.gst_all_1.gstreamer
  pkgs.gtk4
  pkgs.libadwaita
]
++ lib.optionals (stdenv.hostPlatform.isLinux && enableX11) [
  pkgs.xorg.libX11
  pkgs.xorg.libXcursor
  pkgs.xorg.libXi
  pkgs.xorg.libXrandr
]
++ lib.optionals (stdenv.hostPlatform.isLinux && enableWayland) [
  pkgs.gtk4-layer-shell
  pkgs.wayland
]
