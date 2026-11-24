# Release Notes {#release-notes}

The changes in each libghostty-vt release, newest first.

## 1.0.2 {#release-notes-1-0-2}

Released November 24, 2026.

### Bug Fixes {#release-notes-1-0-2-fixes}

- The mouse encoder no longer forgets the last cell when calling
  `ghostty_mouse_encoder_set_from_terminal` and setting the size
  now only forget it when the value actually changes. Previously, with
  `GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL` on, motion in the same cell was
  reported again, so a click could come out as a press, a motion and a release.
  This isn't incorrect VT sequencing, but it was wasteful and unnecessary.
- With grapheme clustering (mode 2027), a skin tone modifier now makes an emoji
  that is text by default 2 cells wide, the same as VS16. For example, U+261D
  U+1F3FB (index pointing up, light skin tone) was 1 cell and is now 2.
  `ghostty_unicode_grapheme_width` changes the same way.
- Terminals created with the C API now ignore the Kitty drag and drop protocol
  (OSC 72), including its queries. The C API can't deliver drops yet, so
  programs registered for drops that never came instead of falling back.
- Insert and delete lines (IL and DL) no longer break the soft wraps of rows
  that move together. Previously a wrapped line in the scroll region, such as a
  long URL, became two lines until the program redrew it.
- Insert and delete lines with left and right margins no longer drop the
  semantic prompt marks (OSC 133) of the rows they move, so scrolling by prompts
  no longer skips prompts.
- Kitty graphics: Unicode placeholders no longer disappear when insert or delete
  lines with left and right margins move their row.
- A restored snapshot now keeps a pending wrap at any column, for both the
  cursor and the saved cursor (DECSC). Previously it was kept only on the last
  column, so with a right margin (DECSLRM) the next character overwrote the
  cursor cell instead of wrapping. The snapshot format is unchanged.

### Performance {#release-notes-1-0-2-performance}

- Insert and delete lines with left and right margins now move styled rows with
  a single copy. This is how tmux scrolls a pane next to another pane, and how
  Neovim scrolls a vertical split. A stream that does this went from 1,716 to
  936 ms on x86_64 (1.8x) and from 1,100 to 695 ms on an M1 Pro (1.6x).
- Hyperlinks (OSC 8) are hashed in one pass instead of a byte at a time.
  `ls -laR --hyperlink=always` output is 1.3x faster.
- Carriage returns and absolute column moves (CHA, HPA) no longer look up the
  cursor's row again. Scrolling streams are up to 6% faster.
- Erasing cells skips rows that are already blank and releases styles a run at a
  time instead of a cell at a time. Erase-heavy streams are 3–6% faster.

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
