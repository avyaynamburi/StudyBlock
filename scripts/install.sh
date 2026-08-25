#!/bin/bash
# Builds StudyBlock (Release) and installs it into /Applications.
# SMAppService daemons register most reliably when the app runs from /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! xcodebuild -version >/dev/null 2>&1; then
    echo "error: full Xcode is required (Command Line Tools alone can't build app bundles)." >&2
    echo "Install Xcode from the App Store, then run:" >&2
    echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    exit 1
fi

xcodegen generate
xcodebuild -project StudyBlock.xcodeproj \
           -scheme StudyBlock \
           -configuration Release \
           -derivedDataPath build \
           build

APP="build/Build/Products/Release/StudyBlock.app"

osascript -e 'quit app "StudyBlock"' 2>/dev/null || true
rm -rf /Applications/StudyBlock.app
cp -R "$APP" /Applications/

echo
echo "Installed /Applications/StudyBlock.app — launching."
echo "First run: click 'Set Up Helper' in the app, then approve StudyBlock in"
echo "System Settings → General → Login Items & Extensions."
open /Applications/StudyBlock.app
