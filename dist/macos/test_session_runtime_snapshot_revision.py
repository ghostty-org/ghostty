import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("runtime_builder", Path(__file__).with_name("build-session-runtime.py"))
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class SnapshotRevisionTests(unittest.TestCase):
    def test_only_the_exact_verified_tree_reuses_the_epoch(self):
        current, previous = "a" * 64, "b" * 20
        self.assertEqual(builder.snapshot_revision(current, {current: previous}), previous)
        self.assertEqual(builder.snapshot_revision("c" * 64, {current: previous}), "c" * 20)
        self.assertEqual(builder.snapshot_revision(current, {}), current[:20])

    def test_invalid_mapping_fails_the_build(self):
        for mapping in [[], {"a": "b" * 20}, {"a" * 64: ""}, {"a" * 64: "z" * 20}]:
            with self.subTest(mapping=mapping), self.assertRaises(ValueError):
                builder.snapshot_revision("a" * 64, mapping)


if __name__ == "__main__":
    unittest.main()
