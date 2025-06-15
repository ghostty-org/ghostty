{
  lib,
  stdenv,
  callPackage,
  gobject-introspection,
  blueprint-compiler,
  libxml2,
  gettext,
  wrapGAppsHook4,
  git,
  ncurses,
  pkg-config,
  zig_0_14,
  pandoc,
  revision ? "dirty",
  optimize ? "Debug",
  enableX11 ? true,
  enableWayland ? true,
  wayland-protocols,
  wayland-scanner,
  pkgs,
}: let
  # The Zig hook has no way to select the release type without actual
  # overriding of the default flags.
  #
  # TODO: Once
  # https://github.com/ziglang/zig/issues/14281#issuecomment-1624220653 is
  # ultimately acted on and has made its way to a nixpkgs implementation, this
  # can probably be removed in favor of that.
  zig_hook = zig_0_14.hook.overrideAttrs {
    zig_default_flags = "-Dcpu=baseline -Doptimize=${optimize} --color off";
  };
  gi_typelib_path = import ./build-support/gi-typelib-path.nix {
    inherit pkgs lib stdenv;
  };
  buildInputs = import ./build-support/build-inputs.nix {
    inherit pkgs lib stdenv enableX11 enableWayland;
  };
  strip = optimize != "Debug" && optimize != "ReleaseSafe";
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "ghostty";
    version = "1.1.4";

    # We limit source like this to try and reduce the amount of rebuilds as possible
    # thus we only provide the source that is needed for the build
    #
    # NOTE: as of the current moment only linux files are provided,
    # since darwin support is not finished
    src = lib.fileset.toSource {
      root = ../.;
      fileset = lib.fileset.intersection (lib.fileset.fromSource (lib.sources.cleanSource ../.)) (
        lib.fileset.unions [
          ../dist/linux
          ../images
          ../include
          ../po
          ../pkg
          ../src
          ../vendor
          ../build.zig
          ../build.zig.zon
          ../build.zig.zon.nix
        ]
      );
    };

    deps = callPackage ../build.zig.zon.nix {name = "ghostty-cache-${finalAttrs.version}";};

    nativeBuildInputs =
      [
        git
        ncurses
        pandoc
        pkg-config
        zig_hook
        gobject-introspection
        wrapGAppsHook4
        blueprint-compiler
        libxml2 # for xmllint
        gettext
      ]
      ++ lib.optionals enableWayland [
        wayland-scanner
        wayland-protocols
      ];

    buildInputs = buildInputs;

    dontConfigure = true;
    dontStrip = !strip;

    GI_TYPELIB_PATH = gi_typelib_path;

    zigBuildFlags = [
      "--system"
      "${finalAttrs.deps}"
      "-Dversion-string=${finalAttrs.version}-${revision}-nix"
      "-Dgtk-x11=${lib.boolToString enableX11}"
      "-Dgtk-wayland=${lib.boolToString enableWayland}"
      "-Dstrip=${lib.boolToString strip}"
    ];

    outputs = [
      "out"
      "terminfo"
      "shell_integration"
      "vim"
    ];

    postInstall = ''
      terminfo_src=${
        if stdenv.hostPlatform.isDarwin
        then ''"$out/Applications/Ghostty.app/Contents/Resources/terminfo"''
        else "$out/share/terminfo"
      }

      mkdir -p "$out/nix-support"

      mkdir -p "$terminfo/share"
      mv "$terminfo_src" "$terminfo/share/terminfo"
      ln -sf "$terminfo/share/terminfo" "$terminfo_src"
      echo "$terminfo" >> "$out/nix-support/propagated-user-env-packages"

      mkdir -p "$shell_integration"
      mv "$out/share/ghostty/shell-integration" "$shell_integration/shell-integration"
      ln -sf "$shell_integration/shell-integration" "$out/share/ghostty/shell-integration"
      echo "$shell_integration" >> "$out/nix-support/propagated-user-env-packages"

      mv $out/share/vim/vimfiles "$vim"
      ln -sf "$vim" "$out/share/vim/vimfiles"
      echo "$vim" >> "$out/nix-support/propagated-user-env-packages"

      echo "gst_all_1.gstreamer" >> "$out/nix-support/propagated-user-env-packages"
      echo "gst_all_1.gst-plugins-base" >> "$out/nix-support/propagated-user-env-packages"
      echo "gst_all_1.gst-plugins-good" >> "$out/nix-support/propagated-user-env-packages"
    '';

    meta = {
      homepage = "https://ghostty.org";
      license = lib.licenses.mit;
      platforms = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      mainProgram = "ghostty";
    };
  })
