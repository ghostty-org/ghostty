#!/bin/sh
#
# Darwin-only: rewrite a static archive so that consumers linking it bind
# libc/libm symbols to Apple's libSystem instead of the bundled Zig
# compiler-rt. This uses the Apple toolchain (xcrun, nmedit) and libSystem
# semantics, so it must run on a Darwin host for a Darwin target.
#
# Background: our static library bundles Zig's compiler-rt, which defines
# its own copies of libc/libm functions (memcpy, memmove, memset, cos,
# sin, ...). Mach-O marks these copies "private external". That keeps
# them out of a dylib's exports, but the static linker still sees them.
# So when a consumer (e.g. the macOS app via the XCFramework) links this
# archive, ld64 uses the archive's copies instead of libSystem's. This
# silently replaces Apple's highly optimized implementations
# (_platform_memmove and friends, vectorized libm) with compiler-rt's
# generic ones. We measured
# Zig 0.16 (LLVM 21) compiler-rt memmove costing several percent of PTY
# throughput on scroll-region workloads versus libSystem's.
#
# The mechanism is to localize (make non-external) the libSystem-provided
# symbols defined by the compiler_rt.o archive member. This keeps
# compiler_rt.o functional for the intrinsics that libSystem does NOT
# provide (e.g. the f128 conversions ___extenddftf2/___extendxftf2, *q
# math, sincos*) while letting every other archive member bind the
# well-known libc/libm symbols to libSystem at final link.
#
# Only the compiler_rt.o member is edited. If one of our own members
# defines one of these names, that is a bug in our code. CI should catch
# it rather than have this script hide it.
#
# The output does not depend on the caller's environment. Every tool is
# run by absolute path or through /usr/bin/xcrun, and the locale is
# fixed to C, so a GNU, uutils or Homebrew tool earlier on PATH can't
# change the result. (An earlier version piped `sort` into `comm`. Under
# uutils coreutils and a UTF-8 locale the two disagreed on sort order,
# and some symbols were silently left global.)
#
# The script checks its own work and exits with status 1 rather than
# write an archive it could not fix. It fails when:
#
#   - the input does not have exactly one compiler_rt.o member, or
#   - after the edit, a symbol from the list below is still global, or
#     a symbol that should have stayed global is not.
#
# On success, each listed symbol in compiler_rt.o goes from private
# external to non-external, and every other symbol is left alone:
#
#   $ nm -m compiler_rt.o | grep -E ' _(memset|cos)$| ___extenddftf2$'
#
#   before:
#     (__TEXT,__text) private external ___extenddftf2
#     (__TEXT,__text) private external _cos
#     (__TEXT,__text) private external _memset
#
#   after:
#     (__TEXT,__text) private external ___extenddftf2
#     (__TEXT,__text) non-external (was a private external) _cos
#     (__TEXT,__text) non-external (was a private external) _memset
#
# On failure, it lists each problem symbol before the error, for example:
#
#   libsystem_override.sh:   still global: _memset
#   libsystem_override.sh: error: nmedit did not rewrite compiler_rt.o from <input.a> as expected
#
# usage: libsystem_override.sh <input.a> <output.a>
set -eu

LC_ALL=C
export LC_ALL

# Tell Apple's ar and ranlib to write a zero timestamp for each member,
# so the same input always produces a byte-identical output.
ZERO_AR_DATE=1
export ZERO_AR_DATE

# Print an error message to stderr and exit with status 1.
die() {
  printf 'libsystem_override.sh: error: %s\n' "$*" >&2
  exit 1
}

[ "$#" -eq 2 ] || die "usage: libsystem_override.sh <input.a> <output.a>"
in="$1"
out="$2"

# Zig 0.17 passes generated paths relative to the build root. Preserve
# their meaning when we change into the temporary directory below.
case "$in" in
/*) ;;
*) in="$PWD/$in" ;;
esac
case "$out" in
/*) ;;
*) out="$PWD/$out" ;;
esac

[ -f "$in" ] || die "input archive not found: $in"

tmp="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$tmp"' EXIT
cd "$tmp"

# The symbols to prefer from libSystem. Everything listed here is a
# stable macOS export (verified against libSystem's link surface).
# Notably NOT listed (not exported by libSystem): the *q (f128)
# variants, sincos/sincosf/sincosl, and all ___-prefixed compiler
# intrinsics except the fortify _chk wrappers below.
cat >localize.txt <<'EOF'
_bcmp
_memcmp
_memcpy
_memmove
_memset
_strlen
___memcpy_chk
___memmove_chk
___memset_chk
___strcat_chk
___strcpy_chk
_ceil
_ceilf
_ceill
_cos
_cosf
_cosl
_exp
_exp2
_exp2f
_exp2l
_expf
_expl
_fabs
_fabsf
_fabsl
_floor
_floorf
_floorl
_fma
_fmaf
_fmal
_fmax
_fmaxf
_fmaxl
_fmin
_fminf
_fminl
_fmod
_fmodf
_fmodl
_log
_log10
_log10f
_log10l
_log2
_log2f
_log2l
_logf
_logl
_round
_roundf
_roundl
_sin
_sinf
_sinl
_sqrt
_sqrtf
_sqrtl
_tan
_tanf
_tanl
_trunc
_truncf
_truncl
EOF

# Tool output is written to files rather than piped. In a pipeline,
# `set -e` only sees the exit status of the last command, so a failing
# ar or nm would go unnoticed.

# Print how many members of archive $1 are named compiler_rt.o. An
# archive can hold several members with the same name, so the answer
# can be more than one.
count_compiler_rt() {
  /usr/bin/xcrun ar t "$1" >members.txt
  /usr/bin/awk '$0 == "compiler_rt.o" { n++ } END { print n + 0 }' members.txt
}

# Print the name of each global symbol that object file $1 defines, one
# per line. "Global" includes private external symbols, which is how
# compiler-rt marks its copies. The nm flags select global symbols (-g),
# skip undefined ones (-U), and print names only (-j):
#
#   $ global_defs compiler_rt.o
#   ___absvdi2
#   ___absvsi2
#   ...
#   _cos
#   ...
#   _memset
#   ...
global_defs() {
  /usr/bin/xcrun nm -gUj "$1"
}

/bin/cp -f "$in" lib.a
/bin/chmod u+w lib.a

n="$(count_compiler_rt lib.a)"
case "$n" in
1) ;;
0) die "$in has no compiler_rt.o member (is compiler-rt bundled?)" ;;
*) die "$in has $n compiler_rt.o members, expected exactly one" ;;
esac

/usr/bin/xcrun ar x lib.a compiler_rt.o
/bin/chmod 644 compiler_rt.o

# nmedit takes a keep-list (-s): all current global definitions except
# the ones we want to localize.
#
# The awk program reads localize.txt first (NR == FNR is only true for
# the first file), then prints each line of before.txt that wasn't in
# it. Names are compared as exact strings, so no sorting is needed.
global_defs compiler_rt.o >before.txt
/usr/bin/awk 'NR == FNR { loc[$0] = 1; next } !($0 in loc)' \
  localize.txt before.txt >keep.txt
/usr/bin/xcrun nmedit -s keep.txt compiler_rt.o

/usr/bin/xcrun ar r lib.a compiler_rt.o
/usr/bin/xcrun ranlib lib.a

# Check the archive we are about to write out, not the loose
# compiler_rt.o we edited. That way a problem in `ar r` is caught too.
# The member is extracted into check/ so it can't be confused with the
# loose copy.
n="$(count_compiler_rt lib.a)"
[ "$n" -eq 1 ] ||
  die "rewritten archive has $n compiler_rt.o members, expected exactly one"
/bin/mkdir check
(cd check && /usr/bin/xcrun ar x ../lib.a compiler_rt.o)
/bin/chmod 644 check/compiler_rt.o
global_defs check/compiler_rt.o >after.txt

# Compare the result against both lists. Each problem is one line:
#
#   still global: _memset           (meant to be localized, but wasn't)
#   no longer global: ___extenddftf2 (meant to be kept, but was localized)
/usr/bin/awk '
  FILENAME == ARGV[1] { loc[$0] = 1; next }
  FILENAME == ARGV[2] { keep[$0] = 1; next }
  { after[$0] = 1 }
  END {
    for (s in loc) if (s in after) print "still global: " s
    for (s in keep) if (!(s in after)) print "no longer global: " s
  }
' localize.txt keep.txt after.txt >problems.txt

if [ -s problems.txt ]; then
  /usr/bin/sort problems.txt | /usr/bin/sed 's/^/libsystem_override.sh:   /' >&2
  die "nmedit did not rewrite compiler_rt.o from $in as expected"
fi

# Write the output only after every check passed, so a failed run never
# leaves a bad archive behind for the build to pick up.
/bin/cp -f lib.a "$out"
