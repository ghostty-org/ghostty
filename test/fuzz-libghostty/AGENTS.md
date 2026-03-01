# AFL++ Fuzzer for Libghostty

- `ghostty-fuzz` is a binary built with `afl-cc`
- Build `ghostty-fuzz` with `zig build`
- After running `afl-cmin`/`afl-tmin`, run `corpus/sanitize-filenames.sh`
  before committing to replace colons with underscores (colons are invalid
  on Windows NTFS).

## Important: stdin-based input

The instrumented binary (`afl.c` harness) reads fuzz input from **stdin**,
not from a file argument. This affects how you invoke AFL++ tools:

- **`afl-fuzz`**: Uses shared-memory fuzzing automatically; `@@` works
  because AFL writes directly to shared memory, bypassing file I/O.
- **`afl-showmap`**: Must pipe input via stdin, **not** `@@`:

  ```sh
  cat testcase | afl-showmap -o map.txt -- zig-out/bin/ghostty-fuzz
  ```

- **`afl-cmin`**: Do **not** use `@@`. Requires `AFL_NO_FORKSRV=1` with
  the bash version due to a bug in the Python `afl-cmin` (AFL++ 4.35c):

  ```sh
  AFL_NO_FORKSRV=1 /opt/homebrew/Cellar/afl++/4.35c/libexec/afl-cmin.bash \
    -i afl-out/default/queue -o corpus/vt-parser-cmin \
    -- zig-out/bin/ghostty-fuzz
  ```

- **`afl-tmin`**: Also requires `AFL_NO_FORKSRV=1`, no `@@`:

  ```sh
  AFL_NO_FORKSRV=1 afl-tmin -i <input> -o <output> -- zig-out/bin/ghostty-fuzz
  ```

If you pass `@@` or a filename argument, `afl-showmap`/`afl-cmin`/`afl-tmin`
will see only ~4 tuples (the C main paths) and produce useless results.
