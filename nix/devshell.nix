{ mkShell, lib, stdenv

, debugedit
, flatpak-builder
, gdb
, glxinfo
, ncurses
, nodejs
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
, llvmPackages_latest

, bzip2
, expat
, fontconfig
, freetype
, glib
, gtk4
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
    zlib

    libX11
    libXcursor
    libXi
    libXrandr

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

    # For web and wasm stuff
    nodejs

    # Testing
    parallel
    python3
    tracy
    vttest

    # wasm
    wabt
    wasmtime
  ] ++ lib.optionals stdenv.isLinux [
    # Flatpak builds
    debugedit
    flatpak-builder

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
    pixman
    zlib

    libX11
    libXcursor
    libXext
    libXi
    libXinerama
    libXrandr

    # Only needed for GTK builds
    gtk4
    glib
  ];

  # This should be set onto the rpath of the ghostty binary if you want
  # it to be "portable" across the system.
  LD_LIBRARY_PATH = lib.makeLibraryPath rpathLibs;
}
