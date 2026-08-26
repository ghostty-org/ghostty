#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <ghostty/vt.h>

//! [key-encode]
int main() {
  // Create encoder
  GhosttyKeyEncoder encoder;
  GhosttyResult result = ghostty_key_encoder_new(NULL, &encoder);
  assert(result == GHOSTTY_SUCCESS);

  // Enable Kitty keyboard protocol with all features
  ghostty_key_encoder_setopt(encoder, GHOSTTY_KEY_ENCODER_OPT_KITTY_FLAGS,
                             &(uint8_t){GHOSTTY_KITTY_KEY_ALL});

  // Create and configure key event for Ctrl+C press
  GhosttyKeyEvent event;
  result = ghostty_key_event_new(NULL, &event);
  assert(result == GHOSTTY_SUCCESS);
  ghostty_key_event_set_action(event, GHOSTTY_KEY_ACTION_PRESS);
  ghostty_key_event_set_key(event, GHOSTTY_KEY_C);
  ghostty_key_event_set_mods(event, GHOSTTY_MODS_CTRL);

  // Encode the key event
  char buf[128];
  size_t written = 0;
  result = ghostty_key_encoder_encode(encoder, event, buf, sizeof(buf), &written);
  assert(result == GHOSTTY_SUCCESS);

  // Use the encoded sequence (e.g., write to terminal)
  fwrite(buf, 1, written, stdout);

  // Cleanup
  ghostty_key_event_free(event);
  ghostty_key_encoder_free(encoder);
  return 0;
}
//! [key-encode]
