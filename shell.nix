with import <nixpkgs> {};

pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    pkgconfig
    gtk4.dev
  ];

  hardeningDisable = [ "all" ];
}
