{
  pkgs,
  lib,
  stdenv,
}:
lib.makeSearchPath "lib/girepository-1.0" (map (lib.getOutput "lib") (lib.optionals stdenv.hostPlatform.isLinux [
  pkgs.cairo
  pkgs.gdk-pixbuf
  pkgs.glib
  pkgs.gobject-introspection
  pkgs.graphene
  pkgs.gtk4
  pkgs.gtk4-layer-shell
  pkgs.harfbuzz
  pkgs.libadwaita
  pkgs.pango
]))
