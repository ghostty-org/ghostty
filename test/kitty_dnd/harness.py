#!/usr/bin/env python3
"""Drive `kitten dnd` against libghostty-vt's Kitty DnD C API.

libghostty-vt is the terminal: kitten's output is fed to
ghostty_terminal_vt_write and the terminal's replies go back through the
write_pty effect. This script plays the OS side of drag and drop with
the ghostty_kitty_dnd_* functions.
"""

import ctypes as C
import fcntl
import os
import select
import shutil
import struct
import subprocess
import sys
import termios
import time

if len(sys.argv) != 4 or sys.argv[2] not in ("drop", "drag"):
    raise SystemExit(f"usage: {sys.argv[0]} LIBGHOSTTY_VT_SO drop|drag WORKDIR")

LIB = sys.argv[1]
SCENARIO = sys.argv[2]
WORKDIR = sys.argv[3]
KITTEN = "kitten"
if shutil.which(KITTEN) is None:
    raise SystemExit("kitten not found on PATH; install kitty to get it")

lib = C.CDLL(LIB)
Terminal = C.c_void_p

class String(C.Structure):
    _fields_ = [("ptr", C.c_void_p), ("len", C.c_size_t)]

class Position(C.Structure):
    _fields_ = [("size", C.c_size_t), ("cell_x", C.c_uint32), ("cell_y", C.c_uint32),
                ("pixel_x", C.c_int32), ("pixel_y", C.c_int32), ("operations", C.c_uint32)]

class DataRequest(C.Structure):
    _fields_ = [("size", C.c_size_t), ("id", C.c_uint32), ("mime_index", C.c_uint32), ("mime", String)]

class DragData(C.Structure):
    _fields_ = [("size", C.c_size_t), ("data", C.c_void_p), ("data_len", C.c_size_t),
                ("status", C.c_int), ("error", C.c_int)]

class SizeReport(C.Structure):
    _fields_ = [("rows", C.c_uint16), ("columns", C.c_uint16),
                ("cell_width", C.c_uint32), ("cell_height", C.c_uint32)]

WritePtyFn = C.CFUNCTYPE(None, Terminal, C.c_void_p, C.POINTER(C.c_uint8), C.c_size_t)
KittyDndFn = C.CFUNCTYPE(None, Terminal, C.c_void_p, C.c_int)
SizeFn = C.CFUNCTYPE(C.c_bool, Terminal, C.c_void_p, C.POINTER(SizeReport))

OPT_WRITE_PTY, OPT_SIZE, OPT_KITTY_DND = 1, 6, 44
EVENTS = ["registration", "acceptance", "data_request", "concluded_none", "concluded_copy",
          "concluded_move", "offers", "drag_start", "drag_image", "drag_data", "drag_cancel"]
DATA_DROP_REGISTERED, DATA_DROP_ACCEPTED, DATA_DROP_REQUEST = 1, 3, 5
DATA_DRAG_MIME_COUNT = 9

for name, argtypes in {
    "ghostty_terminal_new": [C.c_void_p, C.POINTER(Terminal), C.c_uint16, C.c_uint16],
    "ghostty_terminal_set": [Terminal, C.c_int, C.c_void_p],
    "ghostty_terminal_vt_write": [Terminal, C.c_char_p, C.c_size_t],
    "ghostty_kitty_dnd_get": [Terminal, C.c_int, C.c_void_p],
    "ghostty_kitty_dnd_drop_move": [Terminal, C.POINTER(Position), C.POINTER(String), C.c_size_t, C.c_void_p],
    "ghostty_kitty_dnd_drop": [Terminal, C.POINTER(Position), C.POINTER(String), C.c_size_t, C.c_void_p],
    "ghostty_kitty_dnd_drop_respond_data": [Terminal, C.c_uint32, C.c_char_p, C.c_size_t],
    "ghostty_kitty_dnd_drop_respond_end": [Terminal, C.c_uint32],
    "ghostty_kitty_dnd_drag_gesture": [Terminal, C.POINTER(Position)],
    "ghostty_kitty_dnd_drag_mime": [Terminal, C.c_size_t, C.POINTER(String)],
    "ghostty_kitty_dnd_drag_pre_sent": [Terminal, C.c_size_t, C.POINTER(String)],
    "ghostty_kitty_dnd_drag_start_result": [Terminal, C.c_int],
    "ghostty_kitty_dnd_drag_report": [Terminal, C.c_int, C.c_int32],
    "ghostty_kitty_dnd_drag_request_data": [Terminal, C.c_size_t],
    "ghostty_kitty_dnd_drag_take_data": [Terminal, C.c_size_t, C.POINTER(DragData)],
}.items():
    getattr(lib, name).argtypes = argtypes
    if name != "ghostty_terminal_vt_write":
        getattr(lib, name).restype = C.c_int

def show(b):
    return b.decode("utf-8", "replace").replace("\x1b", "ESC").replace("\x07", "BEL")

def string(s):
    return C.string_at(s.ptr, s.len)

# The pty.
master, slave = os.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 480, 800))

if SCENARIO == "drop":
    argv = [KITTEN, "dnd", "--drop-anywhere=copy", "--drop", "text/plain:out.txt"]
else:
    with open(os.path.join(WORKDIR, "in.txt"), "w") as f:
        f.write("dragged from kitten\n")
    argv = [KITTEN, "dnd", "--drag", "text/plain:in.txt"]
def make_controlling_tty():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)

proc = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave, cwd=WORKDIR,
                        preexec_fn=make_controlling_tty)
os.close(slave)

events = []
RAW = open(os.path.join(WORKDIR, "raw.bin"), "wb")

@WritePtyFn
def write_pty(_t, _ud, data, length):
    b = C.string_at(data, length)
    print(f"  terminal -> kitten: {show(b)}")
    os.write(master, b)

@KittyDndFn
def on_event(_t, _ud, ev):
    print(f"  event: {EVENTS[ev]}")
    events.append(EVENTS[ev])

@SizeFn
def size_cb(_t, _ud, out):
    out.contents.rows, out.contents.columns = 24, 80
    out.contents.cell_width, out.contents.cell_height = 10, 20
    return True

term = Terminal()
assert lib.ghostty_terminal_new(None, C.byref(term), 80, 24) == 0
lib.ghostty_terminal_set(term, OPT_WRITE_PTY, C.cast(write_pty, C.c_void_p))
lib.ghostty_terminal_set(term, OPT_SIZE, C.cast(size_cb, C.c_void_p))
lib.ghostty_terminal_set(term, OPT_KITTY_DND, C.cast(on_event, C.c_void_p))

def pump(timeout):
    """Feed kitten's output to the terminal until quiet for `timeout`."""
    while True:
        r, _, _ = select.select([master], [], [], timeout)
        if not r:
            return
        try:
            b = os.read(master, 65536)
        except OSError:
            return
        if not b:
            return
        dnd = [p for p in b.split(b"\x1b]") if p.startswith(b"72;")]
        for p in dnd:
            print(f"  kitten -> terminal: {p.split(b'\x1b')[0]!r}")
        RAW.write(b)
        lib.ghostty_terminal_vt_write(term, b, len(b))

def wait_for(name, timeout=10):
    deadline = time.time() + timeout
    while name not in events:
        if time.time() > deadline:
            raise SystemExit(f"FAIL: timed out waiting for {name}")
        pump(0.2)
    events.remove(name)

def pos(ops=1):
    return Position(C.sizeof(Position), 2, 1, 25, 30, ops)

text = b"hello from ghostty\n"

if SCENARIO == "drop":
    wait_for("registration")
    mimes = (String * 1)(String(C.cast(C.c_char_p(b"text/plain"), C.c_void_p), 10))
    print("OS: drag moves over the terminal")
    assert lib.ghostty_kitty_dnd_drop_move(term, C.byref(pos()), mimes, 1, None) == 0
    wait_for("acceptance")
    op = C.c_int(-1)
    lib.ghostty_kitty_dnd_get(term, DATA_DROP_ACCEPTED, C.byref(op))
    print(f"OS: client accepts operation {op.value}")
    print("OS: drop")
    assert lib.ghostty_kitty_dnd_drop(term, C.byref(pos()), mimes, 1, None) == 0
    wait_for("data_request")
    req = DataRequest(C.sizeof(DataRequest))
    while lib.ghostty_kitty_dnd_get(term, DATA_DROP_REQUEST, C.byref(req)) == 0:
        print(f"OS: serving {string(req.mime)!r}")
        assert lib.ghostty_kitty_dnd_drop_respond_data(term, req.id, text, len(text)) == 0
        assert lib.ghostty_kitty_dnd_drop_respond_end(term, req.id) == 0
    deadline = time.time() + 10
    while not any(e.startswith("concluded") for e in events):
        if time.time() > deadline:
            raise SystemExit("FAIL: no conclusion")
        pump(0.2)
    print(f"OS: drop concluded: {[e for e in events if e.startswith('concluded')]}")
    pump(0.5)
    out = os.path.join(WORKDIR, "out.txt")
    got = open(out, "rb").read() if os.path.exists(out) else None
    print(f"out.txt: {got!r}")
    assert got == text, "FAIL: dropped data not written"
else:
    wait_for("offers")
    print("OS: drag gesture")
    assert lib.ghostty_kitty_dnd_drag_gesture(term, C.byref(pos(0))) == 0
    wait_for("drag_start")
    count = C.c_size_t()
    lib.ghostty_kitty_dnd_get(term, DATA_DRAG_MIME_COUNT, C.byref(count))
    mimes = []
    for i in range(count.value):
        s = String()
        lib.ghostty_kitty_dnd_drag_mime(term, i, C.byref(s))
        d = String()
        pre = string(d) if lib.ghostty_kitty_dnd_drag_pre_sent(term, i, C.byref(d)) == 0 else None
        mimes.append(string(s))
        print(f"OS: offered {string(s)!r} pre-sent {pre!r}")
    assert lib.ghostty_kitty_dnd_drag_start_result(term, 0) == 0
    pump(0.5)
    print("OS: target accepts text/plain, copy, drops, and asks for the data")
    lib.ghostty_kitty_dnd_drag_report(term, 0, mimes.index(b"text/plain"))
    lib.ghostty_kitty_dnd_drag_report(term, 1, 1)
    lib.ghostty_kitty_dnd_drag_report(term, 2, 0)
    idx = mimes.index(b"text/plain")
    assert lib.ghostty_kitty_dnd_drag_request_data(term, idx) == 0
    got = b""
    deadline = time.time() + 10
    while True:
        pump(0.2)
        d = DragData(C.sizeof(DragData))
        assert lib.ghostty_kitty_dnd_drag_take_data(term, idx, C.byref(d)) == 0
        if d.data_len:
            got += C.string_at(d.data, d.data_len)
        if d.status != 0:
            print(f"OS: data status {d.status} error {d.error}: {got!r}")
            break
        if time.time() > deadline:
            raise SystemExit("FAIL: no drag data")
    lib.ghostty_kitty_dnd_drag_report(term, 3, 0)
    pump(0.5)
    assert got == b"dragged from kitten\n", "FAIL: wrong drag data"

os.write(master, b"\x03")
try:
    proc.wait(timeout=5)
except subprocess.TimeoutExpired:
    proc.kill()
print("PASS")
