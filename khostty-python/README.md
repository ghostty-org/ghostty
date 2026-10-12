# khostty-vt

Python bindings for **libghostty-vt**, the virtual-terminal emulation library
extracted from [Ghostty](https://ghostty.org).

This is not a terminal widget. It is for tooling that needs to *understand*
terminal output rather than display it: agent harnesses that read a pane's state
as data, log scrapers that want the screen without escape-sequence noise, test
helpers that assert on what a program actually drew.

The bindings are ABI-mode [cffi](https://cffi.readthedocs.io): nothing is
compiled, and an already-built `libghostty-vt` is opened with `dlopen`.

## Install

```bash
pip install khostty-vt
```

The Python side has one dependency, `cffi`. It does **not** ship the C library,
which must be built from a Khostty or Ghostty checkout:

```bash
zig build install -Doptimize=ReleaseFast
```

Then tell the bindings where it is, unless it is already on the loader path:

```bash
export KHOSTTY_VT_LIB=/path/to/libghostty-vt.dylib   # a full path
export KHOSTTY_VT_LIB_DIR=/path/to/lib               # or a directory
```

Discovery order, and what happens when nothing is found, is described under
[Finding the library](#finding-the-library).

## Usage

```python
from khostty_vt import Format, Terminal, restore

with Terminal(cols=80, rows=24) as term:
    term.write("\x1b[1m$ build\x1b[0m\r\n")
    term.write("\x1b[31merror\x1b[0m: cannot find symbol 'Widget'\r\n")

    # Text, with styles preserved, or as HTML.
    print(term.text())
    print(term.formatter(format=Format.VT, trim=True).format()[:40])
    print(term.formatter(format=Format.HTML, trim=True).text()[:40])

    # Structured state, rather than a rendered screen.
    print(term.cols, term.rows, term.cursor_position)
    print(term.active_screen, term.cursor_at_prompt, term.mouse_tracking)

    # Search across the screen and scrollback.
    with term.search("error") as found:
        found.run()
        print(found.counts())  # (total, viewport)
        print(found.select_next())  # index, 0 is newest

    # Snapshots are self-contained and can be stored or shipped.
    snapshot = term.snapshot()

with restore(snapshot) as resumed:
    print(resumed.text())
```

Running examples live in [`examples/`](examples): `basic.py` covers terminal,
formatting, search, and snapshot; `agent.py` covers the agent workflow, where
each fact is read as data instead of being scraped from a screen.

```bash
python examples/basic.py
python examples/agent.py
```

## Key and mouse input

The bindings also produce the byte sequences an application expects, which is
the other half of driving a pane:

```python
from khostty_vt import (
    KeyAction,
    KeyEncoder,
    KeyEvent,
    Keys,
    KittyFlags,
    Mods,
    MouseAction,
    MouseButton,
    MouseEncoder,
    MouseEvent,
    MouseFormat,
    MousePosition,
    MouseTrackingMode,
    EncoderSize,
)

with Terminal(cols=80, rows=24) as term, KeyEncoder() as keys, KeyEvent() as event:
    keys.sync_from_terminal(term)  # follow the app's modes

    event.set_key(Keys.A).set_utf8("a").set_action(KeyAction.PRESS)
    print(keys.encode(event))  # b'a'

    event.set_key(Keys.C).set_mods(Mods.CTRL).set_utf8("")
    print(keys.encode(event))  # b'\x03'

    # Kitty protocol needs the unshifted codepoint as well as the key.
    keys.set_kitty_flags(KittyFlags.ALL)
    event.set_key(Keys.C).set_mods(Mods.CTRL)
    event.set_unshifted_codepoint(ord("c"))
    print(keys.encode(event))  # b'\x1b[99;5u'

with MouseEncoder() as mouse, MouseEvent() as click:
    mouse.set_tracking_mode(MouseTrackingMode.NORMAL)
    mouse.set_format(MouseFormat.SGR)
    mouse.set_size(
        EncoderSize(
            screen_width=800,
            screen_height=600,
            cell_width=10,
            cell_height=20,
        )
    )

    click.set_action(MouseAction.PRESS).set_button(MouseButton.LEFT)
    click.set_position(MousePosition(x=50, y=40))
    print(mouse.encode(click))  # b'\x1b[<0;6;3M'
```

Three behaviours are worth knowing, because each makes an encode produce
nothing rather than raising:

* A printable key needs its text. A physical key code does not say which
  character was produced, so ``set_utf8`` is required for anything that types.
* Kitty encoding additionally needs the unshifted codepoint.
* An Alt prefix needs both the DEC 1036 mode and option-as-alt.

And an empty result from the mouse encoder is a valid outcome, not a failure:
motion with no button held is not reportable under
``MouseTrackingMode.NORMAL``. The same empty result appears for a less obvious
reason, so it is worth stating: the encoder needs the *surface* dimensions as
well as the cell size, and a zero ``screen_width`` or ``screen_height`` makes
every event unreportable.

## Design notes

**RAII handles.** `Terminal`, `Formatter`, and `Search` are context managers
that free the underlying C object on exit, and also close themselves from
`__del__` as a backstop. Using a closed handle raises `GhosttyError` instead of
passing a dangling pointer to C.

**Errors are typed, not numeric.** Every C result code becomes a `GhosttyError`
with its symbolic name attached, so no caller has to compare against magic
negatives:

```python
>>> from khostty_vt import GhosttyError, Terminal
>>> with Terminal(80, 24) as t:
...     t.close()
...     t.text()
Traceback (most recent call last):
khostty_vt.errors.GhosttyError: terminal is closed: libghostty-vt rejected the
value (bad argument or released handle) [INVALID_VALUE]
```

**`NO_VALUE` is a result, not a failure.** Querying something that is not
currently set returns `None` where the API documents it, for example
`Search.selected_index()` before any match is selected.

**Threading.** A terminal is not thread-safe: the C library requires callers to
serialize all access to one handle. Searching is split so that `Search.tick()`,
`Search.status()`, `Search.total_matches()`, and `Search.selected_index()` only
touch search-owned memory, while `Search.feed()`, `Search.set_needle()`, and the
select methods read the terminal.

## Finding the library

The shared object is located on first use, not at import, so `import
khostty_vt` always succeeds and only real use requires the library. Locations
are tried in order:

1. `KHOSTTY_VT_LIB` — full path to the shared object.
2. `KHOSTTY_VT_LIB_DIR` — directory containing it.
3. Paths relative to the package: `../../zig-out/lib`, `../zig-out/lib`,
   `../../build/lib`, `../../dist/lib` — which covers running from a checkout.
4. `ctypes.util.find_library("ghostty-vt")` — the system loader path.
5. Bare library names resolved by the loader.

If none succeed, `LibraryNotFoundError` lists every location tried and both
environment variables. Note that an installed (non-editable) package has no
relationship to a checkout, so an installation outside a Khostty tree needs
`KHOSTTY_VT_LIB`, `KHOSTTY_VT_LIB_DIR`, or a loader-path install.

## Verifying a bindings/library pair

ABI-mode cffi reproduces C struct layouts by hand, so a mismatched pair of
headers and binary would otherwise only show up as wrong values. The library
publishes its own type manifest, and the bindings check themselves against it:

```python
>>> import khostty_vt
>>> khostty_vt.validate_abi()["ok"]
True
>>> khostty_vt.validate_struct_sizes()   # declared vs library, per struct
{}
>>> khostty_vt.validate_enum_values()    # both directions, per enum member
{}
```

`validate_abi()` also reports the library version and path it checked.

## Development

```bash
uv venv --python 3.13 .venv
uv pip install --python .venv/bin/python -e ".[test]"

.venv/bin/python -m pytest tests/       # 162 tests against the real library
.venv/bin/ruff check .                  # lint
.venv/bin/ruff format --check .         # formatting
.venv/bin/python -m build               # sdist + wheel
```

The test suite fails rather than skips when no shared library is found, because
a green run against nothing would prove nothing. Set
`KHOSTTY_VT_SKIP_IF_MISSING=1` for a lint-only job.

## License

MIT, matching Ghostty.
