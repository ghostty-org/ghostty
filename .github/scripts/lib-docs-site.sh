#!/usr/bin/env bash
#
# Assembles a libghostty-vt docs site into a folder that Vercel can serve as
# it is, with no build step. .github/workflows/lib-docs.yml deploys the result.
#
#   lib-docs-site.sh tip OUT DOCS
#   lib-docs-site.sh release OUT DOCS...
#
# OUT is the folder to create. It must not exist yet.
#
# The tip site has a single copy of the docs. DOCS is the folder that Doxygen
# wrote, and the site serves it at /vt/:
#
#   lib-docs-site.sh tip site zig-out/share/ghostty/doc/libghostty
#
# The release site has every release. Each DOCS is an unzipped docs zip, and
# its name gives the version, such as libghostty-vt-0.2.0-docs. They can come
# in any order, because the script finds the newest one itself:
#
#   lib-docs-site.sh release site docs/libghostty-vt-*-docs
#
# With releases 0.1.0 and 0.2.0, that writes:
#
#   site/
#     robots.txt
#     vercel.json
#     vt/             0.2.0, the newest release
#       0.1.0/
#       0.2.0/
#
# robots.txt and vercel.json are copied from dist/doxygen/site/MODE/. JSON has
# no comments, so the two choices in the release vercel.json are explained here:
#
#   - It doesn't set trailingSlash, which the tip site does. Vercel would read
#     the ".0" in /vt/0.1.0/ as a file extension and remove the slash, which
#     breaks the page's relative links. It lists its redirects by hand instead.
#
#   - It has two X-Robots-Tag rules, because a /:path* pattern matches the pages
#     under /vt/0.1.0/ but not /vt/0.1.0/ itself.

set -euo pipefail

usage() {
  sed -n '6,7s/^# *//p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

[ "$#" -ge 3 ] || usage
mode=$1
out=$2
shift 2

site=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../dist/doxygen/site" && pwd)

# Copies the contents of a docs folder to a folder of the site.
copy_docs() {
  if [ ! -f "$1/index.html" ]; then
    echo "error: no index.html in $1" >&2
    exit 1
  fi
  mkdir -p "$2"
  cp -R "$1/." "$2/"
}

case "$mode" in
tip)
  [ "$#" -eq 1 ] || usage
  mkdir "$out"
  copy_docs "$1" "$out/vt"
  ;;

release)
  mkdir "$out"
  versions=()
  for docs in "$@"; do
    name=$(basename "$docs")
    version=${name#libghostty-vt-}
    version=${version%-docs}
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "error: not a release docs folder: $docs" >&2
      exit 1
    fi
    copy_docs "$docs" "$out/vt/$version"
    versions+=("$version")
  done

  # A version sort, so that 0.10.0 is newer than 0.9.0.
  newest=$(printf '%s\n' "${versions[@]}" | sort -V | tail -n 1)
  echo "newest release: $newest"
  cp -R "$out/vt/$newest/." "$out/vt/"
  ;;

*)
  usage
  ;;
esac

cp "$site/$mode/vercel.json" "$site/$mode/robots.txt" "$out/"
