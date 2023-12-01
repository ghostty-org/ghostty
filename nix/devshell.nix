{ mkShell, lib, stdenv

, bashInteractive
, gdb
, glxinfo
, ncurses
, nodejs
, nodePackages
, oniguruma
, parallel
, pkg-config
, python3
, scdoc
, tracy
, valgrind
, vulkan-loader
, vttest
, wabt
, wasmtime
, wraptest
, zig
, zip
, zls
, llvmPackages_latest

, bzip2
, expat
, fontconfig
, freetype
, glib
, gtk4
, libadwaita
, harfbuzz
, libpng
, libGL
, libX11
, libXcursor
, libXext
, libXi
, libXinerama
, libXrandr
, pixman
, zlib
}:
let
  # See package.nix. Keep in sync.
  rpathLibs = [
    libGL
  ] ++ lib.optionals stdenv.isLinux [
    bzip2
    expat
    fontconfig
    freetype
    harfbuzz
    libpng
    oniguruma
    pixman
    zlib

    libX11
    libXcursor
    libXi
    libXrandr

    libadwaita
    gtk4
    glib
  ];
in mkShell rec {
  name = "ghostty";

  nativeBuildInputs = [
    # For builds
    llvmPackages_latest.llvm
    ncurses
    pkg-config
    scdoc
    zig
    zip
    zls

    # For web and wasm stuff
    nodejs

    # Linting
    nodePackages.prettier

    # Testing
    parallel
    python3
    tracy
    vttest

    # wasm
    wabt
    wasmtime
  ] ++ lib.optionals stdenv.isLinux [
    # My nix shell environment installs the non-interactive version
    # by default so we have to include this.
    bashInteractive

    gdb
    valgrind
    wraptest
  ];

  buildInputs = [
    # TODO: non-linux
  ] ++ lib.optionals stdenv.isLinux [
    bzip2
    expat
    fontconfig
    freetype
    harfbuzz
    libpng
    oniguruma
    pixman
    zlib

    libX11
    libXcursor
    libXext
    libXi
    libXinerama
    libXrandr

    # Only needed for GTK builds
    libadwaita
    gtk4
    glib
  ];

  # This should be set onto the rpath of the ghostty binary if you want
  # it to be "portable" across the system.
  LD_LIBRARY_PATH = lib.makeLibraryPath rpathLibs;
}
