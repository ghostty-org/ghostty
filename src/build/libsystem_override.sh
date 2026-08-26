#!/bin/sh
#
# Darwin-only: rewrite a static archive so that consumers linking it bind
# libc/libm symbols to Apple's libSystem instead of the bundled Zig
# compiler-rt. This uses the Apple toolchain (xcrun, nmedit) and libSystem
# semantics, so it must run on a Darwin host for a Darwin target.
#
# Background: our static library bundles Zig's compiler-rt, which defines
# strong global implementations of libc/libm functions (memcpy, memmove,
# memset, cos, sin, ...). When a consumer (e.g. the macOS app via the
# XCFramework) links this archive, ld64 resolves those symbols from the
# archive instead of libSystem, silently replacing Apple's highly
# optimized implementations (_platform_memmove and friends, vectorized
# libm) with compiler-rt's generic ones. We measured Zig 0.16 (LLVM 21)
# compiler-rt memmove costing several percent of PTY throughput on
# scroll-region workloads versus libSystem's.
#
# The mechanism is to localize (make non-external) the libSystem-provided
# symbols defined by the compiler_rt.o archive member. This keeps
# compiler_rt.o functional for the intrinsics that libSystem does NOT
# provide (e.g. the f128 conversions ___extenddftf2/___extendxftf2, *q
# math, sincos*) while letting every other archive member bind the
# well-known libc/libm symbols to libSystem at final link.
#
# usage: libsystem_override.sh <input.a> <output.a>
set -eu

in="$1"
out="$2"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cp -f "$in" "$out"
chmod u+w "$out"

# The symbols to prefer from libSystem. Everything listed here is a
# stable macOS export (verified against libSystem's link surface).
# Notably NOT listed (not exported by libSystem): the *q (f128)
# variants, sincos/sincosf/sincosl, and all ___-prefixed compiler
# intrinsics except the fortify _chk wrappers below.
cat >"$tmp/localize.txt" <<'EOF'
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

cd "$tmp"

xcrun ar x "$out" compiler_rt.o
chmod 644 compiler_rt.o

# nmedit takes a keep-list (-s): all current global definitions except
# the ones we want to localize.
xcrun nm -g compiler_rt.o | awk '$2 ~ /^[A-TV-Z]$/ {print $3}' | sort -u >all.txt
sort -u localize.txt >loc.txt
comm -23 all.txt loc.txt >keep.txt
xcrun nmedit -s keep.txt compiler_rt.o

xcrun ar r "$out" compiler_rt.o
xcrun ranlib "$out" 2>/dev/null || true
