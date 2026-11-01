"""Daemon-owned completion cleanup and conversation recovery using a fixture Agent."""
import json
import os
from pathlib import Path
import socket
import shlex
import subprocess
import tempfile
import time
import unittest
import uuid
from test_sessions import BINARY, encode, frame


class AgentRecoveryTests(unittest.TestCase):
    def test_completion_persists_conversation_and_resume_uses_new_pid(self):
        with tempfile.TemporaryDirectory(prefix='omg-agent-', dir='/tmp') as directory:
            root = Path(directory)
            home = root/'home'
            home.mkdir()
            conversation = 'fixture-conversation'
            store = home/'.claude/projects/project'
            store.mkdir(parents=True)
            (store/(conversation+'.jsonl')).write_text('{"type":"session"}\n')
            bin_dir = root/'bin'
            bin_dir.mkdir()
            agent = bin_dir/'claude'
            agent.write_text('#!/bin/sh\nprintf "RESUMED:%s:%s\\n" "$1" "$2"\nexec sleep 60\n')
            agent.chmod(0o700)
            shell = root/'shell'
            shell.write_text('#!/bin/sh\nexport PATH="'+str(bin_dir)+':/usr/bin:/bin"\nexec /bin/sh "$@"\n')
            shell.chmod(0o700)
            (root/'policy.json').write_text(json.dumps({'close_on_agent_done': True,
                'agent_done_grace_seconds': 1, 'terminate_grace_seconds': 1,
                'detached_ttl_seconds': 60, 'host_idle_seconds': 60}))
            host = subprocess.Popen([str(BINARY), 'host', str(root), '--', str(shell), '-i'],
                                    env={**os.environ, 'HOME': str(home)})
            pane = str(uuid.uuid4())
            clients = []
            def attach(resume_generation=None):
                s = socket.socket(socket.AF_UNIX)
                s.settimeout(8)
                s.connect(str(root/'host.sock'))
                clients.append(s)
                if resume_generation is None:
                    s.sendall(encode(b'H', 1, pane.encode()))
                else:
                    request = json.dumps({
                        'id': pane,
                        'generation': resume_generation,
                    }).encode()
                    s.sendall(encode(b'U', 1, request))
                info = None
                while True:
                    kind, stream, data = frame(s)
                    if kind == b'E': self.fail(data.decode())
                    if kind != b'D': continue
                    if data[:1] == b'J': info = json.loads(data[13:])
                    if data[:1] == b'S':
                        import struct
                        seq = struct.unpack('>Q', data[1:9])[0]
                        s.sendall(encode(b'D', 1, encode(b'A', seq)))
                        s.sendall(encode(b'D', 1, encode(b'W')))
                    if data[:1] == b'W': return s, info
            try:
                for _ in range(100):
                    if (root/'host.sock').exists(): break
                    time.sleep(.02)
                first, original = attach()
                task = f'"$OMG_RUNTIME_BIN" report claude working {conversation} {root}; sleep 0.2; "$OMG_RUNTIME_BIN" report claude done {conversation} {root}; exec sleep 60'
                command = '/bin/sh -c ' + shlex.quote(task) + '\n'
                first.sendall(encode(b'D', 1, encode(b'I', 0, command.encode())))
                record_path = root/'sessions'/f'{pane}.json'
                for _ in range(100):
                    record = json.loads(record_path.read_text())
                    if record.get('resume'): break
                    time.sleep(.02)
                self.assertEqual(record['resume']['conversation_id'], conversation)
                first.close()
                for _ in range(400):
                    record = json.loads(record_path.read_text())
                    if record['pid'] is None and record['ended']: break
                    time.sleep(.02)
                self.assertEqual(record['ended'], 'agent_completed')
                self.assertIsNone(record['pid'])
                attach_only = socket.socket(socket.AF_UNIX)
                attach_only.settimeout(5)
                attach_only.connect(str(root/'host.sock'))
                clients.append(attach_only)
                policy = json.loads((root/'policy.json').read_text())
                request = json.dumps({
                    'id': pane,
                    'policy': policy,
                    'create': False,
                    'cwd': None,
                }).encode()
                attach_only.sendall(encode(b'C', 2, request))
                while True:
                    kind, stream, _ = frame(attach_only)
                    if stream == 2:
                        self.assertEqual(kind, b'E')
                        break
                record = json.loads(record_path.read_text())
                self.assertEqual(record['ended'], 'agent_completed')
                self.assertIsNone(record['pid'])
                restored, current = attach(original['generation'])
                self.assertNotEqual(current['pid'], original['pid'])
                self.assertEqual(current['session_id'], original['session_id'])
                self.assertNotEqual(current['generation'], original['generation'])
                record = json.loads(record_path.read_text())
                self.assertEqual(record['resume']['conversation_id'], conversation)
                restored.sendall(encode(b'D', 1, encode(b'K')))
                while True:
                    k, _, data = frame(restored)
                    if k == b'D' and data[:1] == b'X': break
            finally:
                for client in clients: client.close()
                host.kill()
                host.wait()


if __name__ == '__main__': unittest.main()
