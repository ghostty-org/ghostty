# Colors {#guide-colors}

A terminal has a foreground color, a background color, a cursor color and a
256-color palette. You set them to your theme, and the programs running in the
terminal can change them.

That's the problem this page is about. A program can change the background with
an OSC sequence, but that shouldn't erase the theme you configured. So each
color has two layers: a default that you set, and an override that programs set
with OSC sequences, such as OSC 10, 11 and 12 for the foreground, background and
cursor, and OSC 4 for a palette entry.

If you only need to set a theme, read the first two sections. The rest is for
reading colors out of config files, generating palettes, and telling programs
whether you're in light or dark mode.

## Setting your theme {#guide-colors-defaults}

Use ghostty_terminal_set() to set the default colors. Passing `NULL` clears a
default and leaves that color unset.

| Option                                 | Input type              | Description               |
| -------------------------------------- | ----------------------- | ------------------------- |
| #GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND | `GhosttyColorRgb*`      | Default foreground color  |
| #GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND | `GhosttyColorRgb*`      | Default background color  |
| #GHOSTTY_TERMINAL_OPT_COLOR_CURSOR     | `GhosttyColorRgb*`      | Default cursor color      |
| #GHOSTTY_TERMINAL_OPT_COLOR_PALETTE    | `GhosttyColorRgb[256]*` | Default 256-color palette |

The palette is a little different. Passing `NULL` resets it to the built-in
default palette, and setting it keeps any per-index overrides that programs have
applied. Only the unmodified indices are updated.

@snippet c-vt-colors/src/main.c colors-set-defaults

Full program: @ref c-vt-colors/src/main.c

## Reading colors {#guide-colors-reading}

Use ghostty_terminal_get() to read colors. Each color has two keys. The
effective value is what you should draw with: the override if a program set one,
and the default if not. The default value ignores overrides.

| Data                                            | Output type             | Description                                    |
| ----------------------------------------------- | ----------------------- | ---------------------------------------------- |
| #GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND         | `GhosttyColorRgb*`      | Effective foreground (override or default)     |
| #GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND         | `GhosttyColorRgb*`      | Effective background (override or default)     |
| #GHOSTTY_TERMINAL_DATA_COLOR_CURSOR             | `GhosttyColorRgb*`      | Effective cursor (override or default)         |
| #GHOSTTY_TERMINAL_DATA_COLOR_PALETTE            | `GhosttyColorRgb[256]*` | Current palette (with any OSC overrides)       |
| #GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND_DEFAULT | `GhosttyColorRgb*`      | Default foreground only (ignores OSC override) |
| #GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND_DEFAULT | `GhosttyColorRgb*`      | Default background only (ignores OSC override) |
| #GHOSTTY_TERMINAL_DATA_COLOR_CURSOR_DEFAULT     | `GhosttyColorRgb*`      | Default cursor only (ignores OSC override)     |
| #GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT    | `GhosttyColorRgb[256]*` | Default palette only (ignores OSC overrides)   |

The foreground, background and cursor getters return `GHOSTTY_NO_VALUE` if
there's neither a default nor an override. So handle that case, because a new
terminal starts with these unset. The palette getters always succeed, since the
palette always has a value. If nothing else is set, it's the built-in default.

@snippet c-vt-colors/src/main.c colors-read

Full program: @ref c-vt-colors/src/main.c

Here are the two layers working together. A program overrides the foreground
with OSC 10, and then clearing the default leaves the override in place.

@snippet c-vt-colors/src/main.c colors-main

Full program: @ref c-vt-colors/src/main.c

## Parsing colors {#guide-colors-parsing}

Your theme probably starts out as text. These functions parse the same color
strings as Ghostty's config and theme files, and none of them need a terminal.

ghostty_color_parse() accepts:

- X11 color names, matched ASCII case-insensitively.
- 3- or 6-digit hex colors, with or without a leading `#`.
- 9- or 12-digit hex colors, with a leading `#`.
- XParseColor-style `rgb:<red>/<green>/<blue>` values.
- XParseColor-style `rgbi:<red>/<green>/<blue>` values.

Leading and trailing spaces and tabs are ignored. Use ghostty_color_parse_x11()
when you only want to accept X11 names.

```c
GhosttyColorRgb color;

if (ghostty_color_parse(
        "ForestGreen",
        sizeof("ForestGreen") - 1,
        &color) != GHOSTTY_SUCCESS) {
  // Handle invalid color input.
}

ghostty_color_parse("#abc", sizeof("#abc") - 1, &color);
ghostty_color_parse("rgb:12/34/56", sizeof("rgb:12/34/56") - 1, &color);
```

ghostty_color_x11_names() returns the table of X11 names, if you want to offer
them to someone. The table is static memory that lives as long as the program.
Entries are in rgb.txt order, and an entry with `name == NULL` ends the table.
ghostty_color_x11_name_count() returns the number of entries, not counting that
last one.

```c
const GhosttyColorX11Entry* names = ghostty_color_x11_names();
size_t count = ghostty_color_x11_name_count();

for (size_t i = 0; i < count; i++) {
  // names[i].name and names[i].color are valid here.
}
```

## Palettes {#guide-colors-palettes}

ghostty_color_palette_default() gives you the same 256-color palette the
terminal uses by default. ghostty_color_parse_palette_entry() parses one Ghostty
palette override in `INDEX=COLOR` form. The index can be decimal or use a `0x`,
`0o` or `0b` prefix, and the color side accepts anything ghostty_color_parse()
does.

```c
GhosttyColorRgb palette[256];
ghostty_color_palette_default(palette);

uint8_t index;
GhosttyColorRgb rgb;

if (ghostty_color_parse_palette_entry(
        "0x10=#282c34",
        sizeof("0x10=#282c34") - 1,
        &index,
        &rgb) == GHOSTTY_SUCCESS) {
  palette[index] = rgb;
}
```

ghostty_color_palette_generate() derives the 216-color cube and the grayscale
ramp from a base palette, a background and a foreground, so they match the
theme. Set bits in a GhosttyColorPaletteMask to keep specific indices from the
base palette. The output can be the same pointer as the base.

```c
GhosttyColorRgb palette[256];
ghostty_color_palette_default(palette);

GhosttyColorPaletteMask skip = {0};
GHOSTTY_COLOR_PALETTE_MASK_SET(&skip, 16);

GhosttyColorRgb background = {40, 44, 52};
GhosttyColorRgb foreground = {220, 223, 228};

ghostty_color_palette_generate(
    palette,
    &skip,
    &background,
    &foreground,
    true,
    palette);
```

If your UI needs to make decisions from a color, ghostty_color_luminance(),
ghostty_color_perceived_luminance() and ghostty_color_contrast() give you the
luminance and contrast values.

## Light and dark reports {#guide-colors-scheme}

Programs want to know if your terminal is light or dark, so they can pick colors
that fit. There are two ways they find out.

A program can ask with `CSI ? 996 n`. Register a GhosttyTerminalColorSchemeFn
with `GHOSTTY_TERMINAL_OPT_COLOR_SCHEME` and fill in the current scheme, or
return false to ignore the query. See @ref guide-effects.

Or a program can set mode 2031 and expect you to tell it when the scheme
changes. For this one, encode the report yourself with
ghostty_color_scheme_report_encode() and write it to the pty. Only send it if
`GHOSTTY_MODE_REPORT_COLOR_SCHEME` is set, which you read with
ghostty_terminal_get() and `GHOSTTY_TERMINAL_DATA_MODE`. Dark schemes encode as
`ESC [ ? 997 ; 1 n` and light schemes as `ESC [ ? 997 ; 2 n`, which are the same
bytes as the terminal's reply to the query.

If your buffer is too small, the function returns `GHOSTTY_OUT_OF_SPACE` and
sets the output parameter to the size it needs.

@snippet c-vt-color-scheme/src/main.c color-scheme-report-encode

Full program: @ref c-vt-color-scheme/src/main.c
