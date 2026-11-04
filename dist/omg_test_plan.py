#!/usr/bin/env python3
"""Plan app-hosted Swift tests; never build, launch apps, or report tests passed."""

import argparse
from collections import Counter
from dataclasses import dataclass
from fnmatch import fnmatchcase
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
VERSION_PROJECT = "macos/Ghostty.xcodeproj/project.pbxproj"


@dataclass(frozen=True)
class Module:
    sources: tuple
    tests: tuple
    dependents: tuple = ()


# Dependents are deliberately one hop. Shared host/core changes instead use ALL.
MODULES = {
    "foundation": Module(
        (),
        ("macos/Tests/*.swift", "macos/Tests/Helpers/*.swift", "macos/Tests/Ghostty/**/*.swift"),
    ),
    "terminal": Module(
        ("macos/Sources/Features/Terminal/**", "macos/Sources/Features/Splits/**"),
        ("macos/Tests/Terminal/*.swift", "macos/Tests/Splits/*.swift"),
        ("tabs", "inspector", "agents", "editor"),
    ),
    "tabs": Module(
        ("macos/Sources/Features/Terminal/Tabs/**",),
        ("macos/Tests/Plugins/Vertical*.swift", "macos/Tests/Terminal/TerminalTabSelectionRestorationTests.swift"),
        ("terminal",),
    ),
    "git": Module(
        ("macos/Sources/Features/Git/**",),
        ("macos/Tests/Git/*.swift",),
        ("editor", "inspector"),
    ),
    "editor": Module(
        ("macos/Sources/Features/Editor/**", "dist/markdown-editor/**"),
        ("macos/Tests/Editor/*.swift",),
        ("git", "terminal"),
    ),
    "inspector": Module(
        ("macos/Sources/Features/Inspector/**",),
        ("macos/Tests/Inspector/*.swift",),
        ("git", "agents"),
    ),
    "settings": Module(
        ("macos/Sources/Features/Settings/**", "docs/settings/**"),
        ("macos/Tests/Settings/*.swift",),
        ("foundation", "terminal", "tabs", "editor", "git", "inspector"),
    ),
    "plugins": Module(
        ("macos/Sources/Features/Plugins/Plugin*.swift",),
        ("macos/Tests/Plugins/Plugin*.swift",),
        ("agents", "ssh", "inspector", "tabs"),
    ),
    "agents": Module(
        ("macos/Sources/Features/Plugins/Agent*.swift",),
        ("macos/Tests/Plugins/Agent*.swift", "macos/Tests/Terminal/PaneAgentHistoryServiceTests.swift",
         "macos/Tests/Terminal/PanePromptReaderTests.swift", "macos/Tests/Inspector/BuiltInAgentHistoryInspectorProviderTests.swift"),
        ("inspector", "quick-input", "tabs", "terminal"),
    ),
    "ssh": Module(
        ("macos/Sources/Features/Plugins/SSH*.swift", "macos/Sources/Features/Plugins/WorkspaceProvider.swift",
         "dist/*ssh*.py"),
        ("macos/Tests/Plugins/SSH*.swift", "macos/Tests/Plugins/WorkspaceProviderTests.swift",
         "macos/Tests/Git/SSHGitExecutorTests.swift"),
        ("agents", "terminal", "git", "tabs"),
    ),
    "quick-input": Module(
        ("macos/Sources/Features/QuickInput/**",),
        ("macos/Tests/QuickInput/*.swift",),
        ("agents",),
    ),
    "update": Module(
        ("macos/Sources/Features/Update/**", "macos/Sources/Features/About/**"),
        ("macos/Tests/Update/*.swift", "macos/Tests/Helpers/OhMyGhosttyVersionTests.swift"),
    ),
}

FULL_SUITE_GLOBS = (
    "src/**", "include/**", "build.zig*", "macos/Sources/App/**", "macos/Sources/Ghostty/**",
    "macos/Sources/Helpers/**", "macos/Sources/Extensions/**",
    "macos/Sources/Features/Terminal/TerminalController.swift",
    "macos/Sources/Features/Terminal/TerminalView.swift", "macos/Ghostty-Info.plist",
    "macos/Sources/Features/Settings/OhMyGhosttySettings.swift", "macos/Ghostty.xcodeproj/**",
    "macos/*.xctestplan", "macos/build.nu", "dist/omg_test_plan.py", "dist/test_omg_test_plan.py",
    "macos/Tests/Helpers/TemporaryConfig.swift", "macos/Tests/Helpers/OMGTestTags.swift",
    "macos/Tests/Helpers/AppKitTestWait.swift",
)
NO_SWIFT_GLOBS = (
    "docs/**", "*.md", "LICENSE*", ".agents/skills/omg-issue-report/**",
    ".agents/skills/*/SKILL.md", "dist/*docs*.py", ".github/ISSUE_TEMPLATE/**",
)
SMOKE_SUITE = "GhosttyTests/OhMyGhosttyVersionTests"
SUITE_TYPE = re.compile(r"\b(?:struct|class|enum)\s+(\w+(?:Tests|Suite))\b")
DESKTOP_TAG = re.compile(r"\.tags\([^)]*\.interactiveDesktop\b")
SUITE_TRAITS = re.compile(r"@Suite\s*\((.*?)\)\s*(?:@MainActor\s*)?(?:struct|class|enum)\s+\w+", re.DOTALL)
METHOD_TRAITS = re.compile(r"@Test\s*\((.*?)\)\s*func\s+(\w+)", re.DOTALL)


def normalized_identifier(identifier):
    return identifier[:-2] if identifier.endswith("()") else identifier


def matches(path, patterns):
    return any(fnmatchcase(path, pattern) for pattern in patterns)


def test_path_matches(path, pattern):
    # pathlib.match does not give ** the recursive/zero-directory semantics of glob.
    if "**/" in pattern:
        prefix, suffix = pattern.split("**/", 1)
        return path.startswith(prefix) and Path(path[len(prefix):]).match(suffix)
    return Path(path).match(pattern)


def inventory(root):
    """Suite names must end in Tests/Suite; every new test file needs a module."""
    groups = {name: set() for name in MODULES}
    desktop = set()
    files = {}
    for path in sorted((root / "macos/Tests").rglob("*.swift")):
        text = path.read_text()
        names = {"GhosttyTests/" + name for name in SUITE_TYPE.findall(text)}
        if "@Test" in text and not names:
            raise ValueError(f"Cannot discover a suite in {path.relative_to(root)}; use a Tests/Suite type name")
        if not names:
            continue
        files[path] = names
        if DESKTOP_TAG.search(text):
            if len(names) != 1:
                raise ValueError(f"Put each desktop-tagged test type in its own file: {path}")
            suite_tagged = any(DESKTOP_TAG.search(traits) for traits in SUITE_TRAITS.findall(text))
            methods = [method for traits, method in METHOD_TRAITS.findall(text) if DESKTOP_TAG.search(traits)]
            if not suite_tagged and not methods:
                raise ValueError(f"Cannot discover interactiveDesktop tag in {path}")
            if suite_tagged:
                desktop.update(names)
            else:
                desktop.update(next(iter(names)) + "/" + method + "()" for method in methods)
    assigned = set()
    for name, module in MODULES.items():
        for pattern in module.tests:
            for path in root.glob(pattern):
                groups[name].update(files.get(path, ()))
                assigned.add(path)
    unassigned = set(files) - assigned
    if unassigned:
        raise ValueError("Unmapped test files; update MODULES: " + ", ".join(str(p.relative_to(root)) for p in sorted(unassigned)))
    all_suites = set().union(*groups.values())
    if SMOKE_SUITE not in all_suites:
        raise ValueError("Version smoke suite is missing")
    return groups, desktop


def git(root, *args):
    result = subprocess.run(["git", *args], cwd=root, capture_output=True, check=True)
    return result.stdout.decode("utf-8", errors="surrogateescape")


def changed_paths(root, reference):
    if not reference or reference.startswith("-"):
        raise ValueError("--changed-since needs a valid Git commit/ref")
    commit = git(root, "rev-parse", "--verify", "--end-of-options", reference + "^{commit}").strip()
    paths = set()
    for args in [
        ("diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--name-only", "-z", commit, "HEAD", "--"),
        ("diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--name-only", "-z", "HEAD", "--"),
        ("ls-files", "--others", "--exclude-standard", "-z"),
    ]:
        paths.update(p for p in git(root, *args).split("\0") if p)
    return sorted(paths), commit


def version_only_change(root, commit):
    """Version bumps don't turn every release into a full-suite release."""
    changed = []
    for comparison in [(commit, "HEAD"), ("HEAD",)]:
        diff = git(root, "diff", "--no-ext-diff", "--no-textconv", "--unified=0", *comparison, "--", VERSION_PROJECT)
        changed.extend(line for line in diff.splitlines() if line.startswith(("+", "-")) and not line.startswith(("+++", "---")))
    if not changed:
        return False
    counts = {"+": Counter(), "-": Counter()}
    for line in changed:
        match = re.fullmatch(r"[+-]\s*(MARKETING_VERSION|CURRENT_PROJECT_VERSION)\s*=\s*[^;]+;", line)
        if not match:
            return False
        counts[line[0]][match[1]] += 1
    return counts["+"] == counts["-"]


def make_plan(catalog, *, modules=None, paths=None, only_testing=None, include_desktop=False, version_only=False):
    if sum(value is not None for value in (modules, paths, only_testing)) > 1:
        raise ValueError("Choose only one of --test-modules, --changed-since, --only-testing")
    groups, desktop = catalog
    all_suites = set().union(*groups.values())
    roots = set()
    unknown = []
    fallback = []
    scope = "all"
    selected = set(all_suites)
    if only_testing is not None:
        scope = "explicit"
        selected = set(only_testing)
        if not selected:
            raise ValueError("Empty --only-testing selection")
        for test in selected:
            suite = "/".join(test.split("/")[:2])
            if test != "GhosttyTests" and suite not in all_suites:
                raise ValueError(f"Unknown app-hosted suite: {test}")
            if any(normalized_identifier(test) == normalized_identifier(identifier) or test.startswith(identifier + "/")
                   for identifier in desktop) and not include_desktop:
                raise ValueError("Interactive desktop suite/method requires --include-desktop-tests (unlocked, foreground desktop)")
    elif modules is not None:
        roots = set(modules)
        if not roots or roots - (set(MODULES) | {"all"}):
            raise ValueError("Unknown/empty module selection; available: " + ", ".join(MODULES))
        scope = "all" if "all" in roots else "modules"
    elif paths is not None:
        scope = "changed"
        for path in paths:
            if path == VERSION_PROJECT and version_only:
                roots.add("update")
                continue
            if matches(path, FULL_SUITE_GLOBS):
                fallback.append(path)
                continue
            source_matches = [(len(pattern.split("*")[0]), name) for name, module in MODULES.items()
                              for pattern in module.sources if fnmatchcase(path, pattern)]
            # Prefer Tabs over the containing Terminal namespace, for example.
            longest = max((length for length, _ in source_matches), default=-1)
            matched = {name for length, name in source_matches if length == longest}
            # Test changes select every module that owns this file (overlaps are intentional).
            for name, module in MODULES.items():
                for pattern in module.tests:
                    if test_path_matches(path, pattern):
                        matched.add(name)
            if matched:
                roots.update(matched)
            elif not matches(path, NO_SWIFT_GLOBS):
                unknown.append(path)
        if fallback or unknown:
            scope = "all"
    if scope not in ("all", "explicit"):
        expanded = roots | {dependent for name in roots for dependent in MODULES[name].dependents}
        selected = {SMOKE_SUITE} | set().union(*(groups[name] for name in expanded)) if roots else set()
    else:
        expanded = set(MODULES) if scope == "all" else set()
    omitted = desktop if scope == "all" or "GhosttyTests" in selected else {
        test for test in desktop if any(normalized_identifier(identifier) == normalized_identifier(test) or
                                       identifier.startswith(test + "/") or test.startswith(identifier + "/")
                                       for identifier in selected)
    }
    skip = {"GhosttyUITests"}
    if not include_desktop:
        skip.update(desktop)
        selected.difference_update(desktop)
    else:
        omitted = set()
    return {
        "scope": scope,
        "modules": sorted(expanded),
        "root_modules": sorted(roots),
        "only_testing": [] if scope == "all" else sorted(selected),
        "skip_testing": sorted(skip),
        "deferred_desktop": sorted(omitted) if not include_desktop else [],
        "unknown_paths": sorted(unknown),
        "full_suite_paths": sorted(fallback),
        "changed_paths": paths or [],
        "run_swift": bool(selected),
        "suite_count": len(all_suites - (desktop if not include_desktop else set())) if scope == "all" or "GhosttyTests" in selected else len({"/".join(t.split("/")[:2]) for t in selected}),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    scope = parser.add_mutually_exclusive_group()
    scope.add_argument("--modules")
    scope.add_argument("--changed-since")
    scope.add_argument("--only-testing")
    parser.add_argument("--include-desktop-tests", action="store_true")
    parser.add_argument("--list-modules", action="store_true")
    args = parser.parse_args()
    try:
        catalog = inventory(ROOT)
        if args.list_modules:
            result = {name: {"suite_count": len(tests), "dependents": MODULES[name].dependents} for name, tests in catalog[0].items()}
        else:
            paths, commit = changed_paths(ROOT, args.changed_since) if args.changed_since is not None else (None, None)
            result = make_plan(
                catalog,
                modules=[item.strip() for item in args.modules.split(",")] if args.modules is not None else None,
                paths=paths,
                only_testing=[item.strip() for item in args.only_testing.split(",")] if args.only_testing is not None else None,
                include_desktop=args.include_desktop_tests,
                version_only=VERSION_PROJECT in (paths or []) and version_only_change(ROOT, commit),
            )
        print(json.dumps(result, indent=2, ensure_ascii=True))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(2, f"Test plan error: {error}\n")


if __name__ == "__main__":
    main()
