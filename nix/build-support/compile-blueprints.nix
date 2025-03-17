{pkgs}: let
  # this needs to be kept in sync with deps from devShell.nix and package.nix
  gi_typelib_path = pkgs.lib.makeSearchPath "lib/girepository-1.0" (map (pkg: pkgs.lib.getOutput "lib" pkg) [
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
  ]);
  program = pkgs.writeShellScript "compile-blueprints" ''
    set -e
    ${pkgs.findutils}/bin/find . -name \*.blp -print0 | ${pkgs.findutils}/bin/xargs --null --replace=BLP -- ${pkgs.lib.getExe pkgs.blueprint-compiler} format --fix BLP
    ${pkgs.findutils}/bin/find . -name \*.blp -print0 | ${pkgs.findutils}/bin/xargs --null --replace=BLP -- sh -c "export B=BLP; ${pkgs.lib.getExe pkgs.blueprint-compiler} compile --typelib-path=${gi_typelib_path} --output \''${B%.*}.ui \$B"
  '';
in {
  type = "app";
  program = "${program}";
}
