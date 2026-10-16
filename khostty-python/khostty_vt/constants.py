"""Symbolic constants for the libghostty-vt C enums.

Every value here was taken from the library's own type manifest (the JSON
returned by ``ghostty_type_json()``), not transcribed by hand from the headers.
:func:`khostty_vt.validate_enum_values` re-derives them from the linked library
at runtime, so a value that drifts in a future version is reported instead of
silently selecting the wrong field.

Members are ``IntEnum``, so they can be passed straight to the C API and also
compared against plain integers.
"""

from __future__ import annotations

from enum import IntEnum

__all__ = [
    "CursorShape",
    "FormatterFormat",
    "Result",
    "Screen",
    "SearchData",
    "SearchOption",
    "SearchScroll",
    "SearchStatus",
    "StyleColorKind",
    "TerminalData",
    "TerminalOption",
    "Underline",
]


class Result(IntEnum):
    """``GhosttyResult``: the outcome of every fallible C call."""

    SUCCESS = 0
    OUT_OF_MEMORY = -1
    INVALID_VALUE = -2
    OUT_OF_SPACE = -3
    NO_VALUE = -4
    IO_ERROR = -5
    LIMIT_EXCEEDED = -6
    REJECTED = -7


class TerminalData(IntEnum):
    """``GhosttyTerminalData``: a typed field readable from a terminal.

    The docstring on each member names the Python type returned by
    :meth:`khostty_vt.Terminal.get`.
    """

    INVALID = 0
    COLS = 1  #: int
    ROWS = 2  #: int
    CURSOR_X = 3  #: int
    CURSOR_Y = 4  #: int
    CURSOR_PENDING_WRAP = 5  #: bool
    ACTIVE_SCREEN = 6  #: Screen
    CURSOR_VISIBLE = 7  #: bool
    KITTY_KEYBOARD_FLAGS = 8  #: int
    SCROLLBAR = 9  #: dict with total/offset/len
    CURSOR_STYLE = 10  #: Style
    MOUSE_TRACKING = 11  #: bool
    TITLE = 12  #: str
    PWD = 13  #: str
    TOTAL_ROWS = 14  #: int
    SCROLLBACK_ROWS = 15  #: int
    WIDTH_PX = 16  #: int
    HEIGHT_PX = 17  #: int
    COLOR_FOREGROUND = 18  #: tuple[int, int, int]
    COLOR_BACKGROUND = 19  #: tuple[int, int, int]
    COLOR_CURSOR = 20  #: tuple[int, int, int]
    COLOR_PALETTE = 21  #: unsupported: a 256-entry array, not a scalar
    COLOR_FOREGROUND_DEFAULT = 22  #: tuple[int, int, int]
    COLOR_BACKGROUND_DEFAULT = 23  #: tuple[int, int, int]
    COLOR_CURSOR_DEFAULT = 24  #: tuple[int, int, int]
    COLOR_PALETTE_DEFAULT = 25  #: unsupported: a 256-entry array, not a scalar
    KITTY_IMAGE_STORAGE_LIMIT = 26  #: int
    KITTY_IMAGE_MEDIUM_FILE = 27  #: bool
    KITTY_IMAGE_MEDIUM_TEMP_FILE = 28  #: bool
    KITTY_IMAGE_MEDIUM_SHARED_MEM = 29  #: bool
    KITTY_GRAPHICS = 30  #: unsupported: a borrowed handle
    SELECTION = 31  #: unsupported: a borrowed struct
    VIEWPORT_ACTIVE = 32  #: unsupported: a viewport identity, not exposed
    VT_PROCESSING_ERROR = 33  #: unsupported: a parser error record
    SCROLLBACK_MAX_BYTES = 34  #: int
    SCROLLBACK_MAX_LINES = 35  #: int
    CONTINUATION_MAX_BYTES = 36  #: int
    MODE = 37  #: unsupported: an in/out GhosttyTerminalModeConfig
    VT_GROUND = 38  #: bool
    CURSOR_AT_PROMPT = 39  #: bool
    CLIPBOARD_WRITE_MAX_BYTES = 40  #: int
    MOUSE_SHAPE = 41  #: GhosttyMouseShape
    MEMORY_USAGE = 42  #: GhosttyTerminalMemoryUsage


class TerminalOption(IntEnum):
    """``GhosttyTerminalOption``: a writable terminal option.

    Callback-valued options are declared for completeness; the Python bindings
    expose only the scalar and string options, whose Python types are noted
    below.
    """

    USERDATA = 0  #: callback userdata, not exposed
    WRITE_PTY = 1  #: callback, not exposed
    BELL = 2  #: callback, not exposed
    ENQUIRY = 3  #: callback, not exposed
    XTVERSION = 4  #: callback, not exposed
    TITLE_CHANGED = 5  #: callback, not exposed
    SIZE = 6  #: callback, not exposed
    COLOR_SCHEME = 7  #: callback, not exposed
    DEVICE_ATTRIBUTES = 8  #: callback, not exposed
    TITLE = 9  #: str
    PWD = 10  #: str
    COLOR_FOREGROUND = 11  #: (r, g, b)
    COLOR_BACKGROUND = 12  #: (r, g, b)
    COLOR_CURSOR = 13  #: (r, g, b)
    COLOR_PALETTE = 14  #: unsupported: a 256-entry array
    KITTY_IMAGE_STORAGE_LIMIT = 15  #: int
    KITTY_IMAGE_MEDIUM_FILE = 16  #: bool
    KITTY_IMAGE_MEDIUM_TEMP_FILE = 17  #: bool
    KITTY_IMAGE_MEDIUM_SHARED_MEM = 18  #: bool
    APC_MAX_BYTES = 19  #: int
    APC_MAX_BYTES_KITTY = 20  #: int
    SELECTION = 21  #: unsupported: a borrowed struct
    DEFAULT_CURSOR_STYLE = 22  #: CursorShape
    DEFAULT_CURSOR_BLINK = 23  #: bool
    GLYPH_PROTOCOL = 24  #: unsupported: a protocol enum
    PWD_CHANGED = 25  #: callback, not exposed
    CLIPBOARD_WRITE = 26  #: callback, not exposed
    SCROLLBACK_MAX_BYTES = 27  #: int
    SCROLLBACK_MAX_LINES = 28  #: int
    DESKTOP_NOTIFICATION = 29  #: callback, not exposed
    PROGRESS_REPORT = 30  #: callback, not exposed
    CONTINUATION_MAX_BYTES = 31  #: int
    TITLE_REPORT = 32  #: bool
    MODE_DEFAULT = 33  #: unsupported: a GhosttyTerminalModeConfig
    MODE = 34  #: unsupported: a GhosttyTerminalModeConfig
    UNKNOWN_SEQUENCE = 35  #: callback, not exposed
    UNKNOWN_MAX_BYTES = 36  #: int
    TERMINFO_NAME = 37  #: str
    CLIPBOARD_READ = 38  #: callback, not exposed
    CLIPBOARD_WRITE_MAX_BYTES = 39  #: int
    RESIZE_PULL_SCROLLBACK = 40  #: bool
    RENDER_HOLD = 41  #: callback, not exposed
    SEMANTIC_PROMPT = 42  #: callback, not exposed
    RESET = 43  #: callback, not exposed
    XT_CHECKSUM_REPORT = 44  #: bool
    XT_CHECKSUM_EXTENSION = 45  #: int
    PROGRAM_STATUS = 46  #: callback, not exposed
    RESIZE_WINDOW = 47  #: callback, not exposed


class Screen(IntEnum):
    """``GhosttyTerminalScreen``: which screen buffer is active."""

    PRIMARY = 0
    ALTERNATE = 1


class CursorShape(IntEnum):
    """``GhosttyTerminalCursorStyle``: a cursor shape.

    This is the value type of ``TerminalOption.DEFAULT_CURSOR_STYLE``. It is
    unrelated to :attr:`TerminalData.CURSOR_STYLE`, which reports the SGR style
    applied to newly printed text.
    """

    BAR = 0
    BLOCK = 1
    UNDERLINE = 2
    BLOCK_HOLLOW = 3


class FormatterFormat(IntEnum):
    """``GhosttyFormatterFormat``: a formatter output encoding."""

    PLAIN = 0
    VT = 1
    HTML = 2


class SearchData(IntEnum):
    """``GhosttySearchData``: a field readable from a search."""

    STATUS = 0
    NEEDLE = 1
    TOTAL_MATCHES = 2
    SELECTED_INDEX = 3
    SELECTED_MATCH = 4
    MATCHES = 5
    VIEWPORT_MATCHES = 6
    SELECT_SCROLL = 7


class SearchOption(IntEnum):
    """``GhosttySearchOption``: a field writable on a search."""

    NEEDLE = 0
    SELECT_NEXT = 1
    SELECT_PREV = 2
    SELECT_SCROLL = 3


class SearchStatus(IntEnum):
    """``GhosttySearchStatus``: search progress."""

    RUNNING = 0
    FEED_REQUIRED = 1
    COMPLETE = 2


class SearchScroll(IntEnum):
    """``GhosttySearchScroll``: viewport policy when a match is selected."""

    IF_NEEDED = 0
    NONE = 1


class StyleColorKind(IntEnum):
    """``GhosttyStyleColorTag``: which arm of a style color is set."""

    NONE = 0
    PALETTE = 1
    RGB = 2


class Underline(IntEnum):
    """``GhosttySgrUnderline``: an underline decoration."""

    NONE = 0
    SINGLE = 1
    DOUBLE = 2
    CURLY = 3
    DOTTED = 4
    DASHED = 5
