Bugs:

* Glyph baseline is using the main font, but it can vary font to font

Performance:

* libuv allocates on every read, we should use a read buffer pool
* for scrollback, investigate using segmented list for sufficiently large
  scrollback scenarios.
* reflow: text reflow is really poorly implemented right now specifically
  for shrinking columns. Look into this. This may require changing the
  screen data structure.
* Screen cell structure should be rethought to use some data oriented design,
  also bring it closer to GPU cells, perhaps.
* Loading fonts on startups should probably happen in multiple threads

Correctness:

* `exit` in the shell should close the window
* test wrap against wraptest: https://github.com/mattiase/wraptest
  - automate this in some way
* Charsets: UTF-8 vs. ASCII mode
  - we only support UTF-8 input right now
  - need fallback glyphs if they're not supported
  - can effect a crash using `vttest` menu `3 10` since it tries to parse
    ASCII as UTF-8.
* Graphemes need to be detected and treated as a single unit

Improvements:

* scrollback: configurable
* selection on top/bottom should scroll up/down (while extending selection)
* double-click to select a word
* triple-click to select a line
* shift-click and drag to continue selection

Major Features:

* Bell
* Mac:
  - Switch to raw Cocoa and Metal instead of glfw and libuv (major!)
* Sixels: https://saitoha.github.io/libsixel/
* Kitty keyboard protocol: https://sw.kovidgoyal.net/kitty/keyboard-protocol/
* Kitty graphics protocol: https://sw.kovidgoyal.net/kitty/graphics-protocol/
