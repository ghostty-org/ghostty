#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <ghostty/vt.h>

int main() {
  GhosttyOscParser parser;
  if (ghostty_osc_new(NULL, &parser) != GHOSTTY_SUCCESS) {
    return 1;
  }
  
  // Setup change window title command to change the title to "hello"
  ghostty_osc_next(parser, '0');
  ghostty_osc_next(parser, ';');
  const char *title = "hello";
  for (size_t i = 0; i < strlen(title); i++) {
    ghostty_osc_next(parser, title[i]);
  }
  
  // End parsing and get command
  GhosttyOscCommand command = ghostty_osc_end(parser, 0);
  
  // Get and print command type
  GhosttyOscCommandType type = ghostty_osc_command_type(command);
  printf("Command type: %d\n", type);
  
  // Extract and print the title
  if (ghostty_osc_command_data(command, GHOSTTY_OSC_DATA_CHANGE_WINDOW_TITLE_STR, &title)) {
    printf("Extracted title: %s\n", title);
  } else {
    printf("Failed to extract title\n");
  }
  
  ghostty_osc_free(parser);
  return 0;
}
