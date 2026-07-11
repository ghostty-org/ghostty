#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <ghostty/vt.h>

//! [compression-idle-step]
// Perform one step after the application's idle timer fires. Returning true
// asks the application to schedule another step while the terminal is idle.
static bool compression_idle_step(GhosttyTerminal terminal) {
  GhosttyTerminalCompressionResult compression_result;
  GhosttyResult result = ghostty_terminal_compress(
      terminal,
      GHOSTTY_TERMINAL_COMPRESSION_MODE_INCREMENTAL,
      &compression_result);
  assert(result == GHOSTTY_SUCCESS);

  switch (compression_result) {
    case GHOSTTY_TERMINAL_COMPRESSION_RESULT_PENDING:
      return true;
    case GHOSTTY_TERMINAL_COMPRESSION_RESULT_COMPLETE:
    case GHOSTTY_TERMINAL_COMPRESSION_RESULT_UNSUPPORTED:
      return false;
    default:
      assert(false);
      return false;
  }
}
//! [compression-idle-step]

int main(void) {
  GhosttyTerminal terminal;
  GhosttyTerminalOptions opts = {
    .cols = 80,
    .rows = 24,
    .max_scrollback = 10 * 1024 * 1024,
  };
  GhosttyResult result = ghostty_terminal_new(NULL, &terminal, opts);
  assert(result == GHOSTTY_SUCCESS);

  //! [compression-activity]
  uint64_t compression_activity;
  result = ghostty_terminal_compression_activity(
      terminal,
      &compression_activity);
  assert(result == GHOSTTY_SUCCESS);

  // Terminal mutations may change the token. When it changes, restart the
  // application's idle timer rather than compressing on the output path.
  const char *line = "repeated and compressible terminal history\r\n";
  for (size_t i = 0; i < 4000; i++) {
    ghostty_terminal_vt_write(
        terminal,
        (const uint8_t *)line,
        strlen(line));
  }

  uint64_t new_activity;
  result = ghostty_terminal_compression_activity(terminal, &new_activity);
  assert(result == GHOSTTY_SUCCESS);
  if (new_activity != compression_activity) {
    compression_activity = new_activity;
    // Restart the application's compression idle timer here.
  }
  //! [compression-activity]

  // Simulate the idle timer and its short pending-work continuations.
  while (compression_idle_step(terminal)) {}

  ghostty_terminal_free(terminal);
  return 0;
}
