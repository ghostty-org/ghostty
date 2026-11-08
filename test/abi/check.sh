#!/usr/bin/env bash
#
# Dump and compare the ABI of libghostty-vt with libabigail.
#
# Usage:
#
#   test/abi/check.sh dump <lib.so> <out.abi>
#   test/abi/check.sh diff <baseline.abi> <lib.so>
#
# `dump` writes the ABI of a build to a file. `diff` compares the ABI of
# a build to a baseline and fails if the ABI broke, or if the library's
# SONAME or symbol version nodes aren't the expected ones. For example,
# to compare a fresh build to the committed baseline:
#
#   test/abi/check.sh diff test/abi/baseline.abi zig-out/lib/libghostty-vt.so
#
# libabigail can't read the ABI from the library's own debug info,
# because Zig doesn't mark exported functions as external there. So this
# script builds a small "probe" library from the public headers, with one
# typed pointer for each API function, and checks the ABI of the probe
# instead. See test/abi/README.md for the details and the policy.
#
# Run this on Linux inside `nix develop`, which provides libabigail.
# Optional environment variables:
#
#   CC                   C compiler for the probe (default: cc)
#   GHOSTTY_ABI_INCLUDE  public headers (default: the repo's include/)

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
suppr="$root/test/abi/libghostty-vt.suppr"
include="${GHOSTTY_ABI_INCLUDE:-$root/include}"
cc="${CC:-cc}"

# Exported functions that aren't part of the API. The library's own C++
# code calls them, so they have to be exported, but no header declares
# them.
internal='^ghostty_(simd|hwy)_'

indent() {
  sed 's/^/  /'
}

usage() {
  echo "usage: $0 dump <lib.so> <out.abi>" >&2
  echo "       $0 diff <baseline.abi> <lib.so>" >&2
  exit 2
}

# Print the exported ghostty_* functions of the library at $1. The
# version script in src/terminal/c/ghostty-vt.map tags every export with
# a symbol version, and GNU nm prints that as part of the name, for
# example ghostty_terminal_new@@GHOSTTY_VT_1.0. We strip it so the names
# match the headers.
exported_functions() {
  nm -D --defined-only --format=posix "$1" |
    awk '$2 == "T" && $1 ~ /^ghostty_/ { sub(/@.*/, "", $1); print $1 }' |
    sort -u
}

# Print the SONAME of the library at $1.
soname_of() {
  readelf -d "$1" | sed -n 's/.*Library soname: \[\(.*\)\].*/\1/p'
}

# Check that the library at $1 has the SONAME of the major version in
# lib_version, and defines exactly the version nodes that
# src/terminal/c/ghostty-vt.map declares. abidiff can't see either one,
# because the probe copies the SONAME and only uses the library's symbols.
# The BASE entry in the version definitions is the SONAME, not a node.
check_versions() {
  local lib="$1" major soname declared defined

  major="$(sed -nE 's/^const lib_version = "([0-9]+)\..*/\1/p' "$root/build.zig")"
  soname="$(soname_of "$lib")"
  if [ "$soname" != "libghostty-vt.so.$major" ]; then
    echo "error: SONAME is '$soname', expected libghostty-vt.so.$major" >&2
    return 1
  fi

  declared="$(sed -nE 's/^(GHOSTTY_VT_[0-9.]+)[[:space:]]*\{.*/\1/p' \
    "$root/src/terminal/c/ghostty-vt.map" | sort)"
  defined="$(readelf --version-info --wide "$lib" |
    sed -nE '/Flags: BASE/d; s/.* Rev: .* Name: ([^ ]+).*/\1/p' | sort)"
  if [ "$declared" != "$defined" ]; then
    echo "error: version nodes don't match ghostty-vt.map" >&2
    diff <(echo "$declared") <(echo "$defined") | indent >&2
    return 1
  fi

  echo "SONAME $soname, version nodes: ${defined//$'\n'/ }"
}

# Print the ghostty_* functions the public headers declare with
# GHOSTTY_API. The headers only define GHOSTTY_API if it isn't defined
# already, so we define it to a marker and look for the marker in the
# preprocessed headers. This skips the static inline helpers in the
# headers, which aren't part of the library.
declared_functions() {
  printf '#include <ghostty/vt.h>\n' |
    "$cc" -E -P -I "$include" -DGHOSTTY_API=__ghostty_api__ -x c - |
    tr '\n' ' ' |
    tr ';' '\n' |
    sed -nE 's/.*__ghostty_api__[^(]*\b(ghostty_[a-z0-9_]+)[[:space:]]*\(.*/\1/p' |
    sort -u
}

# Build the probe library for the library at $1 in the directory $2. The
# API functions, the ones the library exports and the headers declare,
# are written to $2/api.txt. For each one, the probe has a line like:
#
#   __typeof__(ghostty_terminal_new) *const abi_ghostty_terminal_new = &ghostty_terminal_new;
build_probe() {
  local lib="$1" dir="$2" soname

  exported_functions "$lib" >"$dir/exported.txt"
  declared_functions >"$dir/declared.txt"
  comm -12 "$dir/exported.txt" "$dir/declared.txt" >"$dir/api.txt"

  # An exported function that the headers don't declare would never be
  # checked, so it's an error, unless it's one of the internal functions.
  # A declared function that this build doesn't export is only listed.
  local extra
  extra="$(comm -23 "$dir/exported.txt" "$dir/declared.txt" |
    grep -E "$internal" || true)"
  if [ -n "$extra" ]; then
    echo "Exported internal functions (not checked):"
    indent <<<"$extra"
  fi
  extra="$(comm -23 "$dir/exported.txt" "$dir/declared.txt" |
    grep -vE "$internal" || true)"
  if [ -n "$extra" ]; then
    echo "error: exported but not declared in the public headers:" >&2
    indent <<<"$extra" >&2
    return 1
  fi
  extra="$(comm -13 "$dir/exported.txt" "$dir/declared.txt")"
  if [ -n "$extra" ]; then
    echo "Declared in the headers but not exported (not checked):"
    indent <<<"$extra"
  fi

  if [ ! -s "$dir/api.txt" ]; then
    echo "error: $lib exports no ghostty_* function the headers declare" >&2
    return 1
  fi

  {
    echo '#include <ghostty/vt.h>'
    echo
    sed -E 's/^(.*)$/__typeof__(\1) *const abi_\1 = \&\1;/' "$dir/api.txt"
  } >"$dir/probe.c"

  soname="$(soname_of "$lib")"
  if [ -z "$soname" ]; then
    echo "error: $lib has no SONAME" >&2
    return 1
  fi

  # Emit debug info for every type, not only the ones the pointers use,
  # because many functions take a struct through a void pointer.
  # Linking with --no-undefined fails if the library is missing any
  # function. Compiling inside the probe's directory with these prefix
  # maps makes the paths in the dump the same on every machine.
  lib="$(cd "$(dirname "$lib")" && pwd)/$(basename "$lib")"
  (
    cd "$dir"
    "$cc" -shared -fPIC -O1 -g -fno-eliminate-unused-debug-types \
      -ffile-prefix-map="$include/"= -ffile-prefix-map="$dir"=. \
      -I "$include" \
      -o probe.so probe.c \
      -Wl,-soname,"$soname" -Wl,--no-undefined "$lib"
  )
}

# Write the ABI of the probe library in the directory $1 to $2, and
# check that it describes every API function.
dump_probe() {
  local dir="$1" out="$2" missing

  abidw --load-all-types \
    --drop-undefined-syms \
    --no-corpus-path \
    --no-comp-dir-path \
    --suppressions "$suppr" \
    --out-file "$out" \
    "$dir/probe.so"

  # If libabigail can't see a function, the check can't catch changes to
  # it. So every API function must be in the dump as a typed variable.
  missing="$(while read -r f; do
    grep -q "<var-decl name='abi_$f' .*elf-symbol-id='abi_$f'" "$out" ||
      echo "$f"
  done <"$dir/api.txt")"
  if [ -n "$missing" ]; then
    echo "error: these functions are missing from the ABI dump:" >&2
    indent <<<"$missing" >&2
    return 1
  fi

  echo "Dumped the ABI of $(wc -l <"$dir/api.txt") functions to $out"
}

# Write a suppression to $2 that allows new members at the end of every
# sized struct in the ABI dump $1. A sized struct starts with a `size`
# member that tells the library how much of the struct the caller has
# (see GHOSTTY_INIT_SIZED in include/ghostty/vt/types.h), so adding
# members at its end is compatible. A struct that contains a sized
# struct is still reported, because its own members move.
#
# We find the sized structs in the dump by looking for a struct whose
# first member is named `size` and sits at offset 0.
sized_suppression() {
  local names
  names="$(awk -v q="'" '
    /<class-decl / {
      cls = ""
      if (match($0, "name=" q "[^" q "]*" q)) {
        cls = substr($0, RSTART + 6, RLENGTH - 7)
      }
      first = 1
      next
    }
    first && /<data-member / {
      off0 = index($0, "layout-offset-in-bits=" q "0" q) > 0
      next
    }
    first && /<var-decl / {
      if (off0 && index($0, "name=" q "size" q) > 0 && cls != "") print cls
      first = 0
    }
  ' "$1" | sort -u | paste -sd '|' -)"

  : >"$2"
  if [ -n "$names" ]; then
    {
      echo "[suppress_type]"
      echo "  type_kind = struct"
      echo "  name_regexp = ^($names)\$"
      echo "  has_data_member_inserted_at = end"
      echo "  has_size_change = yes"
    } >"$2"
  fi
}

# Print the names of the structs, unions, enums and typedefs in the ABI
# dump $1.
type_names() {
  grep -oE "<(class|union|enum|typedef)-decl name='[^']+'" "$1" |
    sed -E "s/.* name='([^']+)'/\1/" |
    sort -u
}

# Write a suppression to $3 for the types in the ABI dump $2 that the
# baseline $1 doesn't have. `abidiff --no-added-syms` ignores added
# functions and variables, but it still reports added types. A new type
# can't hide a change to an existing one, so suppressing new types by
# name is safe.
added_types_suppression() {
  local names
  names="$(comm -13 <(type_names "$1") <(type_names "$2") |
    paste -sd '|' -)"

  : >"$3"
  if [ -n "$names" ]; then
    {
      echo "[suppress_type]"
      echo "  name_regexp = ^($names)\$"
    } >"$3"
  fi
}

# Append stdin to the GitHub Actions step summary, if there is one.
summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    cat >>"$GITHUB_STEP_SUMMARY"
  else
    cat >/dev/null
  fi
}

# Add a step summary section with the title $1, the text $2 and the
# abidiff report $3.
summarize() {
  {
    echo "## libghostty-vt ABI: $1"
    echo
    echo "$2"
    echo
    echo '```'
    echo "$3"
    echo '```'
  } | summary
}

cmd_dump() {
  [ $# -eq 2 ] || usage
  build_probe "$1" "$work"
  dump_probe "$work" "$2"
}

cmd_diff() {
  [ $# -eq 2 ] || usage
  local baseline="$1" lib="$2" status breaks report
  build_probe "$lib" "$work"
  dump_probe "$work" "$work/current.abi"
  sized_suppression "$baseline" "$work/sized.suppr"
  added_types_suppression "$baseline" "$work/current.abi" "$work/added.suppr"

  # abidiff's exit status is a set of bits: 1 is an error, 2 a usage
  # error, 4 an ABI change and 8 an incompatible ABI change. We can't
  # rely on 8 alone. For example, if a function takes a struct by
  # pointer and one of its members gets bigger, abidiff only reports 4,
  # the same as for an addition. So abidiff runs twice. The first run
  # reports everything, additions included. The second ignores
  # additions, and any change it still finds fails the check.
  local args=(
    --non-reachable-types
    --suppressions "$suppr"
    --suppressions "$work/sized.suppr"
    "$baseline" "$work/current.abi"
  )

  status=0
  report="$(abidiff "${args[@]}")" || status=$?
  echo "$report"
  if [ $((status & 3)) -ne 0 ]; then
    echo "error: abidiff failed with exit status $status" >&2
    return 1
  fi

  breaks=0
  abidiff --no-added-syms --suppressions "$work/added.suppr" \
    "${args[@]}" >/dev/null || breaks=$?
  if [ $((breaks & 3)) -ne 0 ]; then
    echo "error: abidiff failed with exit status $breaks" >&2
    return 1
  fi

  if [ "$breaks" -ne 0 ]; then
    summarize "incompatible change" \
      "The ABI changed incompatibly since \`test/abi/baseline.abi\`. If the break is intended, regenerate the baseline in this PR (see \`test/abi/README.md\`)." \
      "$report"
    echo "error: incompatible ABI change" \
      "(abidiff exit status $breaks without additions)" >&2
    return 1
  fi

  if [ "$status" -ne 0 ]; then
    summarize "additions" \
      "The ABI grew since \`test/abi/baseline.abi\` without breaking it." \
      "$report"
    echo "The ABI grew compatibly since the baseline."
    return 0
  fi

  echo "The ABI matches the baseline."
}

[ $# -ge 1 ] || usage
cmd="$1"
shift
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
case "$cmd" in
dump) cmd_dump "$@" ;;
diff)
  cmd_diff "$@"
  check_versions "$2"
  ;;
*) usage ;;
esac
