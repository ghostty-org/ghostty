{
  pkgs,
  lib,
  stdenv,
  enableX11 ? true,
  enableWayland ? true,
  # Also include everything the inputs propagate. pkg-config links against
  # propagated libraries too (gtk4 propagates pango, cairo, gdk-pixbuf and
  # more), and a binary linked by Zig's self-hosted backend needs every
  # one of them directly. Propagation lists dev outputs, which hold the
  # pkg-config files, so this picks each package's library output.
  propagated ? false,
}: let
  inputs = import ./build-inputs.nix {
    inherit pkgs lib stdenv enableX11 enableWayland;
  };
  closure = map (p: p.lib or p.out or p) (lib.closePropagation inputs);
in
  lib.makeLibraryPath (
    if propagated
    then lib.unique closure
    else inputs
  )
