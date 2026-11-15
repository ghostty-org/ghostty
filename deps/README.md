# Generated dependency files

This directory holds lists of Ghostty's Zig dependencies in forms that
tools other than Zig can read. Zig itself reads only `build.zig.zon`.

Every file here except this README is generated from `build.zig.zon` (and
the `build.zig.zon` files under `pkg/`). Do not edit them by hand. To
regenerate them after changing a dependency, run this from the repository
root:

```sh
./nix/build-support/check-zig-cache.sh --update
```

Run it without `--update` to check that the files are current. CI runs that
check and fails if any file is out of date.

## Files

- `packages.nix`: every dependency as a Nix derivation. Read by `flake.nix`,
  `nix/package.nix` and `nix/libghostty-vt.nix`.
- `packages.txt`: every dependency's URL, one per line. The default list for
  `nix/build-support/fetch-zig-cache.sh`, which downloads the packages so
  Ghostty can build offline.
- `packages.json`: every dependency's URL and Zig package hash. Read by
  `fetch-zig-cache.sh`, `nix/build-support/update-mirror.nu` and
  `nix/build-support/gen-lib-vt-deps.sh`.
- `libghostty-vt.txt`: the URLs of only the packages a libghostty-vt build
  needs. Packagers of the library pass it to `fetch-zig-cache.sh`, and the
  `test-lib-vt-offline` CI job builds the library from it.
- `libghostty-vt-third-party.json`: every third-party project in a
  libghostty-vt build, with its version, upstream URL, license, and whether
  its code ends up inside the library. Distributions use it for their package
  metadata. `nix/build-support/gen-lib-vt-deps.sh` documents the format.

`flatpak/zig-packages.json` belongs to the same generated set. It stays next
to the Flatpak manifests because they reference it by a relative path.
