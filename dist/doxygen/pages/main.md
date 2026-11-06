# libghostty-vt {#mainpage}

libghostty-vt is a C library for building terminal emulators. You give it the bytes a program writes, and it gives you back the state of the terminal: the screen, the cursor, the styles, the scrollback, and more.

This is the same core that runs inside [Ghostty](https://ghostty.org). We didn't write a new terminal for the library. We extracted the one we already had. You get the SIMD-optimized parser, the Unicode support, the Kitty protocols, and years of fuzzing and bug fixes along with it.

The library needs nothing but libc, and you can build it without that too.

Here is a complete program. It creates a terminal, writes some text with a color sequence in it, and prints what ended up on the screen. We left out the error checks to keep it short.

@snippet c-vt-hello/src/main.c hello

Full program: @ref c-vt-hello/src/main.c

It prints `Hello, world!`. The color is in the terminal's state, and plain text just doesn't show it. That's a terminal emulator. It has no window and no pty, but the text went through the same parser Ghostty uses.

Where to go next:

- Getting the library? See @ref installing.
- Building a terminal? Read @ref first-terminal, then @ref building-a-terminal.
- Only need one piece? The parsers and encoders work without a terminal. See @ref api_building_blocks "Building Blocks" and @ref api_input "Input".
- Writing bindings for another language? Read @ref conventions first. It will save you time.

libghostty-vt is pre-1.0. The core is the code Ghostty ships and it is very stable. The API is not: any minor release may change it. See @ref stability for exactly what can break.
