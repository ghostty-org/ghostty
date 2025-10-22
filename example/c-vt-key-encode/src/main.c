#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <ghostty/vt.h>

int main() {
  GhosttyKeyEncoder encoder;
  GhosttyResult result = ghostty_key_encoder_new(NULL, &encoder);
  assert(result == GHOSTTY_SUCCESS);

  // Set kitty flags with all features enabled
  ghostty_key_encoder_setopt(encoder, GHOSTTY_KEY_ENCODER_OPT_KITTY_FLAGS, &(uint8_t){GHOSTTY_KITTY_KEY_ALL});

  // Create key event
  GhosttyKeyEvent event;
  result = ghostty_key_event_new(NULL, &event);
  assert(result == GHOSTTY_SUCCESS);
  ghostty_key_event_set_action(event, GHOSTTY_KEY_ACTION_RELEASE);
  ghostty_key_event_set_key(event, GHOSTTY_KEY_CONTROL_LEFT);
  ghostty_key_event_set_mods(event, GHOSTTY_MODS_CTRL);
  printf("Encoding event: left ctrl release with all Kitty flags enabled\n");

  // Optionally, encode with null buffer to get required size. You can
  // skip this step and provide a sufficiently large buffer directly.
  // If there isn't enoug hspace, the function will return an out of memory
  // error.
  size_t required = 0;
  result = ghostty_key_encoder_encode(encoder, event, NULL, 0, &required);
  assert(result == GHOSTTY_OUT_OF_MEMORY);
  printf("Required buffer size: %zu bytes\n", required);

  // Encode the key event. We don't use our required size above because
  // that was just an example; we know 128 bytes is enough.
  char buf[128];
  size_t written = 0;
  result = ghostty_key_encoder_encode(encoder, event, buf, sizeof(buf), &written);
  assert(result == GHOSTTY_SUCCESS);
  printf("Encoded %zu bytes\n", written);

  // Print the encoded sequence (hex and string)
  printf("Hex: ");
  for (size_t i = 0; i < written; i++) printf("%02x ", (unsigned char)buf[i]);
  printf("\n");

  printf("String: ");
  for (size_t i = 0; i < written; i++) {
    if (buf[i] == 0x1b) {
      printf("\\x1b");
    } else {
      printf("%c", buf[i]);
    }
  }
  printf("\n");

  ghostty_key_event_free(event);
  ghostty_key_encoder_free(encoder);
  return 0;
}
