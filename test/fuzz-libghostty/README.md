# AFL++ Fuzzer for Libghostty

This directory contains an [AFL++](https://aflplus.plus/) fuzzing harness for
libghostty-vt (Zig module). At the time of writing this README, it only
fuzzes the VT parser, but it can be extended to cover other components of
libghostty as well.

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

This compiles a Zig static library (with the fuzz harness in `src/lib.zig`),
emits LLVM bitcode, then links it with `src/main.c` using `afl-cc` to produce
the instrumented binary at `zig-out/bin/ghostty-fuzz`.

## Running the Fuzzer

The build system has a convenience step that invokes `afl-fuzz` with the
correct arguments:

```sh
zig build run
```

This is equivalent to:

```sh
afl-fuzz -i corpus/initial -o afl-out -- zig-out/bin/ghostty-fuzz @@
```

You may want to run `afl-fuzz` directly with different options
for your own experimentation.

The fuzzer runs indefinitely. Let it run for as long as you like; meaningful
coverage is usually reached within a few hours, but longer runs can find
deeper bugs. Press `ctrl+c` to stop the fuzzer when you're done.

## Finding Crashes and Hangs

After (or during) a run, results are written to `afl-out/default/`:

```

afl-out/default/
├── crashes/ # Inputs that triggered crashes
├── hangs/ # Inputs that triggered hangs/timeouts
└── queue/ # All interesting inputs (the evolved corpus)

```

Each file in `crashes/` or `hangs/` is a raw byte file that triggered the
issue. The filename encodes metadata about how it was found (e.g.
`id:000000,sig:06,...`).

## Reproducing a Crash

Replay any crashing input by piping it into the harness:

```sh
cat afl-out/default/crashes/<filename> | zig-out/bin/ghostty-fuzz
```

## Corpus Management

After a fuzzing run, the queue in `afl-out/default/queue/` typically
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
  -i afl-out/default/queue \
  -o corpus/vt-parser-cmin \
  -- zig-out/bin/ghostty-fuzz
```

`AFL_NO_FORKSRV=1` is required because the Python `afl-cmin` wrapper has
a bug in AFL++ 4.35c. Use the `afl-cmin.bash` script instead (typically
found in AFL++'s `libexec` directory).

### Test case minimization (`afl-tmin`)

Shrink each file in the minimized corpus to the smallest input that
preserves its unique coverage:

```sh
mkdir -p corpus/vt-parser-min
for f in corpus/vt-parser-cmin/*; do
  AFL_NO_FORKSRV=1 afl-tmin \
    -i "$f" \
    -o "corpus/vt-parser-min/$(basename "$f")" \
    -- zig-out/bin/ghostty-fuzz
done
```

This is slow (hundreds of executions per file) but produces the most
compact corpus. It can be skipped if you only need edge-level
deduplication from `afl-cmin`.

### Windows compatibility

AFL++ output filenames contain colons (e.g., `id:000024,time:0,...`), which
are invalid on Windows (NTFS). After running `afl-cmin` or `afl-tmin`,
rename the output files to replace colons with underscores before committing:

```sh
./corpus/sanitize-filenames.sh
```

### Corpus directories

| Directory                | Contents                                        |
| ------------------------ | ----------------------------------------------- |
| `corpus/initial/`        | Hand-written seed inputs for `afl-fuzz -i`      |
| `corpus/vt-parser-cmin/` | Output of `afl-cmin` (edge-deduplicated corpus) |
| `corpus/vt-parser-min/`  | Output of `afl-tmin` (individually minimized)   |
