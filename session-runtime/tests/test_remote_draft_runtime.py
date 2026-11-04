"""Persistent SSH sessions must provision the explicit-request editor bridge."""
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
import uuid

from test_sessions import BINARY, encode, frame
from test_local_runtime import wait_socket, inner_event

ROOT = Path(__file__).resolve().parents[2]


class RemoteRuntimeDraftTests(unittest.TestCase):
    def test_runtime_editor_import_preserves_draft_and_binds_generation(self):
        with tempfile.TemporaryDirectory(prefix="omg-runtime-draft-", dir="/tmp") as directory:
            home = Path(directory)
            revision = "draft-fixture"
            state = home / ".omg/run" / hashlib.sha256(revision.encode()).hexdigest()[:12]
            state.mkdir(parents=True, mode=0o700)
            original = home / "input.txt"
            original.write_text("中文 draft\nsecond line")
            agent = home / "agent.py"
            agent.write_text(textwrap.dedent("""
                import os, pathlib, subprocess, tty
                tty.setraw(0)
                pathlib.Path(os.environ['DRAFT_INPUT']).with_suffix('.ready').touch()
                while True:
                    data = os.read(0, 64)
                    if not data: break
                    if b'\\x07' in data:
                        subprocess.run([os.environ['VISUAL'], os.environ['DRAFT_INPUT']], check=True)
            """))
            environment = dict(os.environ, HOME=directory, VISUAL="/bin/false", DRAFT_INPUT=str(original))
            daemon = subprocess.Popen([str(BINARY), "host", str(state), "--", sys.executable, str(agent)],
                                      env=environment)
            identity = str(uuid.uuid4()).upper()
            stream = socket.socket(socket.AF_UNIX)
            stream.settimeout(8)
            try:
                wait_socket(state / "host.sock", daemon)
                stream.connect(str(state / "host.sock"))
                stream.sendall(encode(b"H", 1, identity.encode()))
                inner_event(stream, 1, b"J")
                offset, _ = inner_event(stream, 1, b"S")
                stream.sendall(encode(b"D", 1, encode(b"A", offset)))
                stream.sendall(encode(b"D", 1, encode(b"W")))
                inner_event(stream, 1, b"W")
                session = "omg-runtime-" + identity.lower()
                root = state / "draft"
                scope = root / "sessions" / hashlib.sha256(session.encode()).hexdigest()
                metadata = json.loads((scope / "session.json").read_text())
                self.assertEqual(metadata["runtime_id"], identity)
                self.assertEqual(metadata["editor"], "/bin/false")
                env = dict(environment, OMG_REMOTE_ROOT=str(root))
                request = str(uuid.uuid4())
                command = [sys.executable, str(root / "omg")]
                wrong = subprocess.run(command + ["draft-begin", session, request, metadata["tty"], "wrong"],
                                       env=env, capture_output=True, timeout=5)
                self.assertNotEqual(wrong.returncode, 0)
                subprocess.run(command + ["draft-begin", session, request, metadata["tty"], metadata["runtime_generation"]],
                               env=env, capture_output=True, check=True, timeout=5)
                for _ in range(100):
                    if original.with_suffix(".ready").exists(): break
                    time.sleep(.02)
                self.assertTrue(original.with_suffix(".ready").exists())
                stream.sendall(encode(b"D", 1, encode(b"I", 0, b"\x07")))
                result = subprocess.run(command + ["draft-read", session, request], env=env,
                                        capture_output=True, check=True, timeout=8)
                self.assertEqual(result.stdout, "OMG_REMOTE_DRAFT_V1\n中文 draft\nsecond line".encode())
                self.assertEqual(original.read_text(), "中文 draft\nsecond line")
                source = (ROOT / "macos/Sources/Features/QuickInput/QuickInputRemoteDraftBridge.swift").read_text()
                probe = textwrap.dedent(source.split('static let runtimeProbe = #"""', 1)[1].split('"""#', 1)[0])
                result = subprocess.run([sys.executable, "-", revision, identity], input=probe, env=environment,
                                        capture_output=True, text=True, check=True, timeout=8)
                target = json.loads(result.stdout)
                self.assertEqual(target["session"], session)
                self.assertEqual(target["tty"], metadata["tty"])
                self.assertEqual(target["generation"], metadata["runtime_generation"])
                metadata["runtime_generation"] = "replacement"
                (scope / "session.json").write_text(json.dumps(metadata))
                changed = subprocess.run(command + ["draft-read", session, request], env=env,
                                         capture_output=True, timeout=5)
                self.assertNotEqual(changed.returncode, 0)
            finally:
                stream.close()
                try:
                    deadline = time.monotonic() + 8
                    while True:
                        with socket.socket(socket.AF_UNIX) as control:
                            control.settimeout(3)
                            control.connect(str(state / "host.sock"))
                            control.sendall(encode(b"K", 1, identity.encode()))
                            _, _, data = frame(control)
                        if data[13:] == b"closed" or time.monotonic() > deadline: break
                        time.sleep(.05)
                finally:
                    daemon.terminate()
                    daemon.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
