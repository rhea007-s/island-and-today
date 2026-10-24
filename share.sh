#!/bin/bash
# Package Island for someone else to try: a universal Mac app (Apple silicon
# and Intel) and the Android APK, with install steps, in ~/Desktop/Island-share.
#   ./share.sh
set -euo pipefail
cd "$(dirname "$0")"

OUT="$HOME/Desktop/Island-share"
BUILD="$HOME/Library/Developer/Xcode/DerivedData/IslandShare"
mkdir -p "$OUT"

xcodegen generate --quiet
xcodebuild -project TodayWidget.xcodeproj -scheme Island -configuration Release \
  -derivedDataPath "$BUILD" -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO -quiet build
APP="$BUILD/Build/Products/Release/Island.app"
echo "Mac app architectures: $(lipo -archs "$APP/Contents/MacOS/Island")"
# A disk image with the app next to an Applications shortcut: open it, drag
# Island across, done — the way most Mac apps arrive.
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/Island.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Island" -srcfolder "$STAGE" -ov -format UDZO "$OUT/Island-Mac.dmg"
# Older copies of this folder had a zip instead.
[ -f "$OUT/Island-Mac.zip" ] && mv -f "$OUT/Island-Mac.zip" "$STAGE/old.zip"

./android.sh apk >/dev/null
cp -f "$HOME/Library/Caches/IslandAndroid/app/outputs/apk/release/app-release.apk" "$OUT/Island-Android.apk"

cat > "$OUT/HOW TO INSTALL.txt" <<'TXT'
Island: a Dynamic Island for your Mac and your Android tablet or phone
=======================================================================

MAC (macOS 14 Sonoma or newer; Apple silicon or Intel)
1. Open Island-Mac.dmg and drag Island onto the Applications folder.
2. Open Island from Applications or Launchpad. The first time, macOS will
   say it cannot check the app for malware, because the app is not from the
   App Store or a paid Apple developer account. To allow it, once:
   System Settings > Privacy & Security > scroll down > "Open Anyway" next
   to Island > confirm with your password.
   (Or in Terminal:  xattr -dr com.apple.quarantine /Applications/Island.app)
3. The island appears at the top centre of the screen: in the notch on a
   MacBook that has one, as a black pill on any other display.
   Click it to open. The capsule icon in the menu bar has Settings, Start at
   Login (on by default) and Quit.
4. Allow the prompts as they come: Calendar (events), Automation for
   Music/Spotify (now playing). Tasks sync only if you create an account
   in Settings > Sync. The Claude tile appears only if you use Claude Code.

ANDROID (Android 10 or newer)
1. Copy Island-Android.apk to the device and open it. Allow "Install unknown
   apps" for the app you opened it from (Files, Chrome, WhatsApp...).
2. Open Island and tap "Allow" on each Setup row:
   - Draw over other apps
   - Notification access. On Android 13+ this may be greyed out with
     "Restricted setting". Then go to Settings > Apps > Island > the
     three-dot menu (top right) > "Allow restricted settings", and try again.
   - Calendar
3. Tap the pill to open it, swipe down to expand, swipe up or tap outside
   to close. Tapping the album art opens the song in its player.
TXT

echo "✓ Ready: $OUT"
ls -lh "$OUT"
