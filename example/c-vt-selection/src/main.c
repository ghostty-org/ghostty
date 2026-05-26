#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <ghostty/vt.h>

//! [selection-main]
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
  GhosttyFormatterTerminalOptions opts = GHOSTTY_INIT_SIZED(GhosttyFormatterTerminalOptions);
  opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
  opts.trim = true;
  opts.selection = selection;

  GhosttyFormatter formatter;
  GhosttyResult result = ghostty_formatter_terminal_new(
      NULL, &formatter, terminal, opts);
  assert(result == GHOSTTY_SUCCESS);

  uint8_t *buf = NULL;
  size_t len = 0;
  result = ghostty_formatter_format_alloc(formatter, NULL, &buf, &len);
  assert(result == GHOSTTY_SUCCESS);

  printf("%s: ", label);
  fwrite(buf, 1, len, stdout);
  printf("\n");

  ghostty_free(NULL, buf, len);
  ghostty_formatter_free(formatter);
}

int main() {
  GhosttyTerminal terminal;
  GhosttyTerminalOptions opts = {
    .cols = 80,
    .rows = 8,
    .max_scrollback = 0,
  };
  GhosttyResult result = ghostty_terminal_new(NULL, &terminal, opts);
  assert(result == GHOSTTY_SUCCESS);

  // A realistic shell transcript with OSC 133 semantic prompt markers.
  // Ghostty uses these markers to distinguish prompt/input from command
  // output for semantic line and output selections.
  vt_write(terminal,
      "\033]133;A\007$ "           // Prompt starts: "$ "
      "\033]133;B\007git status"  // Input starts: "git status"
      "\033]133;C\007\r\n"        // Output starts after Enter
      "On branch main\r\n"
      "nothing to commit, working tree clean");

  GhosttySelection selection = GHOSTTY_INIT_SIZED(GhosttySelection);

  // Double-click style word selection under the cursor.
  GhosttyTerminalSelectWordOptions word = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectWordOptions);
  word.ref = ref_at(terminal, 6, 0); // the "status" in "git status"
  result = ghostty_terminal_select_word(terminal, &word, &selection);
  assert(result == GHOSTTY_SUCCESS);
  print_selection(terminal, "word", &selection);

  //! [selection-word-between]
  // Double-click-and-drag style selection. Suppose the user double-clicks
  // "git" and drags to "status". The pointer may pass over whitespace, so
  // select the nearest word between the original click and current drag point
  // in both directions, then combine the outer word bounds.
  GhosttyGridRef click_ref = ref_at(terminal, 2, 0); // the "git" in "git status"
  GhosttyGridRef drag_ref = ref_at(terminal, 6, 0);  // the "status" in "git status"

  GhosttyTerminalSelectWordBetweenOptions start_word_opts =
      GHOSTTY_INIT_SIZED(GhosttyTerminalSelectWordBetweenOptions);
  start_word_opts.start = click_ref;
  start_word_opts.end = drag_ref;

  GhosttySelection start_word = GHOSTTY_INIT_SIZED(GhosttySelection);
  result = ghostty_terminal_select_word_between(
      terminal, &start_word_opts, &start_word);
  assert(result == GHOSTTY_SUCCESS);

  GhosttyTerminalSelectWordBetweenOptions end_word_opts =
      GHOSTTY_INIT_SIZED(GhosttyTerminalSelectWordBetweenOptions);
  end_word_opts.start = drag_ref;
  end_word_opts.end = click_ref;

  GhosttySelection end_word = GHOSTTY_INIT_SIZED(GhosttySelection);
  result = ghostty_terminal_select_word_between(
      terminal, &end_word_opts, &end_word);
  assert(result == GHOSTTY_SUCCESS);

  GhosttySelection drag_selection = GHOSTTY_INIT_SIZED(GhosttySelection);
  drag_selection.start = start_word.start;
  drag_selection.end = end_word.end;
  print_selection(terminal, "double-click drag", &drag_selection);
  //! [selection-word-between]

  // Triple-click style line selection. With semantic prompt boundaries enabled,
  // this selects only the input area rather than the leading "$ " prompt.
  GhosttyTerminalSelectLineOptions line = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectLineOptions);
  line.ref = ref_at(terminal, 2, 0); // the "git status" input area
  line.semantic_prompt_boundary = true;
  result = ghostty_terminal_select_line(terminal, &line, &selection);
  assert(result == GHOSTTY_SUCCESS);
  print_selection(terminal, "line", &selection);

  // Select exactly the command output for the command under the cursor.
  result = ghostty_terminal_select_output(
      terminal, ref_at(terminal, 0, 1), &selection);
  assert(result == GHOSTTY_SUCCESS);
  print_selection(terminal, "output", &selection);

  // Select all visible content.
  result = ghostty_terminal_select_all(terminal, &selection);
  assert(result == GHOSTTY_SUCCESS);
  print_selection(terminal, "all", &selection);

  ghostty_terminal_free(terminal);
  return 0;
}
//! [selection-main]
