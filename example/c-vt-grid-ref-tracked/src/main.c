#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <ghostty/vt.h>

//! [grid-ref-tracked]
static uint32_t codepoint_at_tracked_ref(GhosttyTrackedGridRef tracked) {
  GhosttyGridRef snapshot = GHOSTTY_INIT_SIZED(GhosttyGridRef);
  GhosttyResult result = ghostty_tracked_grid_ref_snapshot(tracked, &snapshot);
  assert(result == GHOSTTY_SUCCESS);

  GhosttyCell cell;
  result = ghostty_grid_ref_cell(&snapshot, &cell);
  assert(result == GHOSTTY_SUCCESS);

  bool has_text = false;
  ghostty_cell_get(cell, GHOSTTY_CELL_DATA_HAS_TEXT, &has_text);
  assert(has_text);

  uint32_t codepoint = 0;
  ghostty_cell_get(cell, GHOSTTY_CELL_DATA_CODEPOINT, &codepoint);
  return codepoint;
}

int main() {
  GhosttyTerminal terminal;
  GhosttyTerminalOptions opts = {
    .cols = 8,
    .rows = 3,
    .max_scrollback = 100,
  };
  GhosttyResult result = ghostty_terminal_new(NULL, &terminal, opts);
  assert(result == GHOSTTY_SUCCESS);

  const char *text = "alpha\r\n"
                     "bravo\r\n"
                     "charlie";
  ghostty_terminal_vt_write(
      terminal, (const uint8_t *)text, strlen(text));

  GhosttyTrackedGridRef tracked = NULL;
  GhosttyPoint alpha = {
    .tag = GHOSTTY_POINT_TAG_ACTIVE,
    .value = { .coordinate = { .x = 0, .y = 0 } },
  };
  result = ghostty_terminal_grid_ref_track(terminal, alpha, &tracked);
  assert(result == GHOSTTY_SUCCESS);

  // Writing another line scrolls the original "alpha" row into scrollback.
  // The tracked ref still follows the same cell.
  const char *more = "\r\ndelta";
  ghostty_terminal_vt_write(
      terminal, (const uint8_t *)more, strlen(more));

  assert(ghostty_tracked_grid_ref_has_value(tracked));
  printf("tracked codepoint after scroll: %c\n",
      (char)codepoint_at_tracked_ref(tracked));

  GhosttyPointCoordinate screen = {0};
  result = ghostty_tracked_grid_ref_point(
      tracked, GHOSTTY_POINT_TAG_SCREEN, &screen);
  assert(result == GHOSTTY_SUCCESS);
  printf("tracked screen point: %u,%u\n", screen.x, screen.y);

  // Resetting the terminal discards the old grid contents. The tracked
  // handle remains valid, but no longer has a meaningful location.
  ghostty_terminal_reset(terminal);
  assert(!ghostty_tracked_grid_ref_has_value(tracked));

  GhosttyGridRef discarded = GHOSTTY_INIT_SIZED(GhosttyGridRef);
  result = ghostty_tracked_grid_ref_snapshot(tracked, &discarded);
  assert(result == GHOSTTY_NO_VALUE);

  // The same handle can be moved to a new point after it loses its value.
  const char *replacement = "echo";
  ghostty_terminal_vt_write(
      terminal, (const uint8_t *)replacement, strlen(replacement));

  GhosttyPoint echo = {
    .tag = GHOSTTY_POINT_TAG_ACTIVE,
    .value = { .coordinate = { .x = 0, .y = 0 } },
  };
  result = ghostty_tracked_grid_ref_set(tracked, terminal, echo);
  assert(result == GHOSTTY_SUCCESS);
  assert(ghostty_tracked_grid_ref_has_value(tracked));
  printf("tracked codepoint after reset/set: %c\n",
      (char)codepoint_at_tracked_ref(tracked));

  ghostty_tracked_grid_ref_free(tracked);
  ghostty_terminal_free(terminal);
  return 0;
}
//! [grid-ref-tracked]
