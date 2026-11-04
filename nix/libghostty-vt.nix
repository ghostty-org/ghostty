{
  callPackage,
  cmake,
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
  zig_0_17,
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
        ../deps/packages.nix
        ../dist/cmake/ghostty-vt-config.cmake.in
      ]
    );
  };

  deps = callPackage ../deps/packages.nix {};

  nativeBuildInputs =
    [
      git
      pkg-config
      zig_0_17
    ]
    ++ lib.optionals stdenv.hostPlatform.isDarwin [
      darwin.cctools
      fixDarwinDylibNames
      xcbuild
    ];

  buildInputs = [];

  doCheck = false;
  dontSetZigDefaultFlags = true;

  zigBuildFlags = [
    "--system"
    "${finalAttrs.deps}"
    "-Dlib-version-string=${finalAttrs.version}"
    "-Dcpu=baseline"
    "-Doptimize=${optimize}"
    "-Dapp-runtime=none"
    "-Demit-lib-vt=true"
    "-Dsimd=${lib.boolToString simd}"
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
    substituteInPlace "$dev/lib/pkgconfig/libghostty-vt-static.pc" \
      --replace-fail "$out" "$dev"

    # The CMake config is moved to $dev along with the headers and the
    # static library, so its relative paths find those in $dev. The shared
    # library stays in $out, so point the config at it directly.
    substituteInPlace "$dev/lib/cmake/ghostty-vt/ghostty-vt-config.cmake" \
      --replace-fail 'set(_ghostty_vt_shared_libdir "''${_ghostty_vt_libdir}")' \
      'set(_ghostty_vt_shared_libdir "'"$out/lib"'")'
  '';

  passthru.tests = let
    sharedExt = stdenv.hostPlatform.extensions.sharedLibrary;
    sharedLibName = version:
      if stdenv.hostPlatform.isDarwin
      then "libghostty-vt.${version}${sharedExt}"
      else "libghostty-vt${sharedExt}.${version}";

    # The version metadata policy is documented on SharedVersion in
    # src/build/GhosttyLibVt.zig. These follow it.
    #
    # libVersion drops any pre-release or build suffix, for example "0.1.0"
    # for "0.1.0-dev+abc-nix".
    libVersion = "${lib.versions.major finalAttrs.version}.${lib.versions.minor finalAttrs.version}.${lib.versions.patch finalAttrs.version}";
    libMajor = lib.versions.major finalAttrs.version;

    # The oldest release with the same ABI. Every 0.x minor release may break
    # the ABI, so before 1.0 this is 0.<minor>.0, and <major>.0.0 after.
    libCompatVersion =
      if libMajor == "0"
      then "0.${lib.versions.minor finalAttrs.version}.0"
      else "${libMajor}.0.0";

    # The library name a program records when it links against the shared
    # library. On Linux this is the SONAME, which only has the major version
    # (libghostty-vt.so.0). On Darwin the fixup phase replaces the @rpath
    # install name with the absolute path of the real file, so the full
    # version appears there (/libghostty-vt.0.1.0.dylib).
    runtimeName =
      if stdenv.hostPlatform.isDarwin
      then "/${sharedLibName libVersion}"
      else "libghostty-vt${sharedExt}.${libMajor}";
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
        export PKG_CONFIG_PATH="${finalAttrs.finalPackage.dev}/lib/pkgconfig"

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
        ${linkCheck "$out/bin/test" "-F '${runtimeName} '"}
        ${lib.optionalString stdenv.hostPlatform.isDarwin ''
          otool -L "$out/bin/test" | grep -qF "(compatibility version ${libCompatVersion}, current version ${libVersion})"
        ''}

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
    build-with-cmake = stdenv.mkDerivation {
      name = "build-with-cmake";
      src = ./test-src;
      doInstallCheck = true;
      dontUseCmakeConfigure = true;
      nativeBuildInputs = [cmake];
      buildInputs = [finalAttrs.finalPackage llvmPackages.libcxxClang];
      buildPhase = ''
        runHook preBuildHooks

        cat > CMakeLists.txt <<'EOF'
        cmake_minimum_required(VERSION 3.19)
        project(test LANGUAGES C)
        find_package(ghostty-vt ${lib.versions.majorMinor finalAttrs.version} CONFIG REQUIRED)
        add_executable(test_shared test_libghostty_vt.c)
        target_link_libraries(test_shared PRIVATE ghostty-vt::ghostty-vt)
        add_executable(test_static test_libghostty_vt.c)
        target_link_libraries(test_static PRIVATE ghostty-vt::ghostty-vt-static)
        EOF
        cmake -B build -S .
        cmake --build build

        runHook postBuildHooks
      '';
      installPhase = ''
        runHook preInstallHooks

        mkdir -p "$out/bin";
        cp -a build/test_shared build/test_static "$out/bin/";

        runHook postInstallHooks
      '';
      installCheckPhase = ''
        runHook preInstallCheckHooks

        for bin in test_shared test_static; do
          "$out/bin/$bin" | grep -q "SIMD: ${
          if simd
          then "yes"
          else "no"
        }"
        done
        ${linkCheck "$out/bin/test_shared" "libghostty-vt"}
        ! ${linkCheck "$out/bin/test_static" "libghostty-vt"}

        runHook postInstallCheckHooks
      '';
      meta = {
        mainProgram = "test_shared";
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
    platforms = zig_0_17.meta.platforms;
    pkgConfigModules = [
      "libghostty-vt"
      "libghostty-vt-static"
    ];
  };
})
