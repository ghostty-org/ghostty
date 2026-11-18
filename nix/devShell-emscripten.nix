{
  mkShellNoCC,
  zig,
  emscripten,
  nodejs,
  bash,
  coreutils,
  git,
  pkg-config,
}:
  mkShellNoCC {
    name = "ghostty-emscripten";
    packages = [
      zig
      emscripten
      nodejs
      bash
      coreutils
      git
      pkg-config
    ];
  }
