"""Inline viewer integration on private PTYs; no SSH host or GUI is contacted."""
import base64
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import socket
import subprocess
import struct
import sys
import tempfile
import termios
import time
import unittest
import uuid

from test_sessions import BINARY, encode, frame


def private_json(path, value):
    path.write_text(json.dumps(value))
    path.chmod(0o600)


class InlineSSHTests(unittest.TestCase):
    def test_remote_exit_returns_to_same_local_shell_and_restores_its_terminal(self):
        self.exercise(False)

    def test_reconnect_keeps_original_process_and_returns_to_same_local_shell(self):
        self.exercise(True)

    def test_resize_queries_use_the_outer_terminals_cursor(self):
        self.exercise(False, resize=True)

    def test_inline_reconnect_restores_agent_changes_made_during_transport_loss(self):
        self.exercise(True, agent_changes=True)

    def exercise(self, disconnect, resize=False, agent_changes=False):
        with tempfile.TemporaryDirectory(prefix="omg-inline-", dir="/tmp") as directory:
            root = Path(directory)
            host = root / "host"
            host.mkdir(mode=0o700)
            policy = dict(detached_ttl_seconds=30, expires_at=None, close_on_agent_done=False,
                          agent_done_grace_seconds=1, terminate_grace_seconds=1,
                          host_idle_seconds=1, record_retention_seconds=60)
            private_json(host / "policy.json", policy)
            daemon = subprocess.Popen([str(BINARY), "host-local", str(host), "--", "/bin/sh"])
            parent, master = pty.fork()
            if parent == 0:
                env = dict(os.environ, OMG_SSH_HANDOFF_DIRECTORY=directory,
                           OMG_SSH_HANDOFF_TOKEN="inline-fixture", OMGD=str(BINARY))
                os.execve("/bin/sh", ["/bin/sh", "-c",
                    'printf "LOCAL_BEFORE:%s\\n" "$$"; "$OMGD" handoff /usr/bin/ssh fixture; '
                    'status=$?; printf "LOCAL_AFTER:%s:%s\\n" "$$" "$status"; exit "$status"'], env)
            output = bytearray()
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 640, 384))
            remote_id = str(uuid.uuid4())
            remote_pid = root / "remote.pid"
            active = root / "active.json"
            local_status = None
            replies = 0
            cursor_row = 7

            def read_output():
                nonlocal replies
                if select.select([master], [], [], .05)[0]:
                    try:
                        output.extend(os.read(master, 65536))
                        while output.count(b"\x1b[6n") > replies:
                            os.write(master, f"\x1b[{cursor_row};1R".encode())
                            replies += 1
                    except OSError as error:
                        if error.errno != errno.EIO:
                            raise

            def wait_until(condition, seconds=8):
                deadline = time.monotonic() + seconds
                while time.monotonic() < deadline:
                    if condition():
                        return
                    read_output()
                self.fail("inline viewer fixture timed out: " + repr(bytes(output[-1000:])))

            try:
                wait_until(lambda: bool(list(root.glob("*.json"))))
                request = next(root.glob("*.json"))
                payload = json.loads(request.read_text())
                self.assertEqual(payload["viewer"], "inline/1")
                self.assertEqual(payload["token"], "inline-fixture")
                connection_id = "omg-ssh-inline-" + request.stem
                private_json(active, dict(connectionID=connection_id))
                config = root / "connection.json"
                private_json(config, dict(
                    transport="local", executable="/usr/bin/ssh", arguments=["fixture"], cwd=directory,
                    local_shell="/bin/sh", bundle=str(BINARY.parent), revision="fixture",
                    policy=policy, local_state_directory=str(host), tty_authentication=True))
                script = (
                    "import os,sys,tty,select,time,signal\n"
                    f"open({str(remote_pid)!r},'w').write(str(os.getpid()))\n"
                    "tty.setraw(0)\n"
                    "signal.signal(signal.SIGWINCH,lambda *args:os.write(1,b'\\x1b[6n'))\n"
                    "os.write(1,b'REMOTE_READY\\r\\n\\x1b[6n')\n"
                    "def status(value):\n"
                    " os.write(1,('\\x1b]3008;start=omg-agent-omp-%d;type=app;omg_agent=omp;"
                    "omg_scope=remote;omg_liveness=pid;omg_state=%s\\x07'%(os.getpid(),value)).encode())\n"
                    "status('working'); changed=False\n"
                    "data=b''; deadline=time.monotonic()+12; announced=False\n"
                    f"while (b'hello' not in data or data.count(b'R')<{2 if resize else 1}) and time.monotonic()<deadline:\n"
                    " if select.select([0],[],[],.1)[0]: data+=os.read(0,4096)\n"
                    f" if not changed and os.path.exists({str(root / 'agent-change')!r}):\n"
                    "  status('needsAttention'); changed=True\n"
                    " if not announced and b'R' in data:\n"
                    "  os.write(1,b'REMOTE_QUERY_ACCEPTED\\r\\n'); announced=True\n"
                    "count=data.count(b'R')\n"
                    "os.write(1,('REMOTE_QUERY_COUNT:%d\\r\\n'%count).encode())\n"
                    f"sys.exit(7 if count=={2 if resize else 1} and b'hello' in data and b'STALE' not in data "
                    f"and b'[{9 if resize else 7};1R' in data else 90)\n"
                )
                launch = dict(argv=[sys.executable, "-c", script],
                              env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                                   "HOME": directory, "TERM": "xterm-256color"},
                              cwd=directory, cols=80, rows=24, pixel_width=640, pixel_height=384,
                              input_base64=base64.b64encode(b"").decode())
                relay = root / "relay.sock"
                approval = dict(helper=str(BINARY), configuration=str(config), socket=str(relay),
                    open=dict(id=remote_id, create=True, policy=policy, launch=launch, inline_viewer=True),
                    context=dict(connection_id=connection_id, target="fixture", local_cwd=directory,
                                 active_record=str(active)))
                private_json(request.with_suffix(".accepted"), approval)
                wait_until(lambda: b"REMOTE_QUERY_ACCEPTED" in output and active.exists()
                           and json.loads(active.read_text()).get("phase") == "ready" and replies >= 1)
                self.assertNotIn(b"LOCAL_AFTER", output)
                self.assertNotIn(b"\x1b[2J", output, "first attach must preserve the local terminal contents")
                self.assertEqual(replies, 1, "the outer terminal must be the only cursor-query authority")
                original_pid = int(remote_pid.read_text())
                if resize:
                    cursor_row = 9
                    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 10, 40, 320, 160))
                    wait_until(lambda: replies == 2)
                if disconnect:
                    generation = json.loads(active.read_text())["attachmentGeneration"]
                    before_reconnect = len(output)
                    daemon.terminate()
                    daemon.wait(timeout=5)
                    if agent_changes:
                        (root / "agent-change").touch()
                    wait_until(lambda: active.exists() and
                               json.loads(active.read_text()).get("phase") != "ready")
                    os.write(master, b"STALE\n")
                    wait_until(lambda: active.exists() and
                               json.loads(active.read_text()).get("phase") == "ready" and
                               json.loads(active.read_text()).get("attachmentGeneration", 0) > generation)
                    self.assertEqual(int(remote_pid.read_text()), original_pid)
                    os.kill(original_pid, 0)
                    if agent_changes:
                        wait_until(lambda: b"omg_state=needsAttention" in output[before_reconnect:]
                                   and b"start=omg-agent-sync;begin" in output[before_reconnect:])
                os.write(master, b"hello\n")
                wait_until(lambda: b"LOCAL_AFTER:" in output)
                for _ in range(50):
                    done, local_status = os.waitpid(parent, os.WNOHANG)
                    if done:
                        break
                    read_output()
                self.assertTrue(done, "the original shell must finish after remote exit")
                self.assertEqual(os.waitstatus_to_exitcode(local_status), 7, bytes(output[-1500:]))
                self.assertIn(f"LOCAL_BEFORE:{parent}".encode(), output)
                self.assertIn(f"LOCAL_AFTER:{parent}:7".encode(), output)
                self.assertIn(f"REMOTE_QUERY_COUNT:{2 if resize else 1}".encode(), output)
                self.assertFalse(active.exists())
            finally:
                if (host / "host.sock").exists():
                    try:
                        with socket.socket(socket.AF_UNIX) as control:
                            control.settimeout(2)
                            control.connect(str(host / "host.sock"))
                            control.sendall(encode(b"K", 1, remote_id.encode()))
                            frame(control)
                    except OSError:
                        pass
                if local_status is None:
                    try:
                        os.kill(parent, signal.SIGTERM)
                        os.waitpid(parent, 0)
                    except ProcessLookupError:
                        pass
                if daemon.poll() is None:
                    daemon.terminate()
                    daemon.wait(timeout=5)
                os.close(master)


if __name__ == "__main__":
    unittest.main()
