"""Local holder lifetime, launch and catalogue contract."""
import base64
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import tempfile
import time
import unittest
import uuid
from test_sessions import BINARY, encode, frame


def wait_socket(path, process):
    for _ in range(250):
        if path.exists():
            socket_probe = socket.socket(socket.AF_UNIX)
            try:
                socket_probe.connect(str(path))
            except OSError:
                socket_probe.close()
            else:
                socket_probe.close()
                return
        if process.poll() is not None:
            raise RuntimeError("local host exited before becoming ready")
        time.sleep(.02)
    raise TimeoutError("local host startup")


def wait_holders_stopped(root):
    deadline = time.monotonic() + 5
    while list(root.glob("*.ctl")) and time.monotonic() < deadline:
        time.sleep(.02)
    if list(root.glob("*.ctl")):
        raise TimeoutError("local holder shutdown")


def next_inner_event(stream, stream_id):
    while True:
        kind, outer_id, data = frame(stream)
        if kind == b"E" and outer_id == stream_id:
            raise AssertionError(data.decode(errors="replace"))
        if kind != b"D" or outer_id != stream_id:
            continue
        inner, sequence, count = struct.unpack(">cQI", data[:13])
        if count != len(data) - 13:
            raise AssertionError("invalid inner frame length")
        return inner, sequence, data[13:]


def inner_event(stream, stream_id, wanted):
    while True:
        kind, sequence, data = next_inner_event(stream, stream_id)
        if kind == wanted:
            return sequence, data


class LocalRuntimeTests(unittest.TestCase):
    def test_holder_survives_broker_restart_and_initial_input_is_not_replayed(self):
        with tempfile.TemporaryDirectory(prefix="omg-local-runtime-", dir="/tmp") as directory:
            root = Path(directory)
            host_socket = root / "host.sock"
            marker = root / "startup.txt"
            session_id = str(uuid.uuid4())
            policy = {
                "detached_ttl_seconds": 259200,
                "expires_at": None,
                "close_on_agent_done": False,
                "agent_done_grace_seconds": 60,
                "terminate_grace_seconds": 1,
                "host_idle_seconds": 300,
                "record_retention_seconds": 604800,
            }
            daemon = subprocess.Popen([
                str(BINARY), "host-local", directory, "--", "/bin/sh", "-i",
            ])
            live_shell_pid = None
            attached = []
            try:
                wait_socket(host_socket, daemon)
                transport = socket.socket(socket.AF_UNIX)
                transport.settimeout(8)
                transport.connect(str(host_socket))

                # A catalogue read is available before any session exists.
                empty = subprocess.check_output(
                    [str(BINARY), "list-local", str(host_socket)], timeout=5
                )
                self.assertEqual(json.loads(empty), [])
                self.assertEqual(list((root / "sessions").glob("*.json")), [])

                launch = {
                    "argv": ["/bin/sh", "-i"],
                    "env": {
                        "HOME": os.environ.get("HOME", directory),
                        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                        "TERM": "xterm-256color",
                    },
                    "cwd": directory,
                    "cols": 87,
                    "rows": 31,
                    "pixel_width": 1305,
                    "pixel_height": 651,
                    "input_base64": base64.b64encode(
                        f"printf 'ONCE\\n' >> {marker}\n".encode()
                    ).decode(),
                }
                request = {
                    "id": session_id,
                    "policy": policy,
                    "create": True,
                    # Local launch.cwd is authoritative; legacy request cwd is ignored.
                    "cwd": "/definitely/not/a/directory",
                    "launch": launch,
                }
                transport.sendall(encode(b"C", 1, json.dumps(request).encode()))
                _, info_data = inner_event(transport, 1, b"J")
                info = json.loads(info_data)
                live_shell_pid = info["pid"]
                self.assertEqual(info["version"], 2)
                self.assertEqual(
                    (info["cols"], info["rows"], info["pixel_width"], info["pixel_height"]),
                    (87, 31, 1305, 651),
                )
                snapshot_seq, _ = inner_event(transport, 1, b"S")
                transport.sendall(encode(b"D", 1, encode(b"A", snapshot_seq)))
                deadline = time.monotonic() + 5
                while not marker.exists() and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertTrue(marker.exists(), "one-time startup input was not delivered")
                self.assertEqual(marker.read_text().splitlines(), ["ONCE"])

                # accept() may preserve O_NONBLOCK from the listener on macOS.
                # A controller which writes just after accept must not see EOF.
                control_path = root / (
                    hashlib.sha256(session_id.encode()).hexdigest()[:16] + ".ctl"
                )
                record = json.loads((root / "sessions" / (session_id + ".json")).read_text())
                with socket.socket(socket.AF_UNIX) as control:
                    control.settimeout(3)
                    control.connect(str(control_path))
                    time.sleep(.1)
                    control.sendall(encode(b"V", 0, json.dumps({
                        "id": session_id,
                        "generation": record["generation"],
                        "capability": record["holder_capability"],
                    }).encode()))
                    kind, _, status = frame(control)
                    self.assertEqual(kind, b"V")
                    self.assertEqual(json.loads(status)["session_pid"], live_shell_pid)
                time.sleep(.6)

                listing = subprocess.check_output(
                    [str(BINARY), "list-local", str(host_socket)], timeout=5
                )
                entries = json.loads(listing)
                self.assertEqual(len(entries), 1)
                entry = entries[0]
                self.assertEqual(entry["id"], session_id)
                self.assertEqual(entry["pid"], live_shell_pid)
                self.assertEqual(entry["cwd"], str(Path(directory).resolve()))
                self.assertNotIn("holder_capability", entry)
                self.assertNotIn("env", entry)
                self.assertNotIn("argv", entry)

                # A crashed broker cannot own or recreate the persistent holder.
                transport.close()
                daemon.kill()
                daemon.wait(timeout=5)
                os.kill(live_shell_pid, 0)
                daemon = subprocess.Popen([
                    str(BINARY), "host-local", directory, "--", "/bin/sh", "-i",
                ])
                wait_socket(host_socket, daemon)

                reattached = socket.socket(socket.AF_UNIX)
                reattached.settimeout(8)
                reattached.connect(str(host_socket))
                attached.append(reattached)
                attach_request = {
                    "id": session_id,
                    "policy": policy,
                    "create": False,
                    "cwd": None,
                }
                reattached.sendall(
                    encode(b"C", 1, json.dumps(attach_request).encode())
                )
                _, attach_info = inner_event(reattached, 1, b"J")
                self.assertEqual(json.loads(attach_info)["pid"], live_shell_pid)
                self.assertEqual(marker.read_text().splitlines(), ["ONCE"])
            finally:
                for stream in attached:
                    stream.close()
                if live_shell_pid:
                    try:
                        os.killpg(live_shell_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    wait_holders_stopped(root)
                if daemon.poll() is None:
                    daemon.terminate()
                    daemon.wait(timeout=5)

    def test_password_mode_and_final_runtime_are_reported(self):
        with tempfile.TemporaryDirectory(prefix="omg-local-meta-", dir="/tmp") as directory:
            root = Path(directory)
            daemon = subprocess.Popen([
                str(BINARY), "host-local", directory, "--", "/bin/sh", "-i",
            ])
            stream = None
            try:
                wait_socket(root / "host.sock", daemon)
                stream = socket.socket(socket.AF_UNIX)
                stream.settimeout(8)
                stream.connect(str(root / "host.sock"))
                session_id = str(uuid.uuid4())
                policy = {
                    "detached_ttl_seconds": 259200,
                    "expires_at": None,
                    "close_on_agent_done": False,
                    "agent_done_grace_seconds": 60,
                    "terminate_grace_seconds": 1,
                    "host_idle_seconds": 300,
                    "record_retention_seconds": 604800,
                }
                launch = {
                    "argv": [
                        "/bin/sh", "-c",
                        "stty -echo; sleep 0.55; stty echo; sleep 0.15; exit 7",
                    ],
                    "env": {
                        "HOME": os.environ.get("HOME", directory),
                        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                        "TERM": "xterm-256color",
                    },
                    "cwd": directory,
                    "cols": 80,
                    "rows": 24,
                    "pixel_width": 640,
                    "pixel_height": 384,
                }
                request = {
                    "id": session_id,
                    "policy": policy,
                    "create": True,
                    "cwd": directory,
                    "launch": launch,
                }
                stream.sendall(encode(b"C", 1, json.dumps(request).encode()))
                _, info_data = inner_event(stream, 1, b"J")
                info = json.loads(info_data)
                self.assertEqual(info["version"], 2)
                self.assertFalse(info["password_input"])
                snapshot_seq, _ = inner_event(stream, 1, b"S")
                stream.sendall(encode(b"D", 1, encode(b"A", snapshot_seq)))

                password_states = []
                final_runtime = None
                while True:
                    kind, _, data = next_inner_event(stream, 1)
                    if kind == b"M":
                        metadata = json.loads(data)
                        password_states.append(metadata["password_input"])
                        if not metadata["password_input"]:
                            final_runtime = metadata["runtime_ms"]
                    elif kind == b"X":
                        self.assertEqual(data, b"7")
                        break
                self.assertIn(True, password_states)
                self.assertIn(False, password_states)
                self.assertIsNotNone(final_runtime)
                self.assertGreaterEqual(final_runtime, 500)
            finally:
                if stream is not None:
                    stream.close()
                if daemon.poll() is None:
                    daemon.terminate()
                    daemon.wait(timeout=5)

    def test_resize_v2_preserves_pixels_and_legacy_resize_still_works(self):
        with tempfile.TemporaryDirectory(prefix="omg-local-resize-", dir="/tmp") as directory:
            root = Path(directory)
            daemon = subprocess.Popen([
                str(BINARY), "host-local", directory, "--", "/bin/sh", "-i",
            ])
            streams = []
            pid = None
            try:
                wait_socket(root / "host.sock", daemon)
                stream = socket.socket(socket.AF_UNIX)
                stream.settimeout(8)
                stream.connect(str(root / "host.sock"))
                streams.append(stream)
                session_id = str(uuid.uuid4())
                policy = {
                    "detached_ttl_seconds": 259200,
                    "expires_at": None,
                    "close_on_agent_done": False,
                    "agent_done_grace_seconds": 60,
                    "terminate_grace_seconds": 1,
                    "host_idle_seconds": 300,
                    "record_retention_seconds": 604800,
                }
                launch = {
                    "argv": ["/bin/sh", "-i"],
                    "env": {
                        "HOME": os.environ.get("HOME", directory),
                        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                        "TERM": "xterm-256color",
                    },
                    "cwd": directory,
                    "cols": 80,
                    "rows": 24,
                    "pixel_width": 640,
                    "pixel_height": 384,
                }
                request = {
                    "id": session_id,
                    "policy": policy,
                    "create": True,
                    "cwd": directory,
                    "launch": launch,
                }
                stream.sendall(encode(b"C", 1, json.dumps(request).encode()))
                _, info_data = inner_event(stream, 1, b"J")
                pid = json.loads(info_data)["pid"]
                snapshot_seq, _ = inner_event(stream, 1, b"S")
                stream.sendall(encode(b"D", 1, encode(b"A", snapshot_seq)))
                stream.sendall(encode(b"D", 1, encode(b"W")))
                inner_event(stream, 1, b"W")

                stream.settimeout(2)
                response_started = time.monotonic()
                stream.sendall(
                    encode(
                        b"D",
                        1,
                        encode(b"I", 0, b"printf 'POLL_WAKE_OK\\n'\n"),
                    )
                )
                output = b""
                while time.monotonic() - response_started < 3:
                    kind, _, data = next_inner_event(stream, 1)
                    if kind == b"O":
                        output += data
                    if b"POLL_WAKE_OK" in output:
                        break
                self.assertIn(b"POLL_WAKE_OK", output)
                self.assertLess(time.monotonic() - response_started, 3)
                stream.settimeout(8)

                v2 = struct.pack(">HHHH", 92, 36, 1840, 900)
                stream.sendall(encode(b"D", 1, encode(b"R", 0, v2)))
                inner_event(stream, 1, b"R")
                attach = socket.socket(socket.AF_UNIX)
                attach.settimeout(8)
                attach.connect(str(root / "host.sock"))
                streams.append(attach)
                request = {
                    "id": session_id,
                    "policy": policy,
                    "create": False,
                    "cwd": None,
                }
                attach.sendall(encode(b"C", 2, json.dumps(request).encode()))
                _, info_data = inner_event(attach, 2, b"J")
                info = json.loads(info_data)
                self.assertEqual(
                    (info["cols"], info["rows"], info["pixel_width"], info["pixel_height"]),
                    (92, 36, 1840, 900),
                )

                legacy = struct.pack(">HH", 80, 24)
                stream.sendall(encode(b"D", 1, encode(b"R", 0, legacy)))
                inner_event(stream, 1, b"R")
                third = socket.socket(socket.AF_UNIX)
                third.settimeout(8)
                third.connect(str(root / "host.sock"))
                streams.append(third)
                third.sendall(encode(b"C", 3, json.dumps(request).encode()))
                _, info_data = inner_event(third, 3, b"J")
                info = json.loads(info_data)
                self.assertEqual(
                    (info["cols"], info["rows"], info["pixel_width"], info["pixel_height"]),
                    (80, 24, 640, 384),
                )
            finally:
                for stream in streams:
                    stream.close()
                if pid:
                    try:
                        os.killpg(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    wait_holders_stopped(root)
                if daemon.poll() is None:
                    daemon.terminate()
                    daemon.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
