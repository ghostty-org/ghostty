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
  scdoc,
  tracy,
  valgrind,
  #, vulkan-loader # unused
  vttest,
  wabt,
  wasmtime,
  wraptest,
  zig,
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

    nativeBuildInputs =
      [
        # For builds
        llvmPackages_latest.llvm
        ncurses
        pandoc
        pkg-config
        scdoc
        zig
        zip
        zls

        # For web and wasm stuff
        nodejs

        # Linting
        nodePackages.prettier
        alejandra

        # Testing
        parallel
        python3
        tracy
        vttest

        # wasm
        wabt
        wasmtime
      ]
      ++ lib.optionals stdenv.isLinux [
        # My nix shell environment installs the non-interactive version
        # by default so we have to include this.
        bashInteractive

        gdb
        valgrind
        wraptest
      ];

    buildInputs =
      [
        # TODO: non-linux
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
