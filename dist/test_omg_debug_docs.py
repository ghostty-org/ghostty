"""Offline contracts for the OMG debug skill and its Dev-state policy."""

from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent
DEBUG_SKILL = ROOT / ".agents/skills/omg-debug/SKILL.md"
DIAGNOSTICS_DOC = ROOT / "docs/omg-dev-memory-diagnostics.md"


class OmgDebugDocsTests(unittest.TestCase):
    def test_release_app_and_unrelated_work_stay_protected(self):
        skill = DEBUG_SKILL.read_text()
        self.assertIn("Never quit, rebuild over, replace, or modify the release app", skill)
        self.assertIn("/Applications/OMG.app", skill)
        self.assertIn("the release app stay out of scope", skill)
        self.assertIn("stopping unrelated processes", skill)
        self.assertIn("issue/PR publication, pushes, or merges", skill)
        self.assertIn("the user's uncommitted", skill)

    def test_dev_state_is_treated_as_disposable(self):
        skill = DEBUG_SKILL.read_text()
        self.assertIn("Dev state is disposable", skill)
        self.assertIn("do not spend the task", skill)
        self.assertIn("Confirm the target is a Dev bundle", skill)
        self.assertNotIn("preserve its session data", skill)
        self.assertNotIn("task authorization is not permission to lose user work", skill)

    def test_diagnostics_doc_matches_the_dev_state_policy(self):
        diagnostics = DIAGNOSTICS_DOC.read_text()
        self.assertIn("Dev session state is disposable", diagnostics)
        self.assertNotIn("preserve open terminal sessions through the normal", diagnostics)

    def test_skill_links_resolve(self):
        skill = DEBUG_SKILL.read_text()
        self.assertIn("../../../docs/omg-dev-memory-diagnostics.md", skill)
        self.assertIn("../omg-build/SKILL.md", skill)


if __name__ == "__main__":
    unittest.main()
