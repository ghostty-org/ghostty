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
  zig_0_17,
  pandoc,
  systemd,
  revision ? "dirty",
  optimize ? "debug",
  enableX11 ? true,
  enableWayland ? true,
  wayland-protocols,
  wayland-scanner,
  pkgs,
}: let
  gi_typelib_path = import ./build-support/gi-typelib-path.nix {
    inherit pkgs lib stdenv;
  };
  buildInputs = import ./build-support/build-inputs.nix {
    inherit pkgs lib stdenv enableX11 enableWayland;
  };
  strip = optimize != "debug" && optimize != "safe";
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "ghostty";
    version = "1.4.1-dev+${revision}-nix";

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

    deps = callPackage ../build.zig.zon.nix {};

    nativeBuildInputs =
      [
        git
        ncurses
        pandoc
        pkg-config
        zig_0_17
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

    dontStrip = !strip;

    GI_TYPELIB_PATH = gi_typelib_path;

    dontSetZigDefaultFlags = true;

    zigBuildFlags = [
      "--system"
      "${finalAttrs.deps}"
      "-Dversion-string=${finalAttrs.version}"
      "-Dgtk-x11=${lib.boolToString enableX11}"
      "-Dgtk-wayland=${lib.boolToString enableWayland}"
      "-Dcpu=baseline"
      "-Doptimize=${optimize}"
      "-Dstrip=${lib.boolToString strip}"
      "-Dinstalled-exe-path=${placeholder "out"}/bin/ghostty"
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

      echo "${pkgs.gst_all_1.gstreamer}" >> "$out/nix-support/propagated-user-env-packages"
      echo "${pkgs.gst_all_1.gst-plugins-base}" >> "$out/nix-support/propagated-user-env-packages"
      echo "${pkgs.gst_all_1.gst-plugins-good}" >> "$out/nix-support/propagated-user-env-packages"
    '';

    # The systemd, D-Bus and desktop files launch Ghostty by the path given
    # in -Dinstalled-exe-path. systemd only searches its own directory for a
    # bare name on NixOS, so check that every one of them names an
    # executable that exists.
    doInstallCheck = stdenv.hostPlatform.isLinux;

    nativeInstallCheckInputs = [systemd];

    installCheckPhase = ''
      runHook preInstallCheck

      # The verifier starts a user manager, which needs somewhere to keep
      # its runtime state; the sandbox gives it no /run. dbus.socket and
      # graphical-session.target aren't in the sandbox either, so only the
      # unit itself is checked, including its ExecStart.
      export XDG_RUNTIME_DIR="$TMPDIR/run" HOME="$TMPDIR/home"
      mkdir -p -m 0700 "$XDG_RUNTIME_DIR" "$HOME"
      for unit in "$out"/share/systemd/user/*.service; do
        # Its messages are colored and end in a carriage return, which
        # `nix build -L` shows as a blank line, so strip both.
        status=0
        output=$(SYSTEMD_COLORS=0 systemd-analyze --user verify --man=no --recursive-errors=no "$unit" 2>&1) || status=$?
        [[ -z "$output" ]] || echo "''${output//$'\r'/}" >&2
        if ((status != 0)); then
          exit "$status"
        fi
      done

      for file in "$out"/share/dbus-1/services/*.service "$out"/share/applications/com.mitchellh.ghostty*.desktop; do
        while IFS='=' read -r key value; do
          exe=''${value%% *}
          if [[ "$exe" != /* || ! -x "$exe" ]]; then
            echo "$file: $key does not name an executable: $exe" >&2
            exit 1
          fi
        done < <(grep -E '^(TryExec|Exec)=' "$file")
      done

      runHook postInstallCheck
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
