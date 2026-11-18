{
  mkShellNoCC,
  zig,
  emscripten,
  binaryen,
  fetchFromGitHub,
  nodejs,
  bash,
  coreutils,
  git,
  pkg-config,
}: let
  # Emscripten 6.0.9 expects Binaryen 132. Keep the matching dependency local
  # to this shell until nixpkgs supplies compatible versions together.
  binaryen132 = binaryen.overrideAttrs (_: rec {
    version = "132";
    src = fetchFromGitHub {
      owner = "WebAssembly";
      repo = "binaryen";
      rev = "version_${version}";
      hash = "sha256-di/M4QidDwa1doomy79yfN7chCng9VcDB2KgmaEunDc=";
    };
  });
in
  mkShellNoCC {
    name = "ghostty-emscripten";
    packages = [
      zig
      (emscripten.override {binaryen = binaryen132;})
      nodejs
      bash
      coreutils
      git
      pkg-config
    ];
  }
