#!/usr/bin/env bash

set -euxo pipefail

old=$(mktemp -d)
cp po/*.po po/com.mitchellh.ghostty.pot "$old"/
zig build update-translations

# Compare previous POT to current POT
msgcmp "$old"/com.mitchellh.ghostty.pot po/com.mitchellh.ghostty.pot --use-untranslated

# Compare committed POs (before regeneration) to current POT
for f in "$old"/*.po; do
  # Ignore untranslated entries; any diagnostic means the `.po` is out of sync
  out=$(msgcmp --use-untranslated "$f" po/com.mitchellh.ghostty.pot 2>&1 || true);
  if [ -n "$out" ]; then
    echo "$out" >&2
    exit 1
  fi
done
