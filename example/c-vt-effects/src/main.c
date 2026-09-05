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
void on_clipboard_write(
    GhosttyTerminal terminal,
    void* userdata,
    const GhosttyClipboardWrite* write) {
  (void)terminal;
  (void)userdata;

  // The write is synchronous: a real embedder would ask the user for
  // permission here (unless write->granted) and the VT stream waits until
  // this callback returns. The replied result is sent to the program
  // (OSC 5522) through the write_pty callback.
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

  GhosttyClipboardWriteReply reply = {
      .size = sizeof(reply),
      .result = GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS,
      .remember = false,
  };
  write->reply(write, &reply);
}
//! [effects-clipboard-write]

//! [effects-clipboard-read]
void on_clipboard_read(
    GhosttyTerminal terminal,
    void* userdata,
    const GhosttyClipboardRead* read) {
  (void)terminal;
  (void)userdata;

  // The read is synchronous: a real embedder would ask the user for
  // permission here (unless read->granted) and the VT stream waits until
  // this callback returns. The reply is sent to the program through the
  // write_pty callback.
  printf("  clipboard read (location=%d, mimes=%zu)\n",
         (int)read->location, read->mimes_len);
  for (size_t i = 0; i < read->mimes_len; i++) {
    printf("    ");
    fwrite(read->mimes[i].ptr, 1, read->mimes[i].len, stdout);
    printf("\n");
  }

  // Reply with every requested representation we have. This example only
  // has text.
  const char* text = "Hello from the clipboard";
  GhosttyClipboardContent content = {
      .mime = {.ptr = (const uint8_t*)"text/plain", .len = 10},
      .data = {.ptr = (const uint8_t*)text, .len = strlen(text)},
  };
  GhosttyClipboardReadReply reply = {
      .size = sizeof(reply),
      .result = GHOSTTY_CLIPBOARD_READ_RESULT_SUCCESS,
      .contents = &content,
      .contents_len = 1,
      .available = NULL,
      .available_len = 0,
      .remember = false,
  };
  read->reply(read, &reply);
}
//! [effects-clipboard-read]

//! [effects-unknown-sequence]
void on_unknown_sequence(
    GhosttyTerminal terminal,
    void* userdata,
    const GhosttyTerminalUnknownSequence* sequence) {
  (void)terminal;
  (void)userdata;

  switch (sequence->tag) {
  case GHOSTTY_TERMINAL_UNKNOWN_SEQUENCE_APC: {
    const GhosttyTerminalUnknownStringSequence* apc = &sequence->value.apc;
    printf("  unknown APC (truncated=%s, content=%zu bytes): ",
           apc->truncated ? "yes" : "no",
           apc->content.len);
    if (apc->content.len > 0) {
      fwrite(apc->content.ptr, 1, apc->content.len, stdout);
    }
    printf("\n");
    break;
  }
  default:
    break;
  }
}
//! [effects-unknown-sequence]

//! [effects-register]
int main() {
  // Create a terminal
  GhosttyTerminal terminal = NULL;
  if (ghostty_terminal_new(NULL, &terminal, 80, 24) != GHOSTTY_SUCCESS) {
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
  ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_CLIPBOARD_READ,
      (const void *)on_clipboard_read);
  ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_UNKNOWN_SEQUENCE,
      (const void *)on_unknown_sequence);

  // Unknown sequence capture is independently bounded and disabled by
  // default. This limit will apply to every supported unknown sequence type.
  size_t unknown_max_bytes = 256;
  ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_UNKNOWN_MAX_BYTES,
      &unknown_max_bytes);

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

  // 5. Clipboard read (OSC 52 ; c ; ? ST)
  printf("Sending clipboard read:\n");
  const char* clipboard_read_seq = "\x1B]52;c;?\x1B\\";
  ghostty_terminal_vt_write(terminal, (const uint8_t*)clipboard_read_seq,
                            strlen(clipboard_read_seq));

  // 6. Unsupported APC sequence
  printf("Sending unknown APC:\n");
  const char* unknown_apc = "\x1B_private-command;payload\x1B\\";
  ghostty_terminal_vt_write(terminal, (const uint8_t*)unknown_apc,
                            strlen(unknown_apc));

  // 7. Another bell to show the counter increments
  printf("Sending another BEL:\n");
  ghostty_terminal_vt_write(terminal, &bel, 1);

  printf("Total bells: %d\n", bell_count);

  ghostty_terminal_free(terminal);
  return 0;
}
//! [effects-register]
