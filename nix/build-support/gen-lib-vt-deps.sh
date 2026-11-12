#!/usr/bin/env bash
#
# Generates the two files that describe libghostty-vt's dependencies:
#
#   deps/libghostty-vt.txt
#     Every Zig package a libghostty-vt build needs, as one URL per line.
#     This is a subset of deps/packages.txt. Pass it to fetch-zig-cache.sh to
#     download only what the library needs.
#
#   deps/libghostty-vt-third-party.json
#     Every third-party project in that build, with its version, upstream
#     URL, and license, and whether its code ends up inside the library.
#     Distributions need this for their package metadata. A project whose
#     code is inside the library ("use": "linked") is what Fedora calls a
#     bundled library, declared as `Provides: bundled(wuffs) = 0.4.0-alpha.10`,
#     and what Debian calls an embedded code copy. Licenses go in Fedora's
#     License tag and Debian's debian/copyright file.
#
# You normally do not run this directly. `check-zig-cache.sh --update` runs
# it and writes both files to deps/, and CI fails if they are out of
# date. Do not edit either file by hand.
#
# Usage:
#
#   gen-lib-vt-deps.sh <packages.json> <list.txt> <third-party.json>
#
# Example entry in the third-party file:
#
#   {
#     "name": "wuffs",
#     "kind": "zig-package",
#     "version": "0.4.0-alpha.10",
#     "commit": "7411f488fe2e2c205c3d3b3d28638b7356522930",
#     "url": "https://deps.files.ghostty.org/wuffs-7411f488....tar.gz",
#     "hash": "N-V-__8AAP5JWgCGP_AD0teWpa4krRvE9VPZzvviGdbmN4jI",
#     "license": "Apache-2.0 OR MIT",
#     "use": "linked"
#   }
#
#   - kind is "zig-package" for packages fetched by Zig, or "vendored" for
#     source code copied into this repository. Vendored entries have a "path"
#     instead of a "hash".
#   - version and commit are null when the source does not state them.
#   - use is "linked" when the project's code can end up inside the library,
#     or "build" when only the build uses it, such as a code generator.
#
# Where the information comes from
#
#   - The list of packages comes from Zig. See "How the list is found".
#   - Whether a package is linked, and each package's version, come from the
#     `zig build lib-vt-packages` step (src/build/LibVtPackages.zig).
#   - Licenses, and versions of packages that do not declare one, come from
#     the `.third_party` field of the build.zig.zon that lists the package's URL.
#   - Vendored code takes its version from the build.zig.zon of the package
#     that holds it, such as pkg/simdutf/build.zig.zon, unless its
#     .third_party entry sets one.
#     That file is the one place to update when adding or upgrading a
#     dependency. src/build/LibVtPackages.zig documents the field.
#
# How the list is found
#
# The list is not written by hand. The script asks Zig what it needs:
#
#   1. Start with an empty package directory.
#   2. Run `zig build lib-vt-packages --system <dir>`. --system makes Zig use
#      only <dir> and never download. The step itself compiles nothing.
#   3. If a package is missing, Zig fails and names it. Download it into
#      <dir> and go back to step 2.
#   4. When the build runs successfully, <dir> holds exactly what the build
#      needs, and the step has written its report.
#
# Some packages are only needed for certain targets, so this repeats for
# every target in TARGETS and keeps them all. The result includes packages
# that the library does not use but Zig still insists on downloading, and
# leaves out optional ("lazy") packages that the library build never asks
# for.
#
# Errors and how to fix them
#
#   "no .third_party entry for <name>"
#     A new package is on the list. Add an entry for it to the build.zig.zon
#     that lists its URL.
#   "<name> is linked but has no version"
#     The package has no build.zig.zon of its own. Add a version to its
#     .third_party entry.
#   "the .third_party entry for <name> sets a version, but ..."
#     The package, or for vendored code the package that holds it, declares
#     its own version. Remove the one in .third_party.
#   "the vendored code <name> has no version"
#     Set .version in the build.zig.zon that holds the code.
#   "the .third_party entry for <name> names no package"
#     The package was removed. Remove its entry.
#   "<path> is compiled into the library but no .third_party entry covers it"
#     Code was copied into a vendor directory. Add an entry with .path.

set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <packages.json> <list.txt> <third-party.json>" >&2
  exit 1
fi

ZON_JSON="$(realpath "$1")"
OUT_TXT="$2"
OUT_THIRD_PARTY="$3"

ROOT="$(realpath "$(dirname "$0")/../../")"
FETCH="$ROOT/nix/build-support/fetch-zig-cache.sh"

TARGETS=(
  x86_64-linux-gnu
  aarch64-linux-gnu
  x86_64-linux-musl
  x86_64-freebsd
  aarch64-macos
  x86_64-windows-gnu
  wasm32-freestanding
)

LIB_FLAGS=(
  -Demit-lib-vt=true
  -Demit-xcframework=false
)

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Downloads go into one cache and the build uses a second, empty cache. This
# avoids a Zig 0.17 crash ("reached unreachable code") that happens when an
# optional package is missing from the --system directory but an archive of
# it sits in the global cache, which a developer's ~/.cache/zig often has.
# The empty cache also ensures the build sees only the packages fetched here.
#
# The build also gets an empty local cache, so build.zig always runs and the
# report always reflects the current files.
FETCH_CACHE="$WORK_DIR/cache"
PKG_DIR="$FETCH_CACHE/p"
mkdir -p "$PKG_DIR"
BUILD_CACHE="$WORK_DIR/build-cache"
LOCAL_CACHE="$WORK_DIR/local-cache"

for target in "${TARGETS[@]}"; do
  settled=false
  for _ in $(seq 1 20); do
    if (cd "$ROOT" && ZIG_GLOBAL_CACHE_DIR="$BUILD_CACHE" \
      zig build lib-vt-packages --system "$PKG_DIR" \
      --cache-dir "$LOCAL_CACHE" --prefix "$WORK_DIR/out/$target" \
      "${LIB_FLAGS[@]}" -Dtarget="$target") \
      >/dev/null 2>"$WORK_DIR/stderr"; then
      settled=true
      break
    fi

    # Zig reports a missing required package as
    #   package not found at '<dir>/<hash>'
    # and a missing optional one as
    #   lazy dependency package not found: <dir>/<hash>
    sed -n \
      -e "s|.*package not found at '$PKG_DIR/\([^/']*\)'.*|\1|p" \
      -e "s|.*lazy dependency package not found: $PKG_DIR/\([^/]*\)\$|\1|p" \
      "$WORK_DIR/stderr" | sort -u >"$WORK_DIR/missing"

    if [ ! -s "$WORK_DIR/missing" ]; then
      echo "zig build failed for $target without naming a missing package:" >&2
      cat "$WORK_DIR/stderr" >&2
      exit 1
    fi

    jq -r --rawfile missing "$WORK_DIR/missing" '
      . as $json
      | $missing | split("\n")[] | select(. != "")
      | $json[.].url // error("\(.) is not in deps/packages.json")
    ' "$ZON_JSON" >"$WORK_DIR/urls"

    ZIG_GLOBAL_CACHE_DIR="$FETCH_CACHE" ZIG_ZON_JSON="$ZON_JSON" \
      "$FETCH" "$WORK_DIR/urls" 2>/dev/null
  done

  if [ "$settled" != true ]; then
    echo "packages for $target did not settle after 20 rounds" >&2
    exit 1
  fi
done

# Use every package in PKG_DIR, not only the ones Zig named. Downloading a
# package also downloads its required dependencies (translate_c brings in
# aro), so Zig never reports those as missing.
find "$PKG_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -exec basename {} \; |
  sort >"$WORK_DIR/hashes"

jq -r --rawfile hashes "$WORK_DIR/hashes" '
  . as $json
  | [$hashes | split("\n")[] | select(. != "") | $json[.].url]
  | sort[]
' "$ZON_JSON" >"$OUT_TXT"

# Every target's report, as one array.
jq -s '.' "$WORK_DIR"/out/*/lib-vt-packages.json >"$WORK_DIR/reports.json"

jq --rawfile hashes "$WORK_DIR/hashes" \
  --slurpfile reports "$WORK_DIR/reports.json" '
  # The git commit, when the URL names one. That is either a git URL ending
  # in #<commit>, or a mirror archive named <name>-<commit>.tar.gz. Some
  # mirror names hold a longer hex string, which is a content hash rather
  # than a commit, so only exactly 40 hex digits count.
  def commit:
    (capture("#(?<c>[0-9a-f]{40})$") // capture("-(?<c>[0-9a-f]{40})\\.tar\\.") | .c) // null;

  # Joins a package directory and a path inside it. Ghostty itself is "".
  def join($dir; $path):
    if $dir == "" then $path else "\($dir)/\($path)" end;

  # Whether $file is the directory $dir or inside it.
  def within($dir): . == $dir or startswith($dir + "/");

  . as $json
  | [$hashes | split("\n")[] | select(. != "")] as $list
  | [$reports[0][].packages[]] as $packages

  # Packages in this repository: Ghostty and the pkg/ directories. Only
  # their .third_party fields count. A fetched package does not get to describe
  # other packages.
  | [$packages[] | select($json[.hash] == null)] as $local

  # Every .third_party entry, with the directory of the build.zig.zon it is in.
  # Each target reports the same entries, so drop the repeats.
  | [$local[] | .hash as $dir | .third_party[] | . + {dir: $dir}]
    | unique_by([.dir, .name]) as $entries
  | ($entries | group_by(.name) | map(select(length > 1) | .[0].name)) as $dupes
  | if ($dupes | length) > 0
    then error("more than one .third_party entry for: \($dupes | join(", "))")
    else . end
  | ($entries | map({key: .name, value: .}) | from_entries) as $by_name

  | ($json | [.[].name] | unique) as $names
  | [$entries[] | select(.path == null and (.name | IN($names[]) | not)) | .name] as $stale
  | if ($stale | length) > 0
    then error("the .third_party entry for \($stale | join(", ")) names no package in deps/packages.json; remove it")
    else . end

  # Packages compiled into the library for any target, and every file of
  # this repository compiled into it, relative to the repository root.
  | [$packages[] | select(.linked_paths | length > 0) | .hash] | unique as $linked
  | [$local[] | .hash as $dir | .linked_paths[] | join($dir; .)] | unique as $linked_files

  # Vendored code must have an entry, so that copying code into a vendor
  # directory cannot go unnoticed.
  | [$entries[] | select(.path != null) | . + {path: join(.dir; .path)}] as $vendored
  | [$linked_files[]
      | select(split("/") | index("vendor"))
      | . as $f
      | select([$vendored[] | .path as $dir | select($f | within($dir))] | length == 0)
    ] as $uncovered
  | if ($uncovered | length) > 0
    then error("\($uncovered | join(", ")) is compiled into the library but no .third_party entry covers it; add one with .path")
    else . end

  | {
      generator: "nix/build-support/gen-lib-vt-deps.sh",
      third_party: (
        [
          $list[] as $h
          | $json[$h] as $pkg
          | ($by_name[$pkg.name]
              // error("no .third_party entry for \($pkg.name) (\($pkg.url)); add one to the build.zig.zon that lists this URL")) as $entry
          | ([$packages[] | select(.hash == $h) | .version] | first // null) as $declared
          | if $declared != null and $entry.version != null
            then error("the .third_party entry for \($pkg.name) sets a version, but its build.zig.zon declares \($declared); remove the one in .third_party")
            else . end
          | ($declared // $entry.version) as $version
          | ($h | IN($linked[])) as $is_linked
          | if $version == null and $is_linked
            then error("\($pkg.name) is linked but has no version; add one to its .third_party entry")
            else . end
          | {
              name: $pkg.name,
              kind: "zig-package",
              version: $version,
              commit: ($pkg.url | commit),
              url: $pkg.url,
              hash: $h,
              license: $entry.license,
              use: (if $is_linked then "linked" else "build" end)
            }
        ]
        + [
          # Vendored code used by other builds, such as the app, is left out.
          $vendored[]
          | . as $v
          | select([$linked_files[] | select(within($v.path))] | length > 0)
          | ([$local[] | select(.hash == $v.dir) | .version] | first // null) as $declared
          | if $declared != null and .version != null
            then error("the .third_party entry for \(.name) sets a version, but \(join($v.dir; "build.zig.zon")) declares \($declared); remove the one in .third_party")
            else . end
          | ($declared // .version) as $version
          | if $version == null
            then error("the vendored code \(.name) has no version; set .version in \(join($v.dir; "build.zig.zon"))")
            else . end
          | {
              name,
              kind: "vendored",
              version: $version,
              commit: null,
              url,
              path,
              license,
              use: "linked"
            }
        ]
        | sort_by(.name)
      )
    }
' "$ZON_JSON" >"$OUT_THIRD_PARTY"

# A vendored entry must point at a directory that exists.
jq -r '.third_party[] | select(.kind == "vendored") | .path' "$OUT_THIRD_PARTY" |
  while IFS= read -r path; do
    if [ ! -d "$ROOT/$path" ]; then
      echo "the .third_party entry for $path points at a directory that does not exist" >&2
      exit 1
    fi
  done
