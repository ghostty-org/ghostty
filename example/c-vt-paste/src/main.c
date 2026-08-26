#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <ghostty/vt.h>

#define GS(s) ((GhosttyString){.ptr = (const uint8_t*)(s), .len = sizeof(s) - 1})

// Print bytes destined for the pty with control characters made visible.
static void print_escaped(const uint8_t* data, size_t len) {
  for (size_t i = 0; i < len; i++) {
    switch (data[i]) {
    case 0x1b: printf("ESC"); break;
    case '\r': printf("\\r"); break;
    case '\n': printf("\\n"); break;
    default: putchar(data[i]); break;
    }
  }
}

// The base64 password of the last paste event, captured from the OK
// packet so the example can play the program's side of the protocol.
static char event_pw[128];

// Everything the terminal writes to the running program: the pasted
// text, or the paste event packets when mode 5522 is enabled.
static void on_write_pty(GhosttyTerminal terminal,
                         void* userdata,
                         const uint8_t* data,
                         size_t len) {
  (void)terminal;
  (void)userdata;
  printf("  -> pty (%zu bytes): ", len);
  print_escaped(data, len);
  printf("\n");

  // A paste event's OK packet: OSC 5522 ; type=read:status=OK:pw=<b64> ST
  const char* prefix = "\x1b]5522;type=read:status=OK:pw=";
  size_t prefix_len = strlen(prefix);
  if (len > prefix_len && memcmp(data, prefix, prefix_len) == 0) {
    size_t end = prefix_len;
    while (end < len && data[end] != 0x1b) end++;
    size_t pw_len = end - prefix_len;
    if (pw_len < sizeof(event_pw)) {
      memcpy(event_pw, data + prefix_len, pw_len);
      event_pw[pw_len] = 0;
    }
  }
}

// Serves clipboard reads. After a paste event the program's read arrives
// with `granted` set, because it carries the event's one-time password,
// so the embedder skips its permission prompt.
static void on_clipboard_read(GhosttyTerminal terminal,
                              void* userdata,
                              const GhosttyClipboardRead* read) {
  (void)terminal;
  (void)userdata;
  printf("  clipboard read: name=\"");
  fwrite(read->name.ptr, 1, read->name.len, stdout);
  printf("\" granted=%s\n", read->granted ? "yes (no prompt needed)" : "no");

  const char* text = "hello from the clipboard";
  GhosttyClipboardContent content = {
      .mime = GS("text/plain"),
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

// A real embedder would show a dialog here.
static bool confirm_with_user(void) {
  printf("  paste could inject commands; user confirmed\n");
  return true;
}

//! [terminal-paste]
// What the clipboard holds. A real embedder would keep a handle to the
// pasteboard or its items here; the data is only produced on demand.
typedef struct {
  const char* text;
} clipboard_t;

// Produces the data of one representation when the terminal needs it.
// Only the text is ever read: the image is listed on a paste event
// but never requested, so a large image costs nothing to paste.
// Nothing written to the writer is retained, so the data can be
// streamed from anywhere in pieces of any size.
static bool read_clipboard(void* userdata, GhosttyString mime, GhosttyWriter writer) {
  clipboard_t* clipboard = userdata;
  if (mime.len == strlen("text/plain") &&
      memcmp(mime.ptr, "text/plain", mime.len) == 0) {
    // Stream the text in small pieces just to show that it works.
    const uint8_t* data = (const uint8_t*)clipboard->text;
    size_t len = strlen(clipboard->text);
    for (size_t offset = 0; offset < len; offset += 4) {
      size_t n = len - offset < 4 ? len - offset : 4;
      if (!writer.write(writer.userdata, data + offset, n)) return false;
    }
    return true;
  }
  printf("  image read requested, which never happens\n");
  return false;
}

// Paste whatever the clipboard holds. The terminal applies its own
// state: bracketed paste framing (mode 2004) or a Kitty paste event
// (mode 5522) instead of the text.
static void paste_clipboard(GhosttyTerminal terminal, const char* text) {
  clipboard_t clipboard = {.text = text};
  GhosttyString mimes[] = {
      // The first text representation is what a text paste writes.
      GS("text/plain"),
      // Listed on a paste event, never read.
      GS("image/png"),
  };
  GhosttyPaste paste = {
      .size = sizeof(paste),
      .location = GHOSTTY_CLIPBOARD_LOCATION_STANDARD,
      .source = GHOSTTY_PASTE_SOURCE_CLIPBOARD,
      .mimes = mimes,
      .mimes_len = sizeof(mimes) / sizeof(mimes[0]),
      .reader = {.read = read_clipboard, .userdata = &clipboard},
      .allow_unsafe = false,
  };

  bool written = false;
  GhosttyResult result = ghostty_terminal_paste(terminal, &paste, &written);
  if (result == GHOSTTY_REJECTED) {
    // The text could inject commands (e.g. a newline outside of a
    // bracketed paste). Nothing was written; ask, then retry.
    if (!confirm_with_user()) return;
    paste.allow_unsafe = true;
    result = ghostty_terminal_paste(terminal, &paste, &written);
  }
  if (result != GHOSTTY_SUCCESS) {
    fprintf(stderr, "paste failed: %d\n", (int)result);
    return;
  }

  // Whether the pty got the text or a paste event depends on the
  // terminal's modes; either way it went through write_pty above, in
  // chunks as the text was read.
  printf("  %s\n", written ? "written" : "nothing to paste");
}
//! [terminal-paste]

//! [paste-safety]
void safety_example() {
  const char* safe_data = "hello world";
  const char* unsafe_data = "rm -rf /\n";

  if (ghostty_paste_is_safe(safe_data, strlen(safe_data))) {
    printf("Safe to paste\n");
  }

  if (!ghostty_paste_is_safe(unsafe_data, strlen(unsafe_data))) {
    printf("Unsafe! Contains newline\n");
  }
}
//! [paste-safety]

//! [paste-encode]
void encode_example() {
  // The input buffer is modified in place (unsafe bytes are stripped).
  char data[] = "hello\nworld";
  char buf[64];
  size_t written = 0;

  GhosttyResult result = ghostty_paste_encode(
      data, strlen(data), true, buf, sizeof(buf), &written);

  if (result == GHOSTTY_SUCCESS) {
    printf("Encoded %zu bytes: ", written);
    print_escaped((const uint8_t*)buf, written);
    printf("\n");
  }
}
//! [paste-encode]

static void vt_write(GhosttyTerminal terminal, const char* seq) {
  ghostty_terminal_vt_write(terminal, (const uint8_t*)seq, strlen(seq));
}

int main() {
  GhosttyTerminal terminal = NULL;
  if (ghostty_terminal_new(NULL, &terminal, 80, 24) != GHOSTTY_SUCCESS) {
    fprintf(stderr, "Failed to create terminal\n");
    return 1;
  }

  // Pasted bytes and paste events go to write_pty. Serving clipboard
  // reads is what lets the terminal send paste events at all: without
  // this callback the program could never read the clipboard, so pastes
  // stay text even when mode 5522 is enabled.
  ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                       (const void*)on_write_pty);
  ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_CLIPBOARD_READ,
                       (const void*)on_clipboard_read);

  printf("Plain paste:\n");
  paste_clipboard(terminal, "hello world");

  printf("Paste with a newline (refused, then confirmed):\n");
  paste_clipboard(terminal, "echo hi\n");

  // The program enables bracketed paste: newlines are safe inside the
  // frame and are preserved.
  printf("Bracketed paste (mode 2004):\n");
  vt_write(terminal, "\x1b[?2004h");
  paste_clipboard(terminal, "line one\nline two");

  // The program enables paste events: the clipboard's MIME types are
  // listed with a one-time password instead of writing the data.
  printf("Paste event (mode 5522):\n");
  vt_write(terminal, "\x1b[?5522h");
  paste_clipboard(terminal, "hello world");

  // Play the program's side: read the clipboard with the password from
  // the event. The read arrives granted and the data is served through
  // write_pty as base64 without any permission prompt.
  if (event_pw[0] != 0) {
    printf("Program reads with the event password:\n");
    char read_seq[256];
    snprintf(read_seq, sizeof(read_seq),
             "\x1b]5522;type=read:pw=%s:name=UGFzdGUgZXZlbnQ=;dGV4dC9wbGFpbg==\x1b\\",
             event_pw);
    vt_write(terminal, read_seq);
  }

  // Text inserted by other means (IME, drag and drop) is never an event.
  printf("IME text with mode 5522 enabled:\n");
  {
    clipboard_t clipboard = {.text = "committed"};
    GhosttyString mime = GS("text/plain");
    GhosttyPaste paste = {
        .size = sizeof(paste),
        .location = GHOSTTY_CLIPBOARD_LOCATION_STANDARD,
        .source = GHOSTTY_PASTE_SOURCE_TEXT,
        .mimes = &mime,
        .mimes_len = 1,
        .reader = {.read = read_clipboard, .userdata = &clipboard},
        .allow_unsafe = true,
    };
    bool written = false;
    if (ghostty_terminal_paste(terminal, &paste, &written) == GHOSTTY_SUCCESS &&
        written) {
      printf("  written\n");
    }
  }

  ghostty_terminal_free(terminal);

  printf("\nTerminal-free building blocks:\n");
  safety_example();
  encode_example();

  return 0;
}
