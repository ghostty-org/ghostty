# AFL++ Fuzzer for Libghostty

This directory contains [AFL++](https://aflplus.plus/) fuzzing harnesses for
libghostty-vt (Zig module).

## Fuzz Targets

| Target   | Binary        | Description                                             |
| -------- | ------------- | ------------------------------------------------------- |
| `osc`    | `fuzz-osc`    | OSC parser with allocator (`osc.Parser.next` + `end`)   |
| `parser` | `fuzz-parser` | VT parser only (`Parser.next` byte-at-a-time)           |
| `stream` | `fuzz-stream` | Full terminal stream (`nextSlice` + `next` via handler) |

The osc target directly fuzzes the `osc.Parser` with an allocator enabled,
exercising the allocating writer code paths for large payloads. The first
byte selects the terminator variant (BEL, ST, or missing). Seeds cover OSC
52, 66, 133, 3008, 1337, and 5522.

The stream target creates a small `Terminal` and exercises the readonly
`Stream` handler, covering printing, CSI dispatch, OSC, DCS, SGR, cursor
movement, scrolling regions, and more. The first byte of each input selects
between the slice path (SIMD fast-path) and the scalar path.

## Prerequisites

Install AFL++ so that `afl-cc` and `afl-fuzz` are on your `PATH`.

- **macOS (Homebrew):** `brew install aflplusplus`
- **Linux:** build from source or use your distro's package (e.g.
  `apt install afl++` on Debian/Ubuntu).

## Building

From this directory (`test/fuzz-libghostty`):

```sh
zig build
```

This compiles Zig static libraries for each fuzz target, emits LLVM bitcode,
then links each with `afl.c` using `afl-cc` to produce instrumented binaries
at `zig-out/bin/fuzz-osc`, `zig-out/bin/fuzz-parser`, and `zig-out/bin/fuzz-stream`.

## Running the Fuzzer

Each target has its own run step:

```sh
zig build run-osc       # Run the OSC parser fuzzer
zig build run-parser    # Run the VT parser fuzzer
zig build run-stream    # Run the VT stream fuzzer
```

Or invoke `afl-fuzz` directly:

```sh
afl-fuzz -i corpus/stream-initial -o afl-out/stream -- zig-out/bin/fuzz-stream @@
```

The fuzzer runs indefinitely. Let it run for as long as you like; meaningful
coverage is usually reached within a few hours, but longer runs can find
deeper bugs. Press `ctrl+c` to stop the fuzzer when you're done.

## Finding Crashes and Hangs

After (or during) a run, results are written to `afl-out/<target>/default/`:

```
afl-out/stream/default/
├── crashes/ # Inputs that triggered crashes
├── hangs/   # Inputs that triggered hangs/timeouts
└── queue/   # All interesting inputs (the evolved corpus)
```

Each file in `crashes/` or `hangs/` is a raw byte file that triggered the
issue. The filename encodes metadata about how it was found (e.g.
`id:000000,sig:06,...`).

## Reproducing a Crash

Replay any crashing input by piping it into the harness:

```sh
cat afl-out/stream/default/crashes/<filename> | zig-out/bin/fuzz-stream
```

## Corpus Management

After a fuzzing run, the queue in `afl-out/<target>/default/queue/` typically
contains many redundant inputs. Use `afl-cmin` to find the smallest
subset that preserves full edge coverage, and `afl-tmin` to shrink
individual test cases.

> **Important:** The instrumented binary reads input from **stdin**, not
> from file arguments. Do **not** use `@@` with `afl-cmin`, `afl-tmin`,
> or `afl-showmap` — it will cause them to see only the C harness
> coverage (~4 tuples) instead of the Zig VT parser coverage.

### Corpus minimization (`afl-cmin`)

Reduce the evolved queue to a minimal set covering all discovered edges:

```sh
AFL_NO_FORKSRV=1 afl-cmin.bash \
  -i afl-out/stream/default/queue \
  -o corpus/stream-cmin \
  -- zig-out/bin/fuzz-stream
```

`AFL_NO_FORKSRV=1` is required because the Python `afl-cmin` wrapper has
a bug in AFL++ 4.35c. Use the `afl-cmin.bash` script instead (typically
found in AFL++'s `libexec` directory).

### Windows compatibility

AFL++ output filenames contain colons (e.g., `id:000024,time:0,...`), which
are invalid on Windows (NTFS). After running `afl-cmin`,
rename the output files to replace colons with underscores before committing:

```sh
./corpus/sanitize-filenames.sh
```

### Corpus directories

| Directory                | Contents                                        |
| ------------------------ | ----------------------------------------------- |
| `corpus/osc-initial/`    | Hand-written seed inputs for osc-parser         |
| `corpus/osc-cmin/`       | Output of `afl-cmin` (edge-deduplicated corpus) |
| `corpus/parser-initial/` | Hand-written seed inputs for vt-parser          |
| `corpus/parser-cmin/`    | Output of `afl-cmin` (edge-deduplicated corpus) |
| `corpus/stream-initial/` | Hand-written seed inputs for vt-stream          |
| `corpus/stream-cmin/`    | Output of `afl-cmin` (edge-deduplicated corpus) |
