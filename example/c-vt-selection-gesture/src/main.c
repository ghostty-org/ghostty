#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <ghostty/vt.h>

//! [selection-gesture-main]
static void vt_write(GhosttyTerminal terminal, const char *s) {
  ghostty_terminal_vt_write(terminal, (const uint8_t *)s, strlen(s));
}

static GhosttyGridRef ref_at(GhosttyTerminal terminal, uint16_t x, uint16_t y) {
  GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
  GhosttyPoint point = {
    .tag = GHOSTTY_POINT_TAG_ACTIVE,
    .value = { .coordinate = { .x = x, .y = y } },
  };

  GhosttyResult result = ghostty_terminal_grid_ref(terminal, point, &ref);
  assert(result == GHOSTTY_SUCCESS);
  return ref;
}

static void print_selection(
    GhosttyTerminal terminal,
    const char *label,
    const GhosttySelection *selection) {
  GhosttyTerminalSelectionFormatOptions opts =
      GHOSTTY_INIT_SIZED(GhosttyTerminalSelectionFormatOptions);
  opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
  opts.trim = true;
  opts.selection = selection;

  uint8_t *buf = NULL;
  size_t len = 0;
  GhosttyResult result = ghostty_terminal_selection_format_alloc(
      terminal, NULL, opts, &buf, &len);
  assert(result == GHOSTTY_SUCCESS);

  printf("%s: ", label);
  fwrite(buf, 1, len, stdout);
  printf("\n");

  ghostty_free(NULL, buf, len);
}

static GhosttySelectionGestureEvent new_event(
    GhosttySelectionGestureEventType type) {
  GhosttySelectionGestureEvent event = NULL;
  GhosttyResult result = ghostty_selection_gesture_event_new(NULL, &event, type);
  assert(result == GHOSTTY_SUCCESS);
  return event;
}

int main() {
  GhosttyTerminal terminal;
  GhosttyTerminalOptions opts = {
    .cols = 20,
    .rows = 4,
    .max_scrollback = 100,
  };
  GhosttyResult result = ghostty_terminal_new(NULL, &terminal, opts);
  assert(result == GHOSTTY_SUCCESS);

  vt_write(terminal, "hello world\r\nsecond line");

  GhosttySelectionGesture gesture = NULL;
  result = ghostty_selection_gesture_new(NULL, &gesture);
  assert(result == GHOSTTY_SUCCESS);

  GhosttySelectionGestureEvent press =
      new_event(GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS);
  GhosttySelectionGestureEvent drag =
      new_event(GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG);
  GhosttySelectionGestureEvent release =
      new_event(GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE);
  GhosttySelectionGestureEvent deep_press =
      new_event(GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DEEP_PRESS);

  GhosttySelectionGestureGeometry geometry = {
    .columns = 20,
    .cell_width = 10,
    .padding_left = 0,
    .screen_height = 40,
  };

  // Press in the first cell. A normal single press records the click anchor but
  // doesn't produce a selection yet, so we discard the optional output.
  GhosttyGridRef press_ref = ref_at(terminal, 0, 0);
  result = ghostty_selection_gesture_event_set(
      press, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &press_ref);
  assert(result == GHOSTTY_SUCCESS);

  GhosttySurfacePosition press_pos = { .x = 2, .y = 8 };
  result = ghostty_selection_gesture_event_set(
      press, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &press_pos);
  assert(result == GHOSTTY_SUCCESS);

  result = ghostty_selection_gesture_event(
      gesture, terminal, press, NULL);
  assert(result == GHOSTTY_NO_VALUE);

  // Drag across "hello". The drag event returns a selection snapshot that the
  // embedder can apply to its UI, copy, or format immediately.
  GhosttyGridRef drag_ref = ref_at(terminal, 4, 0);
  result = ghostty_selection_gesture_event_set(
      drag, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &drag_ref);
  assert(result == GHOSTTY_SUCCESS);

  GhosttySurfacePosition drag_pos = { .x = 46, .y = 8 };
  result = ghostty_selection_gesture_event_set(
      drag, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &drag_pos);
  assert(result == GHOSTTY_SUCCESS);

  result = ghostty_selection_gesture_event_set(
      drag, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geometry);
  assert(result == GHOSTTY_SUCCESS);

  GhosttySelection selection = GHOSTTY_INIT_SIZED(GhosttySelection);
  result = ghostty_selection_gesture_event(
      gesture, terminal, drag, &selection);
  assert(result == GHOSTTY_SUCCESS);
  print_selection(terminal, "drag", &selection);

  // Release updates gesture state but never produces a selection.
  result = ghostty_selection_gesture_event_set(
      release, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &drag_ref);
  assert(result == GHOSTTY_SUCCESS);
  result = ghostty_selection_gesture_event(
      gesture, terminal, release, NULL);
  assert(result == GHOSTTY_NO_VALUE);

  bool dragged = false;
  result = ghostty_selection_gesture_get(
      gesture, terminal, GHOSTTY_SELECTION_GESTURE_DATA_DRAGGED, &dragged);
  assert(result == GHOSTTY_SUCCESS);
  printf("dragged: %s\n", dragged ? "true" : "false");

  // Deep press uses the active click anchor to select the surrounding word.
  ghostty_selection_gesture_reset(gesture, terminal);
  GhosttyGridRef world_ref = ref_at(terminal, 6, 0);
  result = ghostty_selection_gesture_event_set(
      press, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &world_ref);
  assert(result == GHOSTTY_SUCCESS);
  result = ghostty_selection_gesture_event(
      gesture, terminal, press, NULL);
  assert(result == GHOSTTY_NO_VALUE);

  result = ghostty_selection_gesture_event(
      gesture, terminal, deep_press, &selection);
  assert(result == GHOSTTY_SUCCESS);
  print_selection(terminal, "deep press", &selection);

  ghostty_selection_gesture_event_free(deep_press);
  ghostty_selection_gesture_event_free(release);
  ghostty_selection_gesture_event_free(drag);
  ghostty_selection_gesture_event_free(press);
  ghostty_selection_gesture_free(gesture, terminal);
  ghostty_terminal_free(terminal);
  return 0;
}
//! [selection-gesture-main]
