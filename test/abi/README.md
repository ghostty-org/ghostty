# libghostty-vt ABI Checks

This directory contains the tooling that checks the ABI of libghostty-vt
in CI. For every change, we compare the ABI of the Linux x86_64 shared
library against a baseline committed here, using
[libabigail](https://sourceware.org/libabigail/). The check runs as the
`abi-check` job in `.github/workflows/test.yml`. A second check,
`zig build test-lib-vt-abi`, covers what this one can't, such as macOS and
WebAssembly. It compares the library to the manifest goldens and symbol
list in `src/terminal/c/abi/`.

The goal is that a change never breaks the ABI by accident. If a change
would break programs already built against libghostty-vt, CI fails and
shows what changed. If the break is intentional, the same change updates
the baseline, so the break is visible in review.

| File                  | Purpose                                                       |
| --------------------- | ------------------------------------------------------------- |
| `check.sh`            | Dumps the ABI of a build, or compares a build to a baseline.  |
| `libghostty-vt.suppr` | Suppressions for changes we know are compatible. Empty today. |
| `baseline.abi`        | The baseline ABI.                                             |
| `baseline.txt`        | The commit, version and tag the baseline was dumped from.     |

## What Fails the Check

The baseline is the ABI as of the last release or the last intentional
break. Any change from the baseline that could break an existing program
fails the check. For example:

- Removing a function, or changing its parameters or return type.
- Adding, removing, resizing or reordering a struct member.
- Changing the value of an enum constant.

Additions pass, because no existing program uses them yet:

- A new function.
- A new type.
- A new enum constant.
- A new member at the end of a sized struct.

A sized struct is a struct whose first member is `size_t size`. The
caller sets it to the size of the struct it was compiled with, usually
with `GHOSTTY_INIT_SIZED`, so the library knows which members the caller
has. That is what makes it safe to add members to the end of a sized
struct. Adding a member to any other struct is a break:

```c
// A sized struct. Adding a member at the end passes the check.
typedef struct {
  size_t size;
  bool viewport_has_value;
  // ...
  GhosttyRenderStateCursorVisualStyle visual_style;
  uint32_t new_member; // OK
} GhosttyRenderStateCursor;

// Not a sized struct. Adding a member fails the check, because a
// program built against the old header allocates a smaller struct.
typedef struct {
  uint16_t rows;
  uint16_t columns;
  uint32_t cell_width;
  uint32_t cell_height;
  uint32_t new_member; // Break
} GhosttySizeReportSize;
```

When a change only adds to the ABI, the job lists the additions in its
step summary so reviewers can see how the ABI grew. When a change breaks
it, the step summary shows the full libabigail report.

The check also reads the library itself, because libabigail can't see
these two things. It fails if:

- The SONAME isn't `libghostty-vt.so.<major>`, with the major version of
  `lib_version` in `build.zig`.
- The symbol version nodes the library defines aren't exactly the nodes
  `src/terminal/c/ghostty-vt.map` declares. Renaming a node breaks every
  program built against it, because the loader looks them up by name.

## Breaking the ABI on Purpose

Only a new major version of libghostty-vt may break the ABI (see
[`PACKAGING-LIBGHOSTTY.md`](../../PACKAGING-LIBGHOSTTY.md)). A pull
request that breaks the ABI on purpose must update `baseline.abi` and
`baseline.txt` in the same pull request. The diff of the baseline is how
reviewers see the break.

> [!IMPORTANT]
>
> A change to the baseline must come with a major version bump
> and a new SONAME. The job doesn't enforce this yet, so reviewers must.

## Updating the Baseline

The baseline is refreshed after every release, so that what a release
added is protected from then on. Until then, the check treats those
additions as new, and removing one would pass.

Every run of the `abi-check` job uploads an artifact named
`libghostty-vt-abi`. It contains a `baseline.abi` and `baseline.txt` for
the commit the job ran on. Artifacts expire after a week, so refresh the
baseline soon after tagging. To update the baseline:

1. Find the `abi-check` job for the commit you want as the baseline. For
   a release, this is the Test run of the `vt-X.Y.Z` tag. For an
   intentional break, this is the latest commit of the pull request.
2. Download its `libghostty-vt-abi` artifact.
3. Copy `baseline.abi` and `baseline.txt` into this directory. For a
   release, add a `tag: vt-X.Y.Z` line to `baseline.txt`.
4. Commit them.

Please use the artifact rather than a dump from your own machine. A dump
made with a different compiler or C library can differ from CI's in ways
that don't matter, and those differences make the baseline diff hard to
review.

## Running the Check Locally

libabigail only reads ELF files, so the check only runs on Linux. From
the root of the repository, build the library with the same options CI
uses:

```sh
nix develop -c zig build -Demit-lib-vt -Doptimize=ReleaseFast -Dcpu=baseline
```

Then compare the build to the baseline:

```sh
nix develop -c test/abi/check.sh diff test/abi/baseline.abi zig-out/lib/libghostty-vt.so
```

`diff` exits with 0 if the ABI matches the baseline or only grew and the
SONAME and version nodes are right, and with 1 if not or if something
went wrong. To write the ABI of a build
to a file instead, use `dump`:

```sh
nix develop -c test/abi/check.sh dump zig-out/lib/libghostty-vt.so /tmp/libghostty-vt.abi
```

If you ever need to commit a dump from your own machine, write
`baseline.txt` next to it in the same format the job uses:

```
commit: <full commit hash>
version: <the Version line of zig-out/lib/pkgconfig/libghostty-vt.pc>
```

`check.sh` reads two optional environment variables:

- `CC`: the C compiler that builds the probe library described below.
  Defaults to `cc`.
- `GHOSTTY_ABI_INCLUDE`: the directory with the public headers. Defaults
  to the repository's `include/` directory.

## How It Works

Normally, libabigail reads the ABI of a library from its debug info. That
doesn't work for libghostty-vt. Zig writes the debug info of exported
functions under their Zig names, such as `terminal.c.terminal.new` for
`ghostty_terminal_new`, and doesn't mark them as external. So libabigail
treats every one of them as private. It sees the symbols, but not their
types.

Instead, `check.sh` builds a small "probe" library from the public
headers. For each function that the library exports and the headers
declare with `GHOSTTY_API`, the probe holds one pointer with the type the
header gives it:

```c
#include <ghostty/vt.h>

__typeof__(ghostty_terminal_new) *const abi_ghostty_terminal_new = &ghostty_terminal_new;
__typeof__(ghostty_terminal_resize) *const abi_ghostty_terminal_resize = &ghostty_terminal_resize;
// ...and so on for every function.
```

The probe is compiled with debug info for every type in the headers,
including structs that functions only take through a `void *`. It links
against the library and takes the library's SONAME. The ABI of the probe
is the ABI that programs compile against, and that is what we dump and
compare.

This is why libabigail reports show functions as `abi_*` variables. For
example, this is the report for a build that no longer exports
`ghostty_terminal_resize`:

```
1 Removed variable:

  [D] 'GhosttyResult (* const abi_ghostty_terminal_resize)(GhosttyTerminal, uint16_t, uint16_t, uint32_t, uint32_t)'    {abi_ghostty_terminal_resize}
error: incompatible ABI change (abidiff exit status 12 without additions)
```

The dump also makes sure that no function slips past the check. It
fails if the library exports a `ghostty_*` function that the headers
don't declare, or if a function is missing from the dump. The only
exceptions are the internal `ghostty_simd_*` and `ghostty_hwy_*`
helpers.

To compare, `diff` runs libabigail's `abidiff` twice. libabigail sorts
what it finds into "incompatible changes" and plain "changes", and some
real breaks end up in the second group. For example, if a function takes
a struct by pointer and one of the struct's members gets bigger,
libabigail calls it a change, the same as adding a function. So the
first run reports everything, and the second run ignores additions. If
the second run still finds a change, the check fails.

## Limits

- The check compares the headers, not the Zig code behind them. The
  header parity tests in `src/terminal/c/abi_test.zig` make sure that
  the headers match the Zig types.
- libabigail considers some changes harmless and doesn't report them,
  even though they can break programs at the source level. Two examples
  are renaming a struct member and changing an integer to another
  integer of the same size, such as `uint32_t` to `int32_t`.
- Only the Linux x86_64 library is checked. Other targets use the same
  headers, but some types, such as `size_t`, have different sizes there.
