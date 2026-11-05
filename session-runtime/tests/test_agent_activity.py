"""Agent presentation state survives detached changes on a real private PTY."""
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

from test_sessions import BINARY, encode, frame


class AgentActivityTests(unittest.TestCase):
    def test_detached_changes_and_exit_replace_the_snapshot_without_restarting_process(self):
        with tempfile.TemporaryDirectory(prefix="omg-activity-", dir="/tmp") as directory:
            root = Path(directory)
            stage = root / "stage"
            script = root / "agent.py"
            script.write_text("""
import os, pathlib, time
stage = pathlib.Path(__file__).with_name('stage')
last = None
while True:
    value = stage.read_text() if stage.exists() else '0'
    if value != last:
        pid = os.getpid()
        def hook(agent, state):
            os.write(1, ('\\x1b]3008;start=omg-agent-%s-%d;type=app;omg_agent=%s;'
                'omg_scope=remote;omg_liveness=pid;omg_state=%s\\x07' %
                (agent, pid, agent, state)).encode())
        def end(agent):
            os.write(1, ('\\x1b]3008;end=omg-agent-%s-%d\\x07' % (agent, pid)).encode())
        if value == '0': hook('pi', 'working')
        elif value == '1':
            end('pi')
            hook('omp', 'needsAttention')
        elif value == '2':
            end('omp')
            os.write(1, b'\\x1b]7501;state=done:app=codex\\x07')
        else: os.write(1, b'\\x1b]7501;state=clear\\x07')
        last = value
    time.sleep(.01)
""")
            state = root / "state"
            state.mkdir(mode=0o700)
            host = subprocess.Popen([str(BINARY), "host", str(state), "--", sys.executable, str(script)])
            pane = str(uuid.uuid4()).encode()
            pid = None

            def snapshot():
                with socket.socket(socket.AF_UNIX) as client:
                    client.settimeout(5)
                    client.connect(str(state / "host.sock"))
                    client.sendall(encode(b"H", 1, pane))
                    info = None
                    while True:
                        kind, stream, data = frame(client)
                        if kind == b"E":
                            self.fail(data.decode())
                        if kind != b"D" or stream != 1:
                            continue
                        inner, sequence, size = struct.unpack(">cQI", data[:13])
                        self.assertEqual(size, len(data) - 13)
                        if inner == b"J":
                            info = json.loads(data[13:])
                        if inner == b"S":
                            client.sendall(encode(b"D", 1, encode(b"A", sequence)))
                        if inner == b"G":
                            return info["pid"], json.loads(data[13:])["records"]

            def wait_snapshot(expected):
                deadline = time.monotonic() + 8
                latest = None
                while time.monotonic() < deadline:
                    if (state / "host.sock").exists():
                        current_pid, latest = snapshot()
                        if pid is not None:
                            self.assertEqual(current_pid, pid)
                        if expected(latest):
                            return current_pid
                    time.sleep(.03)
                self.fail("latest Agent state did not arrive: " + repr(latest))

            try:
                pid = wait_snapshot(lambda r: len(r) == 1 and "omg_state=working" in r[0]["metadata"])
                # No attachment exists while each of these changes happens.
                stage.write_text("1")
                wait_snapshot(lambda r: len(r) == 1 and "omg_agent=omp" in r[0]["metadata"]
                              and "omg_state=needsAttention" in r[0]["metadata"])
                stage.write_text("2")
                wait_snapshot(lambda r: len(r) == 1 and r[0]["id"] == "omg-program-status"
                              and "state=done" in r[0]["metadata"])
                stage.write_text("3")
                wait_snapshot(lambda r: r == [])
                os.kill(pid, 0)
            finally:
                # Close by owned session identity while the host can still
                # validate it; never signal a historical PID after host exit.
                deadline = time.monotonic() + 3
                while host.poll() is None and time.monotonic() < deadline:
                    try:
                        with socket.socket(socket.AF_UNIX) as control:
                            control.settimeout(1)
                            control.connect(str(state / "host.sock"))
                            control.sendall(encode(b"K", 2, pane))
                            kind, _, data = frame(control)
                            if kind == b"D" and data[:1] == b"K" and data[13:] == b"closed":
                                break
                    except (OSError, EOFError):
                        break
                    time.sleep(.02)
                host.terminate()
                host.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
