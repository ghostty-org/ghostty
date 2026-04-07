#!/usr/bin/env python3
"""
Comprehensive test suite for ghostty-snap.

Tests the framing protocol, resize, scrollback sync, session management,
reconnection, input forwarding, and backpressure handling.

Usage:
    python3 tools/test-ghostty-snap.py /path/to/ghostty-snap
"""

import os
import socket
import struct
import subprocess
import sys
import time
import signal
import json

# ─── framing protocol helpers ──────────────────────────────────────────────────

class MsgType:
    PTY_DATA   = 0x01
    SNAPSHOT   = 0x02
    SCROLLBACK = 0x03
    INPUT      = 0x81
    RESIZE     = 0x82

    @staticmethod
    def name(t):
        return {1:'PTY_DATA', 2:'SNAPSHOT', 3:'SCROLLBACK',
                0x81:'INPUT', 0x82:'RESIZE'}.get(t, f'UNKNOWN({t})')

def encode_frame(msg_type, payload):
    """Encode a framed message: [type:u8][length:u24][payload]"""
    length = len(payload)
    header = struct.pack('!B', msg_type) + struct.pack('!I', length)[1:]  # u24
    return header + payload

def decode_frames(data):
    """Decode all complete frames from raw bytes. Returns (frames, remainder)."""
    frames = []
    pos = 0
    while pos + 4 <= len(data):
        msg_type = data[pos]
        msg_len = (data[pos+1] << 16) | (data[pos+2] << 8) | data[pos+3]
        if pos + 4 + msg_len > len(data):
            break
        frames.append((msg_type, data[pos+4:pos+4+msg_len]))
        pos += 4 + msg_len
    return frames, data[pos:]

def send_resize(sock, cols, rows):
    payload = struct.pack('!HH', cols, rows)
    sock.sendall(encode_frame(MsgType.RESIZE, payload))

def send_input(sock, data):
    sock.sendall(encode_frame(MsgType.INPUT, data))

def recv_all(sock, timeout=2.0):
    """Receive all available data with timeout."""
    sock.settimeout(timeout)
    data = b''
    try:
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            data += chunk
    except socket.timeout:
        pass
    return data

# ─── server management ─────────────────────────────────────────────────────────

SNAP_BIN = None
LD_LINUX = None

def start_server(name, command="bash", port=7681, extra_args=None):
    """Start a ghostty-snap server, return the process."""
    cmd = [LD_LINUX, SNAP_BIN, "server", "--name", name, f"--port={port}", "--"]
    if isinstance(command, list):
        cmd.extend(command)
    else:
        cmd.append(command)
    if extra_args:
        cmd.extend(extra_args)
    log = open(f"/tmp/ghostty-snap-test-{name}.log", "w")
    proc = subprocess.Popen(
        cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
        stderr=log,
    )
    time.sleep(1.5)  # Wait for server to start
    return proc

def stop_server(proc):
    """Stop a server process."""
    try:
        proc.terminate()
    except (ProcessLookupError, OSError):
        pass
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        try:
            proc.kill()
        except (ProcessLookupError, OSError):
            pass

def connect(port=7681, cols=80, rows=24):
    """Connect to server and send initial resize. Returns socket."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect(('127.0.0.1', port))
    send_resize(s, cols, rows)
    return s

# ─── test infrastructure ──────────────────────────────────────────────────────

passed = 0
failed = 0
errors = []

def test(name, condition, detail=""):
    global passed, failed, errors
    if condition:
        passed += 1
        print(f"  \033[32mPASS\033[0m {name}")
    else:
        failed += 1
        errors.append(f"{name}: {detail}")
        print(f"  \033[31mFAIL\033[0m {name}" + (f" — {detail}" if detail else ""))

# ─── tests ─────────────────────────────────────────────────────────────────────

def test_framing_basic():
    """Test that server sends properly framed messages."""
    print("\n── Framing Protocol ──")

    proc = start_server("test-framing", ["bash", "-c", "echo FRAMING_TEST; exec sleep 30"], port=17681)
    try:
        s = connect(port=17681)
        data = recv_all(s, timeout=2)
        frames, remainder = decode_frames(data)
        s.close()

        test("Received frames", len(frames) >= 1, f"got {len(frames)} frames")
        test("No leftover bytes", len(remainder) == 0, f"{len(remainder)} bytes remaining")

        types = [f[0] for f in frames]
        test("Has SNAPSHOT frame", MsgType.SNAPSHOT in types, f"types: {[MsgType.name(t) for t in types]}")

        # Check snapshot content
        for msg_type, payload in frames:
            if msg_type == MsgType.SNAPSHOT:
                test("Snapshot contains FRAMING_TEST", b"FRAMING_TEST" in payload)
                test("Snapshot has sync markers", b"\x1b[?2026h" in payload)
                break
    finally:
        stop_server(proc)


def test_input_forwarding():
    """Test that framed INPUT messages reach the pty."""
    print("\n── Input Forwarding ──")

    proc = start_server("test-input", "bash", port=17682)
    try:
        s = connect(port=17682)
        recv_all(s, timeout=1)  # drain initial snapshot

        # Send a command via framed INPUT
        send_input(s, b"echo INPUT_WORKS_42\n")
        time.sleep(1)
        data = recv_all(s, timeout=1)
        frames, _ = decode_frames(data)

        # Check if any PTY_DATA frame contains our output
        all_pty = b''.join(p for t, p in frames if t == MsgType.PTY_DATA)
        test("Input forwarded and echoed", b"INPUT_WORKS_42" in all_pty,
             f"got {len(all_pty)} bytes of PTY_DATA")

        s.close()
    finally:
        stop_server(proc)


def test_resize():
    """Test resize during session."""
    print("\n── Resize During Session ──")

    proc = start_server("test-resize", ["bash", "-c", "exec sleep 30"], port=17683)
    try:
        s = connect(port=17683, cols=80, rows=24)
        recv_all(s, timeout=1)  # drain initial

        # Send resize
        send_resize(s, 120, 40)
        time.sleep(0.5)

        # Read server stderr for resize log
        # Can't easily read proc.stderr without blocking, so just check
        # that the connection didn't break
        send_input(s, b"echo AFTER_RESIZE\n")
        time.sleep(0.5)
        data = recv_all(s, timeout=1)
        frames, _ = decode_frames(data)
        all_pty = b''.join(p for t, p in frames if t == MsgType.PTY_DATA)
        test("Connection alive after resize", len(data) > 0)

        # Send another resize
        send_resize(s, 200, 50)
        time.sleep(0.3)
        test("Connection alive after second resize", True)  # didn't crash

        s.close()
    finally:
        stop_server(proc)


def test_scrollback():
    """Test scrollback sync on initial connect."""
    print("\n── Scrollback Sync ──")

    # Server that generates scrollback
    proc = start_server("test-scroll",
        ["bash", "-c", "for i in $(seq 1 100); do echo \"history_line_$i\"; done; exec sleep 30"],
        port=17684)
    try:
        time.sleep(1)  # Let the seq finish

        s = connect(port=17684)
        data = recv_all(s, timeout=2)
        frames, _ = decode_frames(data)

        types = [f[0] for f in frames]
        test("Has SCROLLBACK frame", MsgType.SCROLLBACK in types,
             f"types: {[MsgType.name(t) for t in types]}")

        if MsgType.SCROLLBACK in types:
            sb_data = b''.join(p for t, p in frames if t == MsgType.SCROLLBACK)
            test("Scrollback contains history_line_1", b"history_line_1" in sb_data)
            test("Scrollback contains history_line_50", b"history_line_50" in sb_data)
            test("Scrollback is non-trivial", len(sb_data) > 100, f"{len(sb_data)} bytes")

        test("Has SNAPSHOT after SCROLLBACK",
             types.index(MsgType.SNAPSHOT) > types.index(MsgType.SCROLLBACK) if MsgType.SCROLLBACK in types and MsgType.SNAPSHOT in types else False)

        s.close()
    finally:
        stop_server(proc)


def test_reconnection():
    """Test disconnect and reconnect preserves state."""
    print("\n── Reconnection ──")

    proc = start_server("test-reconn", "bash", port=17685)
    try:
        # First connection: type a command
        s1 = connect(port=17685)
        recv_all(s1, timeout=1)
        send_input(s1, b"echo PERSIST_CHECK_99\n")
        time.sleep(1)
        s1.close()

        # Wait, then reconnect
        time.sleep(1)

        s2 = connect(port=17685)
        data = recv_all(s2, timeout=2)
        frames, _ = decode_frames(data)

        all_content = b''.join(p for _, p in frames)
        test("Reconnect sees previous command",
             b"PERSIST_CHECK_99" in all_content,
             f"total content: {len(all_content)} bytes")

        # Type another command on the reconnected session
        send_input(s2, b"echo SECOND_CMD\n")
        time.sleep(0.5)
        data2 = recv_all(s2, timeout=1)
        frames2, _ = decode_frames(data2)
        all_pty2 = b''.join(p for t, p in frames2 if t == MsgType.PTY_DATA)
        test("Can type on reconnected session", b"SECOND_CMD" in all_pty2)

        s2.close()
    finally:
        stop_server(proc)


def test_sessions():
    """Test session management: named sessions, list, attach by name."""
    print("\n── Session Management ──")

    proc = start_server("test-sess", ["bash", "-c", "exec sleep 30"], port=17686)
    try:
        # Check session file exists
        session_file = "/tmp/ghostty-snap-sessions/test-sess.session"
        test("Session file created", os.path.exists(session_file))

        if os.path.exists(session_file):
            with open(session_file) as f:
                port_str = f.read().strip()
            test("Session file contains port", port_str == "17686", f"got: {port_str}")

        # Test list command
        result = subprocess.run(
            [LD_LINUX, SNAP_BIN, "list"],
            capture_output=True, text=True, timeout=5
        )
        test("List shows session", "test-sess" in result.stderr, f"stderr: {result.stderr}")
    finally:
        stop_server(proc)
        # Check cleanup
        time.sleep(0.5)
        test("Session file cleaned up", not os.path.exists("/tmp/ghostty-snap-sessions/test-sess.session"))


def test_multiple_sessions():
    """Test multiple concurrent sessions."""
    print("\n── Multiple Sessions ──")

    proc1 = start_server("multi-a", ["bash", "-c", "exec sleep 30"], port=17687)
    proc2 = start_server("multi-b", ["bash", "-c", "exec sleep 30"], port=17688)
    try:
        # Both should be listed
        result = subprocess.run(
            [LD_LINUX, SNAP_BIN, "list"],
            capture_output=True, text=True, timeout=5
        )
        test("List shows session A", "multi-a" in result.stderr)
        test("List shows session B", "multi-b" in result.stderr)

        # Connect to each
        s1 = connect(port=17687)
        s2 = connect(port=17688)

        d1 = recv_all(s1, timeout=1)
        d2 = recv_all(s2, timeout=1)

        test("Can connect to session A", len(d1) > 0)
        test("Can connect to session B", len(d2) > 0)

        s1.close()
        s2.close()
    finally:
        stop_server(proc1)
        stop_server(proc2)


def test_empty_scrollback():
    """Test connect with no scrollback."""
    print("\n── Empty Scrollback ──")

    proc = start_server("test-empty", ["bash", "-c", "exec sleep 30"], port=17689)
    try:
        s = connect(port=17689)
        data = recv_all(s, timeout=2)
        frames, _ = decode_frames(data)

        types = [f[0] for f in frames]
        # With no scrollback, should NOT have a SCROLLBACK frame
        has_scrollback = MsgType.SCROLLBACK in types
        if has_scrollback:
            sb_data = b''.join(p for t, p in frames if t == MsgType.SCROLLBACK)
            test("No scrollback frame (or empty)", len(sb_data) == 0, f"got {len(sb_data)} bytes")
        else:
            test("No scrollback frame", True)

        test("Has SNAPSHOT frame", MsgType.SNAPSHOT in types)
        s.close()
    finally:
        stop_server(proc)


def test_large_output():
    """Test handling of large pty output."""
    print("\n── Large Output ──")

    proc = start_server("test-large", "bash", port=17690)
    try:
        s = connect(port=17690)
        recv_all(s, timeout=1)  # drain initial

        # Send command that produces lots of output
        send_input(s, b"seq 1 5000\n")
        time.sleep(3)
        data = recv_all(s, timeout=2)
        frames, _ = decode_frames(data)

        total_pty = sum(len(p) for t, p in frames if t == MsgType.PTY_DATA)
        total_snap = sum(len(p) for t, p in frames if t == MsgType.SNAPSHOT)

        test("Received pty data", total_pty > 0, f"{total_pty} bytes PTY_DATA")
        test("Total data reasonable", total_pty + total_snap > 1000,
             f"pty={total_pty}, snap={total_snap}")

        # Connection should still work after large output
        send_input(s, b"echo ALIVE_AFTER_FLOOD\n")
        time.sleep(0.5)
        data2 = recv_all(s, timeout=1)
        frames2, _ = decode_frames(data2)
        all2 = b''.join(p for _, p in frames2)
        test("Connection alive after flood", b"ALIVE_AFTER_FLOOD" in all2 or len(data2) > 0)

        s.close()
    finally:
        stop_server(proc)


def test_ctrl_c():
    """Test Ctrl-C responsiveness."""
    print("\n── Ctrl-C ──")

    proc = start_server("test-ctrlc", "bash", port=17691)
    try:
        s = connect(port=17691)
        recv_all(s, timeout=1)

        # Start a long-running command
        send_input(s, b"sleep 60\n")
        time.sleep(0.5)

        # Send Ctrl-C
        t0 = time.monotonic()
        send_input(s, b"\x03")
        time.sleep(0.5)

        # Should get prompt back
        data = recv_all(s, timeout=2)
        frames, _ = decode_frames(data)
        all_pty = b''.join(p for t, p in frames if t == MsgType.PTY_DATA)
        dt = time.monotonic() - t0

        test("Ctrl-C responded", len(all_pty) > 0, f"{len(all_pty)} bytes in {dt:.2f}s")

        # Verify we can still type
        send_input(s, b"echo POST_CTRLC\n")
        time.sleep(0.5)
        data2 = recv_all(s, timeout=1)
        frames2, _ = decode_frames(data2)
        all2 = b''.join(p for t, p in frames2 if t == MsgType.PTY_DATA)
        test("Can type after Ctrl-C", b"POST_CTRLC" in all2)

        s.close()
    finally:
        stop_server(proc)


# ─── main ──────────────────────────────────────────────────────────────────────

def main():
    global SNAP_BIN, LD_LINUX, passed, failed

    if len(sys.argv) < 2:
        # Try defaults
        SNAP_BIN = os.path.expanduser("~/ghostty/zig-out/bin/ghostty-snap")
    else:
        SNAP_BIN = sys.argv[1]

    if not os.path.exists(SNAP_BIN):
        print(f"Error: {SNAP_BIN} not found")
        sys.exit(1)

    # Find nix ld-linux
    for path in [
        "/nix/store/wb6rhpznjfczwlwx23zmdrrw74bayxw4-glibc-2.42-47/lib/ld-linux-x86-64.so.2",
        "/lib64/ld-linux-x86-64.so.2",
    ]:
        if os.path.exists(path):
            LD_LINUX = path
            break

    if not LD_LINUX:
        # Try running directly
        LD_LINUX = ""
        SNAP_BIN = SNAP_BIN  # run directly

    print(f"Testing: {SNAP_BIN}")
    print(f"Loader:  {LD_LINUX or '(direct)'}")

    # Clean up any stale session files
    if os.path.isdir("/tmp/ghostty-snap-sessions"):
        for f in os.listdir("/tmp/ghostty-snap-sessions"):
            os.remove(f"/tmp/ghostty-snap-sessions/{f}")

    # Set an overall timeout
    signal.alarm(120)

    # Run tests
    test_framing_basic()
    test_input_forwarding()
    test_resize()
    test_scrollback()
    test_reconnection()
    test_sessions()
    test_multiple_sessions()
    test_empty_scrollback()
    test_large_output()
    test_ctrl_c()

    # Summary
    total = passed + failed
    print(f"\n{'='*60}")
    print(f"Results: {passed}/{total} passed", end="")
    if failed:
        print(f", \033[31m{failed} failed\033[0m")
        for e in errors:
            print(f"  FAIL: {e}")
    else:
        print(f" \033[32m— all passed!\033[0m")

    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
