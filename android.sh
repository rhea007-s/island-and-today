#!/bin/bash
# Build the Android tablet island, install it on the connected device, grant
# its permissions over adb (no tapping through Settings), and start it.
#   ./android.sh               build + install + start
#   ./android.sh apk           only build; prints where the APK is
#   ./android.sh pair IP:PORT  Wi-Fi pairing (Developer options → Wireless debugging)
set -euo pipefail
cd "$(dirname "$0")/Android"

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
export PATH="$JAVA_HOME/bin:$HOME/Library/Android/sdk/platform-tools:$PATH"
APK="$HOME/Library/Caches/IslandAndroid/app/outputs/apk/release/app-release.apk"
PKG=com.karaman.island

if [ "${1:-}" = "pair" ]; then
  adb pair "$2"
  echo "Paired. Now: adb connect <IP:PORT shown under Wireless debugging>"
  exit 0
fi

./gradlew -q assembleRelease
echo "✓ APK: $APK"
[ "${1:-}" = "apk" ] && exit 0

if ! adb get-state >/dev/null 2>&1; then
  echo "Tablet bulunamadı. USB ile bağla (USB debugging açık) ya da: ./android.sh pair IP:PORT"
  exit 1
fi

# A copy signed with another key (the old debug builds) cannot be updated in
# place; remove it and install fresh.
if ! adb install -r "$APK" 2>"$TMPDIR/island-install.log"; then
  if grep -q "INSTALL_FAILED_UPDATE_INCOMPATIBLE" "$TMPDIR/island-install.log"; then
    echo "Eski imzalı kopya kaldırılıyor…"
    adb uninstall $PKG >/dev/null
    adb install "$APK"
  else
    cat "$TMPDIR/island-install.log"; exit 1
  fi
fi
adb shell appops set $PKG SYSTEM_ALERT_WINDOW allow
adb shell cmd notification allow_listener $PKG/$PKG.IslandListener || true
adb shell pm grant $PKG android.permission.READ_CALENDAR || true
adb shell pm grant $PKG android.permission.POST_NOTIFICATIONS 2>/dev/null || true
# Keep Android's battery saver from killing the overlay in the background.
adb shell dumpsys deviceidle whitelist +$PKG >/dev/null || true
adb shell am start -n $PKG/.MainActivity >/dev/null
echo "✓ Island tablete kuruldu ve açıldı"
