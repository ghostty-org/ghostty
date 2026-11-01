"""Opt-in SSH check: set OMG_SSH_TEST_CONFIG to a deployment connection JSON."""
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
from test_sessions import encode, frame


@unittest.skipUnless(os.environ.get('OMG_SSH_TEST_CONFIG'), 'requires explicit SSH deployment configuration')
class SSHMultiplexTests(unittest.TestCase):
    def test_two_panes_share_ssh_and_survive_transport_restart(self):
        binary = Path(__file__).resolve().parents[1] / 'target/debug/omgd'
        with tempfile.TemporaryDirectory(prefix='omg-mux-', dir='/tmp') as directory:
            path = directory + '/s'
            identities = [str(uuid.uuid4()).encode(), str(uuid.uuid4()).encode()]
            config = json.loads(Path(os.environ['OMG_SSH_TEST_CONFIG']).read_text())
            clients = []
            relay = None
            def start():
                p = subprocess.Popen([str(binary), 'connect', path, os.environ['OMG_SSH_TEST_CONFIG']], stderr=subprocess.DEVNULL)
                for _ in range(1500):
                    if os.path.exists(path):
                        return p
                    time.sleep(.02)
                raise TimeoutError('relay startup')
            def attach(identity):
                s = socket.socket(socket.AF_UNIX)
                s.settimeout(10)
                s.connect(path)
                clients.append(s)
                request = json.dumps({
                    'id': identity.decode(),
                    'policy': config['policy'],
                    'create': True,
                    'cwd': None,
                }).encode()
                s.sendall(encode(b'H', 0, request))
                generation = None
                info = None
                while True:
                    kind, seq, data = frame(s)
                    if kind == b'T':
                        generation = seq
                    elif kind == b'J':
                        info = json.loads(data)
                    elif kind == b'S':
                        self.assertIsNotNone(generation)
                        s.sendall(encode(b'A', seq, struct.pack('>Q', generation)))
                        s.sendall(encode(b'W', generation))
                    elif kind == b'W':
                        break
                    elif kind == b'E':
                        self.fail(data.decode())
                return s, info, generation
            try:
                relay = start()
                one, a, one_generation = attach(identities[0])
                two, b, two_generation = attach(identities[1])
                self.assertNotEqual(a['pid'], b['pid'])
                children = subprocess.check_output(['pgrep', '-P', str(relay.pid)], text=True).split()
                self.assertEqual(len(children), 1, 'one SSH child for both panes')
                ssh_pid = int(children[0])
                os.kill(ssh_pid, 15)
                def restore(existing, old_generation):
                    generation = old_generation
                    saw_new_status = False
                    info = None
                    while True:
                        kind, seq, data = frame(existing)
                        if kind == b'T' and seq != old_generation:
                            generation = seq
                            saw_new_status = True
                        elif kind == b'J':
                            info = json.loads(data)
                        elif kind == b'S' and saw_new_status:
                            existing.sendall(encode(b'A', seq, struct.pack('>Q', generation)))
                            existing.sendall(encode(b'W', generation))
                        elif kind == b'W' and saw_new_status:
                            return info, generation
                        elif kind == b'E':
                            self.fail(data.decode())
                again_a, one_generation = restore(one, one_generation)
                again_b, two_generation = restore(two, two_generation)
                self.assertEqual(a['pid'], again_a['pid'])
                self.assertEqual(b['pid'], again_b['pid'])
                one.sendall(encode(b'I', one_generation, b'sleep 60\n'))
                time.sleep(.2)
                one.sendall(encode(b'I', one_generation, b'\x03'))
                one.sendall(encode(b'I', one_generation, b'printf "MUX_%s_OK\\n" SIGNAL\n'))
                data = b''
                while b'MUX_SIGNAL_OK' not in data:
                    kind, _, payload = frame(one)
                    if kind == b'O':
                        data += payload
                for s in [one, two]:
                    generation = one_generation if s is one else two_generation
                    s.sendall(encode(b'K', generation))
                    while frame(s)[0] != b'X':
                        pass
            finally:
                for s in clients:
                    s.close()
                if relay is not None and relay.poll() is None:
                    relay.terminate()
                    relay.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
