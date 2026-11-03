"""Explicit setup uses the deployment path without changing automatic consent."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_sessions import BINARY


class RuntimeInstallationTests(unittest.TestCase):
    def test_explicit_install_probes_with_automatic_install_disabled(self):
        with tempfile.TemporaryDirectory(prefix="omg-setup-", dir="/tmp") as directory:
            root = Path(directory)
            marker = root / "probed"
            ssh = root / "ssh"
            ssh.write_text(f"#!/bin/sh\ntouch '{marker}'\nexit 1\n")
            ssh.chmod(0o700)
            config = root / "connection.json"
            config.write_text(json.dumps(dict(
                executable=str(ssh), arguments=["fixture"], cwd=directory,
                bundle=directory, revision="fixture", policy={})))
            sidecar = root / "connection.json.setup.json"
            sidecar.write_text('{"auto_install":false}')
            result = subprocess.run(
                [str(BINARY), "install-runtime", str(config)],
                capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(marker.exists(), result.stderr)
            self.assertEqual(json.loads(sidecar.read_text()), {"auto_install": False})
            self.assertNotIn("auto_install", json.loads(config.read_text()))

    def test_explicit_install_rejects_local_transport_before_probing(self):
        with tempfile.TemporaryDirectory(prefix="omg-setup-", dir="/tmp") as directory:
            config = Path(directory) / "connection.json"
            config.write_text(json.dumps(dict(
                transport="local", executable="/does/not/exist",
                arguments=[], cwd=directory, bundle=directory,
                revision="fixture", policy={})))
            result = subprocess.run(
                [str(BINARY), "install-runtime", str(config)],
                capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("installation requires an SSH host", result.stderr)


if __name__ == "__main__":
    unittest.main()
