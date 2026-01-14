#!/bin/bash
# Bump the build number in the Xcode project

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_FILE="$PROJECT_DIR/.terminaut-build"
PBXPROJ="$PROJECT_DIR/macos/Ghostty.xcodeproj/project.pbxproj"

# Read current build number
if [ -f "$BUILD_FILE" ]; then
    BUILD=$(cat "$BUILD_FILE")
else
    BUILD=0
fi

# Increment
BUILD=$((BUILD + 1))

# Save new build number
echo "$BUILD" > "$BUILD_FILE"

# Update CURRENT_PROJECT_VERSION in project.pbxproj (all occurrences)
sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = $BUILD;/g" "$PBXPROJ"

echo "v0.1.$BUILD"
