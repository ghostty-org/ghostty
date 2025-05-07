#!/bin/sh

old_pot=$(mktemp)
cp po/com.mitchellh.ghostty.pot "$old_pot"
zig build update-translations

# Compare previous POT to current POT
msgcmp "$old_pot" po/com.mitchellh.ghostty.pot --use-untranslated

# Compare all other POs to current POT
for f in po/*.po; do
  # Ignore untranslated entries
  msgcmp --use-untranslated "$f" po/com.mitchellh.ghostty.pot;
done
