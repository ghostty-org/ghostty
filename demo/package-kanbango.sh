#!/bin/bash
# Build and run kanbango, auto-restore GhosttyDemo after launch

set -e
cd "$(dirname "$0")"

mv Sources/GhosttyDemo Sources/kanbango
sed -i '' 's/GhosttyDemo/kanbango/g' Package.swift run.sh

swift build
bash run.sh

mv Sources/kanbango Sources/GhosttyDemo
sed -i '' 's/kanbango/GhosttyDemo/g' Package.swift run.sh
