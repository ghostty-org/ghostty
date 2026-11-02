"""Behavior tests for generated +ssh identity wrappers (requires mise/zig and shells).
Run: python3 dist/test_ssh_agent_wrappers.py
"""
from pathlib import Path
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

BOOTSTRAP_PREFIX = "__omg_bootstrap=$(printf %s "
BOOTSTRAP_SUFFIX = " | base64 -d)"


def decoded_bootstrap(envelope):
    """Return the bootstrap script behind the base64 envelope.

    The session id (omg-ssh-<n>) lives inside the encoded script, so the
    acceptance comparison must decode before normalizing it.
    """
    start = envelope.find(BOOTSTRAP_PREFIX)
    if start < 0:
        return envelope
    start += len(BOOTSTRAP_PREFIX)
    end = envelope.find(BOOTSTRAP_SUFFIX, start)
    if end < 0:
        raise AssertionError("SSH bootstrap envelope is missing its base64 terminator")
    return base64.b64decode(envelope[start:end]).decode()


class RemoteAgentWrappersTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="omg-agent-wrappers-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.directory = Path(cls.temp.name)
        cls.bin = cls.directory / "bin"
        cls.bin.mkdir()
        source = (ROOT / "src/cli/ssh.zig").read_text()
        agent = source.split("const RemoteAgent = enum {", 1)[1].split("\n};", 1)[0]
        wrapper = source.split("fn remoteShellCommand(", 1)[1].split("\nfn writeSessionStart", 1)[0]
        # The snippet runs as its own module rooted at the temp directory, so
        # the packaging module and the files it embeds must live inside that
        # root with the same layout as src/: cli/ssh_shell_integration.zig
        # embeds ../shell-integration/....
        wrapper = wrapper.replace(
            '@import("ssh_shell_integration.zig")',
            '@import("cli/ssh_shell_integration.zig")',
        )
        (cls.directory / "cli").mkdir()
        shutil.copyfile(
            ROOT / "src/cli/ssh_shell_integration.zig",
            cls.directory / "cli" / "ssh_shell_integration.zig",
        )
        shutil.copytree(ROOT / "src/shell-integration", cls.directory / "shell-integration")
        driver = cls.directory / "wrappers.zig"
        driver.write_text(
            'const std = @import("std");\n'
            'const Allocator = std.mem.Allocator;\n'
            'const RemoteAgent = enum {' + agent + '\n};\n'
            'fn remoteShellCommand(' + wrapper + '\n'
            'extern "c" fn write(c_int, [*]const u8, usize) isize;\n'
            'pub fn main() !void {\n'
            '  inline for (.{RemoteQuoteStyle.fish, RemoteQuoteStyle.shell}) |style| {\n'
            '    var output: std.Io.Writer.Allocating = .init(std.heap.page_allocator);\n'
            '    defer output.deinit();\n'
            '    try writeRemoteAgentWrappers(&output.writer, style);\n'
            '    _ = write(1, output.written().ptr, output.written().len);\n'
            '    _ = write(1, "\\x00", 1);\n'
            '  }\n'
            '  const command = remoteShellCommand(std.heap.page_allocator, "cloud", "omg-ssh-test", null, .antigravity, null).?;\n'
            '  _ = write(1, command.ptr, command.len);\n'
            '  _ = write(1, "\\x00", 1);\n'
            '}\n'
        )
        compiled = subprocess.run(
            ["mise", "exec", "zig@0.16.0", "--", "zig", "run", "-lc", str(driver)],
            cwd=ROOT, capture_output=True, check=True, timeout=120,
        )
        fish, shell, cls.bootstrap, _ = compiled.stdout.decode().split("\0")
        cls.binary_bootstrap = None
        if binary := os.environ.get("OMG_TEST_BINARY"):
            for required in ("fish", "bash", "zsh"):
                if not shutil.which(required):
                    raise RuntimeError(f"Binary acceptance requires {required}")
            capture = cls.bin / "capture-ssh"
            output = cls.directory / "ssh-argv.json"
            capture.write_text(f'#!{sys.executable}\nimport os,json,sys\nopen(os.environ["OMG_CAPTURE"], "w").write(json.dumps(sys.argv[1:]))\n')
            capture.chmod(0o700)
            subprocess.run([binary, "+ssh", "--terminfo=false", "--forward-env=false", "--cache=false",
                            "--ssh=" + str(capture), "--remote-agent=antigravity", "--", "cloud"],
                           env=dict(os.environ, OMG_CAPTURE=str(output)), capture_output=True, check=True, timeout=30)
            cls.binary_bootstrap = json.loads(output.read_text())[-1]
            normalized = re.sub(r"omg-ssh-[0-9]+", "omg-ssh-test",
                                decoded_bootstrap(cls.binary_bootstrap))
            if normalized != decoded_bootstrap(cls.bootstrap):
                raise AssertionError("App binary emits a different SSH bootstrap than current source; rebuild GhosttyKit before linking the app")
        cls.scripts = {"fish": fish.lstrip("; "), "bash": shell, "zsh": shell}
        for name in ("agy", "codex"):
            executable = cls.bin / name
            executable.write_text('#!/bin/sh\nprintf "ARG:<%s>\\n" "$@"\nexit 7\n')
            executable.chmod(0o700)

    def test_full_bootstrap_through_each_login_shell(self):
        real_fish = shutil.which("fish")
        if not real_fish:
            self.skipTest("fish not installed")
        # Preserve the actual generated -C argument, but disable interactive
        # startup files and terminate after the restored test agent returns.
        shim = self.bin / "fish"
        shim.write_text('#!/bin/sh\nexec ' + real_fish + ' --no-config -c "$3"\n')
        shim.chmod(0o700)
        try:
            for shell in ("fish", "bash", "zsh"):
                with self.subTest(login_shell=shell):
                    result = self.run_shell(shell, self.binary_bootstrap or self.bootstrap)
                    self.assertEqual(result.returncode, 7, result.stderr)
                    self.assertIn("omg_agent=antigravity;omg_scope=remote;omg_state=idle", result.stdout)
                    self.assertRegex(result.stdout, r"start=omg-ssh-(?:test|[0-9]+);type=remote")
                    self.assertNotIn("Unsupported use", result.stderr)
        finally:
            shim.unlink()

    def run_shell(self, shell, script):
        executable = shutil.which(shell)
        if not executable:
            self.skipTest(f"{shell} not installed")
        env = {
            "PATH": f"{self.bin}:/usr/bin:/bin:/opt/homebrew/bin",
            "HOME": str(self.directory),
            "ZDOTDIR": str(self.directory),
            "XDG_CONFIG_HOME": str(self.directory),
            "SHELL": shutil.which("fish") or "/bin/sh",
        }
        flags = ["--no-config"] if shell == "fish" else ["-f"] if shell == "zsh" else ["--noprofile", "--norc"]
        return subprocess.run([executable, *flags, "-c", script], env=env,
                              capture_output=True, text=True, timeout=15)

    def test_remote_omg_draft_bridge_in_real_pty(self):
        import pty
        agent = self.bin / "agy"
        original = agent.read_text()
        agent.write_text('''#!/usr/bin/env python3
import os, subprocess, sys
from pathlib import Path
omg = os.environ["OMG_REMOTE_COMMAND"]
session = os.environ["OMG_REMOTE_SESSION"]
request = "12345678-1234-1234-1234-123456789ABC"
draft = Path(os.environ["HOME"]) / "draft.md"
text = "中文 draft\\nsecond line\\n"
draft.write_text(text)
subprocess.run(["python3", omg, "draft-begin", session, request, os.ttyname(0)], check=True)
subprocess.run([os.environ["EDITOR"], str(draft)], check=True)
result = subprocess.check_output(["python3", omg, "draft-read", session, request])
assert result == b"OMG_REMOTE_DRAFT_V1\\n" + text.encode(), result
assert draft.read_text() == text
subprocess.run(["python3", omg, "draft-finish", session, request], check=True)
print("OMG_PTY_DRAFT_OK", flush=True)
''')
        fish_shim = self.bin / "fish"
        real_fish = shutil.which("fish")
        if real_fish:
            fish_shim.write_text('#!/bin/sh\nexec ' + real_fish + ' --no-config -c "$3"\n')
            fish_shim.chmod(0o700)
        try:
            for shell in ("bash", "zsh", "fish"):
                executable = shutil.which(shell)
                if not executable:
                    continue
                with self.subTest(shell=shell):
                    master, slave = pty.openpty()
                    try:
                        env = dict(os.environ, TMPDIR="/tmp", HOME=str(self.directory), ZDOTDIR=str(self.directory),
                                   XDG_CONFIG_HOME=str(self.directory), SHELL=executable,
                                   PATH=f"{self.bin}:/usr/bin:/bin:/opt/homebrew/bin")
                        import time
                        with tempfile.TemporaryFile() as output:
                            bootstrap = decoded_bootstrap(self.bootstrap)
                            bootstrap = bootstrap.replace('exec bash --rcfile "$__omg_rc" -i',
                                                          'exec bash --noprofile --norc -c \'source "$OMG_SSH_RC"\'')
                            bootstrap = bootstrap.replace('exec zsh -l',
                                                          'exec zsh -f -c \'source "$ZDOTDIR/.zshrc"\'')
                            process = subprocess.Popen(["/bin/sh", "-c", bootstrap], env=env,
                                                       stdin=slave, stdout=output, stderr=output,
                                                       start_new_session=True)
                            try:
                                deadline = time.monotonic() + 12
                                while time.monotonic() < deadline:
                                    output.seek(0)
                                    captured = output.read()
                                    if b"OMG_PTY_DRAFT_OK" in captured:
                                        break
                                    time.sleep(0.05)
                                self.assertIn(b"OMG_PTY_DRAFT_OK", captured, captured.decode(errors="replace")[-3000:])
                            finally:
                                process.wait(timeout=10)
                    finally:
                        os.close(master)
                        os.close(slave)
        finally:
            agent.write_text(original)
            fish_shim.unlink(missing_ok=True)

    def test_identity_arguments_cleanup_and_exit_status(self):
        for shell, wrapper in self.scripts.items():
            for command, agent in (("agy", "antigravity"), ("codex", "codex")):
                with self.subTest(shell=shell, agent=agent):
                    prompt = ("function __omg_report_pwd; printf 'PROMPT\\n'; end\n" if shell == "fish"
                              else "__omg_report_pwd() { printf 'PROMPT\\n'; }\n")
                    result = self.run_shell(shell, prompt + wrapper + f"\n{command} 'two words' ';literal'\n")
                    self.assertEqual(result.returncode, 7, result.stderr)
                    self.assertRegex(result.stdout, re.escape(f"omg_agent={agent};omg_scope=remote;omg_state=idle"))
                    self.assertTrue(result.stdout.endswith("ARG:<two words>\nARG:<;literal>\nPROMPT\n"), result.stdout)
                    self.assertNotIn("omg_state=done", result.stdout)

    def test_all_builtin_agents_have_remote_identity_without_hooks(self):
        source = (ROOT / "src/cli/ssh.zig").read_text()
        body = source.split("const RemoteAgent = enum {", 1)[1].split("fn commandName", 1)[0]
        agents = re.findall(r"^    ([a-z]+),$", body, re.MULTILINE)
        self.assertGreater(len(agents), 10)
        for shell, wrapper in self.scripts.items():
            for agent in agents:
                with self.subTest(shell=shell, agent=agent):
                    self.assertIn(f"omg_agent={agent};omg_scope=remote;omg_state=idle", wrapper)

    def test_existing_user_function_is_preserved(self):
        for shell, wrapper in self.scripts.items():
            with self.subTest(shell=shell):
                custom = ("function codex; printf 'CUSTOM'; end\n" if shell == "fish"
                          else "codex() { printf 'CUSTOM'; }\n")
                result = self.run_shell(shell, custom + wrapper + "\ncodex\n")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "CUSTOM")

    def test_existing_user_alias_is_preserved(self):
        for shell in ("bash", "zsh"):
            with self.subTest(shell=shell):
                enable = "shopt -s expand_aliases\n" if shell == "bash" else ""
                result = self.run_shell(shell, enable + "alias codex='printf CUSTOM'\n" + self.scripts[shell] + "\neval codex\n")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "CUSTOM")


if __name__ == "__main__":
    unittest.main()
