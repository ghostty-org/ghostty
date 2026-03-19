#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// AFL++ fuzzer harness for Zig fuzz targets.
//
// This file is the C "glue" that connects AFL++'s runtime to Zig-defined
// fuzz test functions. We can't use AFL++'s compiler wrappers (afl-clang,
// afl-gcc) because the code under test is compiled with Zig, so we manually
// expand the AFL macros (__AFL_INIT, __AFL_LOOP, __AFL_FUZZ_INIT, etc.) and
// wire up the sanitizer coverage symbols ourselves.

// To ensure checks are not optimized out it is recommended to disable
// code optimization for the fuzzer harness main()
#pragma clang optimize off
#pragma GCC optimize("O0")

// Zig-exported entry points. zig_fuzz_init() performs one-time setup and
// zig_fuzz_test() runs one fuzz iteration on the given input buffer.
// The Zig object should export these.
void zig_fuzz_init();
void zig_fuzz_test(unsigned char*, size_t);

// Linker-provided symbols marking the boundaries of the __sancov_guards
// section. These must be declared extern so the linker provides the actual
// section boundaries from the instrumented code, rather than creating new
// variables that shadow them. On macOS (Mach-O), the linker uses a different
// naming convention for section boundaries than Linux (ELF), so we use asm
// labels to reference them.
#ifdef __APPLE__
extern uint32_t __start___sancov_guards __asm(
    "section$start$__DATA$__sancov_guards");
extern uint32_t __stop___sancov_guards __asm(
    "section$end$__DATA$__sancov_guards");
#else
extern uint32_t __start___sancov_guards;
extern uint32_t __stop___sancov_guards;
#endif

// Provided by afl-compiler-rt; initializes the guard array used by
// SanitizerCoverage's trace-pc-guard instrumentation mode.
void __sanitizer_cov_trace_pc_guard_init(uint32_t*, uint32_t*);

// Stubs for sanitizer coverage callbacks that the Zig-compiled code references
// but AFL's runtime (afl-compiler-rt) does not provide. Without these, linking
// would fail with undefined symbol errors.
__attribute__((visibility("default"))) __attribute__((
    tls_model("initial-exec"))) _Thread_local uintptr_t __sancov_lowest_stack;
void __sanitizer_cov_trace_pc_indir() {}
void __sanitizer_cov_8bit_counters_init() {}
void __sanitizer_cov_pcs_init() {}

// Manual expansion of __AFL_FUZZ_INIT().
//
// Enables shared-memory fuzzing: AFL++ writes test cases directly into
// shared memory (__afl_fuzz_ptr) instead of passing them via stdin, which
// is much faster. When not running under AFL++ (e.g. standalone execution),
// __afl_fuzz_ptr will be NULL and we fall back to reading from stdin into
// __afl_fuzz_alt (a 1 MB static buffer).
int __afl_sharedmem_fuzzing = 1;
extern __attribute__((visibility("default"))) unsigned int* __afl_fuzz_len;
extern __attribute__((visibility("default"))) unsigned char* __afl_fuzz_ptr;
unsigned char __afl_fuzz_alt[1048576];
unsigned char* __afl_fuzz_alt_ptr = __afl_fuzz_alt;

int main(int argc, char** argv) {
  // Tell AFL's coverage runtime about our guard section so it can track
  // which edges in the instrumented Zig code have been hit.
  __sanitizer_cov_trace_pc_guard_init(&__start___sancov_guards,
                                      &__stop___sancov_guards);

  // Manual expansion of __AFL_INIT() — deferred fork server mode.
  //
  // The magic string "##SIG_AFL_DEFER_FORKSRV##" is embedded in the binary
  // so AFL++'s tooling can detect that this harness uses deferred fork
  // server initialization. The `volatile` + `used` attributes prevent the
  // compiler/linker from stripping it. We then call __afl_manual_init() to
  // start the fork server at this point (after our setup) rather than at
  // the very beginning of main().
  static volatile const char* _A __attribute__((used, unused));
  _A = (const char*)"##SIG_AFL_DEFER_FORKSRV##";
#ifdef __APPLE__
  __attribute__((visibility("default"))) void _I(void) __asm__(
      "___afl_manual_init");
#else
  __attribute__((visibility("default"))) void _I(void) __asm__(
      "__afl_manual_init");
#endif
  _I();

  zig_fuzz_init();

  // Manual expansion of __AFL_FUZZ_TESTCASE_BUF.
  // Use shared memory buffer if available, otherwise fall back to the
  // static buffer (for standalone/non-AFL execution).
  unsigned char* buf = __afl_fuzz_ptr ? __afl_fuzz_ptr : __afl_fuzz_alt_ptr;

  // Manual expansion of __AFL_LOOP(UINT_MAX) — persistent mode loop.
  //
  // Persistent mode keeps the process alive across many test cases instead
  // of fork()'ing for each one, dramatically improving throughput. The magic
  // string "##SIG_AFL_PERSISTENT##" signals to AFL++ that this binary
  // supports persistent mode. __afl_persistent_loop() returns non-zero
  // while there are more inputs to process.
  //
  // When connected to AFL++, we loop UINT_MAX times (essentially forever,
  // AFL will restart us periodically). When running standalone, we loop
  // once so the harness can be used for manual testing/reproduction.
  while (({
    static volatile const char* _B __attribute__((used, unused));
    _B = (const char*)"##SIG_AFL_PERSISTENT##";
    extern __attribute__((visibility("default"))) int __afl_connected;
#ifdef __APPLE__
    __attribute__((visibility("default"))) int _L(unsigned int) __asm__(
        "___afl_persistent_loop");
#else
    __attribute__((visibility("default"))) int _L(unsigned int) __asm__(
        "__afl_persistent_loop");
#endif
    _L(__afl_connected ? UINT_MAX : 1);
  })) {
    // Manual expansion of __AFL_FUZZ_TESTCASE_LEN.
    // In shared-memory mode, the length is provided directly by AFL++.
    // In standalone mode, we read from stdin into the fallback buffer.
    int len =
        __afl_fuzz_ptr ? *__afl_fuzz_len
        : (*__afl_fuzz_len = read(0, __afl_fuzz_alt_ptr, 1048576)) == 0xffffffff
            ? 0
            : *__afl_fuzz_len;

    if (len >= 0) {
      zig_fuzz_test(buf, len);
    }
  }

  return 0;
}
