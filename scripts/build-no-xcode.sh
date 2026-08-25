#!/bin/bash
# Builds StudyBlock.app with only the Command Line Tools (no Xcode) and
# installs it into /Applications. The bundle is assembled by hand: swiftc
# compiles the app + helper, then we lay out Contents/ and sign.
#
# Signing uses the stable self-signed identity from scripts/setup-signing.sh
# if present (so the helper's approval survives rebuilds); otherwise it falls
# back to ad-hoc (approval resets each build).
set -euo pipefail
cd "$(dirname "$0")/.."

SDK=$(xcrun --show-sdk-path)
TARGET=arm64-apple-macos13.0
BUILD=build/manual
APP="$BUILD/StudyBlock.app"
BUNDLE_ID="com.avyay.StudyBlock"
HELPER_NAME="com.avyay.studyblock.helper"
VERSION="1.2.0"

SIGN_IDENTITY="StudyBlock Self-Signed"
SIGN_KEYCHAIN="$HOME/Library/Keychains/studyblock-signing.keychain-db"
SIGN_KEYCHAIN_PASS="studyblock"

echo "→ Compiling helper…"
mkdir -p "$BUILD"
swiftc -O -target "$TARGET" -sdk "$SDK" \
    -o "$BUILD/$HELPER_NAME" \
    Shared/*.swift StudyBlockHelper/*.swift

echo "→ Compiling app…"
swiftc -O -target "$TARGET" -sdk "$SDK" -parse-as-library \
    -o "$BUILD/StudyBlock" \
    Shared/*.swift StudyBlock/*.swift StudyBlock/*/*.swift

echo "→ Assembling StudyBlock.app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
cp "$BUILD/StudyBlock" "$APP/Contents/MacOS/"
cp "$BUILD/$HELPER_NAME" "$APP/Contents/MacOS/"
cp "StudyBlock/LaunchDaemons/$HELPER_NAME.plist" "$APP/Contents/Library/LaunchDaemons/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleName</key>
	<string>StudyBlock</string>
	<key>CFBundleDisplayName</key>
	<string>StudyBlock</string>
	<key>CFBundleExecutable</key>
	<string>StudyBlock</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.productivity</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSSupportsAutomaticTermination</key>
	<false/>
	<key>NSSupportsSuddenTermination</key>
	<false/>
	<key>NSAppleEventsUsageDescription</key>
	<string>StudyBlock closes browser tabs on blocked sites while blocking is on.</string>
</dict>
</plist>
PLIST

# Sign inside-out: helper executable first, then the app bundle.
if [ -f "$SIGN_KEYCHAIN" ] && security find-identity -v -p codesigning "$SIGN_KEYCHAIN" | grep -q "$SIGN_IDENTITY"; then
    echo "→ Signing with stable identity ($SIGN_IDENTITY)…"
    security unlock-keychain -p "$SIGN_KEYCHAIN_PASS" "$SIGN_KEYCHAIN"
    codesign --force --keychain "$SIGN_KEYCHAIN" -s "$SIGN_IDENTITY" "$APP/Contents/MacOS/$HELPER_NAME"
    codesign --force --keychain "$SIGN_KEYCHAIN" -s "$SIGN_IDENTITY" "$APP"
else
    echo "→ Signing (ad-hoc — run scripts/setup-signing.sh for stable signing)…"
    codesign --force -s - "$APP/Contents/MacOS/$HELPER_NAME"
    codesign --force -s - "$APP"
fi
codesign --verify --deep "$APP"

echo "→ Installing to /Applications…"
osascript -e 'quit app "StudyBlock"' 2>/dev/null || true
rm -rf /Applications/StudyBlock.app
cp -R "$APP" /Applications/

# The helper is a long-lived launchd daemon: an old copy keeps running after
# reinstall. If it's up, restart it (admin prompt) so launchd relaunches the
# new binary. `kickstart -k` targets the service by its exact label — unlike
# `pkill -f`, which would also match this very command's own process. Harmless
# when the helper isn't installed/running yet.
if pgrep -f "MacOS/$HELPER_NAME" >/dev/null 2>&1; then
    echo "→ Restarting background helper to pick up the new build…"
    osascript -e "do shell script \"/bin/launchctl kickstart -k system/$HELPER_NAME\" with administrator privileges" || true
fi

echo
echo "Installed /Applications/StudyBlock.app — launching."
echo "First run: click 'Set Up Helper' in the app, then approve StudyBlock in"
echo "System Settings → General → Login Items & Extensions."
open /Applications/StudyBlock.app
