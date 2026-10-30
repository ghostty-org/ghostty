# AppKit visual regression corrections - 2026-10-30

The reported screenshots show genuine regressions in the first native-controls
migration. The installed OMG Dev bundle was `0.18.0-dev.f7b29622` when inspected.
The subsequent uncommitted controls work had not been installed.

## Agent logos

The bundled OpenAI, Pi and Claude vector images have a logical size of 1 x 1
point. Their SVG sources use `1em` dimensions. The native history image views
did not upscale these images into their fixed icon slots.

History rows now use proportional up-or-down scaling in their 20-point slots;
the transcript header uses the same scaling in its 18-point slot. Required
intrinsic-width hugging no longer competes with the header slot width. Template
icons use semantic label color; full-color assets retain their original colors.
Shared catalog image sizes and template flags are not mutated.

A direct raster check of the installed OpenAI asset in a 20-point slot at 2x
scale painted 4 pixels with down-only scaling and 760 pixels with up/down
scaling. The regression test measures painted alpha coverage of actual native
image cells, rather than only checking image-view frames.

## Filter and Git popovers

The Agent History filter returns to compact agent/logo/count rows, a bounded
scrolling agent area, directory/time chips, side-by-side grouping/ordering, and
a plain reset action. Counts align to one trailing edge. Selected-state
checkmarks reserve their column so choosing an option does not shift labels.
The popup uses the invoking terminal's opaque theme background and matching
local appearance. It remains an AppKit controller with native controls.

Git scope/reference popovers reuse the existing GitSearchFieldCell and native
search behavior. Compact native button groups restore subtle fill/border
selection instead of the default prominent segmented appearance. Search and
button alignment rectangles reflect the custom drawn bounds. Scope controls
fill the content width; mode controls stay compact. Opaque popup backgrounds
resolve dynamic colors again when appearance changes.

Filter values, local/SSH data sources, search results, keyboard navigation,
context-bound actions and history storage remain on the existing paths.

## Verification

- **50 tests in 9 suites passed**, including native logo drawing, filter
  selection/overflow/layout, history focus/IME, Git search keyboard navigation,
  reference copying, localization and existing Inspector behavior.
  Log: `/tmp/omg-native-visual-acceptance.log`.
- Light/dark fixture renders were generated and visually inspected:
  `/tmp/omg-agent-history-logos-light.png`,
  `/tmp/omg-agent-history-logos-dark.png`,
  `/tmp/omg-agent-filter-light.png`,
  `/tmp/omg-agent-filter-dark.png`,
  `/tmp/omg-git-history-picker-light.png`,
  `/tmp/omg-git-history-picker-dark.png`.
- These are native-view renders using fixture data, not screenshots of an
  updated installed application. Optional rendering is enabled by the temporary
  `/tmp/omg-native-visual-review` marker.

No development app was replaced and no commit, push or release was performed
for these corrections. They remain alongside the prior uncommitted controls
work in the main checkout.
