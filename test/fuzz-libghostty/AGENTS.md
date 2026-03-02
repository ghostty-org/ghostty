# AFL++ Fuzzer for Libghostty

- Build all fuzzer with `zig build`
- The list of available fuzzers is in `build.zig` (search for `fuzzers`).
- Run a specific fuzzer with `zig build run-<name>` (e.g. `zig build run-parser`)
- Corpus directories follow the naming convention `corpus/<fuzzer>-<variant>`
  (e.g. `corpus/parser-initial`, `corpus/stream-cmin`).
- Do NOT run `afl-tmin` unless explicitly requested — it is very slow.
- After running `afl-cmin`, run `corpus/sanitize-filenames.sh`
  before committing to replace colons with underscores (colons are invalid
  on Windows NTFS).

## Important: stdin-based input

The instrumented binaries (`afl.c` harness) read fuzz input from **stdin**,
not from a file argument. This affects how you invoke AFL++ tools:

- **`afl-fuzz`**: Uses shared-memory fuzzing automatically; `@@` works
  because AFL writes directly to shared memory, bypassing file I/O.
- **`afl-showmap`**: Must pipe input via stdin, **not** `@@`:

  ```sh
  cat testcase | afl-showmap -o map.txt -- zig-out/bin/fuzz-stream
  ```

- **`afl-cmin`**: Do **not** use `@@`. Requires `AFL_NO_FORKSRV=1` with
  the bash version due to a bug in the Python `afl-cmin` (AFL++ 4.35c):

  ```sh
  AFL_NO_FORKSRV=1 /opt/homebrew/Cellar/afl++/4.35c/libexec/afl-cmin.bash \
    -i afl-out/fuzz-stream/default/queue -o corpus/stream-cmin \
    -- zig-out/bin/fuzz-stream
  ```

If you pass `@@` or a filename argument, `afl-showmap`/`afl-cmin`
will see only ~4 tuples (the C main paths) and produce useless results.
