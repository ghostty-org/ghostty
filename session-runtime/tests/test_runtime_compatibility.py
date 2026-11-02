"""A current relay must attach to a previously packaged local runtime."""
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time
import unittest
import uuid

from test_sessions import BINARY, encode, frame


@unittest.skipUnless(os.environ.get("OMG_LEGACY_RUNTIME_BINARY"), "requires a previous packaged runtime")
class RuntimeCompatibilityTests(unittest.TestCase):
    def test_current_relay_can_create_attach_and_list_on_legacy_local_host(self):
        legacy = Path(os.environ["OMG_LEGACY_RUNTIME_BINARY"])
        with tempfile.TemporaryDirectory(prefix="omg-compat-", dir="/tmp") as directory:
            root = Path(directory)
            host = root / "host"
            host.mkdir(mode=0o700)
            daemon = subprocess.Popen([str(legacy), "host-local", str(host), "--", "/bin/sh"])
            config = root / "connection.json"
            config.write_text(json.dumps(dict(
                transport="local", executable="/usr/bin/ssh", arguments=[], cwd=directory,
                local_shell="/bin/sh", bundle=str(legacy.parent), revision="legacy-fixture",
                local_state_directory=str(host), policy={})))
            relay_socket = root / "relay.sock"
            relay = subprocess.Popen([str(BINARY), "connect", str(relay_socket), str(config)])
            stream = socket.socket(socket.AF_UNIX)
            session = str(uuid.uuid4())
            try:
                for _ in range(200):
                    if relay_socket.exists():
                        break
                    time.sleep(.02)
                stream.settimeout(8)
                stream.connect(str(relay_socket))
                launch = dict(argv=["/bin/sh", "-c", "printf LEGACY_ALIVE; sleep 15"],
                              env={"PATH": "/usr/bin:/bin", "TERM": "xterm-256color"},
                              cwd=directory, cols=80, rows=24, pixel_width=640,
                              pixel_height=384, input_base64="")
                stream.sendall(encode(b"H", 0, json.dumps(dict(
                    id=session, create=True, policy={}, launch=launch)).encode()))
                generation = None
                while True:
                    kind, sequence, data = frame(stream)
                    self.assertNotEqual(kind, b"E", data)
                    if kind == b"T":
                        generation = sequence
                    elif kind == b"S":
                        self.assertIsNotNone(generation)
                        stream.sendall(encode(b"A", sequence, struct.pack(">Q", generation)))
                        stream.sendall(encode(b"W", generation))
                    elif kind == b"W":
                        break
                inventory = json.loads(subprocess.check_output(
                    [str(BINARY), "list-local", str(relay_socket)], timeout=8))
                record = next(item for item in inventory if item["id"] == session)
                self.assertIsNone(record["ended"])
                self.assertGreater(record["pid"], 1)
                stream.sendall(encode(b"K", generation))
            finally:
                stream.close()
                relay.terminate()
                relay.wait(timeout=5)
                if daemon.poll() is None:
                    daemon.terminate()
                    daemon.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
