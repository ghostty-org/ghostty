{
  lib,
  stdenv,
  bzip2,
  expat,
  fontconfig,
  freetype,
  harfbuzz,
  libpng,
  pixman,
  zlib,
  libGL,
  libX11,
  libXcursor,
  libXi,
  libXrandr,
  glib,
  gtk4,
  libadwaita,
  wrapGAppsHook4,
  gsettings-desktop-schemas,
  git,
  ncurses,
  pkg-config,
  zig_0_12,
  pandoc,
  revision ? "dirty",
}: let
  # The Zig hook has no way to select the release type without actual
  # overriding of the default flags.
  #
  # TODO: Once
  # https://github.com/ziglang/zig/issues/14281#issuecomment-1624220653 is
  # ultimately acted on and has made its way to a nixpkgs implementation, this
  # can probably be removed in favor of that.
  zig012Hook = zig_0_12.hook.overrideAttrs {
    zig_default_flags = "-Dcpu=baseline -Doptimize=ReleaseFast";
  };

  # This hash is the computation of the zigCache fixed-output derivation. This
  # allows us to use remote package dependencies without breaking the sandbox.
  #
  # This will need updating whenever dependencies get updated (e.g. changes are
  # made to zig.build.zon). If you see that the main build is trying to reach
  # out to the internet and failing, this is likely the cause. Change this
  # value back to lib.fakeHash, and re-run. The build failure should emit the
  # updated hash, which of course, should be validated before updating here.
  #
  # (It's also possible that you might see a hash mismatch - without the
  # network errors - if you don't have a previous instance of the cache
  # derivation in your store already. If so, just update the value as above.)
  zigCacheHash = import ./zigCacheHash.nix;

  zigCache = src:
    stdenv.mkDerivation {
      inherit src;
      name = "ghostty-cache";
      nativeBuildInputs = [git zig_0_12.hook];

      dontConfigure = true;
      dontUseZigBuild = true;
      dontUseZigInstall = true;
      dontFixup = true;

      buildPhase = ''
        runHook preBuild

        zig build --fetch

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall

        cp -r --reflink=auto $ZIG_GLOBAL_CACHE_DIR $out

        runHook postInstall
      '';

      outputHashMode = "recursive";
      outputHash = zigCacheHash;
    };
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "ghostty";
    version = "0.1.0";

    src = ./..;

    nativeBuildInputs = [
      git
      ncurses
      pandoc
      pkg-config
      zig012Hook
      wrapGAppsHook4
    ];

    buildInputs =
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
        pixman
        zlib

        libX11
        libXcursor
        libXi
        libXrandr

        libadwaita
        gtk4
        glib
        gsettings-desktop-schemas
      ];

    dontConfigure = true;

    zigBuildFlags = "-Dversion-string=${finalAttrs.version}-${revision}-nix";

    preBuild = ''
      rm -rf $ZIG_GLOBAL_CACHE_DIR
      cp -r --reflink=auto ${zigCache finalAttrs.src} $ZIG_GLOBAL_CACHE_DIR
      chmod u+rwX -R $ZIG_GLOBAL_CACHE_DIR
    '';

    buildPhase = ''
      runHook preBuild
      zig build -Dcpu=baseline -Doptimize=ReleaseSafe -Dversion-string=${finalAttrs.version}-${revision}-nix
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      zig build install -Dcpu=baseline -Doptimize=ReleaseSafe -Dversion-string=${finalAttrs.version}-${revision}-nix --prefix $out
      runHook postInstall
    '';

    outputs = ["out" "terminfo" "shell_integration"];

    postInstall = ''
      terminfo_src=${
        if stdenv.isDarwin
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
    '';

    postFixup = ''
      patchelf --add-rpath "${lib.makeLibraryPath [libX11]}" "$out/bin/.ghostty-wrapped"
    '';

    meta = with lib; {
      homepage = "https://github.com/mitchellh/ghostty";
      license = licenses.mit;
      platforms = ["x86_64-linux" "aarch64-linux"];
      mainProgram = "ghostty";
    };
  })
