#!/usr/bin/env python3

"""Write a multipart payload to the clipboard with the Kitty clipboard
protocol (OSC 5522).

This is the way to reach the clipboard confirmation dialog's multipart
preview, which shows one page per representation. OSC 52 can't get
there: it carries text and nothing else.

Run it in a Ghostty started with the write prompt turned on, since
`clipboard-write` defaults to `allow`:

    ghostty --clipboard-write=ask

then, in that terminal:

    ./test/clipboard-multipart.py

The dialog should offer text/plain, text/html, image/png and
application/octet-stream, previewed as text, text, an image, and a note
that it can't be previewed. Each page is logged at debug level:

    clipboard confirmation preview mime=image/png bytes=73 shown as image
    clipboard confirmation preview parts=4 text=true

The write announces a program name and a session password. The name is
deliberately a hostile sounding one, since a prompt that repeated it
back would be handing an attacker the terminal's credibility; no apprt
should show it. The password is what makes the prompt's "remember"
offer a session grant, so a remembered answer makes every later run
finish with no prompt at all until the terminal exits.

The terminal answers the commit with a status packet, so this reads the
reply rather than leaving it to land on the next shell prompt. It exits
0 on DONE and 1 on anything else, and both the request and the reply go
through /dev/tty, so redirecting stdout doesn't disturb either.
"""

import base64
import os
import re
import select
import struct
import sys
import termios
import time
import tty
import zlib


def b64(value: bytes | str) -> str:
    """Encode a payload or a metadata value the way OSC 5522 wants it."""
    return base64.b64encode(
        value.encode() if isinstance(value, str) else value
    ).decode()


def png(width: int = 2, height: int = 2, rgb: bytes = b"\xff\x00\x00") -> bytes:
    """A tiny solid color PNG, built here so this needs no fixture files."""

    def chunk(tag: bytes, data: bytes) -> bytes:
        body = tag + data
        return (
            struct.pack(">I", len(data))
            + body
            + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
        )

    raw = b"".join(b"\x00" + rgb * width for _ in range(height))
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )


# How long to wait for the status packet. The prompt waits on a person,
# so this is generous; Ctrl-C still works while it does.
RESPONSE_TIMEOUT = 120.0

# One representation of each kind the preview handles differently: text it
# can show, an image it can decode, and bytes it can do neither with.
# A name no apprt should ever repeat back in a prompt, and the password
# that makes a remembered answer into a session grant.
PROGRAM_NAME = "Evil Program"
PASSWORD = "1234"

PARTS: list[tuple[str, bytes]] = [
    ("text/plain", b"Ghostty multipart clipboard"),
    ("text/html", b"<b>Ghostty</b> multipart clipboard"),
    ("image/png", png()),
    ("application/octet-stream", bytes(range(256)) * 8),
]


def read_reply(fd: int, timeout: float) -> bytes | None:
    """Read one OSC packet from the terminal, or None if none arrives."""
    deadline = time.monotonic() + timeout
    buf = bytearray()
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
            return None
        chunk = os.read(fd, 4096)
        if not chunk:
            return None
        buf += chunk
        # Either terminator is allowed; ours are sent with ST, and the
        # reply comes back with whichever the request used.
        if buf.endswith(b"\x1b\\") or buf.endswith(b"\x07"):
            return bytes(buf)


def main() -> int:
    # A transaction is opened by `type=write`, carries one `type=wdata`
    # packet per representation, and is committed by a `type=wdata` with
    # no MIME type.
    packets = [
        f"\x1b]5522;type=write:name={b64(PROGRAM_NAME)}:pw={b64(PASSWORD)}\x1b\\"
    ]
    for mime, data in PARTS:
        packets.append(f"\x1b]5522;type=wdata:mime={b64(mime)};{b64(data)}\x1b\\")
    packets.append("\x1b]5522;type=wdata\x1b\\")

    try:
        fd = os.open("/dev/tty", os.O_RDWR)
    except OSError as err:
        print(f"no controlling terminal: {err}", file=sys.stderr)
        return 1

    saved = termios.tcgetattr(fd)
    try:
        # Read the reply ourselves instead of letting the shell see it.
        # cbreak turns off echo and line buffering while leaving Ctrl-C
        # working, which matters while the prompt is up.
        tty.setcbreak(fd)
        os.write(fd, "".join(packets).encode())
        reply = read_reply(fd, RESPONSE_TIMEOUT)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        os.close(fd)

    if reply is None:
        print(f"no reply within {RESPONSE_TIMEOUT:g}s", file=sys.stderr)
        return 1

    status = re.search(r"status=([A-Z]+)", reply.decode(errors="replace"))
    if status is None:
        print(f"unexpected reply: {reply!r}", file=sys.stderr)
        return 1

    print(f"status={status.group(1)}", file=sys.stderr)
    return 0 if status.group(1) == "DONE" else 1


if __name__ == "__main__":
    sys.exit(main())
