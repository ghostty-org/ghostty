#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <ghostty/vt.h>

//! [mouse-encode]
int main() {
  // Create encoder
  GhosttyMouseEncoder encoder;
  GhosttyResult result = ghostty_mouse_encoder_new(NULL, &encoder);
  assert(result == GHOSTTY_SUCCESS);

  // Configure SGR format with normal tracking
  ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_EVENT,
      &(GhosttyMouseTrackingMode){GHOSTTY_MOUSE_TRACKING_NORMAL});
  ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_FORMAT,
      &(GhosttyMouseFormat){GHOSTTY_MOUSE_FORMAT_SGR});

  // Set terminal geometry for coordinate mapping
  ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE,
      &(GhosttyMouseEncoderSize){
          .size = sizeof(GhosttyMouseEncoderSize),
          .screen_width = 800, .screen_height = 600,
          .cell_width = 10, .cell_height = 20,
      });

  // Create and configure a left button press event
  GhosttyMouseEvent event;
  result = ghostty_mouse_event_new(NULL, &event);
  assert(result == GHOSTTY_SUCCESS);
  ghostty_mouse_event_set_action(event, GHOSTTY_MOUSE_ACTION_PRESS);
  ghostty_mouse_event_set_button(event, GHOSTTY_MOUSE_BUTTON_LEFT);
  ghostty_mouse_event_set_position(event,
      (GhosttyMousePosition){.x = 50.0f, .y = 40.0f});

  // Encode the mouse event
  char buf[128];
  size_t written = 0;
  result = ghostty_mouse_encoder_encode(encoder, event,
      buf, sizeof(buf), &written);
  assert(result == GHOSTTY_SUCCESS);

  // Use the encoded sequence (e.g., write to terminal)
  fwrite(buf, 1, written, stdout);

  // Cleanup
  ghostty_mouse_event_free(event);
  ghostty_mouse_encoder_free(encoder);
  return 0;
}
//! [mouse-encode]
