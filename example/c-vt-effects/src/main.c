#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <ghostty/vt.h>

//! [effects-write-pty]
void on_write_pty(GhosttyTerminal terminal,
                  void* userdata,
                  const uint8_t* data,
                  size_t len) {
  (void)terminal;
  (void)userdata;
  printf("  write_pty (%zu bytes): ", len);
  fwrite(data, 1, len, stdout);
  printf("\n");
}
//! [effects-write-pty]

//! [effects-bell]
void on_bell(GhosttyTerminal terminal, void* userdata) {
  (void)terminal;
  int* count = (int*)userdata;
  (*count)++;
  printf("  bell! (count=%d)\n", *count);
}
//! [effects-bell]

//! [effects-title-changed]
void on_title_changed(GhosttyTerminal terminal, void* userdata) {
  (void)userdata;
  // Query the cursor position to confirm the terminal processed the
  // title change (the title itself is tracked by the embedder via the
  // OSC parser or its own state).
  uint16_t col = 0;
  ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_X, &col);
  printf("  title changed (cursor at col %u)\n", col);
}
//! [effects-title-changed]

//! [effects-clipboard-write]
GhosttyClipboardWriteResult on_clipboard_write(
    GhosttyTerminal terminal,
    void* userdata,
    const GhosttyClipboardWrite* write) {
  (void)terminal;
  (void)userdata;

  printf("  clipboard write (location=%d, contents=%zu)\n",
         (int)write->location, write->contents_len);
  if (write->contents_len == 0) {
    printf("    clear\n");
  }

  for (size_t i = 0; i < write->contents_len; i++) {
    const GhosttyClipboardContent* content = &write->contents[i];
    printf("    ");
    if (content->mime.len > 0) {
      fwrite(content->mime.ptr, 1, content->mime.len, stdout);
    }
    printf(" (%zu bytes): ", content->data.len);
    if (content->data.len > 0) {
      fwrite(content->data.ptr, 1, content->data.len, stdout);
    }
    printf("\n");
  }

  return GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS;
}
//! [effects-clipboard-write]

//! [effects-register]
int main() {
  // Create a terminal
  GhosttyTerminal terminal = NULL;
  GhosttyTerminalOptions opts = {
    .cols = 80,
    .rows = 24,
    .max_scrollback = 0,
  };
  if (ghostty_terminal_new(NULL, &terminal, opts) != GHOSTTY_SUCCESS) {
    fprintf(stderr, "Failed to create terminal\n");
    return 1;
  }

  // Set up userdata — a simple bell counter
  int bell_count = 0;
  ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, &bell_count);

  // Register effect callbacks
  ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY,
      (const void *)on_write_pty);
  ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_BELL,
      (const void *)on_bell);
  ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED,
      (const void *)on_title_changed);
  ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE,
      (const void *)on_clipboard_write);

  // Feed VT data that triggers effects:

  // 1. Bell (BEL = 0x07)
  printf("Sending BEL:\n");
  const uint8_t bel = 0x07;
  ghostty_terminal_vt_write(terminal, &bel, 1);

  // 2. Title change (OSC 2 ; <title> ST)
  printf("Sending title change:\n");
  const char* title_seq = "\x1B]2;Hello Effects\x1B\\";
  ghostty_terminal_vt_write(terminal, (const uint8_t*)title_seq,
                            strlen(title_seq));

  // 3. Device status report (DECRQM for wraparound mode ?7)
  //    triggers write_pty with the response
  printf("Sending DECRQM query:\n");
  const char* decrqm = "\x1B[?7$p";
  ghostty_terminal_vt_write(terminal, (const uint8_t*)decrqm,
                            strlen(decrqm));

  // 4. Clipboard write (OSC 52 ; c ; <base64 data> ST)
  printf("Sending clipboard write:\n");
  const char* clipboard_seq =
      "\x1B]52;c;SGVsbG8gY2xpcGJvYXJk\x1B\\";
  ghostty_terminal_vt_write(terminal, (const uint8_t*)clipboard_seq,
                            strlen(clipboard_seq));

  // 5. Another bell to show the counter increments
  printf("Sending another BEL:\n");
  ghostty_terminal_vt_write(terminal, &bel, 1);

  printf("Total bells: %d\n", bell_count);

  ghostty_terminal_free(terminal);
  return 0;
}
//! [effects-register]
