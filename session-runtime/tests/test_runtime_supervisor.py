"""Real local supervisor reconnect tests using a private fake SSH bridge."""
import json
import os
from pathlib import Path
import shlex
import signal
import socket
import subprocess
import struct
import tempfile
import time
import uuid
import unittest

from test_sessions import BINARY, encode, frame


DEFAULT_POLICY = {
    "detached_ttl_seconds": 259200,
    "expires_at": None,
    "close_on_agent_done": False,
    "agent_done_grace_seconds": 60,
    "terminate_grace_seconds": 1,
    "host_idle_seconds": 300,
    "record_retention_seconds": 604800,
}


def wait_until(predicate, timeout=5, message="condition was not reached"):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError(message)


def stop_process(process):
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=2)


def process_parent_and_group(pid):
    try:
        result = subprocess.run(
            ["/bin/ps", "-o", "ppid=", "-o", "pgid=", "-p", str(pid)],
            capture_output=True,
            text=True,
            timeout=1,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    fields = result.stdout.split()
    if result.returncode != 0 or len(fields) != 2:
        return None
    try:
        return int(fields[0]), int(fields[1])
    except ValueError:
        return None


def find_host_process(state_directory):
    try:
        result = subprocess.run(
            ["/bin/ps", "-axo", "pid=,ppid=,pgid=,command="],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    marker = f"host {state_directory} -- /bin/sh -l"
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 3)
        if len(fields) != 4 or marker not in fields[3]:
            continue
        try:
            return int(fields[0]), int(fields[1]), int(fields[2])
        except ValueError:
            continue
    return None


def kill_owned_child(owner_pid, child_pid):
    # A pid file alone is not authority to signal a potentially reused PID.
    identity = process_parent_and_group(child_pid)
    if identity is None or identity[0] != owner_pid:
        return
    try:
        os.kill(child_pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


def kill_owned_session_group(owner_pid, session_pid):
    # Session workers call setsid, so their own PID is also their process group.
    identity = process_parent_and_group(session_pid)
    if identity is None or identity != (owner_pid, session_pid):
        return
    try:
        os.killpg(session_pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


def stop_owned_host(state_directory, host_pid):
    # The private state path is unique to this test; verify the exact command
    # again before signaling so a reused PID is never treated as ours.
    current = find_host_process(state_directory)
    if current is None or current[0] != host_pid:
        return
    try:
        os.kill(host_pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        return
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        current = find_host_process(state_directory)
        if current is None or current[0] != host_pid:
            return
        time.sleep(0.02)
    current = find_host_process(state_directory)
    if current is not None and current[0] == host_pid:
        try:
            os.kill(host_pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass


def make_connection(
    root,
    ssh_script,
    policy=None,
    transport="ssh",
    local_state_directory=None,
    local_shell=None,
    cwd=None,
):
    config = {
        "transport": transport,
        "executable": str(ssh_script),
        "arguments": ["fake-host"],
        "cwd": str(cwd or root),
        "bundle": str(root),
        "policy": policy or DEFAULT_POLICY,
        "revision": "supervisor-fixture",
        "hooks": None,
    }
    if local_state_directory is not None:
        config["local_state_directory"] = str(local_state_directory)
        config["local_shell"] = local_shell
    path = root / "connection.json"
    path.write_text(json.dumps(config))
    path.chmod(0o600)
    return path


def make_fake_ssh(root, host_socket, failing=False):
    script = root / ("fake-ssh-failing" if failing else "fake-ssh")
    count_path = root / "ssh-count"
    body = [
        "#!/bin/sh",
        "count=0",
        f"if [ -f {shlex.quote(str(count_path))} ]; then read count < {shlex.quote(str(count_path))}; fi",
        "count=$((count + 1))",
        f"printf '%s\\n' \"$count\" > {shlex.quote(str(count_path))}",
    ]
    if failing:
        body.extend([
            "printf 'Permission denied (publickey)\\n' >&2",
            "exit 255",
        ])
    else:
        body.extend([
            f"printf '%s\\n' \"$$\" > {shlex.quote(str(root))}/ssh-\"$count\".pid",
            "printf R",
            f"exec {shlex.quote(str(BINARY))} bridge {shlex.quote(str(host_socket))}",
        ])
    script.write_text("\n".join(body) + "\n")
    script.chmod(0o700)
    return script, count_path


def start_client(socket_path, config):
    relay = subprocess.Popen(
        [str(BINARY), "connect", str(socket_path), str(config)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        wait_until(
            lambda: socket_path.exists(),
            timeout=3,
            message="local supervisor did not bind its stable socket",
        )
    except Exception:
        stop_process(relay)
        raise
    return relay


def receive(peer, timeout=3):
    peer.settimeout(timeout)
    return frame(peer)


def wait_status(peer, state, after_generation=0, timeout=6):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        kind, generation, data = receive(peer, max(0.05, deadline - time.monotonic()))
        if kind == b"E":
            raise AssertionError(data.decode(errors="replace"))
        if kind == b"T":
            status = json.loads(data)
            if status["state"] == state and generation > after_generation:
                return generation, status
    raise AssertionError(f"missing {state} status after generation {after_generation}")


def receive_snapshot(peer, timeout=6):
    deadline = time.monotonic() + timeout
    generation = None
    info = None
    while time.monotonic() < deadline:
        kind, sequence, data = receive(peer, max(0.05, deadline - time.monotonic()))
        if kind == b"T":
            generation = sequence
        elif kind == b"J":
            info = json.loads(data)
        elif kind == b"S":
            if generation is None or info is None:
                raise AssertionError("snapshot arrived before endpoint status and session identity")
            return generation, info, sequence
        elif kind == b"E":
            return generation, None, data.decode(errors="replace")
    raise AssertionError("session did not attach")


def attach_peer(peer, session_id, create=True, cwd="/tmp", timeout=6):
    request = {
        "id": session_id,
        "policy": DEFAULT_POLICY,
        "create": create,
        "cwd": cwd,
    }
    peer.sendall(encode(b"H", 0, json.dumps(request).encode()))
    return receive_snapshot(peer, timeout=timeout)


def claim_writer(peer, generation, snapshot_offset, old_generation=None):
    if old_generation is not None:
        peer.sendall(encode(b"A", snapshot_offset, old_generation.to_bytes(8, "big")))
        peer.sendall(encode(b"W", old_generation))
        deadline = time.monotonic() + 0.15
        while time.monotonic() < deadline:
            try:
                kind, _, data = receive(peer, max(0.05, deadline - time.monotonic()))
            except socket.timeout:
                break
            if kind == b"W":
                raise AssertionError("stale generation claimed the writer")
            if kind == b"B":
                raise AssertionError("stale generation reached the remote writer")
            if kind == b"E":
                raise AssertionError(data.decode(errors="replace"))

    peer.sendall(encode(b"A", snapshot_offset, generation.to_bytes(8, "big")))
    peer.sendall(encode(b"W", generation))
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline:
        kind, sequence, data = receive(peer, max(0.05, deadline - time.monotonic()))
        if kind == b"E":
            raise AssertionError(data.decode(errors="replace"))
        if kind == b"B":
            raise AssertionError("current generation was denied the writer")
        if kind == b"W" and sequence == generation:
            return
    raise AssertionError("current generation did not acquire the writer")


def next_session_frame(peer, kind_wanted, timeout=4):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        kind, sequence, data = receive(peer, max(0.05, deadline - time.monotonic()))
        if kind == b"E":
            raise AssertionError(data.decode(errors="replace"))
        if kind == kind_wanted:
            return sequence, data
    raise AssertionError(f"missing session frame {kind_wanted!r}")


def wait_output_contains(peer, marker, timeout=4):
    output = bytearray()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        kind, _, data = receive(peer, max(0.05, deadline - time.monotonic()))
        if kind == b"E":
            raise AssertionError(data.decode(errors="replace"))
        if kind == b"X":
            raise AssertionError("session exited before output marker")
        if kind == b"O":
            output.extend(data)
            if marker in output:
                return bytes(output)
    raise AssertionError(f"output marker not observed: {marker!r}")


def marker_command(marker):
    octal = "".join(f"\\0{byte:03o}" for byte in marker.encode())
    # The marker is absent from terminal echo; it appears only if the shell ran it.
    return f"printf '%b\\n' '{octal}'\n".encode()


class RuntimeSupervisorTests(unittest.TestCase):
    def start_host(self, root):
        host_root = root / "host"
        host_root.mkdir(mode=0o700)
        host_root.chmod(0o700)
        daemon = subprocess.Popen(
            [str(BINARY), "host", str(host_root), "--", "/bin/sh", "-i"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        wait_until(
            lambda: (host_root / "host.sock").exists(),
            timeout=3,
            message="host daemon did not create its socket",
        )
        return host_root, daemon

    def start_relay(
        self,
        root,
        host_socket,
        failing=False,
        transport="ssh",
        local_state_directory=None,
        local_shell=None,
        cwd=None,
    ):
        local_root = root / "relay"
        local_root.mkdir(mode=0o700)
        local_root.chmod(0o700)
        ssh_script, count_path = make_fake_ssh(root, host_socket, failing=failing)
        config = make_connection(
            root,
            ssh_script,
            transport=transport,
            local_state_directory=local_state_directory,
            local_shell=local_shell,
            cwd=cwd,
        )
        socket_path = local_root / "client.sock"
        relay = start_client(socket_path, config)
        return socket_path, relay, count_path

    def connect_peer(self, socket_path):
        peer = socket.socket(socket.AF_UNIX)
        peer.settimeout(3)
        peer.connect(str(socket_path))
        return peer

    def test_two_confirmed_panes_reattach_and_fence_old_generation(self):
        with tempfile.TemporaryDirectory(prefix="omg-supervisor-", dir="/tmp") as temp:
            root = Path(temp)
            root.chmod(0o700)
            host_root, daemon = self.start_host(root)
            socket_path, relay, count_path = self.start_relay(root, host_root / "host.sock")
            peers = []
            session_pids = []
            ssh_pids = []
            try:
                identities = [str(uuid.uuid4()), str(uuid.uuid4())]
                attached = []
                for identity in identities:
                    peer = self.connect_peer(socket_path)
                    peers.append(peer)
                    generation, info, offset = attach_peer(
                        peer, identity, create=True, cwd=str(root)
                    )
                    self.assertEqual(info["session_id"], identity)
                    session_pids.append(info["pid"])
                    claim_writer(peer, generation, offset)
                    attached.append((peer, generation, info))

                self.assertNotEqual(session_pids[0], session_pids[1])
                wait_until(
                    lambda: count_path.exists() and count_path.read_text().strip() == "1",
                    timeout=3,
                    message="two panes did not share one SSH transport",
                )
                ssh_pids.append(int((root / "ssh-1.pid").read_text()))

                # Ensure the remote shell is responsive before dropping transport.
                token = "BEFORE_DISCONNECT_OK"
                attached[0][0].sendall(
                    encode(b"I", attached[0][1], marker_command(token))
                )
                output = wait_output_contains(attached[0][0], token.encode())
                self.assertIn(token.encode(), output)

                # Kill only the fake SSH child. Its PID is the script's $$,
                # preserved by exec into the bridge binary.
                old_generations = [entry[1] for entry in attached]
                os.kill(ssh_pids[0], signal.SIGTERM)
                generations = []
                for peer, old_generation in zip(peers, old_generations):
                    generation, _ = wait_status(
                        peer, "reconnecting", after_generation=old_generation, timeout=3
                    )
                    generations.append(generation)
                for new_generation, old_generation in zip(generations, old_generations):
                    self.assertGreater(new_generation, old_generation)

                # User input and resize captured under the old generation must
                # not reach the shell after the relay has moved on.
                for peer, old_generation in zip(peers, old_generations):
                    peer.sendall(
                        encode(b"I", old_generation, marker_command("OLD_INPUT_EXECUTED"))
                    )
                    peer.sendall(
                        encode(b"R", old_generation, struct.pack(">HH", 140, 50))
                    )

                wait_until(
                    lambda: count_path.exists()
                    and count_path.read_text().strip().isdigit()
                    and int(count_path.read_text().strip()) >= 2,
                    timeout=4,
                    message="fake SSH transport did not reconnect",
                )
                wait_until((root / "ssh-2.pid").exists, timeout=2)
                ssh_pids.append(int((root / "ssh-2.pid").read_text()))

                resumed = []
                for index, (peer, identity, previous_generation) in enumerate(
                    zip(peers, identities, generations)
                ):
                    generation, info, offset = receive_snapshot(peer, timeout=6)
                    self.assertGreaterEqual(generation, previous_generation)
                    self.assertEqual(info["session_id"], identity)
                    self.assertEqual(info["pid"], session_pids[identities.index(identity)])
                    self.assertEqual(info["cols"], 80)
                    self.assertEqual(info["rows"], 24)
                    claim_writer(
                        peer,
                        generation,
                        offset,
                        old_generation=old_generations[index],
                    )
                    resumed.append((peer, generation))

                # The command that would reveal a replay has no literal marker
                # in its echoed input. Waiting for the later barrier marker makes
                # the absence assertion independent of short timing windows.
                fresh = "AFTER_RECONNECT_OK"
                peers[0].sendall(encode(b"I", resumed[0][1], marker_command(fresh)))
                output = wait_output_contains(peers[0], fresh.encode())
                self.assertIn(fresh.encode(), output)
                self.assertNotIn(b"OLD_INPUT_EXECUTED", output)
            finally:
                for peer in peers:
                    peer.close()
                for pid in ssh_pids:
                    kill_owned_child(relay.pid, pid)
                stop_process(relay)
                for pid in session_pids:
                    kill_owned_session_group(daemon.pid, pid)
                stop_process(daemon)

    def test_missing_attach_retry_preserves_healthy_peer_and_does_not_create(self):
        with tempfile.TemporaryDirectory(prefix="omg-supervisor-retry-", dir="/tmp") as temp:
            root = Path(temp)
            root.chmod(0o700)
            host_root, daemon = self.start_host(root)
            socket_path, relay, count_path = self.start_relay(root, host_root / "host.sock")
            healthy = None
            missing = None
            session_pids = []
            ssh_pids = []
            try:
                healthy = self.connect_peer(socket_path)
                identity = str(uuid.uuid4())
                healthy_generation, info, offset = attach_peer(
                    healthy, identity, create=True, cwd=str(root)
                )
                self.assertEqual(info["session_id"], identity)
                session_pids.append(info["pid"])
                claim_writer(healthy, healthy_generation, offset)
                wait_until(
                    lambda: count_path.exists(),
                    timeout=3,
                    message="fake SSH was not started",
                )
                ssh_pids.append(int((root / "ssh-1.pid").read_text()))

                missing = self.connect_peer(socket_path)
                missing_id = str(uuid.uuid4())
                _, info, error = attach_peer(
                    missing, missing_id, create=False, cwd=str(root)
                )
                self.assertIsNone(info)
                self.assertIn("unknown session", error)
                self.assertFalse((host_root / "sessions" / f"{missing_id}.json").exists())
                self.assertFalse((host_root / "sessions" / f"{missing_id}.created").exists())

                result = subprocess.run(
                    [str(BINARY), "retry-local", str(socket_path)],
                    capture_output=True,
                    timeout=4,
                )
                self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
                # Explicit retry may repeat the missing attach, but must not
                # create that UUID or replace the healthy host transport.
                _, _, retry_error = receive_snapshot(missing, timeout=3)
                self.assertIn("unknown session", retry_error)
                self.assertEqual(count_path.read_text().strip(), "1")
                self.assertFalse((host_root / "sessions" / f"{missing_id}.created").exists())

                token = "HEALTHY_PEER_SURVIVED_RETRY"
                healthy.sendall(
                    encode(b"I", healthy_generation, marker_command(token))
                )
                output = wait_output_contains(healthy, token.encode())
                self.assertIn(token.encode(), output)
                self.assertFalse((host_root / "sessions" / f"{missing_id}.json").exists())
            finally:
                if healthy is not None:
                    healthy.close()
                if missing is not None:
                    missing.close()
                for pid in ssh_pids:
                    kill_owned_child(relay.pid, pid)
                stop_process(relay)
                for pid in session_pids:
                    kill_owned_session_group(daemon.pid, pid)
                stop_process(daemon)

    def test_authentication_failure_waits_for_manual_retry(self):
        with tempfile.TemporaryDirectory(prefix="omg-supervisor-auth-", dir="/tmp") as temp:
            root = Path(temp)
            root.chmod(0o700)
            # The host socket is unused for this case. A fake SSH process returns
            # the same stderr marker used by OpenSSH authentication failures.
            fake, count_path = make_fake_ssh(root, root / "unused-host.sock", failing=True)
            config = make_connection(root, fake)
            local_root = root / "relay"
            local_root.mkdir(mode=0o700)
            local_root.chmod(0o700)
            socket_path = local_root / "client.sock"
            relay = subprocess.Popen(
                [str(BINARY), "connect", str(socket_path), str(config)],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            peer = None
            try:
                wait_until(lambda: socket_path.exists(), timeout=3)
                peer = self.connect_peer(socket_path)
                generation, status = wait_status(peer, "attention", timeout=4)
                self.assertGreater(generation, 0)
                self.assertEqual(status["state"], "attention")
                time.sleep(0.5)
                self.assertEqual(count_path.read_text().strip(), "1")
            finally:
                if peer is not None:
                    peer.close()
                stop_process(relay)

    def test_local_transport_reattaches_detached_pane_without_affecting_sibling(self):
        with tempfile.TemporaryDirectory(prefix="omg-supervisor-local-", dir="/tmp") as temp:
            root = Path(temp)
            root.chmod(0o700)
            host_root, daemon = self.start_host(root)
            socket_path, relay, count_path = self.start_relay(
                root,
                host_root / "host.sock",
                transport="local",
                local_state_directory=host_root,
                local_shell="/bin/sh",
                cwd="/tmp",
            )
            peers = []
            session_pids = []
            try:
                identities = [str(uuid.uuid4()), str(uuid.uuid4())]
                active = []
                for identity in identities:
                    peer = self.connect_peer(socket_path)
                    peers.append(peer)
                    generation, info, offset = attach_peer(
                        peer, identity, create=True, cwd="/tmp"
                    )
                    self.assertEqual(info["session_id"], identity)
                    session_pids.append(info["pid"])
                    claim_writer(peer, generation, offset)
                    active.append((peer, generation))

                self.assertNotEqual(session_pids[0], session_pids[1])
                self.assertFalse(count_path.exists(), "local transport must bypass SSH")
                self.assertFalse((root / "ssh-1.pid").exists())

                before = "LOCAL_SIBLING_BEFORE_DETACH"
                active[1][0].sendall(
                    encode(b"I", active[1][1], marker_command(before))
                )
                output = wait_output_contains(active[1][0], before.encode())
                self.assertIn(before.encode(), output)

                # Losing one app-side attachment detaches that pane; it does not
                # stop its PTY or the shared local host connection.
                active[0][0].close()
                os.kill(session_pids[0], 0)
                self.assertFalse(count_path.exists(), "detaching must not start fake SSH")

                reattached = self.connect_peer(socket_path)
                peers.append(reattached)
                generation, info, offset = attach_peer(
                    reattached, identities[0], create=False, cwd="/tmp"
                )
                self.assertEqual(info["session_id"], identities[0])
                self.assertEqual(info["pid"], session_pids[0])
                claim_writer(reattached, generation, offset)
                self.assertFalse(count_path.exists(), "reattach must not start fake SSH")

                close_deadline = time.monotonic() + 8
                while True:
                    close = subprocess.run(
                        [str(BINARY), "close-local", str(socket_path), identities[0]],
                        capture_output=True,
                        timeout=16,
                    )
                    if close.returncode == 0:
                        break
                    self.assertLess(
                        time.monotonic(),
                        close_deadline,
                        close.stderr.decode(errors="replace"),
                    )
                    time.sleep(0.1)
                with self.assertRaises(ProcessLookupError):
                    os.kill(session_pids[0], 0)

                after = "LOCAL_SIBLING_AFTER_CLOSE"
                active[1][0].sendall(
                    encode(b"I", active[1][1], marker_command(after))
                )
                sibling_output = wait_output_contains(active[1][0], after.encode())
                self.assertIn(after.encode(), sibling_output)
                self.assertFalse(count_path.exists(), "local close must not use SSH")
            finally:
                for peer in peers:
                    peer.close()
                for pid in session_pids:
                    kill_owned_session_group(daemon.pid, pid)
                stop_process(relay)
                stop_process(daemon)

    def test_local_fresh_start_and_relay_restart_reuse_host_and_session(self):
        with tempfile.TemporaryDirectory(prefix="omg-supervisor-local-fresh-", dir="/tmp") as temp:
            root = Path(temp)
            root.chmod(0o700)
            local_state = root / "local-state"
            fake, count_path = make_fake_ssh(root, local_state / "host.sock")
            config = make_connection(
                root,
                fake,
                transport="local",
                local_state_directory=local_state,
                local_shell="/bin/sh",
                cwd="/tmp",
            )
            relay_root = root / "relay"
            relay_root.mkdir(mode=0o700)
            socket_path = relay_root / "client.sock"
            relay = None
            peers = []
            session_pid = None
            try:
                relay = start_client(socket_path, config)
                identity = str(uuid.uuid4())
                first = self.connect_peer(socket_path)
                peers.append(first)
                generation, info, offset = attach_peer(
                    first, identity, create=True, cwd="/tmp"
                )
                session_pid = info["pid"]
                claim_writer(first, generation, offset)
                host_info = find_host_process(local_state)
                self.assertIsNotNone(host_info, "local session host was not started")
                host_pid = host_info[0]
                self.assertFalse(count_path.exists(), "fresh local start must bypass SSH")

                marker = "LOCAL_FRESH_START_OK"
                first.sendall(encode(b"I", generation, marker_command(marker)))
                self.assertIn(marker.encode(), wait_output_contains(first, marker.encode()))

                first.close()
                stop_process(relay)
                relay = None
                socket_path.unlink(missing_ok=True)
                time.sleep(0.1)

                relay = start_client(socket_path, config)
                restored = self.connect_peer(socket_path)
                peers.append(restored)
                generation, info, offset = attach_peer(
                    restored, identity, create=False, cwd="/tmp"
                )
                self.assertEqual(info["session_id"], identity)
                self.assertEqual(info["pid"], session_pid)
                self.assertEqual(find_host_process(local_state)[0], host_pid)
                claim_writer(restored, generation, offset)
                self.assertFalse(count_path.exists(), "local reattach must not invoke SSH")

                marker = "LOCAL_FRESH_REATTACH_OK"
                restored.sendall(encode(b"I", generation, marker_command(marker)))
                self.assertIn(marker.encode(), wait_output_contains(restored, marker.encode()))
            finally:
                for peer in peers:
                    peer.close()
                if relay is not None:
                    for pid_file in root.glob("ssh-*.pid"):
                        try:
                            kill_owned_child(relay.pid, int(pid_file.read_text()))
                        except ValueError:
                            pass
                    stop_process(relay)
                host_info = find_host_process(local_state)
                if host_info is not None:
                    host_pid = host_info[0]
                    if session_pid is not None:
                        kill_owned_session_group(host_pid, session_pid)
                    stop_owned_host(local_state, host_pid)


if __name__ == "__main__":
    unittest.main()
