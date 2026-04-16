{
  lib,
  stdenv,
  callPackage,
  git,
  pkg-config,
  zig_0_15,
  revision ? "dirty",
  optimize ? "Debug",
  simd ? true,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "ghostty";
  version = "0.1.0-dev";

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

  nativeBuildInputs = [
    git
    pkg-config
    zig_0_15
  ];

  buildInputs = [];

  dontSetZigDefaultFlags = true;

  zigBuildFlags = [
    "--system"
    "${finalAttrs.deps}"
    "-Dversion-string=${finalAttrs.version}-${revision}-nix"
    "-Dcpu=baseline"
    "-Doptimize=${optimize}"
    "-Dapp-runtime=none"
    "-Demit-lib-vt=true"
    "-Dsimd=${lib.boolToString simd}"
  ];

  outputs = [
    "out"
    "dev"
  ];

  postInstall = ''
    mkdir -p "$dev/lib"
    mv "$out/lib/libghostty-vt.a" "$dev/lib"
    rm "$out/lib/libghostty-vt.so"
    mv "$out/include" "$dev"
    mv "$out/share" "$dev"

    ln -sf "$out/lib/libghostty-vt.so.0"  "$dev/lib/libghostty-vt.so"
  '';

  postFixup = ''
    substituteInPlace "$dev/share/pkgconfig/libghostty-vt.pc" \
      --replace "$out" "$dev"
  '';

  meta = {
    homepage = "https://github.com/amanthanvi/winghostty";
    license = lib.licenses.mit;
    platforms = zig_0_15.meta.platforms;
  };
})
