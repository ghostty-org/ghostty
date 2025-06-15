{
  mkShell,
  lib,
  stdenv,
  bashInteractive,
  appstream,
  flatpak-builder,
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
  # snapcraft,
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
  gtk4-layer-shell,
  gobject-introspection,
  gst_all_1,
  libadwaita,
  blueprint-compiler,
  gettext,
  adwaita-icon-theme,
  hicolor-icon-theme,
  harfbuzz,
  libpng,
  libxkbcommon,
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
  uv,
  wayland,
  wayland-scanner,
  wayland-protocols,
  zon2nix,
  system,
  pkgs,
}: let
  # See package.nix. Keep in sync.
  ld_library_path = import ./build-support/ld-library-path.nix {
    inherit pkgs lib stdenv;
  };
  gi_typelib_path = import ./build-support/gi-typelib-path.nix {
    inherit pkgs lib stdenv;
  };
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
        zon2nix.packages.${system}.zon2nix

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

        # Localization
        gettext

        # CI
        uv

        # We need these GTK-related deps on all platform so we can build
        # dist tarballs.
        blueprint-compiler
        libadwaita
        gtk4
      ]
      ++ lib.optionals stdenv.hostPlatform.isLinux [
        # My nix shell environment installs the non-interactive version
        # by default so we have to include this.
        bashInteractive

        # Used for testing SIMD codegen. This is Linux only because the macOS
        # build only has the qemu-system files.
        qemu

        appstream
        flatpak-builder
        gdb
        # snapcraft
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

        libxkbcommon
        libX11
        libXcursor
        libXext
        libXi
        libXinerama
        libXrandr

        # Only needed for GTK builds
        gtk4-layer-shell
        glib
        gobject-introspection
        wayland
        wayland-scanner
        wayland-protocols
        gst_all_1.gstreamer
        gst_all_1.gst-plugins-base
        gst_all_1.gst-plugins-good
      ];

    # This should be set onto the rpath of the ghostty binary if you want
    # it to be "portable" across the system.
    LD_LIBRARY_PATH = ld_library_path;
    GI_TYPELIB_PATH = gi_typelib_path;

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

        # We need to remove "xcrun" from the PATH. It is injected by
        # some dependency but we need to rely on system Xcode tools
        export PATH=$(echo "$PATH" | awk -v RS=: -v ORS=: '$0 !~ /xcrun/ || $0 == "/usr/bin" {print}' | sed 's/:$//')
      '');
  }
