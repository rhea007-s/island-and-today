#!/bin/bash
# Build the Mac island (Release), install it into /Applications, launch it.
#   ./island.sh            build + install + open
#   ./island.sh focus      …and open expanded on a tab (today|focus|music|clipboard|system)
set -euo pipefail

cd "$(dirname "$0")"

# Build outside ~/Desktop: iCloud-synced Desktop folders tag files with
# extended attributes, and codesign refuses to sign a bundle that has them
# ("resource fork, Finder information, or similar detritus not allowed").
BUILD="$HOME/Library/Developer/Xcode/DerivedData/IslandBuild"

command -v xcodegen >/dev/null || { echo "xcodegen yok: brew install xcodegen"; exit 1; }
xcodegen generate --quiet

xcodebuild -project TodayWidget.xcodeproj -scheme Island -configuration Release \
  -derivedDataPath "$BUILD" -destination 'platform=macOS' -quiet build

pkill -x Island 2>/dev/null || true
rm -rf /Applications/Island.app
ditto "$BUILD/Build/Products/Release/Island.app" /Applications/Island.app

if [ -n "${1:-}" ]; then
  open /Applications/Island.app --args -IslandOpenTab "$1"
else
  open /Applications/Island.app
fi
echo "✓ Island kuruldu: /Applications/Island.app"
