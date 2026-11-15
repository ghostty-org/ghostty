# Stability {#stability}

libghostty-vt is extremely stable and production proven software.

It has been used by millions of users for years and is shipped in a diverse
set of free and commercial software across every major operating system and
mobile device. It is covered by a significant set of unit tests. It is fuzzed
via an [AFL++](https://aflplus.plus/) harness on multiple dedicated machines
24/7, and we're continuously expanding our fuzz coverage.

## ABI

The C ABI is stable. A program built against one 1.x release keeps
working with every later 1.x release. CI checks every change against these
rules.

A minor release may only add:

- New functions.
- New types.
- New enum values.
- New fields at the end of a @ref sized-structs "sized struct".

Nothing is removed, resized, reordered or re-typed. A behavior change ships as a
new function with a new descriptive name, and the old function is marked
GHOSTTY_DEPRECATED until the next major version.

The snapshot byte format is versioned separately from the library and isn't
covered by the ABI promise. The snapshot functions are part of the C ABI, but
the bytes they produce and accept may change in any release. See the
@ref guide-snapshots "Snapshots guide".

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
