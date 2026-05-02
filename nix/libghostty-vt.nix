{
  callPackage,
  git,
  lib,
  llvmPackages,
  pkg-config,
  runCommand,
  stdenv,
  testers,
  fixDarwinDylibNames,
  versionCheckHook,
  darwin,
  xcbuild,
  zig_0_15,
  revision ? "dirty",
  optimize ? "Debug",
  simd ? true,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "libghostty-vt";
  version = "0.1.0-dev+${revision}-nix";

  # We limit source like this to try and reduce the amount of rebuilds as possible
  # thus we only provide the source that is needed for the build.
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.intersection (lib.fileset.fromSource (lib.sources.cleanSource ../.)) (
      lib.fileset.unions [
        ../include
        ../pkg
        ../src
        ../vendor
        ../build.zig
        ../build.zig.zon
        ../build.zig.zon.nix
      ]
    );
  };

  # Zig's build runner computes relative paths from `cwd` to the build directory.
  # The logic is purely lexical, so if the `cwd` is a symlink that resolves to a different depth during `chdir`, the computed path becomes incorrect.
  #
  # See: https://codeberg.org/ziglang/zig/issues/32121
  #
  # Workaround: override `linkFarm` with a copy-farm so deps are real directories, not symlinks.
  deps = callPackage ../build.zig.zon.nix {
    name = "${finalAttrs.pname}-cache-${finalAttrs.version}";
    linkFarm = name: entries:
      runCommand name {} ''
        mkdir -p $out
        ${lib.concatMapStringsSep "\n" (e: ''
            cp -rL ${e.path} $out/${e.name}
          '')
          entries}
      '';
  };

  nativeBuildInputs =
    [
      git
      pkg-config
      zig_0_15
    ]
    ++ lib.optionals stdenv.hostPlatform.isDarwin [
      darwin.cctools
      fixDarwinDylibNames
      xcbuild
    ];

  buildInputs = [];

  doCheck = false;
  dontSetZigDefaultFlags = true;

  zigBuildFlags =
    [
      "--system"
      "${finalAttrs.deps}"
      "-Dlib-version-string=${finalAttrs.version}"
      "-Dcpu=baseline"
      "-Doptimize=${optimize}"
      "-Dapp-runtime=none"
      "-Demit-lib-vt=true"
      "-Dsimd=${lib.boolToString simd}"
    ]
    ++ lib.optionals stdenv.hostPlatform.isDarwin [
      "-Demit-xcframework=false"
    ];
  zigCheckFlags = finalAttrs.zigBuildFlags ++ ["test-lib-vt"];

  outputs = [
    "out"
    "dev"
  ];

  postInstall = ''
    mkdir -p "$dev/lib"
    mv "$out/lib/libghostty-vt.a" "$dev/lib/"
  '';

  postFixup = ''
    substituteInPlace "$dev/share/pkgconfig/libghostty-vt-static.pc" \
      --replace-fail "$out" "$dev"
  '';

  passthru.tests = let
    sharedExt = stdenv.hostPlatform.extensions.sharedLibrary;
    sharedLibName = version:
      if stdenv.hostPlatform.isDarwin
      then "libghostty-vt.${version}${sharedExt}"
      else "libghostty-vt${sharedExt}.${version}";
    linkCheck = bin: pat:
      if stdenv.hostPlatform.isDarwin
      then ''otool -L "${bin}" | grep -q ${pat}''
      else ''ldd "${bin}" 2>/dev/null | grep -q ${pat}'';
  in {
    sanity-check = let
      version = "${lib.versions.major finalAttrs.version}.${lib.versions.minor finalAttrs.version}.${lib.versions.patch finalAttrs.version}";
    in
      runCommand "sanity-check" {} (builtins.concatStringsSep "\n" [
        ''
          set +o pipefail
          ${lib.getExe' stdenv.cc "nm"} "${finalAttrs.finalPackage}/lib/${sharedLibName version}" | grep -qE 'T _?ghostty_terminal_new'
          ${lib.getExe' stdenv.cc "nm"} "${finalAttrs.finalPackage.dev}/lib/libghostty-vt.a" | grep -qE 'T _?ghostty_terminal_new'
        ''
        (
          lib.optionalString simd
          ''
            ${lib.getExe' stdenv.cc "nm"} "${finalAttrs.finalPackage.dev}/lib/libghostty-vt.a" | grep -q 'T .*simdutf'
            ${lib.getExe' stdenv.cc "nm"} "${finalAttrs.finalPackage.dev}/lib/libghostty-vt.a" | grep -q 'T .*3hwy'
          ''
        )
        ''
          touch "$out"
        ''
      ]);
    pkg-config = testers.hasPkgConfigModules {
      package = finalAttrs.finalPackage.dev;
    };
    pkg-config-libs =
      runCommand "pkg-config-libs" {
        nativeBuildInputs = [pkg-config];
      } ''
        export PKG_CONFIG_PATH="${finalAttrs.finalPackage.dev}/share/pkgconfig"

        pkg-config --libs --static libghostty-vt | grep -q -- '-lghostty-vt'
        pkg-config --libs --static libghostty-vt-static | grep -q -- '${finalAttrs.finalPackage.dev}/lib/libghostty-vt.a'

        touch "$out"
      '';
    build-with-shared = stdenv.mkDerivation {
      name = "build-with-shared";
      src = ./test-src;
      doInstallCheck = true;
      nativeBuildInputs = [pkg-config];
      buildInputs = [finalAttrs.finalPackage];
      buildPhase = ''
        runHook preBuildHooks

        cc -o test test_libghostty_vt.c \
          ''$(pkg-config --cflags --libs libghostty-vt)

        runHook postBuildHooks
      '';
      installPhase = ''
        runHook preInstallHooks

        mkdir -p "$out/bin";
        cp -a test "$out/bin/test";

        runHook postInstallHooks
      '';
      installCheckPhase = ''
        runHook preInstallCheckHooks

        "$out/bin/test" | grep -q "SIMD: ${
          if simd
          then "yes"
          else "no"
        }"
        ${linkCheck "$out/bin/test" "libghostty-vt"}

        runHook postInstallCheckHooks
      '';
      meta = {
        mainProgram = "test";
      };
    };
    build-with-static = stdenv.mkDerivation {
      name = "build-with-static";
      src = ./test-src;
      doInstallCheck = true;
      nativeBuildInputs = [pkg-config];
      buildInputs = [finalAttrs.finalPackage llvmPackages.libcxxClang];
      buildPhase = ''
        runHook preBuildHooks

        cc -o test test_libghostty_vt.c \
          ''$(pkg-config --cflags --libs --static libghostty-vt-static)

        runHook postBuildHooks
      '';
      installPhase = ''
        runHook preInstallHooks

        mkdir -p "$out/bin";
        cp -a test "$out/bin/test";

        runHook postInstallHooks
      '';
      installCheckPhase = ''
        runHook preInstallCheckHooks

        "$out/bin/test" | grep -q "SIMD: ${
          if simd
          then "yes"
          else "no"
        }"
        ! ${linkCheck "$out/bin/test" "libghostty-vt"}

        runHook postInstallCheckHooks
      '';
      meta = {
        mainProgram = "test";
      };
    };
    build-example-c-vt-build-info = stdenv.mkDerivation {
      name = "build-example-c-vt-build-info";
      version = finalAttrs.version;
      src = ../example/c-vt-build-info/src;
      doInstallCheck = true;
      nativeBuildInputs = [pkg-config];
      nativeInstallCheckInputs = [versionCheckHook];
      buildInputs = [finalAttrs.finalPackage];
      buildPhase = ''
        runHook preBuildHooks

        cc -o test main.c \
          ''$(pkg-config --cflags --libs libghostty-vt)

        runHook postBuildHooks
      '';
      installPhase = ''
        runHook preInstallHooks

        mkdir -p "$out/bin";
        cp -a test "$out/bin/test";

        runHook postInstallHooks
      '';
      installCheckPhase = ''
        runHook preInstallCheckHooks

        ${linkCheck "$out/bin/test" "libghostty-vt"}

        runHook postInstallCheckHooks
      '';
      meta = {
        mainProgram = "test";
      };
    };
  };

  meta = {
    homepage = "https://ghostty.org";
    license = lib.licenses.mit;
    platforms = zig_0_15.meta.platforms;
    pkgConfigModules = [
      "libghostty-vt"
      "libghostty-vt-static"
    ];
  };
})
