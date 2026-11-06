# Stability {#stability}

libghostty-vt is extremely stable and production proven software.

It has been used by millions of users for years and is shipped in a diverse
set of free and commercial software across every major operating system and
mobile device. It is covered by a significant set of unit tests. It is fuzzed
via an [AFL++](https://aflplus.plus/) harness on multiple dedicated machines
24/7, and we're continuously expanding our fuzz coverage.

@important The one part that _isn't fully stable yet_ is the C ABI.
Prior to 1.0, we may change the C ABI. We believe all C ABI changes at
this point are complete and plan to release a 1.0 tag soon, but we aren't
promising it until we tag 1.0.

## Checking the Version {#stability-check}

Like any C library, libghostty-vt has two versions: the version you
compile against and the version that is loaded at runtime. They're the
same when statically linking, but can differ when dynamically linking and
programs should be resilient to this.

To check the headers when compiling, use GHOSTTY_VT_VERSION_AT_LEAST(). It works
in any `#if`, so you can also use it to enable code that needs a newer release:

@snippet c-vt-build-info/src/main.c version-check

To read the library's version when your program runs, use ghostty_version() for
the string and ghostty_build_info() for the numbers:

@snippet c-vt-build-info/src/main.c version-library

To make sure the two work together, compare them when your program starts:

@snippet c-vt-build-info/src/main.c version-compatible

Full program: @ref c-vt-build-info/src/main.c

See @ref version "Version" for the version macros and more examples.
