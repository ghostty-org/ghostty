{
  pkgs,
  lib,
  stdenv,
  enableX11 ? true,
  enableWayland ? true,
}:
lib.makeLibraryPath (import ./build-inputs.nix {
  inherit pkgs lib stdenv enableX11 enableWayland;
})
