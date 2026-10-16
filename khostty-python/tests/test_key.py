"""Tests for key event encoding."""

from __future__ import annotations

import sys

import pytest

import khostty_vt
from khostty_vt import (
    GhosttyError,
    KeyAction,
    KeyEncoder,
    KeyEncoderOption,
    KeyEvent,
    Keys,
    KittyFlags,
    Mods,
    OptionAsAlt,
    Result,
    Terminal,
    encode_key,
)
from khostty_vt._verify import ENUM_TYPES

IS_MACOS = sys.platform == "darwin"


def test_generated_keys_match_the_manifest(library: str) -> None:
    """keys.py is generated; re-derive every value so a stale table fails.

    Without this a regenerated-but-not-committed table would silently select
    the wrong key rather than reporting anything.
    """
    values = {
        name: value
        for name, value in khostty_vt.type_manifest()["types"]["GhosttyKey"]["values"].items()
        if not name.endswith("MAX_VALUE")
    }

    assert len(list(Keys)) == len(values)

    declared = {member.name: int(member) for member in Keys}
    assert declared == values


def test_every_declared_enum_is_a_real_enum(library: str) -> None:
    """Everything in ENUM_TYPES must exist in the manifest as an enum.

    ``#define`` bitmasks are deliberately absent from ENUM_TYPES because the
    manifest cannot enumerate them, so this also guards against someone adding
    one back and quietly weakening the check.
    """
    types = khostty_vt.type_manifest()["types"]

    for name in ENUM_TYPES.values():
        entry = types.get(name)
        assert entry is not None, f"{name} is not in the manifest"
        assert entry["kind"] == "enum", f"{name} is a {entry['kind']}, not an enum"


@pytest.mark.parametrize(
    "key,mods,want",
    [
        (Keys.ENTER, Mods.NONE, b"\r"),
        (Keys.ESCAPE, Mods.NONE, b"\x1b"),
        (Keys.TAB, Mods.NONE, b"\t"),
        (Keys.BACKSPACE, Mods.NONE, b"\x7f"),
        (Keys.C, Mods.CTRL, b"\x03"),
        (Keys.D, Mods.CTRL, b"\x04"),
        (Keys.ARROW_UP, Mods.NONE, b"\x1b[A"),
        (Keys.ARROW_DOWN, Mods.NONE, b"\x1b[B"),
        (Keys.ARROW_RIGHT, Mods.NONE, b"\x1b[C"),
        (Keys.ARROW_LEFT, Mods.NONE, b"\x1b[D"),
        (Keys.HOME, Mods.NONE, b"\x1b[H"),
        (Keys.DELETE, Mods.NONE, b"\x1b[3~"),
        (Keys.F1, Mods.NONE, b"\x1bOP"),
    ],
)
def test_control_keys_encode_without_text(key: Keys, mods: Mods, want: bytes, library: str) -> None:
    assert encode_key(key, mods, library=library) == want


def test_printable_key_needs_text(library: str) -> None:
    """A physical key code does not say which character was produced."""
    assert encode_key(Keys.A, library=library) == b""
    assert encode_key(Keys.A, utf8="a", library=library) == b"a"
    assert encode_key(Keys.A, Mods.SHIFT, utf8="A", library=library) == b"A"
    assert encode_key(Keys.SPACE, utf8=" ", library=library) == b" "


@pytest.mark.parametrize("text", ["a", "Z", "0", "é", "日本", "🙂"])
def test_utf8_text_outlives_set_utf8(text: str, library: str) -> None:
    """Regression guard for a cffi lifetime bug.

    The C API documents that a key event does not take ownership of the text
    pointer. When the bindings passed a call-scoped temporary, CPython freed it
    immediately and encoding produced garbage instead of the typed character.
    """
    with KeyEncoder(library=library) as encoder, KeyEvent(library=library) as event:
        event.set_key(Keys.A).set_action(KeyAction.PRESS)

        # Churn the heap so a collected buffer would be overwritten.
        for _ in range(32):
            bytearray(1024)

        event.set_utf8(text)

        assert event.utf8() == text
        assert encoder.encode(event).decode("utf-8") == text


def test_setting_new_text_replaces_the_buffer(library: str) -> None:
    with KeyEvent(library=library) as event:
        event.set_key(Keys.A).set_action(KeyAction.PRESS)

        event.set_utf8("first")
        assert event.utf8() == "first"

        event.set_utf8("second")
        assert event.utf8() == "second"

        event.set_utf8("")
        assert event.utf8() == ""


def test_alt_prefix_needs_both_settings(library: str) -> None:
    """Cross-platform truth table for the Alt ESC prefix.

    Mirrors ``legacyAltPrefix`` in ``src/input/key_encode.zig`` (the only place
    that emits the ``ESC`` byte before a typed character):

    * ``binding_mods.alt`` must be set on the event (the only way to reach
      this branch).
    * ``opts.alt_esc_prefix`` must be ``true``; otherwise the prefix is
      disabled on every platform.
    * On macOS, ``opts.macos_option_as_alt`` must permit the side that was
      pressed (``TRUE`` for either, ``LEFT`` for left alt, ``RIGHT`` for
      right alt); ``FALSE`` skips the prefix because the OS does the
      Option-to-Unicode translation itself.
    * On non-macOS the platform-specific option is ignored — ``alt_esc_prefix``
      alone is sufficient, which is why the same encoder can drive both
      macOS and Linux bindings.

    A previous revision of this test encoded only the macOS contract and
    failed on the Linux CI runner. The platform-aware split below keeps
    the macOS regression coverage while restoring green on Linux.
    """
    # Negative control: alt held but alt_esc_prefix disabled → no prefix.
    assert encode_key(Keys.A, Mods.ALT, utf8="a", library=library) == b"a"

    # Negative control: alt_esc_prefix enabled but Mods.ALT unset → no prefix.
    assert (
        encode_key(
            Keys.A,
            Mods.NONE,
            utf8="a",
            alt_esc_prefix=True,
            option_as_alt=OptionAsAlt.TRUE,
            library=library,
        )
        == b"a"
    )

    if IS_MACOS:
        # macOS: option_as_alt=FALSE disables the prefix even with the mode on.
        assert (
            encode_key(
                Keys.A,
                Mods.ALT,
                utf8="a",
                alt_esc_prefix=True,
                option_as_alt=OptionAsAlt.FALSE,
                library=library,
            )
            == b"a"
        )
        # macOS: option_as_alt=TRUE emits the prefix.
        assert (
            encode_key(
                Keys.A,
                Mods.ALT,
                utf8="a",
                alt_esc_prefix=True,
                option_as_alt=OptionAsAlt.TRUE,
                library=library,
            )
            == b"\x1ba"
        )
    else:
        # Non-macOS: alt_esc_prefix alone is sufficient; option_as_alt is ignored.
        assert (
            encode_key(
                Keys.A,
                Mods.ALT,
                utf8="a",
                alt_esc_prefix=True,
                library=library,
            )
            == b"\x1ba"
        )
        # Non-macOS still emits the prefix when option_as_alt is set, because
        # the underlying encoder does not consult the option on this platform.
        assert (
            encode_key(
                Keys.A,
                Mods.ALT,
                utf8="a",
                alt_esc_prefix=True,
                option_as_alt=OptionAsAlt.TRUE,
                library=library,
            )
            == b"\x1ba"
        )


def test_kitty_encoding_needs_the_codepoint(library: str) -> None:
    """With Kitty flags but no codepoint the encoder produces nothing."""
    assert encode_key(Keys.C, Mods.CTRL, kitty_flags=KittyFlags.ALL, library=library) == b""

    assert (
        encode_key(
            Keys.C,
            Mods.CTRL,
            kitty_flags=KittyFlags.ALL,
            codepoint=ord("c"),
            library=library,
        )
        == b"\x1b[99;5u"
    )


def test_encoder_modes_change_output(library: str) -> None:
    with KeyEncoder(library=library) as encoder, KeyEvent(library=library) as event:
        event.set_key(Keys.ARROW_UP).set_action(KeyAction.PRESS)
        assert encoder.encode(event) == b"\x1b[A"

        # DEC mode 1 switches arrows to SS3 sequences.
        encoder.set_flag(KeyEncoderOption.CURSOR_KEY_APPLICATION, True)
        assert encoder.encode(event) == b"\x1bOA"

        # DEC mode 67 switches Backspace between DEL and BS.
        event.set_key(Keys.BACKSPACE)
        assert encoder.encode(event) == b"\x7f"
        encoder.set_flag(KeyEncoderOption.BACKARROW_KEY_MODE, True)
        assert encoder.encode(event) == b"\b"


def test_sync_from_terminal_follows_the_application(library: str) -> None:
    with Terminal(cols=80, rows=24, library=library) as term:
        with KeyEncoder(library=library) as encoder, KeyEvent(library=library) as event:
            event.set_key(Keys.ARROW_UP).set_action(KeyAction.PRESS)
            assert encoder.encode(event) == b"\x1b[A"

            term.write("\x1b[?1h")
            encoder.sync_from_terminal(term)

            assert encoder.encode(event) == b"\x1bOA"


def test_sync_from_terminal_rejects_a_closed_terminal(library: str) -> None:
    term = Terminal(cols=80, rows=24, library=library)
    term.close()

    with KeyEncoder(library=library) as encoder:
        with pytest.raises(GhosttyError) as excinfo:
            encoder.sync_from_terminal(term)

    assert excinfo.value.code == int(Result.INVALID_VALUE)


def test_event_state_round_trip(library: str) -> None:
    with KeyEvent(library=library) as event:
        assert (
            event.set_key(Keys.F5)
            .set_mods(Mods.SHIFT | Mods.CTRL)
            .set_consumed_mods(Mods.SHIFT)
            .set_action(KeyAction.REPEAT)
            .set_composing(True)
            is event
        )

        assert event.key() == int(Keys.F5)
        assert event.mods() == Mods.SHIFT | Mods.CTRL
        assert event.consumed_mods() == Mods.SHIFT
        assert event.action() == KeyAction.REPEAT
        assert event.composing() is True


def test_codepoint_round_trip(library: str) -> None:
    with KeyEvent(library=library) as event:
        event.set_unshifted_codepoint(ord("c"))

        assert event.unshifted_codepoint() == ord("c")


def test_encoder_reuses_one_event(library: str) -> None:
    """The documented pattern: one encoder and one event for a whole session."""
    with KeyEncoder(library=library) as encoder, KeyEvent(library=library) as event:
        event.set_action(KeyAction.PRESS)

        out = b""
        for char in "hi":
            event.set_key(Keys.A)
            event.set_utf8(char)
            out += encoder.encode(event)

        assert out == b"hi"


def test_closed_handles_are_refused(library: str) -> None:
    encoder = KeyEncoder(library=library)
    assert encoder.close() is None
    assert encoder.close() is None
    assert encoder.closed is True

    with pytest.raises(GhosttyError):
        encoder.encode(KeyEvent(library=library))
    with pytest.raises(GhosttyError):
        encoder.set_kitty_flags(KittyFlags.ALL)

    event = KeyEvent(library=library)
    assert event.close() is None
    assert event.close() is None
    assert event.closed is True

    with pytest.raises(GhosttyError):
        event.set_key(Keys.A)
    with pytest.raises(GhosttyError):
        event.utf8()

    with KeyEncoder(library=library) as open_encoder:
        with pytest.raises(GhosttyError):
            open_encoder.encode(event)


def test_repr_is_informative(library: str) -> None:
    encoder = KeyEncoder(library=library)
    assert "open" in repr(encoder)
    encoder.close()
    assert "closed" in repr(encoder)

    event = KeyEvent(library=library)
    assert "open" in repr(event)
    event.close()
    assert "closed" in repr(event)


def test_mods_is_a_bitmask() -> None:
    both = Mods.SHIFT | Mods.CTRL

    assert int(both) == 0b0011
    assert both & Mods.CTRL == Mods.CTRL
    assert both & Mods.ALT == Mods.NONE


def test_kitty_all_covers_every_flag() -> None:
    for flag in (
        KittyFlags.DISAMBIGUATE,
        KittyFlags.REPORT_EVENTS,
        KittyFlags.REPORT_ALTERNATES,
        KittyFlags.REPORT_ALL,
        KittyFlags.REPORT_ASSOCIATED,
    ):
        assert KittyFlags.ALL & flag == flag

    assert int(KittyFlags.ALL) == 31
