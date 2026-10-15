{
  mkShellNoCC,
  lib,
  stdenv,
  alejandra,
  pinact,
  prettier,
  shellcheck,
  swiftlint,
  typos,
  zig,
}:
# A minimal shell for the CI lint jobs. The default dev shell pulls in our
# entire toolchain and every system library, which these jobs never use.
mkShellNoCC {
  name = "ghostty-lint";
  packages =
    [
      alejandra
      pinact
      prettier
      shellcheck
      typos
      zig
    ]
    ++ lib.optionals stdenv.hostPlatform.isDarwin [
      swiftlint
    ];
}
