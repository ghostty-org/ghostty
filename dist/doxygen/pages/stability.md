# Stability {#stability}

libghostty-vt isn't stable yet. Until 1.0, your program can break on any minor release. libghostty-vt is released separately from Ghostty, with its own version numbers, so these are the numbers to watch.

## Before 1.0 {#stability-before-1}

Each minor release may change the API (the functions and types in these headers) and the ABI (how compiled programs call the library). A program built against 0.1 may not compile against 0.2, or may not run with a 0.2 library installed.

Patch releases, such as 0.1.1, never break programs built against an earlier 0.1 release.

## From 1.0 {#stability-after-1}

From 1.0, only a new major version can break your program, and it comes with a new shared library name such as `libghostty-vt.so.2`. Minor and patch releases only add to the library.

## Checking the Version {#stability-check}

Every 0.x release uses the same shared library name, so the system can't stop a program built against 0.1 from loading a 0.2 library. You can check this yourself when your program starts, by comparing the library's version with the version of the headers you compiled against:

@snippet c-vt-build-info/src/main.c version-compatible

Full program: @ref c-vt-build-info/src/main.c

See @ref version "Version" for the version macros and more examples.
