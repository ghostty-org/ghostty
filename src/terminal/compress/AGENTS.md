# Terminal Compression

Guidance for the codecs and the compressed page representation
(`Page.zig`) in this directory. These compress terminal page backing
memory (`terminal.Page`).

## Priorities

When making tradeoffs, in order:

1. **Compression ratio on page-shaped data.** Encoded bytes are retained
   scrollback memory, and raw `terminal.Page` backing memory is the only
   thing we actually compress. Ratio on text files or synthetic data is a
   secondary signal.
2. **Decompression throughput.** Pages are compressed once when they go
   cold but restored on demand (scrollback access, search, inspection), so
   restore latency is felt directly.
3. **Compression throughput.** Runs on idle pages in the background; being
   fast is nice, being slow is tolerable.

## Testing

- Targeted tests: `zig build test -Dtest-filter=<codec>`
- Prefer `zig build test-lib-vt -Dtest-filter=<codec>` when practical;
  this code ships in libghostty-vt.
- Codecs must keep building for `wasm32-freestanding` (libghostty-vt):
  no libc, no `src/simd` (Highway) dependencies. Verify with
  `zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall`.
- Every codec needs a differential property suite: round-trip identity,
  an independent format walker, wrong-size output rejection, and
  corruption/truncation decoding. Keep a light version in normal unit
  tests and gate the exhaustive version behind an environment variable so
  the default test suite stays fast.

## Verifying Correctness

- Decoders must be memory-safe for arbitrary input bytes. Every blind or
  wide copy needs a stated margin argument bounding it by the output
  buffer; keep those arguments in comments next to the code.
- Writing scratch bytes past a copy's logical end is safe only inside the
  output buffer, because in-order decoding rewrites them before any match
  can read them back. Do not weaken the exact-size output contract.
- When a change should not alter compressor output, prove it: compare
  encoded sizes (or a sequence-count fingerprint) on the same corpus
  before and after. Ratio drift is a functional change, not noise.

## Benchmarking

- Use `ghostty-bench +page-compression` (see `src/benchmark/AGENTS.md`
  for the general workflow). Modes: `compress`, `decompress`, `store`,
  and `report` for ratio.
- Build: `zig build -Demit-bench -Doptimize=ReleaseFast -Demit-macos-app=false`
- The most representative corpus is a raw dump of real page backing
  memory, chunked at the page size (400 KiB on ReleaseFast targets).
  Supplement with a text corpus and random bytes for worst cases, but
  weigh page corpora highest per the priorities above. Keep corpora
  outside the repository and reuse identical files across comparisons.
- `ghostty-bench +scrollback-compression` measures the PageList
  transitions around the codec rather than the codec itself.
- For fast iteration, keep codecs dependent only on `std` so a standalone
  harness can build them directly with `zig build-exe -O ReleaseFast` and
  time the codec in-process (report min-of-N, verify round-trips).
- Measure one change at a time and re-measure the final state; run-to-run
  noise is a few percent, so re-run before believing small deltas.

## Performance Notes

- Real page data decodes as millions of tiny operations (in LZ4: mostly
  zero literals plus a 4-18 byte match). Per-item overhead dominates, so
  branch-light fast paths with blind fixed-size copies win.
- Wide copies are the only SIMD that pays here. Vectorized compares and
  other wide-stride tricks measured as net losses because matches are
  short; prefer the simple word loop unless a measurement on page corpora
  says otherwise.
- `@memcpy` beats stride loops only for long copies (roughly 64 bytes and
  up); call overhead loses below that.

## LZ4 Specific

- The codec is `lz4.zig`, an allocation-free raw block (not frame)
  implementation. Blocks do not carry their decoded size; callers supply
  an exact-size output buffer.
- Tests: `zig build test -Dtest-filter=lz4`. The differential suite is
  `lz4_differential.zig`; run the exhaustive version for any codec
  change:
  `GHOSTTY_LZ4_SLOW=1 zig build test -Dtest-filter="lz4 differential"`
- The compressor must keep the standard format restrictions (final five
  bytes literal, matches start at least twelve bytes before the end) so
  blocks stay consumable by optimized external decoders. The differential
  walker checks this.
