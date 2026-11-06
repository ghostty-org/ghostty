#!/bin/bash

set -euo pipefail

candidate=/tmp/OMG.app.stage
destination=/Applications/OMG.app
expected_bundle=com.jischeng.omg.debug

[[ -d "$candidate" ]] || { echo "staged app is missing" >&2; exit 1; }

candidate_bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Contents/Info.plist")
[[ "$candidate_bundle" == "$expected_bundle" ]] || {
    echo "refusing bundle $candidate_bundle; expected $expected_bundle" >&2
    exit 1
}

if [[ -d "$destination" ]]; then
    installed_bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")
    [[ "$installed_bundle" == "$expected_bundle" ]] || {
        echo "refusing to replace existing bundle $installed_bundle" >&2
        exit 1
    }
fi

pkill -x omg 2>/dev/null || true
sleep 1
rm -rf "$destination"
mv "$candidate" "$destination"
codesign --verify --deep --strict "$destination"
echo "deployed $candidate_bundle"
