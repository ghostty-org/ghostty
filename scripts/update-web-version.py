#!/usr/bin/env python3
"""
Update version strings in web/index.html and web/download.html.
Called from the release workflow after a new tag is pushed.

Usage: python3 scripts/update-web-version.py <tag>
  e.g. python3 scripts/update-web-version.py v0.1.0-beta.12
"""

import re
import sys

if len(sys.argv) != 2:
    print(f"Usage: {sys.argv[0]} <version-tag>", file=sys.stderr)
    sys.exit(1)

version = sys.argv[1]  # e.g. "v0.1.0-beta.12"

# Update DMG download URLs in both files
for fname in ['web/index.html', 'web/download.html']:
    content = open(fname).read()
    content = re.sub(
        r'releases/download/v[\d][^/]*/Ghostties\.dmg',
        f'releases/download/{version}/Ghostties.dmg',
        content
    )
    open(fname, 'w').write(content)
    print(f"Updated DMG URL in {fname}")

# Update terminal line 4 version in index.html
# The source file uses &middot; (HTML entity) not a literal · character
content = open('web/index.html').read()
content = re.sub(
    r'ghostties % v[\d][^ &]+ &middot; \[download now\]',
    f'ghostties % {version} &middot; [download now]',
    content
)
open('web/index.html', 'w').write(content)
print(f"Updated terminal line 4 version in web/index.html")
