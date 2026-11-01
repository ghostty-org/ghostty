"""Real relay capability negotiation and close-local confirmation path."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest
from test_sessions import BINARY, encode, frame


class CloseRelayTests(unittest.TestCase):
    def test_list_local_uses_readonly_relay_control(self):
        with tempfile.TemporaryDirectory(prefix='omg-list-relay-', dir='/tmp') as directory:
            root = Path(directory)
            policy = dict(detached_ttl_seconds=259200, expires_at=None, close_on_agent_done=False,
                          agent_done_grace_seconds=60, terminate_grace_seconds=1,
                          host_idle_seconds=300, record_retention_seconds=604800)
            (root / 'policy.json').write_text(json.dumps(policy))
            daemon = subprocess.Popen([str(BINARY), 'host', directory, '--', '/bin/sh', '-i'])
            relay = None
            try:
                for _ in range(100):
                    if (root / 'host.sock').exists(): break
                    time.sleep(.02)
                ssh = root / 'ssh'
                import shlex
                ssh.write_text('#!/bin/sh\nprintf R\nexec ' + shlex.quote(str(BINARY)) + ' bridge ' + shlex.quote(str(root / 'host.sock')) + '\n')
                ssh.chmod(0o700)
                config = dict(transport='ssh', executable=str(ssh), arguments=['fake-host'], cwd=directory,
                              bundle=directory, policy=policy, revision='fixture',
                              local_state_directory=None, local_shell=None, hooks=None)
                (root / 'config.json').write_text(json.dumps(config))
                relay = subprocess.Popen([str(BINARY), 'connect', str(root / 'relay.sock'), str(root / 'config.json')])
                for _ in range(100):
                    if (root / 'relay.sock').exists(): break
                    time.sleep(.02)
                result = subprocess.run(
                    [str(BINARY), 'list-local', str(root / 'relay.sock')],
                    capture_output=True, text=True, timeout=10,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), [])
                self.assertEqual(list((root / 'sessions').glob('*.json')), [])
                self.assertTrue(relay.poll() is None)
                self.assertTrue(daemon.poll() is None)
            finally:
                for process in [relay, daemon]:
                    if process is not None:
                        process.terminate()
                        process.wait(timeout=5)

    def test_close_local_confirms_without_creating_an_attachment(self):
        with tempfile.TemporaryDirectory(prefix='omg-close-relay-', dir='/tmp') as directory:
            root = Path(directory)
            policy = dict(detached_ttl_seconds=259200, expires_at=None, close_on_agent_done=True,
                          agent_done_grace_seconds=60, terminate_grace_seconds=1,
                          host_idle_seconds=300, record_retention_seconds=604800)
            (root / 'policy.json').write_text(json.dumps(policy))
            daemon = subprocess.Popen([str(BINARY), 'host', directory, '--', '/bin/sh', '-i'])
            relay = None
            pid = None
            try:
                for _ in range(100):
                    if (root / 'host.sock').exists(): break
                    time.sleep(.02)
                ssh = root / 'ssh'
                import shlex
                ssh.write_text('#!/bin/sh\nprintf R\nexec ' + shlex.quote(str(BINARY)) + ' bridge ' + shlex.quote(str(root / 'host.sock')) + '\n')
                ssh.chmod(0o700)
                config = dict(transport='ssh', executable=str(ssh), arguments=['fake-host'], cwd=directory,
                              bundle=directory, policy=policy, revision='fixture',
                              local_state_directory=None, local_shell=None, hooks=None)
                (root / 'config.json').write_text(json.dumps(config))
                relay = subprocess.Popen([str(BINARY), 'connect', str(root / 'relay.sock'), str(root / 'config.json')])
                for _ in range(100):
                    if (root / 'relay.sock').exists(): break
                    time.sleep(.02)
                identity = b'66666666-6666-6666-6666-666666666666'
                with socket.socket(socket.AF_UNIX) as s:
                    s.settimeout(5)
                    s.connect(str(root / 'relay.sock'))
                    request = json.dumps({
                        'id': identity.decode(),
                        'policy': policy,
                        'create': True,
                        'cwd': None,
                    }).encode()
                    s.sendall(encode(b'H', 0, request))
                    while True:
                        kind, _, data = frame(s)
                        if kind == b'J':
                            pid = json.loads(data)['pid']
                            break
                        self.assertEqual(kind, b'T')
                deadline = time.monotonic() + 10
                while True:
                    result = subprocess.run([str(BINARY), 'close-local', str(root / 'relay.sock'), identity.decode()],
                                            capture_output=True, timeout=16)
                    if result.returncode == 0: break
                    self.assertLess(time.monotonic(), deadline, result.stderr)
                    time.sleep(.1)
                self.assertTrue(relay.poll() is None)
                self.assertTrue(daemon.poll() is None)
                with self.assertRaises(ProcessLookupError): os.kill(pid, 0)
            finally:
                for process in [relay, daemon]:
                    if process is not None:
                        process.terminate()
                        process.wait(timeout=5)
                if pid:
                    try: os.killpg(pid, 9)
                    except ProcessLookupError: pass


if __name__ == '__main__': unittest.main()
