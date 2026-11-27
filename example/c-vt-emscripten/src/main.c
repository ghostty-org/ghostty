/* Run with example/c-vt-emscripten/run.sh. */
#include <ghostty/vt.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef TEST_THREADS
#include <pthread.h>
#endif

#define FUNCTIONS(X)                \
  X(ghostty_terminal_new)           \
  X(ghostty_terminal_free)          \
  X(ghostty_terminal_resize)        \
  X(ghostty_terminal_vt_write)      \
  X(ghostty_formatter_terminal_new) \
  X(ghostty_formatter_format_alloc) \
  X(ghostty_formatter_free)         \
  X(ghostty_free)                   \
  X(ghostty_sys_set)                \
  X(ghostty_sys_log_stderr)

#ifdef TEST_DYNAMIC
#include <dlfcn.h>
#define DECLARE(name) static __typeof__(&name) api_##name;
FUNCTIONS(DECLARE)
#define API(name) api_##name
#else
#define API(name) name
#endif

static void check(bool condition, const char* message) {
  if (!condition) {
    fprintf(stderr, "%s\n", message);
    exit(EXIT_FAILURE);
  }
}

static void check_result(GhosttyResult result, const char* operation) {
  if (result != GHOSTTY_SUCCESS) {
    fprintf(stderr, "%s failed: %d\n", operation, (int)result);
    exit(EXIT_FAILURE);
  }
}

typedef struct {
  size_t live_bytes;
  size_t page_allocations;
} Counters;

static void* dirty_alloc(void* ctx,
                         size_t len,
                         uint8_t alignment,
                         uintptr_t ret_addr) {
  Counters* counters = ctx;
  (void)ret_addr;
  size_t align = (size_t)1 << alignment;
  check(align <= 16, "Allocation requires more than 16-byte alignment");
  if (align < sizeof(void*))
    align = sizeof(void*);
  void* memory = aligned_alloc(align, (len + align - 1) & ~(align - 1));
  if (memory) {
    memset(memory, 0xa5, len);
    counters->live_bytes += len;
    if (len >= 65536 && align == 16)
      counters->page_allocations++;
  }
  return memory;
}

static void dirty_free(void* ctx,
                       void* memory,
                       size_t len,
                       uint8_t alignment,
                       uintptr_t ret_addr) {
  Counters* counters = ctx;
  (void)alignment;
  (void)ret_addr;
  check(counters->live_bytes >= len, "Allocator byte count underflow");
  counters->live_bytes -= len;
  memset(memory, 0x5a, len);
  free(memory);
}

static const GhosttyAllocatorVtable vtable = {
    .alloc = dirty_alloc,
    .free = dirty_free,
};

static void exercise(const GhosttyAllocator* allocator, int passes,
                     int row_count, uint16_t resize_cols) {
  /* Keep host allocations live while Ghostty grows and reuses its heap. */
  unsigned char* host = malloc(65536);
  check(host != NULL, "Host allocation failed");
  memset(host, 0x3c, 65536);
  for (int pass = 0; pass < passes; pass++) {
    GhosttyTerminal terminal = NULL;
    GhosttyResult result =
        API(ghostty_terminal_new)(allocator, &terminal, 80, 24);
    check_result(result, "ghostty_terminal_new");
    const char* line = "\033[31mhello wasm\033[0m\r\n";
    for (int row = 0; row < row_count; row++)
      API(ghostty_terminal_vt_write)(terminal, (const uint8_t*)line,
                                     strlen(line));
    /* Exercise reflow in both directions. */
    result = API(ghostty_terminal_resize)(terminal, resize_cols, 24, 8, 16);
    check_result(result, "ghostty_terminal_resize");
    result = API(ghostty_terminal_resize)(terminal, 80, 24, 8, 16);
    check_result(result, "ghostty_terminal_resize");
    API(ghostty_terminal_vt_write)(terminal, (const uint8_t*)line,
                                   strlen(line));
    GhosttyFormatter formatter = NULL;
    result =
        API(ghostty_formatter_terminal_new)(allocator, &formatter, terminal);
    check_result(result, "ghostty_formatter_terminal_new");
    uint8_t* buffer = NULL;
    size_t length = 0;
    result = API(ghostty_formatter_format_alloc)(formatter, allocator, &buffer,
                                                 &length);
    check_result(result, "ghostty_formatter_format_alloc");
    char* copy = malloc(length + 1);
    check(copy != NULL, "Output allocation failed");
    memcpy(copy, buffer, length);
    copy[length] = '\0';
    check(strstr(copy, "hello wasm") != NULL,
          "Formatted output is missing text");
    free(copy);
    API(ghostty_free)(allocator, buffer, length);
    API(ghostty_formatter_free)(formatter);
    API(ghostty_terminal_free)(terminal);
    if (allocator)
      check(((Counters*)allocator->ctx)->live_bytes == 0,
            "Custom allocator leaked memory");
    for (size_t i = 0; i < 65536; i++)
      check(host[i] == 0x3c, "Host allocation was corrupted");
  }
  free(host);
}

static void exercise_logging(void) {
  GhosttyTerminal terminal = NULL;
  check_result(API(ghostty_terminal_new)(NULL, &terminal, 16, 2),
               "ghostty_terminal_new for logging");
  /* An invalid CSI erase-line command emits a warning through std.log,
   * the installed C callback, and finally Emscripten's stderr. */
  const char* invalid = "\033[9K";
  API(ghostty_terminal_vt_write)(terminal, (const uint8_t*)invalid,
                                 strlen(invalid));
  API(ghostty_terminal_free)(terminal);
}

#ifdef TEST_THREADS
static void* thread_main(void* context) {
  pthread_barrier_t* barrier = context;
  int result = pthread_barrier_wait(barrier);
  check(result == 0 || result == PTHREAD_BARRIER_SERIAL_THREAD,
        "pthread_barrier_wait failed");
  exercise_logging();
  Counters counters = {0};
  GhosttyAllocator allocator = {.ctx = &counters, .vtable = &vtable};
  exercise(NULL, 3, 64, 120);
  exercise(&allocator, 3, 64, 120);
  check(counters.page_allocations > 0,
        "Thread's custom allocator did not allocate terminal pages");
  return NULL;
}

static void exercise_threads(void) {
  pthread_barrier_t barrier;
  check(pthread_barrier_init(&barrier, NULL, 2) == 0,
        "pthread_barrier_init failed");
  pthread_t threads[2];
  for (int i = 0; i < 2; i++)
    check(pthread_create(&threads[i], NULL, thread_main, &barrier) == 0,
          "pthread_create failed");
  for (int i = 0; i < 2; i++)
    check(pthread_join(threads[i], NULL) == 0, "pthread_join failed");
  check(pthread_barrier_destroy(&barrier) == 0, "pthread_barrier_destroy failed");
  puts("Emscripten pthread tests passed");
}
#endif

int main(void) {
#ifdef TEST_DYNAMIC
  void* handle = dlopen("/libghostty-vt.so", RTLD_NOW | RTLD_LOCAL);
  check(handle != NULL, "dlopen failed");
#define LOAD(name)                                      \
  api_##name = (__typeof__(&name))dlsym(handle, #name); \
  check(api_##name != NULL, "dlsym failed: " #name);
  FUNCTIONS(LOAD)
#endif
  /* System callbacks are process-global: install before creating threads. */
  check_result(API(ghostty_sys_set)(GHOSTTY_SYS_OPT_LOG,
                                    (const void*)API(ghostty_sys_log_stderr)),
               "install stderr logger");
#ifdef TEST_THREADS
  exercise_threads();
#endif
  exercise_logging();
  check_result(API(ghostty_sys_set)(GHOSTTY_SYS_OPT_LOG, NULL),
               "clear stderr logger");
  puts("Emscripten stderr logging exercised");
  exercise(NULL, 3, 2000, 5000);
  Counters counters = {0};
  GhosttyAllocator allocator = {.ctx = &counters, .vtable = &vtable};
  exercise(&allocator, 3, 2000, 5000);
  check(counters.page_allocations > 0,
        "Custom allocator did not allocate terminal pages");
  /* A single row wider than the standard page capacity cannot use the
   * normal page pool. Cover initial allocation and reflow of that page. */
  GhosttyTerminal wide = NULL;
  GhosttyResult result =
      API(ghostty_terminal_new)(&allocator, &wide, UINT16_MAX, 1);
  check_result(result, "ghostty_terminal_new");
  result = API(ghostty_terminal_resize)(wide, 80, 1, 8, 16);
  check_result(result, "ghostty_terminal_resize");
  API(ghostty_terminal_free)(wide);
  check(counters.live_bytes == 0, "Custom allocator leaked memory");
#ifdef TEST_DYNAMIC
  int close_result = dlclose(handle);
  check(close_result == 0, "dlclose failed");
#endif
  puts("Emscripten allocation tests passed");
  return 0;
}
