# esctest for libghostty-vt

Runs [esctest](https://github.com/ThomasDickey/esctest2), a conformance
suite for terminal emulators, against libghostty-vt without a GUI.

esctest runs under a pty. Everything it writes is fed through a
libghostty-vt `Terminal`, and the terminal's replies (device attributes,
cursor position and size reports) are written back to it. When esctest
exits, its log is copied to stdout. A full run takes about a minute.

CI runs the whole suite in the `test-esctest` job. The job only reports:
its step summary has esctest's tally and the failing tests, and the full
log is uploaded as an artifact, but failures never fail the build.

## Usage

The build fetches esctest itself, pinned in `build.zig.zon`, and installs
it in `zig-out/share/esctest`. esctest is Python, so a Python 3 must be on
`PATH` as `python3`.

From this directory:

```sh
zig build run > esctest.log
grep 'tests passed' esctest.log
```

Arguments after `--` are passed to esctest. For example, to run only the
DECSTR tests and stop at the first failure:

```sh
zig build run -- --include=DECSTR --stop-on-failure
```

`--verbose`, given before any esctest arguments, shows libghostty-vt's own
log on stderr, which names each sequence that it ignores.

To move to a newer esctest, fetch the commit you want:

```sh
zig fetch --save=esctest2 https://github.com/ThomasDickey/esctest2/archive/<commit>.tar.gz
```

## How the terminal is set up

esctest can only check a terminal that answers like some real one, so the
runner passes it `--expected-terminal=xterm --xterm-checksum=411
--xterm-reverse-wrap=411`, and sets up the terminal to match:

- An 80x25 screen, the size esctest resets to before each test.
- Device attributes of a VT520, the highest level esctest tests.

libghostty-vt doesn't implement DECRQCRA, which esctest uses to read back
the screen, so every test that checks screen contents fails. The terminal
never resizes either, so the tests that resize it with XTWINOPS or DECCOLM
fail too.
