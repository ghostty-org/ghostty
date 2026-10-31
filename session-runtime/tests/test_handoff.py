"""Local PTY handoff acknowledgement; never connects to a remote host."""
import json
import os
from pathlib import Path
import pty
import select
import subprocess
import tempfile
import time
import unittest


class HandoffTests(unittest.TestCase):
    def test_accepted_sibling_tab_releases_local_shell_without_waiting_for_remote_exit(self):
        binary = Path(__file__).resolve().parents[1] / "target/debug/omgd"
        with tempfile.TemporaryDirectory() as directory:
            master, slave = pty.openpty()
            env = dict(os.environ, OMG_SSH_HANDOFF_DIRECTORY=directory, OMG_SSH_HANDOFF_TOKEN="test-capability")
            process = subprocess.Popen([str(binary), "handoff", "/usr/bin/ssh", "host"],
                                       stdin=slave, stdout=slave, stderr=subprocess.PIPE, env=env)
            os.close(slave)
            try:
                deadline = time.monotonic() + 3
                requests = []
                while not requests and time.monotonic() < deadline:
                    requests = list(Path(directory).glob("*.json"))
                    if not requests:
                        time.sleep(.02)
                self.assertEqual(len(requests), 1)
                request = requests[0]
                request.with_suffix(".accepted").write_bytes(b"")
                _, stderr = process.communicate(timeout=3)
                self.assertEqual(process.returncode, 0, stderr)
                self.assertFalse(request.exists())
                self.assertFalse(request.with_suffix(".accepted").exists())
                self.assertFalse(request.with_suffix(".done").exists())
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.communicate(timeout=3)
                os.close(master)

    def test_authenticated_failure_returns_without_timeout(self):
        binary = Path(__file__).resolve().parents[1] / "target/debug/omgd"
        self.assertTrue(binary.is_file(), "build the runtime before testing")
        with tempfile.TemporaryDirectory() as directory:
            master, slave = pty.openpty()
            env = dict(os.environ, OMG_SSH_HANDOFF_DIRECTORY=directory, OMG_SSH_HANDOFF_TOKEN="test-capability")
            process = subprocess.Popen([str(binary), "handoff", "/usr/bin/ssh", "host"],
                                       stdin=slave, stdout=slave, stderr=subprocess.PIPE, env=env)
            os.close(slave)
            try:
                deadline = time.monotonic() + 5
                signal = b""
                while b"\x07" not in signal and time.monotonic() < deadline:
                    if select.select([master], [], [], .1)[0]:
                        signal += os.read(master, 65536)
                self.assertIn(b"omg-runtime-request-", signal)
                requests = list(Path(directory).glob("*.json"))
                self.assertEqual(len(requests), 1)
                request = requests[0]
                self.assertEqual(json.loads(request.read_text())["token"], "test-capability")
                request.with_suffix(".failed").write_text("fixture setup failure")
                _, stderr = process.communicate(timeout=3)
                self.assertNotEqual(process.returncode, 0)
                self.assertIn(b"fixture setup failure", stderr)
                self.assertNotIn(b"timed out", stderr)
                self.assertFalse(request.exists())
                self.assertFalse(request.with_suffix(".failed").exists())
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.communicate(timeout=5)
                os.close(master)


if __name__ == "__main__":
    unittest.main()
