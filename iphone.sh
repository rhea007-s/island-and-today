#!/bin/bash
# Build Today + its widgets, sign with the Apple ID in Xcode, install on the
# connected iPhone and open it.   ./iphone.sh
# First time: plug the iPhone in with a cable, unlock it, tap "Trust".
set -euo pipefail
cd "$(dirname "$0")"

# Outside ~/Desktop: iCloud adds xattrs that codesign refuses.
BUILD="$HOME/Library/Developer/Xcode/DerivedData/TodayDevice"

DEVICE="$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && $0 !~ /unavailable/ && $0 !~ /simulated/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-/) {print $i; exit}}')"
if [ -z "$DEVICE" ]; then
  echo "✗ iPhone bulunamadı. Kabloyla bağla, kilidini aç, 'Bu bilgisayara güven' de, tekrar çalıştır."
  exit 1
fi
echo "✓ iPhone: $DEVICE"

command -v xcodegen >/dev/null && xcodegen generate --quiet

xcodebuild -project TodayWidget.xcodeproj -scheme Today -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath "$BUILD" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration -quiet build

APP="$BUILD/Build/Products/Debug-iphoneos/Today.app"
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --device "$DEVICE" com.karaman.today || \
  echo "! Açılmadıysa: iPhone → Ayarlar → Genel → VPN ve Cihaz Yönetimi → Apple ID'ne güven."
echo "✓ Today iPhone'a kuruldu. Widget: ana ekrana uzun bas → + → Today → Up Next"
