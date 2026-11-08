#!/usr/bin/env python3
"""Local-only compatibility check: encrypted key, OpenSSH certificate, forced askpass under a PTY.

Uses throwaway keys and an unprivileged sshd on 127.0.0.1. Never reads real SSH keys or Keychain.
"""
import getpass
import os
from pathlib import Path
import pty
import select
import socket
import subprocess
import tempfile
import time
import plistlib
import uuid
import sys


def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


with tempfile.TemporaryDirectory(prefix="ghostty-ssh-integration-") as work:
    root = Path(work)
    run("/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / "host"))
    run("/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / "ca"))
    run("/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "fixture-passphrase", "-f", str(root / "identity"))
    run("/usr/bin/ssh-keygen", "-q", "-s", str(root / "ca"), "-I", "ghostty-test", "-n", getpass.getuser(),
        "-V", "-1m:+5m", str(root / "identity.pub"))
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    config = root / "sshd_config"
    config.write_text(f"""Port {port}
ListenAddress 127.0.0.1
HostKey {root / 'host'}
PidFile {root / 'sshd.pid'}
AuthorizedKeysFile none
TrustedUserCAKeys {root / 'ca.pub'}
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
LogLevel VERBOSE
""")
    log = (root / "sshd.log").open("w+")
    server = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(config)], stdout=log, stderr=log)
    try:
        for _ in range(50):
            if server.poll() is not None:
                log.seek(0)
                raise RuntimeError("Test sshd could not start: " + log.read())
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                    break
            except OSError:
                time.sleep(0.1)
        helper = root / "askpass"
        helper.write_text(f'''#!/bin/sh
printf '%s\\n' "$1" >> '{root / "prompts"}'
case "$1" in
  *"Are you sure you want to continue connecting"*) printf 'yes\\n' ;;
  "Enter passphrase for key '{root / "identity"}': ") printf 'fixture-passphrase\\n' ;;
  *) exit 1 ;;
esac
''')
        helper.chmod(0o700)
        env = dict(os.environ, LC_ALL="C", SSH_ASKPASS=str(helper), SSH_ASKPASS_REQUIRE="force", DISPLAY="ghostty:0")
        master, slave = pty.openpty()
        client = subprocess.Popen([
            "/usr/bin/ssh", "-F", "/dev/null", "-p", str(port), "-i", str(root / "identity"),
            "-o", f'CertificateFile="{root / "identity-cert.pub"}"', "-o", "IdentitiesOnly=yes",
            "-o", "PreferredAuthentications=publickey", "-o", "StrictHostKeyChecking=ask",
            "-o", f"UserKnownHostsFile={root / 'known_hosts'}", "-o", "ConnectTimeout=5",
            "--", f"{getpass.getuser()}@127.0.0.1", "printf ghostty-ssh-ok"
        ], stdin=slave, stdout=slave, stderr=slave, env=env, start_new_session=True)
        os.close(slave)
        output = bytearray()
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], 0.1)
            if ready:
                try:
                    block = os.read(master, 65536)
                except OSError:
                    break
                if not block:
                    break
                output.extend(block)
            if client.poll() is not None and not ready:
                break
        if client.poll() is None:
            client.kill()
        client.wait()
        os.close(master)
        prompts = (root / "prompts").read_text() if (root / "prompts").exists() else ""
        log.flush()
        log.seek(0)
        server_log = log.read()
        assert client.returncode == 0, output.decode(errors="replace") + server_log
        assert b"ghostty-ssh-ok" in output
        assert "Enter passphrase for key" in prompts, prompts
        assert "Are you sure you want to continue connecting" in prompts, prompts
        assert "Accepted publickey" in server_log and "CERT" in server_log, server_log
        print("PASS: certificate authentication and forced askpass (host confirmation + encrypted key) under PTY")
        if "--signed-helper" in sys.argv:
            # Compile the actual product helper sources, isolated from GhosttyKit.
            repo = Path(__file__).resolve().parents[3]
            app = root / "SSHFixture.app" / "Contents"
            binary = app / "MacOS" / "SSHFixture"
            binary.parent.mkdir(parents=True)
            (app / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "com.mitchellh.ghostty.ssh-test." + uuid.uuid4().hex,
                "CFBundleExecutable": "SSHFixture", "CFBundlePackageType": "APPL"
            }))
            main = root / "main.swift"
            main.write_text((repo / "macos/Tests/SSH/helper-fixture.swift.txt").read_text())
            sources = ["SSHProfile", "SSHAuthenticationPolicy", "SSHChildProcess", "SSHCredentialStore",
                       "SSHAuthentication", "SSHHelperTrust", "SSHRuntime", "SSHEncodingConverter", "SSHEncodingRelay"]
            compile_sources = []
            for name in sources:
                source = (repo / f"macos/Sources/Features/SSH/{name}.swift").read_text()
                if "--diagnose" in sys.argv and name == "SSHHelperTrust":
                    source = source.replace("        var info = proc_bsdinfo()", """        fputs("trust paths: ssh=\\(processPath(sshPID) ?? "nil") launcher=\\(processPath(launcherPID) ?? "nil") self=\\(Bundle.main.executableURL?.path ?? "nil")\\n", stderr)
        var info = proc_bsdinfo()
        let inspected = proc_pidinfo(sshPID, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        fputs("trust ancestry: bytes=\\(inspected) parent=\\(info.pbi_ppid) expected=\\(launcherPID) canonical=\\(Bundle.main.executableURL!.resolvingSymlinksInPath().path)\\n", stderr)""")
                    source = source.replace("        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess", """        let result = SecCodeCheckValidity(code, [], requirement)
        fputs("trust code status: \\(pid) \\(result)\\n", stderr)
        return result == errSecSuccess""")
                copy = root / f"{name}.swift"
                copy.write_text(source)
                compile_sources.append(str(copy))
            spawn_object = root / "SSHPTYSpawn.o"
            spawn_header = repo / "macos/Sources/Features/SSH/SSHPTYSpawn.h"
            run("/usr/bin/clang", "-c", str(repo / "macos/Sources/Features/SSH/SSHPTYSpawn.c"), "-o", str(spawn_object))
            run("/usr/bin/swiftc", "-module-cache-path", str(root / "module-cache"),
                *compile_sources, str(main), str(spawn_object), "-import-objc-header", str(spawn_header), "-liconv", "-o", str(binary))
            run("/usr/bin/codesign", "--force", "--sign", "-", str(app.parent))
            pid, terminal = pty.fork()
            if pid == 0:
                os.execv(str(binary), [str(binary), str(root), str(port), getpass.getuser()])
            os.write(terminal, b"fixture-input\n")
            fixture_output = bytearray()
            deadline = time.monotonic() + 30
            done = False
            try:
                while time.monotonic() < deadline:
                    ready, _, _ = select.select([terminal], [], [], 0.1)
                    if ready:
                        try:
                            block = os.read(terminal, 65536)
                        except OSError:
                            break
                        if not block:
                            break
                        fixture_output.extend(block)
                    completed, status = os.waitpid(pid, os.WNOHANG)
                    if completed:
                        done = True
                        break
                while not done and time.monotonic() < deadline:
                    completed, status = os.waitpid(pid, os.WNOHANG)
                    done = completed != 0
                    if not done:
                        time.sleep(0.05)
                if not done:
                    raise RuntimeError("Signed helper timed out: " + fixture_output.decode(errors="replace"))
                assert os.waitstatus_to_exitcode(status) == 0, fixture_output.decode(errors="replace")
                assert b"ghostty-ssh-helper-ok:fixture-input" in fixture_output, fixture_output
                print("PASS: actual signed helper, Keychain round trip, caller rejection, certificate login and interactive input in foreground PTY")
            finally:
                os.close(terminal)
                if not done:
                    os.kill(pid, 9)
                    os.waitpid(pid, 0)

    finally:
        server.terminate()
        server.wait(timeout=5)
        log.close()
