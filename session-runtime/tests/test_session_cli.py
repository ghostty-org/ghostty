"""Management CLI: real disposable hosts, channel isolation and explicit close."""
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest
import uuid

from test_sessions import BINARY, encode, frame
from test_local_runtime import wait_socket, inner_event, wait_holders_stopped


class SessionCLITests(unittest.TestCase):
    def test_catalogue_and_close_are_scoped_and_require_complete_inventory(self):
        with tempfile.TemporaryDirectory(prefix="omg-cli-", dir="/tmp") as directory:
            home = Path(directory)
            environment = dict(os.environ, HOME=directory)
            fixtures = []

            def host(channel):
                support = home / channel
                revision = "pinned-fixture"
                key = hashlib.sha256((str(support) + "\0" + revision).encode()).hexdigest()[:20]
                state = home / ".omg/run" / key
                state.mkdir(parents=True, mode=0o700)
                daemon = subprocess.Popen([str(BINARY), "host-local", str(state), "--", "/bin/sh"],
                                          env=environment)
                identity = str(uuid.uuid4())
                fixtures.append((daemon, state, identity))
                wait_socket(state / "host.sock", daemon)
                with socket.socket(socket.AF_UNIX) as stream:
                    stream.settimeout(8)
                    stream.connect(str(state / "host.sock"))
                    launch = dict(argv=["/bin/sh", "-c", "sleep 600"],
                                  env={"PATH": "/usr/bin:/bin", "HOME": directory},
                                  cwd=directory, cols=80, rows=24, pixel_width=640,
                                  pixel_height=384, input_base64="")
                    stream.sendall(encode(b"C", 1, json.dumps(dict(
                        id=identity, create=True, launch=launch, policy={})).encode()))
                    inner_event(stream, 1, b"J")
                archive = support / "session-runtime/endpoints.json"
                archive.parent.mkdir(parents=True)
                endpoint = dict(descriptor=dict(revision=revision, policy={}), lastUsedAt=0)
                archive.write_text(json.dumps(dict(version=1, endpoints=[endpoint, endpoint])))
                return support, archive, endpoint

            def run(support, *args):
                return subprocess.run([str(BINARY), "sessions", *args, "--app-support", str(support), "--json"],
                                      env=environment, capture_output=True, text=True, timeout=40)
            try:
                dev, archive, endpoint = host("Dev")
                release, _, _ = host("Release")
                result = run(dev, "list")
                self.assertEqual(result.returncode, 0, result.stderr)
                report = json.loads(result.stdout)
                self.assertEqual(len(report["sessions"]), 1)
                self.assertEqual(report["sessions"][0]["revision"], "pinned-fixture")
                self.assertNotIn("holder_capability", result.stdout)
                refused = run(dev, "close", "--all")
                self.assertNotEqual(refused.returncode, 0)
                self.assertIsNone(json.loads(run(dev, "list").stdout)["sessions"][0]["ended"])
                offline = dict(descriptor=dict(revision="pinned-fixture", connection=dict(
                    destination="offline-fixture", options=[], workspaceID="ssh:offline-fixture",
                    executablePath="/does/not/exist", localWorkingDirectory=directory)))
                archive.write_text(json.dumps(dict(version=1, endpoints=[endpoint, offline])))
                partial = run(dev, "close", "--all", "--yes")
                self.assertNotEqual(partial.returncode, 0)
                self.assertTrue(partial.stdout, partial.stderr)
                self.assertEqual(json.loads(partial.stdout)["closed"], 0)
                self.assertIsNone(json.loads(run(dev, "list", "--local").stdout)["sessions"][0]["ended"])
                closed = run(dev, "close", "--all", "--yes", "--local")
                self.assertEqual(closed.returncode, 0, closed.stderr + closed.stdout)
                self.assertEqual(json.loads(closed.stdout)["closed"], 1)
                self.assertIsNone(json.loads(run(release, "list").stdout)["sessions"][0]["ended"])
                self.assertEqual(run(release, "close", "--all", "--yes").returncode, 0)
            finally:
                for daemon, state, identity in fixtures:
                    try:
                        with socket.socket(socket.AF_UNIX) as stream:
                            stream.settimeout(3)
                            stream.connect(str(state / "host.sock"))
                            stream.sendall(encode(b"K", 1, identity.encode()))
                            frame(stream)
                        wait_holders_stopped(state / "sessions")
                    finally:
                        daemon.terminate()
                        daemon.wait(timeout=5)

    def test_empty_catalogue_is_read_only(self):
        with tempfile.TemporaryDirectory(prefix="omg-cli-", dir="/tmp") as directory:
            support = Path(directory) / "absent"
            result = subprocess.run([str(BINARY), "sessions", "list", "--json",
                                     "--app-support", str(support)],
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["sessions"], [])
            self.assertFalse(support.exists())

    def test_saved_ssh_endpoint_uses_host_protocol_without_deployment(self):
        with tempfile.TemporaryDirectory(prefix="omg-cli-ssh-", dir="/tmp") as directory:
            root = Path(directory)
            state = root / "remote"
            state.mkdir(mode=0o700)
            daemon = subprocess.Popen([str(BINARY), "host", str(state), "--", "/bin/sh", "-i"])
            identity = str(uuid.uuid4())
            try:
                wait_socket(state / "host.sock", daemon)
                with socket.socket(socket.AF_UNIX) as stream:
                    stream.settimeout(8)
                    stream.connect(str(state / "host.sock"))
                    stream.sendall(encode(b"H", 1, identity.encode()))
                    inner_event(stream, 1, b"J")
                ssh = root / "ssh"
                ssh.write_text(f"#!/bin/sh\nprintf R\nexec '{BINARY}' bridge '{state / 'host.sock'}'\n")
                ssh.chmod(0o700)
                support = root / "App"
                archive = support / "session-runtime/endpoints.json"
                archive.parent.mkdir(parents=True)
                endpoint = dict(descriptor=dict(
                    revision="existing-remote", connection=dict(
                        destination="remote-fixture", options=["-p", "2222"], workspaceID="ssh:remote-fixture",
                        executablePath=str(ssh), localWorkingDirectory=directory)))
                alias = json.loads(json.dumps(endpoint))
                alias["descriptor"]["connection"]["destination"] = "second-alias"
                archive.write_text(json.dumps(dict(version=1, endpoints=[endpoint, alias])))
                prefix = [str(BINARY), "sessions"]
                options = ["--host", "remote-fixture", "--app-support", str(support), "--json"]
                result = subprocess.run(prefix + ["list"] + options, capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)["sessions"][0]["id"], identity)
                options = ["--app-support", str(support), "--json"]
                inventory = subprocess.run(prefix + ["list"] + options, capture_output=True, text=True, timeout=15)
                self.assertEqual(len(json.loads(inventory.stdout)["sessions"]), 1)
                result = subprocess.run(prefix + ["close", "--all", "--yes"] + options,
                                        capture_output=True, text=True, timeout=25)
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                self.assertEqual(json.loads(result.stdout)["closed"], 1)
                self.assertFalse((root / ".local").exists())
            finally:
                daemon.terminate()
                daemon.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
