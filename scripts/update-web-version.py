#!/usr/bin/env python3
"""
Update version strings in web/index.html and web/download.html.
Called from the release workflow after a new tag is pushed.

Usage: python3 scripts/update-web-version.py <tag> [dmg-size-bytes]
  e.g. python3 scripts/update-web-version.py v0.1.0-beta.14 158314217

The optional second argument (DMG size in bytes) is rendered as MB in the
download page meta line. Omit to leave the existing size string in place.
"""

import os
import re
import sys
from datetime import datetime


def replace(path: str, pattern: str, repl: str, label: str) -> None:
    """Replace `pattern` with `repl` in `path`. Logs whether it matched."""
    src = open(path).read()
    new, n = re.subn(pattern, repl, src)
    if n == 0:
        print(f"  ! {label}: pattern did not match in {path}")
    else:
        open(path, "w").write(new)
        print(f"  ✓ {label}: {n} replacement(s) in {path}")


if len(sys.argv) not in (2, 3):
    print(f"Usage: {sys.argv[0]} <version-tag> [dmg-size-bytes]", file=sys.stderr)
    sys.exit(1)

version = sys.argv[1]  # e.g. "v0.1.0-beta.14" — strip leading "v" for display where natural
display_version = version  # full form including "v" prefix
short_version = version.lstrip("v")  # "0.1.0-beta.14"

now = datetime.now()
date_long = now.strftime("%B %-d, %Y")          # "April 30, 2026"
date_compact = now.strftime("%-d%b%Y")          # "30Apr2026"
date_compact = re.sub(r"^(\d)([A-Z])", r"0\1\2", date_compact)  # zero-pad single digit day → "01Apr2026"

dmg_size_str = None
if len(sys.argv) == 3:
    bytes_ = int(sys.argv[2])
    mb = round(bytes_ / (1024 * 1024))
    dmg_size_str = f"{mb} MB"

print(f"Bumping site to {version} ({date_long})")

# 1. DMG download URL — only download.html has one. (index.html links to /download.)
replace(
    "web/download.html",
    r"releases/download/v[\d][^/]+/Ghostties\.dmg",
    f"releases/download/{version}/Ghostties.dmg",
    "download.html DMG URL",
)

# 2. download.html — button label  ("Download v0.1.0-beta.X for macOS")
replace(
    "web/download.html",
    r"Download v[\d]\.\d+\.\d+(?:-[a-z0-9.]+)? for macOS",
    f"Download {version} for macOS",
    "download.html button label",
)

# 3. download.html — meta line. "v0.1.0-beta.X &middot; <date> &middot; <size> MB<br>"
if dmg_size_str:
    replace(
        "web/download.html",
        r"v[\d]\.\d+\.\d+(?:-[a-z0-9.]+)? &middot; [A-Z][a-z]+ \d+, \d{4} &middot; [\d]+ MB<br>",
        f"{display_version} &middot; {date_long} &middot; {dmg_size_str}<br>",
        "download.html meta line (with size)",
    )
else:
    # Replace version + date only; leave size as-is
    replace(
        "web/download.html",
        r"v[\d]\.\d+\.\d+(?:-[a-z0-9.]+)? &middot; [A-Z][a-z]+ \d+, \d{4} &middot;",
        f"{display_version} &middot; {date_long} &middot;",
        "download.html meta line (version+date only)",
    )

# 4. download.html — "Last updated <date>"
replace(
    "web/download.html",
    r"Last updated [A-Z][a-z]+ \d+, \d{4}",
    f"Last updated {date_long}",
    "download.html last-updated footer",
)

# 5. index.html — terminal line-4 displayed text "+ ghostties % v0.1.0-beta.X"
replace(
    "web/index.html",
    r"\+ ghostties % v[\d]\.\d+\.\d+(?:-[a-z0-9.]+)?",
    f"+ ghostties % {version}",
    "index.html terminal line-4",
)

# 6. index.html — comments referencing the line (keep them in sync to aid grep)
replace(
    "web/index.html",
    r'line-4: "?\+ ghostties % v[\d]\.\d+\.\d+(?:-[a-z0-9.]+)?"? = (\d+) chars',
    lambda m: f'line-4: "+ ghostties % {version}" = {m.group(1)} chars',
    "index.html line-4 char-count comment (CSS)",
)
replace(
    "web/index.html",
    r"line-4: (\d+) chars: \+ ghostties % v[\d]\.\d+\.\d+(?:-[a-z0-9.]+)?",
    lambda m: f"line-4: {m.group(1)} chars: + ghostties % {version}",
    "index.html line-4 char-count comment (HTML)",
)

# 7. index.html — terminal date line "+ <date> · macOS 13+ · Apple Silicon"
replace(
    "web/index.html",
    r"\+ \d{1,2}[A-Z][a-z]+\d{4} &middot;",
    f"+ {date_compact} &middot;",
    "index.html terminal date",
)
replace(
    "web/index.html",
    r"line-5: (\d+) chars: \+ \d{1,2}[A-Z][a-z]+\d{4}",
    lambda m: f"line-5: {m.group(1)} chars: + {date_compact}",
    "index.html line-5 char-count comment",
)

print("Done.")
