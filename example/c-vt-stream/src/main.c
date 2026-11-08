#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <ghostty/vt.h>

int main(void) {
  //! [vt-stream-init]
  // Create a terminal
  GhosttyTerminal terminal;
  GhosttyResult result = ghostty_terminal_new(NULL, &terminal, 80, 24);
  assert(result == GHOSTTY_SUCCESS);
  //! [vt-stream-init]

  //! [vt-stream-write]
  // Feed VT data into the terminal
  const char *text = "Hello, World!\r\n";
  ghostty_terminal_vt_write(terminal, (const uint8_t *)text, strlen(text));

  // ANSI color codes: ESC[1;32m = bold green, ESC[0m = reset
  text = "\x1b[1;32mGreen Text\x1b[0m\r\n";
  ghostty_terminal_vt_write(terminal, (const uint8_t *)text, strlen(text));

  // Cursor positioning: ESC[1;1H = move to row 1, column 1
  text = "\x1b[1;1HTop-left corner\r\n";
  ghostty_terminal_vt_write(terminal, (const uint8_t *)text, strlen(text));

  // Cursor movement: ESC[5B = move down 5 lines
  text = "\x1b[5B";
  ghostty_terminal_vt_write(terminal, (const uint8_t *)text, strlen(text));
  text = "Moved down!\r\n";
  ghostty_terminal_vt_write(terminal, (const uint8_t *)text, strlen(text));

  // Erase line: ESC[2K = clear entire line
  text = "\x1b[2K";
  ghostty_terminal_vt_write(terminal, (const uint8_t *)text, strlen(text));
  text = "New content\r\n";
  ghostty_terminal_vt_write(terminal, (const uint8_t *)text, strlen(text));

  // Multiple lines
  text = "Line A\r\nLine B\r\nLine C\r\n";
  ghostty_terminal_vt_write(terminal, (const uint8_t *)text, strlen(text));
  //! [vt-stream-write]

  //! [vt-stream-read]
  // Get the final terminal state as a plain string using the formatter
  GhosttyFormatter formatter;
  result = ghostty_formatter_terminal_new(NULL, &formatter, terminal);
  assert(result == GHOSTTY_SUCCESS);

  GhosttyFormatterFormat emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
  result = ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EMIT, &emit);
  assert(result == GHOSTTY_SUCCESS);

  bool trim = true;
  result = ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_TRIM, &trim);
  assert(result == GHOSTTY_SUCCESS);

  uint8_t *buf = NULL;
  size_t len = 0;
  result = ghostty_formatter_format_alloc(formatter, NULL, &buf, &len);
  assert(result == GHOSTTY_SUCCESS);

  fwrite(buf, 1, len, stdout);
  printf("\n");

  ghostty_free(NULL, buf, len);
  ghostty_formatter_free(formatter);
  //! [vt-stream-read]

  //! [vt-stream-render]
  // Create these once and reuse them for every frame.
  GhosttyRenderState render_state = NULL;
  result = ghostty_render_state_new(NULL, &render_state);
  assert(result == GHOSTTY_SUCCESS);

  GhosttyRenderStateRowIterator row_iter = NULL;
  result = ghostty_render_state_row_iterator_new(NULL, &row_iter);
  assert(result == GHOSTTY_SUCCESS);

  GhosttyRenderStateRowCells cells = NULL;
  result = ghostty_render_state_row_cells_new(NULL, &cells);
  assert(result == GHOSTTY_SUCCESS);

  // Capture the frame. This is the only step that reads the terminal.
  result = ghostty_render_state_update(render_state, terminal);
  assert(result == GHOSTTY_SUCCESS);

  // Visit only the rows that changed. In the first frame, that's all of them.
  result = ghostty_render_state_get(
      render_state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &row_iter);
  assert(result == GHOSTTY_SUCCESS);

  uint16_t y = 0;
  while (ghostty_render_state_row_iterator_next_dirty(row_iter, &y)) {
    result = ghostty_render_state_row_get(
        row_iter, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells);
    assert(result == GHOSTTY_SUCCESS);

    while (ghostty_render_state_row_cells_next(cells)) {
      GhosttyStyle style;
      result = ghostty_render_state_row_cells_get(
          cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);
      assert(result == GHOSTTY_SUCCESS);

      uint8_t bytes[64];
      GhosttyBuffer grapheme = {.ptr = bytes, .cap = sizeof(bytes)};
      result = ghostty_render_state_row_cells_get(
          cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &grapheme);
      assert(result == GHOSTTY_SUCCESS);

      // A real renderer draws the cell here. We print it, with its bold
      // style, which the plain text from the formatter didn't have.
      if (grapheme.len == 0) {
        putchar(' ');
        continue;
      }
      bool bold = style.flags & GHOSTTY_STYLE_FLAG_BOLD;
      if (bold) printf("\x1b[1m");
      fwrite(bytes, 1, grapheme.len, stdout);
      if (bold) printf("\x1b[0m");
    }
    putchar('\n');
  }

  // The frame is drawn, so the next one only reports new changes.
  result = ghostty_render_state_clean(render_state);
  assert(result == GHOSTTY_SUCCESS);
  //! [vt-stream-render]

  ghostty_render_state_row_cells_free(cells);
  ghostty_render_state_row_iterator_free(row_iter);
  ghostty_render_state_free(render_state);
  ghostty_terminal_free(terminal);
  return 0;
}
