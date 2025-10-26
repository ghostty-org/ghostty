#include <assert.h>
#include <stdio.h>
#include <ghostty/vt.h>

int main() {
  // Create parser
  GhosttySgrParser parser;
  GhosttyResult result = ghostty_sgr_new(NULL, &parser);
  assert(result == GHOSTTY_SUCCESS);

  // Parse a complex SGR sequence from Kakoune
  // This corresponds to the escape sequence:
  // ESC[4:3;38;2;51;51;51;48;2;170;170;170;58;2;255;97;136m
  //
  // Breaking down the sequence:
  // - 4:3 = curly underline (colon-separated sub-parameters)
  // - 38;2;51;51;51 = foreground RGB color (51, 51, 51) - dark gray
  // - 48;2;170;170;170 = background RGB color (170, 170, 170) - light gray
  // - 58;2;255;97;136 = underline RGB color (255, 97, 136) - pink
  uint16_t params[] = {4, 3, 38, 2, 51, 51, 51, 48, 2, 170, 170, 170, 58, 2, 255, 97, 136};
  
  // Separator array: ':' at position 0 (between 4 and 3), ';' elsewhere
  char separators[] = ";;;;;;;;;;;;;;;;";
  separators[0] = ':';
  
  result = ghostty_sgr_set_params(parser, params, separators, sizeof(params) / sizeof(params[0]));
  assert(result == GHOSTTY_SUCCESS);

  printf("Parsing Kakoune SGR sequence:\n");
  printf("ESC[4:3;38;2;51;51;51;48;2;170;170;170;58;2;255;97;136m\n\n");

  // Iterate through attributes
  GhosttySgrAttribute attr;
  int count = 0;
  while (ghostty_sgr_next(parser, &attr)) {
    count++;
    printf("Attribute %d: ", count);
    
    switch (attr.tag) {
      case GHOSTTY_SGR_ATTR_UNDERLINE:
        printf("Underline style = ");
        switch (attr.value.underline) {
          case GHOSTTY_SGR_UNDERLINE_NONE:
            printf("none\n");
            break;
          case GHOSTTY_SGR_UNDERLINE_SINGLE:
            printf("single\n");
            break;
          case GHOSTTY_SGR_UNDERLINE_DOUBLE:
            printf("double\n");
            break;
          case GHOSTTY_SGR_UNDERLINE_CURLY:
            printf("curly\n");
            break;
          case GHOSTTY_SGR_UNDERLINE_DOTTED:
            printf("dotted\n");
            break;
          case GHOSTTY_SGR_UNDERLINE_DASHED:
            printf("dashed\n");
            break;
          default:
            printf("unknown (%d)\n", attr.value.underline);
            break;
        }
        break;

      case GHOSTTY_SGR_ATTR_DIRECT_COLOR_FG:
        printf("Foreground RGB = (%d, %d, %d)\n",
               attr.value.direct_color_fg.r,
               attr.value.direct_color_fg.g,
               attr.value.direct_color_fg.b);
        break;

      case GHOSTTY_SGR_ATTR_DIRECT_COLOR_BG:
        printf("Background RGB = (%d, %d, %d)\n",
               attr.value.direct_color_bg.r,
               attr.value.direct_color_bg.g,
               attr.value.direct_color_bg.b);
        break;

      case GHOSTTY_SGR_ATTR_UNDERLINE_COLOR:
        printf("Underline color RGB = (%d, %d, %d)\n",
               attr.value.underline_color.r,
               attr.value.underline_color.g,
               attr.value.underline_color.b);
        break;

      case GHOSTTY_SGR_ATTR_FG_8:
        printf("Foreground 8-color = %d\n", attr.value.fg_8);
        break;

      case GHOSTTY_SGR_ATTR_BG_8:
        printf("Background 8-color = %d\n", attr.value.bg_8);
        break;

      case GHOSTTY_SGR_ATTR_FG_256:
        printf("Foreground 256-color = %d\n", attr.value.fg_256);
        break;

      case GHOSTTY_SGR_ATTR_BG_256:
        printf("Background 256-color = %d\n", attr.value.bg_256);
        break;

      case GHOSTTY_SGR_ATTR_BOLD:
        printf("Bold\n");
        break;

      case GHOSTTY_SGR_ATTR_ITALIC:
        printf("Italic\n");
        break;

      case GHOSTTY_SGR_ATTR_UNSET:
        printf("Reset all attributes\n");
        break;

      case GHOSTTY_SGR_ATTR_UNKNOWN:
        printf("Unknown attribute\n");
        break;

      default:
        printf("Other attribute (tag=%d)\n", attr.tag);
        break;
    }
  }

  printf("\nTotal attributes parsed: %d\n", count);

  // Cleanup
  ghostty_sgr_free(parser);
  return 0;
}
