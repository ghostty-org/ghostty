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
  snapcraft,
  valgrind,
  #, vulkan-loader # unused
  vttest,
  wabt,
  wasmtime,
  wraptest,
  zig,
  zip,
  llvmPackages_latest,
  bzip2,
  expat,
  fontconfig,
  freetype,
  glib,
  glslang,
  gtk4,
  gobject-introspection,
  libadwaita,
  blueprint-compiler,
  adwaita-icon-theme,
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
  libxml2,
  spirv-cross,
  simdutf,
  zlib,
  alejandra,
  jq,
  minisign,
  pandoc,
  hyperfine,
  typos,
  wayland,
  wayland-scanner,
  wayland-protocols,
  zig2nix,
  system,
}: let
  # See package.nix. Keep in sync.
  rpathLibs =
    [
      libGL
    ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [
      bzip2
      expat
      fontconfig
      freetype
      harfbuzz
      libpng
      libxml2
      oniguruma
      simdutf
      zlib

      glslang
      spirv-cross

      libX11
      libXcursor
      libXi
      libXrandr

      libadwaita
      gtk4
      glib
      gobject-introspection
      wayland
    ];
in
  mkShell {
    name = "ghostty";

    packages =
      [
        # For builds
        jq
        llvmPackages_latest.llvm
        minisign
        ncurses
        pandoc
        pkg-config
        scdoc
        zig
        zip
        zig2nix.packages.${system}.zon2nix

        # For web and wasm stuff
        nodejs

        # Linting
        nodePackages.prettier
        alejandra
        typos

        # Testing
        parallel
        python3
        vttest
        hyperfine

        # wasm
        wabt
        wasmtime
      ]
      ++ lib.optionals stdenv.hostPlatform.isLinux [
        # My nix shell environment installs the non-interactive version
        # by default so we have to include this.
        bashInteractive

        # Used for testing SIMD codegen. This is Linux only because the macOS
        # build only has the qemu-system files.
        qemu

        gdb
        snapcraft
        valgrind
        wraptest

        bzip2
        expat
        fontconfig
        freetype
        harfbuzz
        libpng
        libxml2
        oniguruma
        simdutf
        zlib

        glslang
        spirv-cross

        libX11
        libXcursor
        libXext
        libXi
        libXinerama
        libXrandr

        # Only needed for GTK builds
        blueprint-compiler
        libadwaita
        gtk4
        glib
        gobject-introspection
        wayland
        wayland-scanner
        wayland-protocols
      ];

    # This should be set onto the rpath of the ghostty binary if you want
    # it to be "portable" across the system.
    LD_LIBRARY_PATH = lib.makeLibraryPath rpathLibs;

    shellHook =
      (lib.optionalString stdenv.hostPlatform.isLinux ''
        # On Linux we need to setup the environment so that all GTK data
        # is available (namely icons).

        # Minimal subset of env set by wrapGAppsHook4 for icons and global settings
        export XDG_DATA_DIRS=$XDG_DATA_DIRS:${hicolor-icon-theme}/share:${adwaita-icon-theme}/share
        export XDG_DATA_DIRS=$XDG_DATA_DIRS:$GSETTINGS_SCHEMAS_PATH # from glib setup hook
      '')
      + (lib.optionalString stdenv.hostPlatform.isDarwin ''
        # On macOS, we unset the macOS SDK env vars that Nix sets up because
        # we rely on a system installation. Nix only provides a macOS SDK
        # and we need iOS too.
        unset SDKROOT
        unset DEVELOPER_DIR
      '');
  }
