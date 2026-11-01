"""Offline selector/runner regressions. No Xcode invocation or desktop interaction."""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

import omg_test_plan as planner

ROOT = Path(__file__).resolve().parent.parent
VISUAL_DESKTOP_TEST = "GhosttyTests/VerticalTabsIntegrationTests/appKitTabGroupDrivesVerticalTabsWithoutRecreatingSurfaces()"
LINK_HOVER_DESKTOP_TEST = "GhosttyTests/TerminalLinkHoverTests/commandHoverRemainsStable()"
QUICK_INPUT_DESKTOP_TEST = "GhosttyTests/QuickInputFooterMouseTests"
WORKSPACE_POPOVER_DESKTOP_TEST = (
    "GhosttyTests/TerminalWorkspacePopoverSwitchTests/"
    "nativeFullscreenMouseSelectionClosesAndSwitchesWithoutAnotherKey()"
)
TERMINATION_DESKTOP_TEST = (
    "GhosttyTests/TerminalApplicationTerminationTests/"
    "confirmedTerminationKeepsSelectedTabDuringRealSixtyTabFullscreenTeardown()"
)
BORDERLESS_DESKTOP_TESTS = {
    "GhosttyTests/TerminalWorkspaceManagementTests/nativeTabObservationSurvivesRepeatedBorderlessStyleChanges()",
    "GhosttyTests/TerminalWorkspaceManagementTests/nonNativeFullscreenSupportsWorkspaceCreationAndReturn()",
}
DESKTOP_TESTS = {
    "GhosttyTests/VerticalTabMouseTests",
    "GhosttyTests/VerticalTabFullscreenTests",
    "GhosttyTests/VerticalNativeTabOutlineDesktopTests",
    "GhosttyTests/TerminalWorkspaceManagementDesktopTests",
    QUICK_INPUT_DESKTOP_TEST,
    VISUAL_DESKTOP_TEST,
    LINK_HOVER_DESKTOP_TEST,
    WORKSPACE_POPOVER_DESKTOP_TEST,
    TERMINATION_DESKTOP_TEST,
    *BORDERLESS_DESKTOP_TESTS,
    "GhosttyTests/TerminalWorkspacePresentationTests/clickingWorkspaceButtonOpensItsNativePopover()",
}


def add_suite(root, relative, name, desktop=False):
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    tag = "@Suite(.tags(.interactiveDesktop))\n" if desktop else ""
    path.write_text(f"import Testing\n{tag}struct {name} {{ @Test func example() {{}} }}\n")


class PlannerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.catalog = planner.inventory(ROOT)

    def plan(self, **kwargs):
        return planner.make_plan(self.catalog, **kwargs)

    def test_default_is_all_regular_swift_without_desktop_or_xcuitest(self):
        result = self.plan()
        self.assertEqual(result["scope"], "all")
        self.assertEqual(result["only_testing"], [])
        self.assertTrue(result["run_swift"])
        self.assertIn("GhosttyUITests", result["skip_testing"])
        self.assertIn("GhosttyTests/VerticalTabMouseTests", result["deferred_desktop"])
        self.assertEqual(result["suite_count"], len(set().union(*self.catalog[0].values()) - self.catalog[1]))

    def test_git_selects_direct_dependents_and_version_smoke(self):
        result = self.plan(modules=["git"])
        self.assertEqual(result["modules"], ["editor", "git", "inspector"])
        self.assertIn(planner.SMOKE_SUITE, result["only_testing"])
        self.assertIn("GhosttyTests/GitDiffServiceTests", result["only_testing"])
        self.assertIn("GhosttyTests/EditorDocumentTests", result["only_testing"])
        self.assertIn("GhosttyTests/InspectorRegistryTests", result["only_testing"])
        self.assertNotIn("GhosttyTests/AgentStatusPluginTests", result["only_testing"])

    def test_every_module_has_valid_dependents_and_nonempty_smoke_coverage(self):
        for name, module in planner.MODULES.items():
            with self.subTest(module=name):
                self.assertTrue(set(module.dependents) <= set(planner.MODULES))
                result = self.plan(modules=[name])
                self.assertTrue(result["run_swift"])
                self.assertIn(planner.SMOKE_SUITE, result["only_testing"])
                self.assertFalse(set(result["only_testing"]) & self.catalog[1])

    def test_combined_modules_are_deduplicated(self):
        result = self.plan(modules=["git", "git", "editor"])
        self.assertEqual(len(result["only_testing"]), len(set(result["only_testing"])))
        self.assertEqual(result["modules"], ["editor", "git", "inspector", "terminal"])

    def test_all_module_retains_full_entry_point(self):
        self.assertEqual(self.plan(modules=["all"])["scope"], "all")

    def test_tabs_keep_policy_tests_and_defer_only_real_native_drag(self):
        result = self.plan(modules=["tabs"])
        self.assertIn("GhosttyTests/VerticalNativeTabOutlineTests", result["only_testing"])
        self.assertIn("GhosttyTests/VerticalNativeTabSidebarTests", result["only_testing"])
        self.assertIn("GhosttyTests/VerticalTabsIntegrationTests", result["only_testing"])
        self.assertNotIn("GhosttyTests/VerticalTabMouseTests", result["only_testing"])
        self.assertEqual(set(result["deferred_desktop"]), DESKTOP_TESTS - {QUICK_INPUT_DESKTOP_TEST})
        self.assertIn("GhosttyTests/VerticalTabsIntegrationTests", result["only_testing"])
        self.assertIn(VISUAL_DESKTOP_TEST, result["skip_testing"])

    def test_opt_in_restores_desktop_without_enabling_xcuitest(self):
        result = self.plan(modules=["tabs"], include_desktop=True)
        self.assertIn("GhosttyTests/VerticalTabMouseTests", result["only_testing"])
        self.assertEqual(result["skip_testing"], ["GhosttyUITests"])
        self.assertEqual(result["deferred_desktop"], [])

    def test_native_suite_or_method_requires_explicit_opt_in(self):
        for test in ["GhosttyTests/VerticalTabMouseTests", "GhosttyTests/VerticalTabMouseTests/mouseSelectionKeepsWorkingAcrossNativeWindows",
                     "GhosttyTests/VerticalTabFullscreenTests",
                     VISUAL_DESKTOP_TEST, VISUAL_DESKTOP_TEST[:-2],
                     LINK_HOVER_DESKTOP_TEST, LINK_HOVER_DESKTOP_TEST[:-2], QUICK_INPUT_DESKTOP_TEST,
                     WORKSPACE_POPOVER_DESKTOP_TEST, WORKSPACE_POPOVER_DESKTOP_TEST[:-2],
                     TERMINATION_DESKTOP_TEST, TERMINATION_DESKTOP_TEST[:-2],
                     *BORDERLESS_DESKTOP_TESTS, *(test[:-2] for test in BORDERLESS_DESKTOP_TESTS)]:
            with self.subTest(test=test), self.assertRaisesRegex(ValueError, "requires --include-desktop-tests"):
                self.plan(only_testing=[test])
            self.assertEqual(self.plan(only_testing=[test], include_desktop=True)["only_testing"], [test])

    def test_existing_single_method_selector_is_preserved(self):
        test = "GhosttyTests/SSHHostRegistryTests/testRegistrationPersistsExactConnectionsAndSwitchingOnlyReadsCache"
        self.assertEqual(self.plan(only_testing=[test])["only_testing"], [test])

    def test_explicit_target_still_excludes_desktop(self):
        result = self.plan(only_testing=["GhosttyTests"])
        self.assertIn("GhosttyTests/VerticalTabMouseTests", result["skip_testing"])
        self.assertEqual(set(result["deferred_desktop"]), DESKTOP_TESTS)

    def test_mixed_suite_keeps_normal_methods_and_defers_only_tagged_method(self):
        result = self.plan(only_testing=["GhosttyTests/VerticalTabsIntegrationTests"])
        self.assertEqual(result["only_testing"], ["GhosttyTests/VerticalTabsIntegrationTests"])
        self.assertEqual(result["deferred_desktop"], [VISUAL_DESKTOP_TEST])
        self.assertIn(VISUAL_DESKTOP_TEST, result["skip_testing"])
        self.assertEqual(result["suite_count"], 1)

    def test_bad_selections_fail_instead_of_running_zero_tests(self):
        for kwargs in [{"modules": []}, {"modules": ["gti"]}, {"only_testing": []},
                       {"only_testing": ["GhosttyTests/MissingTests"]}, {"only_testing": ["GhosttyUITests"]},
                       {"modules": ["git"], "paths": []}]:
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                self.plan(**kwargs)

    def test_source_change_selects_matching_module(self):
        result = self.plan(paths=["macos/Sources/Features/Git/GitDiffService.swift"])
        self.assertEqual(result["scope"], "changed")
        self.assertEqual(result["root_modules"], ["git"])

    def test_tabs_namespace_is_more_specific_than_terminal_parent(self):
        result = self.plan(paths=["macos/Sources/Features/Terminal/Tabs/VerticalTabBarView.swift"])
        self.assertEqual(result["root_modules"], ["tabs"])
        self.assertEqual(result["modules"], ["tabs", "terminal"])

    def test_tests_and_recursive_foundation_paths_are_mapped(self):
        for path in ["macos/Tests/Ghostty/ConfigTests.swift", "macos/Tests/Ghostty/Surface View/SurfaceKeyEquivalentRoutingTests.swift"]:
            with self.subTest(path=path):
                result = self.plan(paths=[path])
                self.assertEqual(result["root_modules"], ["foundation"])
                self.assertEqual(result["unknown_paths"], [])
        self.assertEqual(self.plan(paths=["macos/Tests/Git/GitDiffServiceTests.swift"])["root_modules"], ["git"])

    def test_overlapping_test_owners_are_not_lost(self):
        result = self.plan(paths=["macos/Tests/Git/SSHGitExecutorTests.swift"])
        self.assertEqual(result["root_modules"], ["git", "ssh"])

    def test_shared_core_host_or_configuration_changes_fall_back_to_all(self):
        for path in ["src/Surface.zig", "include/ghostty.h", "build.zig", "macos/build.nu",
                     "macos/Sources/Extensions/SharedAdapter.swift",
                     "macos/Ghostty.xctestplan", "macos/Sources/App/AppDelegate.swift",
                     "macos/Sources/Features/Terminal/TerminalController.swift", planner.VERSION_PROJECT]:
            with self.subTest(path=path):
                result = self.plan(paths=[path])
                self.assertEqual(result["scope"], "all")
                self.assertEqual(result["full_suite_paths"], [path])

    def test_unknown_source_changes_fall_back_to_all(self):
        path = "macos/Sources/Features/NewFeature/Foo.swift"
        result = self.plan(paths=[path])
        self.assertEqual(result["scope"], "all")
        self.assertEqual(result["unknown_paths"], [path])

    def test_documentation_only_or_no_change_does_not_launch_xcode(self):
        for paths in [[], ["docs/TESTING.md"], ["AGENTS.md", ".agents/skills/omg-build/SKILL.md"]]:
            with self.subTest(paths=paths):
                result = self.plan(paths=paths)
                self.assertFalse(result["run_swift"])
                self.assertEqual(result["only_testing"], [])
                self.assertEqual(result["suite_count"], 0)

    def test_settings_schema_is_not_treated_as_irrelevant_documentation(self):
        result = self.plan(paths=["docs/settings/schema.json"])
        self.assertEqual(result["root_modules"], ["settings"])
        self.assertTrue(result["run_swift"])

    def test_version_only_project_change_does_not_force_all(self):
        result = self.plan(paths=[planner.VERSION_PROJECT], version_only=True)
        self.assertEqual(result["scope"], "changed")
        self.assertEqual(result["root_modules"], ["update"])
        self.assertIn(planner.SMOKE_SUITE, result["only_testing"])
        self.assertNotIn("GhosttyTests/GitDiffServiceTests", result["only_testing"])

    def test_link_hover_suite_keeps_routine_methods_without_desktop(self):
        result = self.plan(only_testing=["GhosttyTests/TerminalLinkHoverTests"])
        self.assertEqual(result["only_testing"], ["GhosttyTests/TerminalLinkHoverTests"])
        self.assertEqual(result["deferred_desktop"], [LINK_HOVER_DESKTOP_TEST])
        self.assertIn(LINK_HOVER_DESKTOP_TEST, result["skip_testing"])

    def test_catalog_discovers_all_current_tests_and_single_desktop_suite(self):
        self.assertEqual(self.catalog[1], DESKTOP_TESTS)
        self.assertTrue(all(self.catalog[0].values()))

    def test_new_unmapped_test_file_is_an_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            add_suite(root, "macos/Tests/Helpers/OhMyGhosttyVersionTests.swift", "OhMyGhosttyVersionTests")
            add_suite(root, "macos/Tests/NewArea/AddedTests.swift", "AddedTests")
            with self.assertRaisesRegex(ValueError, "Unmapped test files"):
                planner.inventory(root)

    def test_unrecognized_test_type_cannot_silently_disappear(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / "macos/Tests/Custom.swift"
            path.parent.mkdir(parents=True)
            path.write_text("struct Custom { @Test func sample() {} }")
            with self.assertRaisesRegex(ValueError, "Cannot discover"):
                planner.inventory(root)


class GitSelectionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.run_git("init", "-q")
        self.run_git("config", "user.email", "test@example.invalid")
        self.run_git("config", "user.name", "Test Fixture")
        self.source = "macos/Sources/Features/Git/GitDiffService.swift"
        self.write(self.source, "baseline\n")
        self.write(planner.VERSION_PROJECT, "MARKETING_VERSION = 0.15.3;\nCURRENT_PROJECT_VERSION = 32;\nOTHER_SETTING = YES;\n")
        self.commit()
        self.run_git("tag", "baseline")

    def run_git(self, *args):
        return planner.git(self.root, *args)

    def write(self, relative, text):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def commit(self):
        self.run_git("add", ".")
        self.run_git("commit", "-qm", "fixture")

    def test_committed_staged_unstaged_and_untracked_paths_are_included(self):
        self.write(self.source, "committed\n")
        self.commit()
        staged = "macos/Tests/Git/StagedTests.swift"
        self.write(staged, "staged\n")
        self.run_git("add", staged)
        self.write(planner.VERSION_PROJECT, "unstaged\n")
        untracked = "macos/Sources/Features/Editor/新文件.swift"
        self.write(untracked, "untracked\n")
        paths, _ = planner.changed_paths(self.root, "baseline")
        self.assertEqual(set(paths), {self.source, staged, planner.VERSION_PROJECT, untracked})

    def test_rename_includes_old_and_new_modules_and_deletion(self):
        destination = "macos/Sources/Features/Editor/Renamed.swift"
        (self.root / destination).parent.mkdir(parents=True)
        (self.root / self.source).rename(self.root / destination)
        (self.root / planner.VERSION_PROJECT).unlink()
        self.commit()
        paths, _ = planner.changed_paths(self.root, "baseline")
        self.assertEqual(set(paths), {self.source, destination, planner.VERSION_PROJECT})

    def test_ignored_files_are_not_included(self):
        self.write(".gitignore", "ignored.swift\n")
        self.commit()
        self.write("ignored.swift", "ignore me\n")
        paths, _ = planner.changed_paths(self.root, "HEAD")
        self.assertEqual(paths, [])

    def test_worktree_revert_does_not_hide_committed_change(self):
        self.write(self.source, "new\n")
        self.commit()
        self.write(self.source, "baseline\n")
        paths, _ = planner.changed_paths(self.root, "baseline")
        self.assertEqual(paths, [self.source])

    def test_nul_delimiters_preserve_unusual_filenames(self):
        path = "macos/Sources/Features/Editor/space and\nnewline.swift"
        self.write(path, "untracked\n")
        paths, _ = planner.changed_paths(self.root, "HEAD")
        self.assertEqual(paths, [path])

    def test_bad_or_option_like_reference_fails(self):
        for reference in ["", "-HEAD", "missing-ref", "HEAD; touch injected"]:
            with self.subTest(reference=reference), self.assertRaises((ValueError, subprocess.CalledProcessError)):
                planner.changed_paths(self.root, reference)
        self.assertFalse((self.root / "injected").exists())

    def test_balanced_version_field_updates_are_metadata_only(self):
        self.write(planner.VERSION_PROJECT, "MARKETING_VERSION = 0.16.0;\nCURRENT_PROJECT_VERSION = 33;\nOTHER_SETTING = YES;\n")
        self.assertTrue(planner.version_only_change(self.root, self.run_git("rev-parse", "baseline").strip()))
        self.commit()
        self.assertTrue(planner.version_only_change(self.root, self.run_git("rev-parse", "baseline").strip()))

    def test_structural_project_changes_and_key_removal_are_not_version_only(self):
        for contents in ["MARKETING_VERSION = 0.16.0;\nCURRENT_PROJECT_VERSION = 33;\nOTHER_SETTING = NO;\n",
                         "CURRENT_PROJECT_VERSION = 33;\nOTHER_SETTING = YES;\n"]:
            with self.subTest(contents=contents):
                self.write(planner.VERSION_PROJECT, contents)
                self.assertFalse(planner.version_only_change(self.root, self.run_git("rev-parse", "baseline").strip()))

    def test_unchanged_project_is_not_special_cased(self):
        self.assertFalse(planner.version_only_change(self.root, self.run_git("rev-parse", "HEAD").strip()))


class DevToolContractTests(unittest.TestCase):
    def test_shell_helper_contract(self):
        result = subprocess.run(
            ["/bin/bash", str(ROOT / "dist/test_macos_dev_tool.sh")],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)


@unittest.skipUnless(shutil.which("nu"), "Nushell is needed for wrapper contract tests")
class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        fakebin = self.root / "bin"
        fakebin.mkdir()
        # Intercept the env wrapper, not Xcode: its PATH is deliberately fixed.
        fake_env = fakebin / "env"
        fake_env.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$TEST_CAPTURE"\nexit "${TEST_EXIT:-0}"\n')
        fake_env.chmod(0o755)
        fake_python = fakebin / "python3"
        fake_python.write_text(
            "#!/bin/sh\n"
            'printf "%s\\n" "${SDKROOT-<unset>}" > "$TEST_PYTHON_SDKROOT"\n'
            f"exec {shlex.quote(sys.executable)} \"$@\"\n"
        )
        fake_python.chmod(0o755)
        self.capture = self.root / "captured-args"
        self.python_capture_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.python_capture_dir.cleanup)
        self.python_sdkroot = Path(self.python_capture_dir.name) / "python-sdkroot"
        self.env = dict(
            os.environ,
            PATH=str(fakebin) + os.pathsep + os.environ.get("PATH", ""),
            SDKROOT="/missing/MacOSX-stale.sdk",
            TEST_CAPTURE=str(self.capture),
            TEST_PYTHON_SDKROOT=str(self.python_sdkroot),
        )

    def runner(self, *args, script=None):
        return subprocess.run(["nu", str(script or ROOT / "macos/build.nu"), *args], cwd=self.root,
                              env=self.env, capture_output=True, text=True, timeout=30)

    def test_module_plan_only_never_invokes_xcode_and_works_outside_repo(self):
        result = self.runner("--action", "test", "--test-modules", "git", "--test-plan-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["modules"], ["editor", "git", "inspector"])
        self.assertFalse(self.capture.exists())
        self.assertEqual(self.python_sdkroot.read_text().strip(), "<unset>")

    def test_comma_selections_accept_whitespace(self):
        result = self.runner("--action", "test", "--test-modules", "git, editor", "--test-plan-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["root_modules"], ["editor", "git"])
        self.assertFalse(self.capture.exists())

    def test_default_runner_skips_native_drag_and_serializes_tests(self):
        result = self.runner("--action", "test")
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.capture.read_text().splitlines()
        self.assertIn("NOT RUN (optional interactive desktop)", result.stdout)
        self.assertIn("GhosttyTests/VerticalTabMouseTests", args)
        self.assertIn("GhosttyUITests", args)
        self.assertEqual(args[args.index("-parallel-testing-enabled") + 1], "NO")
        self.assertNotIn("-only-testing", args)

    def test_explicit_desktop_runner_does_not_skip_selected_native_suite(self):
        result = self.runner("--action", "test", "--only-testing", "GhosttyTests/VerticalTabMouseTests", "--include-desktop-tests")
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.capture.read_text().splitlines()
        self.assertEqual(args.count("GhosttyTests/VerticalTabMouseTests"), 1)
        self.assertEqual(args[args.index("-only-testing") + 1], "GhosttyTests/VerticalTabMouseTests")

    def test_failed_xcode_exit_is_preserved(self):
        self.env["TEST_EXIT"] = "65"
        self.assertEqual(self.runner("--action", "test", "--test-modules", "update").returncode, 65)

    def test_bad_scope_or_native_opt_in_fails_before_xcode(self):
        for args in [("--action", "test", "--test-modules", "gti"),
                     ("--action", "test", "--test-modules", ""),
                     ("--action", "test", "--changed-since", ""),
                     ("--action", "test", "--test-modules", "git", "--only-testing", planner.SMOKE_SUITE),
                     ("--action", "test", "--only-testing", "GhosttyTests/VerticalTabMouseTests"),
                     ("--test-modules", "git")]:
            with self.subTest(args=args):
                result = self.runner(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.capture.exists())

    def test_docs_only_change_does_not_run_empty_xcode_selection(self):
        for relative in [
            "macos/build.nu",
            "dist/omg_test_plan.py",
            "dist/macos/dev-tool.sh",
        ]:
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, destination)
        add_suite(self.root, "macos/Tests/Helpers/OhMyGhosttyVersionTests.swift", "OhMyGhosttyVersionTests")
        planner.git(self.root, "init", "-q")
        planner.git(self.root, "-c", "user.name=Fixture", "-c", "user.email=test@example.invalid", "add", ".")
        planner.git(self.root, "-c", "user.name=Fixture", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture")
        (self.root / "docs").mkdir()
        (self.root / "docs/TESTING.md").write_text("Documentation only\n")
        result = self.runner("--action", "test", "--changed-since", "HEAD", script=self.root / "macos/build.nu")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("xcodebuild was not executed", result.stdout)
        self.assertFalse(self.capture.exists())


if __name__ == "__main__":
    unittest.main()
