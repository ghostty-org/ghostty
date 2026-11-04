#!/usr/bin/env python3
"""Validate OMG's engineering documentation against repository facts."""

from pathlib import Path
import re
import sys
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
DOCS = [
    ROOT / "README.md",
    ROOT / "README.zh-CN.md",
    ROOT / "CONTRIBUTING.md",
    ROOT / "docs/REPORTING.md",
    ROOT / "docs/CONTRIBUTING.md",
    ROOT / "docs/omg-dev-memory-diagnostics.md",
    ROOT / "docs/RELEASING.md",
    ROOT / "docs/PLUGIN_DEVELOPMENT.md",
    *sorted((ROOT / ".agents/skills/omg-issue-report").rglob("*.md")),
    ROOT / ".agents/skills/omg-debug/SKILL.md",
]
ERRORS: list[str] = []


def fail(message: str) -> None:
    ERRORS.append(message)


for document in DOCS:
    if not document.is_file():
        fail(f"missing required document: {document.relative_to(ROOT)}")
        continue

    text = document.read_text()
    for raw_target in re.findall(r"\[[^]]*]\(([^)]+)\)", text):
        target = raw_target.split(maxsplit=1)[0].strip("<>")
        if target.startswith(("http://", "https://", "mailto:", "#")):
            continue
        relative = unquote(target.split("#", 1)[0])
        resolved = (document.parent / relative).resolve()
        if not resolved.exists():
            fail(
                f"{document.relative_to(ROOT)} links to missing path: {relative}"
            )

required_paths = [
    "macos/build.nu",
    "dist/macos/sign_omg_app.sh",
    "dist/macos/omg_signing.py",
    "dist/macos/omg_keychain.py",
    "dist/macos/package_omg_dmg.sh",
    "macos/Ghostty.xcodeproj",
    "macos/Ghostty-Info.plist",
    "macos/Assets.xcassets/OMG.appiconset",
]
for relative in required_paths:
    if not (ROOT / relative).exists():
        fail(f"documented path does not exist: {relative}")

protocol_source = (
    ROOT / "macos/Sources/Features/Plugins/PluginProtocol.swift"
).read_text()
plugin_doc = (ROOT / "docs/PLUGIN_DEVELOPMENT.md").read_text()
match = re.search(r"currentVersion:\s*UInt16\s*=\s*(\d+)", protocol_source)
if not match:
    fail("could not read PluginProtocolContract.currentVersion")
elif f"currentVersion == {match.group(1)}" not in plugin_doc:
    fail("Plugin guide does not match current protocol version")

capability_block = re.search(
    r"enum PluginCapability:.*?\{(.*?)\n\}",
    protocol_source,
    re.DOTALL,
)
if not capability_block:
    fail("could not read PluginCapability cases")
else:
    capabilities = re.findall(r"^\s*case\s+(\w+)\s*$", capability_block.group(1), re.MULTILINE)
    undocumented = [name for name in capabilities if f"`{name}`" not in plugin_doc]
    if undocumented:
        fail(f"Plugin guide is missing capabilities: {', '.join(undocumented)}")

release_guide = (ROOT / "docs/RELEASING.md").read_text()
for required in [
    "OMG_SIGNING_MODE=self-signed",
    "signing.env",
    "OMG_PREVIOUS_SIGNED_APP",
    "store-password",
    "not notarized",
]:
    if required not in release_guide:
        fail(f"Release guide is missing signing policy: {required}")
if re.search(r"\b(?:notarytool|stapler)\s+(?:submit|store-credentials|staple)\b", release_guide):
    fail("Release guide contains notarization steps outside the release workflow")

readme = (ROOT / "README.md").read_text()
for required in [
    "README.zh-CN.md", "docs/REPORTING.md", "docs/CONTRIBUTING.md",
    "docs/RELEASING.md", "docs/PLUGIN_DEVELOPMENT.md",
]:
    if required not in readme:
        fail(f"README does not link to {required}")

plugin_guide = (ROOT / "docs/PLUGIN_DEVELOPMENT.md").read_text()
for required in [
    "not externally loadable",
    "must update this document",
    "No public plugin sandbox exists",
]:
    if required.lower() not in plugin_guide.lower():
        fail(f"Plugin guide is missing maintenance/status statement: {required}")

sensitive_patterns = {
    "personal macOS path": re.compile(r"/Users/(?!<)[A-Za-z0-9._-]+"),
    "GitHub token": re.compile(r"\b(?:ghp|gho|github_pat)_[A-Za-z0-9_]{20,}\b"),
    "API key": re.compile(r"\b(?:sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16})\b"),
    "private key": re.compile(r"BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY"),
}
for document in DOCS:
    if not document.exists():
        continue
    text = document.read_text()
    for label, pattern in sensitive_patterns.items():
        if pattern.search(text):
            fail(f"{document.relative_to(ROOT)} contains a possible {label}")

if ERRORS:
    for error in ERRORS:
        print(f"ERROR: {error}", file=sys.stderr)
    raise SystemExit(1)

print("OMG documentation checks passed")
