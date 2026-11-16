# Release Notes {#release-notes}

The changes in each libghostty-vt release, newest first.

## 1.0.1 {#release-notes-1-0-1}

Released November 11, 2026.

### Highlights {#release-notes-1-0-1-highlights}

- **Prebuilt Windows builds.** Releases now include zips for x86_64 and aarch64
  (Windows on Arm), each with the DLL, import and static libraries, headers,
  CMake and pkg-config files. See @ref installing-windows "Windows".
- **Faster memory operations on Linux.** Builds that dynamically link glibc now
  use its `memset`, `memcpy` and `memmove`, which pick the best CPU features at
  runtime and beat Zig's compiler_rt in every benchmark we have.
- **Fixed garbled input with an AVX-512 system simdutf.**

### Bug Fixes {#release-notes-1-0-1-fixes}

- Resizing the column count no longer leaves stale shell prompts behind when the
  shell redraws its prompt (OSC 133). This was most visible with full-line
  prompts like powerlevel10k.
- A resize that grows rows and shrinks columns at the same time now pulls
  scrollback down correctly, matching what you get from doing the two resizes
  one after the other.
- A failed render state update no longer marks unfinished rows as clean. Those
  rows stay dirty and are rebuilt on the next update, instead of being rendered
  from incomplete data (which could crash).
- Kitty graphics: during a chunked transmission that replaces an image, the old
  image now stays until the transmission ends, instead of disappearing on the
  first chunk.

### Performance {#release-notes-1-0-1-performance}

- Setting a scrollback line limit now performs the same as a byte limit. We
  previously decommitted memory only in the line-limit case, which caused storms
  of page faults. With a 1,000-line limit, ASCII throughput went from 298 to
  1,983 MB/s on Linux (6.7x) and from 2,214 to 4,093 MB/s on macOS (1.8x).
  Matches byte limit performance.
- A restored snapshot's last page now gets its full pooled capacity, so the
  first write after a restore doesn't immediately allocate.
- Linux builds that dynamically link glibc now use glibc's `memset`, `memcpy`
  and `memmove` (with runtime CPU feature detection) instead of Zig
  compiler_rt's. ASCII with no scrollback is 23% faster on arm64 and 10% faster
  on x86_64. Resizing is 4–10% faster.
- UTF-8 decoding after the first invalid sequence no longer decodes valid runs
  twice. Valid input is unchanged, and input with invalid sequences decodes
  6–10% faster.
- Faster CSI parameter parsing: 14 instructions and 2 branches per digit on
  x86-64, down from 23 and 5. Style-heavy streams are up to 5% faster.
- Less per-segment overhead in `RenderState.endUpdate`.
- Validating C enums no longer scans every field.

### Packaging {#release-notes-1-0-1-packaging}

- Releases now include prebuilt Windows zips for x86_64 and aarch64
  (`*-windows-gnu`).
- On Windows, pkg-config files are relocatable and `aarch64-windows-gnu` builds.
- Statically linked Darwin builds no longer pick up our `memset` over
  libSystem's.

## 1.0.0 {#release-notes-1-0-0}

Released November 6, 2026. The first stable release. The C ABI is stable from
this release on, see @ref stability.
