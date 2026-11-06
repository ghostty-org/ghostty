# Optional Features {#features}

Some parts of libghostty-vt are optional. A program that only draws a terminal
doesn't need search or snapshots, for example, so the library can be built
without them to make it smaller. You choose features when you build the library,
with the `-Dvt-features` build option.

Optional features don't require program changes. Every function in our
C headers exist in every build, so a program links and loads the same way against
any set of enabled features. When you call a function whose feature was disabled,
the function does nothing and returns GHOSTTY_UNSUPPORTED.

| Feature               | Functions                                                                                                                                                               |
| --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `%color`              | `ghostty_color_*`                                                                                                                                                       |
| `%formatter`          | `ghostty_formatter_*`                                                                                                                                                   |
| `%glyph_protocol`     | None. It lets applications register custom glyphs with Ghostty's glyph protocol.                                                                                        |
| `%grid_introspection` | `ghostty_grid_ref_*`, `ghostty_tracked_grid_ref_*`, `ghostty_cell_get*`, `ghostty_row_get*`, ghostty_terminal_grid_ref_track()                                          |
| `%input_encode`       | `ghostty_key_event_*`, `ghostty_key_encoder_*`, `ghostty_mouse_event_*`, `ghostty_mouse_encoder_*`, ghostty_focus_encode(), `ghostty_paste_*`, ghostty_terminal_paste() |
| `%kitty_graphics`     | `ghostty_kitty_graphics_*`, and the Kitty options and data of ghostty_terminal_set() and ghostty_terminal_get()                                                         |
| `%render_state`       | `ghostty_render_state_*`                                                                                                                                                |
| `%search`             | `ghostty_search_*`                                                                                                                                                      |
| `%selection`          | `ghostty_terminal_select_*`, `ghostty_terminal_selection_*`, `ghostty_selection_gesture_*`                                                                              |
| `%snapshot`           | `ghostty_snapshot_*`                                                                                                                                                    |

A few functions depend on two features:

- ghostty_terminal_grid_ref() and ghostty_terminal_point_from_grid_ref() need
  either `%grid_introspection` or `%selection`.
- ghostty_tracked_grid_ref_snapshot() needs both `%grid_introspection` and
  `%snapshot`.

Kitty graphics need a clock, so builds for targets without an operating system,
such as wasm32-freestanding, never include `%kitty_graphics`.

## Checking for a Feature {#features-check}

To find out up front, for example to hide a menu item, ask ghostty_build_info()
with the feature's key. Each feature has a `GHOSTTY_BUILD_INFO_FEATURE_*` key,
except Kitty graphics, which uses GHOSTTY_BUILD_INFO_KITTY_GRAPHICS:

```c
bool has_search = false;
ghostty_build_info(GHOSTTY_BUILD_INFO_FEATURE_SEARCH, &has_search);
if (!has_search) {
  // Hide the find bar.
}
```

You can also just call the function and check its result. A function that
creates a handle sets the handle to NULL, so cleanup code that frees it still
works:

```c
GhosttySearch search = NULL;
GhosttyResult result = ghostty_search_new(NULL, &search, terminal);
if (result == GHOSTTY_UNSUPPORTED) {
  // This library was built without search. search is NULL.
}
```

## Functions Without a Result {#features-no-result}

A function that doesn't return a GhosttyResult can't report GHOSTTY_UNSUPPORTED.
When its feature is left out, it returns a fixed value instead:

- Functions that free a handle do nothing.
- Functions that return `bool`, such as iterator `_next` functions, return
  false.
- Functions that return a number, an enum or a struct return zero or a zeroed
  struct. ghostty_key_event_get_utf8() returns an empty string.
- ghostty_color_rgb_get(), ghostty_color_palette_default() and
  ghostty_color_palette_generate() fill their outputs with zeros.
- ghostty_color_x11_name_count() returns 0, so the array returned by
  ghostty_color_x11_names() is empty.
- ghostty_kitty_graphics_image() returns NULL.

In practice these values rarely matter. Most of these functions take a handle
that could only come from a `_new` function of the same feature, and that
function returned GHOSTTY_UNSUPPORTED.
