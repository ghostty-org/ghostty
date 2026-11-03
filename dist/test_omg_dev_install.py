import re
import unittest
from pathlib import Path


class DevInstallerProcessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).resolve().parents[1]
        script = (root / ".agents/skills/omg-release/scripts/install-dev.sh").read_text()
        cls.pattern = re.compile(re.search(r"^gui_process_pattern='([^']+)'$", script, re.M)[1])
        cls.executable = "/Applications/OMG Dev.app/Contents/MacOS/omg"

    def test_gui_with_or_without_arguments_blocks_replacement(self):
        for suffix in ["", " --working-directory=/tmp", " -e /bin/sh"]:
            with self.subTest(suffix=suffix):
                self.assertIsNotNone(self.pattern.search(self.executable + suffix))

    def test_persistent_cli_commands_do_not_block_replacement(self):
        for suffix in [" +ssh -- test-host", " +ssh --remote-working-directory=/tmp -- test-host", " +new-window"]:
            with self.subTest(suffix=suffix):
                self.assertIsNone(self.pattern.search(self.executable + suffix))

    def test_other_apps_and_wrapper_command_lines_are_not_gui_processes(self):
        for command in [
            "/Applications/OMG.app/Contents/MacOS/omg",
            "/Applications/OMG Dev PTY.app/Contents/MacOS/omg",
            self.executable + "-helper",
            "/bin/sh -c " + self.executable,
        ]:
            with self.subTest(command=command):
                self.assertIsNone(self.pattern.search(command))


if __name__ == "__main__":
    unittest.main()
