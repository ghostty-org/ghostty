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
    if (data[i] == 0x1b) printf("ESC");
    else putchar(data[i]);
  }
}

// Everything the terminal writes to the running program.
static void on_write_pty(GhosttyTerminal terminal,
                         void* userdata,
                         const uint8_t* data,
                         size_t len) {
  (void)terminal;
  (void)userdata;
  printf("  -> pty: ");
  print_escaped(data, len);
  printf("\n");
}

//! [kitty-dnd-drop]
// The data of the native drop, as an embedder would read it from the
// OS drop session.
static const char* native_drop_data(GhosttyString mime) {
  if (mime.len == 10 && memcmp(mime.ptr, "text/plain", 10) == 0)
    return "hello from the drop";
  return NULL;
}

// Serve the program's drop data requests. This answers synchronously;
// an embedder reading from an OS drop asynchronously answers later the
// same way.
static void serve_drop_requests(GhosttyTerminal terminal) {
  GhosttyKittyDndDataRequest req = GHOSTTY_INIT_SIZED(GhosttyKittyDndDataRequest);
  while (ghostty_kitty_dnd_get(terminal, GHOSTTY_KITTY_DND_DATA_DROP_REQUEST,
                               &req) == GHOSTTY_SUCCESS) {
    printf("  serving request %u for %.*s\n", req.id, (int)req.mime.len,
           (const char*)req.mime.ptr);
    const char* data = native_drop_data(req.mime);
    if (data == NULL) {
      ghostty_kitty_dnd_drop_respond_error(terminal, req.id,
                                           GHOSTTY_KITTY_DND_ERRNO_ENOENT);
      continue;
    }
    ghostty_kitty_dnd_drop_respond_data(terminal, req.id,
                                        (const uint8_t*)data, strlen(data));
    ghostty_kitty_dnd_drop_respond_end(terminal, req.id);
  }
}

// Report a native drag moving over the terminal, or dropping, to the
// program registered to accept drops.
static void native_drag(GhosttyTerminal terminal, bool drop) {
  bool registered = false;
  ghostty_kitty_dnd_get(terminal, GHOSTTY_KITTY_DND_DATA_DROP_REGISTERED,
                        &registered);
  if (!registered) {
    printf("  no program accepts drops; handle the drag natively\n");
    return;
  }

  GhosttyKittyDndPosition pos = GHOSTTY_INIT_SIZED(GhosttyKittyDndPosition);
  pos.cell_x = 4;
  pos.cell_y = 2;
  pos.pixel_x = 40;
  pos.pixel_y = 36;
  pos.operations = GHOSTTY_KITTY_DND_OPERATIONS_COPY;
  GhosttyString mimes[] = {GS("text/plain"), GS("text/uri-list")};
  if (drop) ghostty_kitty_dnd_drop(terminal, &pos, mimes, 2, NULL);
  else ghostty_kitty_dnd_drop_move(terminal, &pos, mimes, 2, NULL);
}
//! [kitty-dnd-drop]

//! [kitty-dnd-drag]
// Start the native drag the program asked for, copying what the OS
// drag session needs from the offer first.
static void start_drag(GhosttyTerminal terminal) {
  size_t count = 0;
  ghostty_kitty_dnd_get(terminal, GHOSTTY_KITTY_DND_DATA_DRAG_MIME_COUNT,
                        &count);
  for (size_t i = 0; i < count; i++) {
    GhosttyString mime, data;
    ghostty_kitty_dnd_drag_mime(terminal, i, &mime);
    printf("  offered %.*s", (int)mime.len, (const char*)mime.ptr);
    if (ghostty_kitty_dnd_drag_pre_sent(terminal, i, &data) == GHOSTTY_SUCCESS)
      printf(" with \"%.*s\"", (int)data.len, (const char*)data.ptr);
    printf("\n");
  }

  // A real embedder starts the OS drag here and reports EPERM if the
  // user already released the mouse button.
  ghostty_kitty_dnd_drag_start_result(terminal, GHOSTTY_KITTY_DND_ERRNO_OK);
}
//! [kitty-dnd-drag]

// The kitty_dnd effect: what the program changed.
static void on_kitty_dnd(GhosttyTerminal terminal,
                         void* userdata,
                         GhosttyKittyDndEvent event) {
  (void)userdata;
  switch (event) {
  case GHOSTTY_KITTY_DND_EVENT_REGISTRATION:
    printf("  event: registration\n");
    break;
  case GHOSTTY_KITTY_DND_EVENT_ACCEPTANCE: {
    GhosttyKittyDndOperation op = GHOSTTY_KITTY_DND_OPERATION_NONE;
    ghostty_kitty_dnd_get(terminal, GHOSTTY_KITTY_DND_DATA_DROP_ACCEPTED, &op);
    printf("  event: acceptance (operation %d)\n", (int)op);
    break;
  }
  case GHOSTTY_KITTY_DND_EVENT_DATA_REQUEST:
    printf("  event: data request\n");
    serve_drop_requests(terminal);
    break;
  case GHOSTTY_KITTY_DND_EVENT_CONCLUDED_NONE:
  case GHOSTTY_KITTY_DND_EVENT_CONCLUDED_COPY:
  case GHOSTTY_KITTY_DND_EVENT_CONCLUDED_MOVE:
    printf("  event: drop concluded, finish the native drop\n");
    break;
  case GHOSTTY_KITTY_DND_EVENT_OFFERS:
    printf("  event: offers\n");
    break;
  case GHOSTTY_KITTY_DND_EVENT_DRAG_START:
    printf("  event: drag start\n");
    start_drag(terminal);
    break;
  case GHOSTTY_KITTY_DND_EVENT_DRAG_CANCEL:
    printf("  event: drag cancel\n");
    break;
  default:
    printf("  event: %d\n", (int)event);
    break;
  }
}

static void vt_write(GhosttyTerminal terminal, const char* seq) {
  ghostty_terminal_vt_write(terminal, (const uint8_t*)seq, strlen(seq));
}

int main() {
  GhosttyTerminal terminal = NULL;
  if (ghostty_terminal_new(NULL, &terminal, 80, 24) != GHOSTTY_SUCCESS) {
    fprintf(stderr, "Failed to create terminal\n");
    return 1;
  }

  // Setting the kitty_dnd effect enables the protocol.
  ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                       (const void*)on_write_pty);
  ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_DND,
                       (const void*)on_kitty_dnd);

  printf("A drag before any program accepts drops:\n");
  native_drag(terminal, false);

  printf("The program registers to accept drops:\n");
  vt_write(terminal, "\x1b]72;t=a\x1b\\");

  printf("A native drag moves over the terminal:\n");
  native_drag(terminal, false);

  printf("The program accepts a copy of text:\n");
  vt_write(terminal, "\x1b]72;t=m:o=1;text/plain\x1b\\");

  printf("The drag drops and the program requests the text:\n");
  native_drag(terminal, true);
  vt_write(terminal, "\x1b]72;t=r:x=1\x1b\\");

  printf("The program concludes the drop:\n");
  vt_write(terminal, "\x1b]72;t=r:o=1\x1b\\");

  printf("The program enables offering drags:\n");
  vt_write(terminal, "\x1b]72;t=o:x=1\x1b\\");

  printf("The user drags over the terminal:\n");
  GhosttyKittyDndPosition pos = GHOSTTY_INIT_SIZED(GhosttyKittyDndPosition);
  pos.cell_x = 1;
  pos.cell_y = 1;
  pos.pixel_x = 12;
  pos.pixel_y = 20;
  ghostty_kitty_dnd_drag_gesture(terminal, &pos);

  printf("The program offers text and starts the drag:\n");
  vt_write(terminal, "\x1b]72;t=o:o=1;text/plain\x1b\\");
  vt_write(terminal, "\x1b]72;t=p:x=0;ZHJhZ2dlZCB0ZXh0\x1b\\");
  vt_write(terminal, "\x1b]72;t=P:x=-1\x1b\\");

  printf("The drag is dropped and finishes:\n");
  ghostty_kitty_dnd_drag_report(terminal, GHOSTTY_KITTY_DND_REPORT_DROPPED, 0);
  ghostty_kitty_dnd_drag_report(terminal, GHOSTTY_KITTY_DND_REPORT_FINISHED, 0);

  ghostty_terminal_free(terminal);
  return 0;
}
