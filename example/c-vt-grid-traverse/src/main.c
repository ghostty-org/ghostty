#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <ghostty/vt.h>

//! [grid-ref-traverse]
int main() {
  // Create a small terminal
  GhosttyTerminal terminal;
  GhosttyTerminalOptions opts = {
    .cols = 10,
    .rows = 3,
    .max_scrollback = 0,
  };
  GhosttyResult result = ghostty_terminal_new(NULL, &terminal, opts);
  assert(result == GHOSTTY_SUCCESS);

  // Write some content so the grid has interesting data
  const char *text = "Hello!\r\n"    // Row 0: H e l l o !
                     "World\r\n"     // Row 1: W o r l d
                     "\033[1mBold";   // Row 2: B o l d (bold style)
  ghostty_terminal_vt_write(
      terminal, (const uint8_t *)text, strlen(text));

  // Get terminal dimensions
  uint16_t cols, rows;
  ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLS, &cols);
  ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ROWS, &rows);

  // Traverse the entire grid using grid refs
  for (uint16_t row = 0; row < rows; row++) {
    printf("Row %u: ", row);
    for (uint16_t col = 0; col < cols; col++) {
      // Resolve the point to a grid reference
      GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
      GhosttyPoint pt = {
        .tag = GHOSTTY_POINT_TAG_ACTIVE,
        .value = { .coordinate = { .x = col, .y = row } },
      };
      result = ghostty_terminal_grid_ref(terminal, pt, &ref);
      assert(result == GHOSTTY_SUCCESS);

      // Read the cell from the grid ref
      GhosttyCell cell;
      result = ghostty_grid_ref_cell(&ref, &cell);
      assert(result == GHOSTTY_SUCCESS);

      // Check if the cell has text
      bool has_text = false;
      ghostty_cell_get(cell, GHOSTTY_CELL_DATA_HAS_TEXT, &has_text);

      if (has_text) {
        uint32_t codepoint = 0;
        ghostty_cell_get(cell, GHOSTTY_CELL_DATA_CODEPOINT, &codepoint);
        printf("%c", (char)codepoint);
      } else {
        printf(".");
      }
    }

    // Also inspect the row for wrap state
    GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
    GhosttyPoint pt = {
      .tag = GHOSTTY_POINT_TAG_ACTIVE,
      .value = { .coordinate = { .x = 0, .y = row } },
    };
    ghostty_terminal_grid_ref(terminal, pt, &ref);

    GhosttyRow grid_row;
    ghostty_grid_ref_row(&ref, &grid_row);

    bool wrap = false;
    ghostty_row_get(grid_row, GHOSTTY_ROW_DATA_WRAP, &wrap);
    printf(" (wrap=%s", wrap ? "true" : "false");

    // Check the style of the first cell with text
    GhosttyStyle style = GHOSTTY_INIT_SIZED(GhosttyStyle);
    ghostty_grid_ref_style(&ref, &style);
    printf(", bold=%s)\n", style.bold ? "true" : "false");
  }

  ghostty_terminal_free(terminal);
  return 0;
}
//! [grid-ref-traverse]
