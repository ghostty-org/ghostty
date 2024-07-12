{
  mkShell,
  lib,
  stdenv,
  bashInteractive,
  gdb,
  #, glxinfo # unused
  ncurses,
  nodejs,
  nodePackages,
  oniguruma,
  parallel,
  pkg-config,
  python3,
  qemu,
  scdoc,
  tracy,
  valgrind,
  #, vulkan-loader # unused
  vttest,
  wabt,
  wasmtime,
  wraptest,
  zig_0_13,
  zip,
  zls,
  llvmPackages_latest,
  bzip2,
  expat,
  fontconfig,
  freetype,
  glib,
  gtk4,
  libadwaita,
  gnome,
  hicolor-icon-theme,
  harfbuzz,
  libpng,
  libGL,
  libX11,
  libXcursor,
  libXext,
  libXi,
  libXinerama,
  libXrandr,
  pixman,
  zlib,
  alejandra,
  pandoc,
  hyperfine,
}: let
  # See package.nix. Keep in sync.
  rpathLibs =
    [
      libGL
    ]
    ++ lib.optionals stdenv.isLinux [
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
in
  mkShell {
    name = "ghostty";

    packages =
      [
        # For builds
        llvmPackages_latest.llvm
        ncurses
        pandoc
        pkg-config
        scdoc
        zig_0_13
        zip

        # For web and wasm stuff
        nodejs

        # Linting
        nodePackages.prettier
        alejandra

        # Testing
        parallel
        python3
        vttest
        hyperfine

        # wasm
        wabt
        wasmtime
      ]
      ++ lib.optionals (!(stdenv.isLinux && stdenv.isAarch64)) [
        # This is currently broken on aarch64 linux. Once this is
        # fixed we can remove this conditional.
        zls
      ]
      ++ lib.optionals stdenv.isLinux [
        # My nix shell environment installs the non-interactive version
        # by default so we have to include this.
        bashInteractive

        # Used for testing SIMD codegen. This is Linux only because the macOS
        # build only has the qemu-system files.
        qemu

        gdb
        valgrind
        wraptest

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

    # On Linux we need to setup the environment so that all GTK data
    # is available (namely icons).
    shellHook = lib.optionalString stdenv.isLinux ''
      # Minimal subset of env set by wrapGAppsHook4 for icons and global settings
      export XDG_DATA_DIRS=$XDG_DATA_DIRS:${hicolor-icon-theme}/share:${gnome.adwaita-icon-theme}/share
      export XDG_DATA_DIRS=$XDG_DATA_DIRS:$GSETTINGS_SCHEMAS_PATH # from glib setup hook
    '';
  }
