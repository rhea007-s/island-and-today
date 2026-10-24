#!/bin/bash
# Build Today + its widget, boot a simulator, install, launch, screenshot.
# Everything here is automatic; only Xcode itself has to be installed by hand.
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

BUNDLE_ID="com.karaman.today"
SCHEME="Today"
BUILD_DIR="$PROJECT_DIR/.build-sim"

bold() { printf "\n\033[1m%s\033[0m\n" "$1"; }
die()  { printf "\n\033[31m✗ %s\033[0m\n" "$1" >&2; exit 1; }

# ---------- 1. Xcode ----------
bold "1/6  Xcode kontrolü"
DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
case "$DEV_DIR" in
  *Xcode.app*) echo "✓ $DEV_DIR" ;;
  *)
    cat <<'MSG'
✗ Aktif geliştirici dizini Command Line Tools.

  1) Xcode'u kur (App Store → "Xcode", ~8 GB indirme)
  2) Bir kez aç, lisansı kabul et, iOS platformunu indirmesini bekle
  3) Sonra:
       sudo xcode-select -s /Applications/Xcode.app
       sudo xcodebuild -runFirstLaunch
  4) Bu betiği tekrar çalıştır: ./run.sh
MSG
    exit 1
    ;;
esac

xcrun simctl help >/dev/null 2>&1 || die "simctl yok — Xcode'u bir kez açıp ilk kurulumu tamamla."

# ---------- 2. xcodegen ----------
bold "2/6  xcodegen"
if ! command -v xcodegen >/dev/null 2>&1; then
  command -v brew >/dev/null 2>&1 || die "Homebrew yok; xcodegen'i elle kur ya da README'deki Option B'yi izle."
  echo "kuruluyor…"; brew install xcodegen || die "xcodegen kurulamadı."
fi
echo "✓ $(xcodegen --version 2>&1 | head -1)"

# ---------- 3. proje ----------
bold "3/6  Proje üretiliyor"
xcodegen generate || die "xcodegen generate başarısız."

# ---------- 4. simülatör ----------
bold "4/6  Simülatör seçiliyor"
UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, re, sys

def version(runtime):
    # Sort numerically: "iOS-9-0" must not beat "iOS-18-2" the way strings do.
    m = re.search(r"iOS-(\d+(?:-\d+)*)$", runtime)
    return tuple(int(x) for x in m.group(1).split("-")) if m else None

best = None
for runtime, devices in json.load(sys.stdin)["devices"].items():
    v = version(runtime)
    if v is None or v < (17,): continue      # widget buttons need iOS 17
    for d in devices:
        if not d.get("isAvailable"): continue
        name = d["name"]
        if "iPhone" not in name: continue
        score = (v, "Pro" in name, name)     # newest runtime, Pro model within it
        if best is None or score > best[0]: best = (score, d["udid"], name, v)
if not best: sys.exit("no iOS 17+ iPhone simulator available")
print(best[1], best[2], "iOS " + ".".join(map(str, best[3])))
')" || die "iOS 17+ iPhone simülatörü yok. Xcode → Settings → Components'tan bir iOS runtime indir."
set -- $UDID
SIM_UDID="$1"; shift
echo "✓ $* — $SIM_UDID"

xcrun simctl boot "$SIM_UDID" 2>/dev/null
open -a Simulator --args -CurrentDeviceUDID "$SIM_UDID"
xcrun simctl bootstatus "$SIM_UDID" -b

# ---------- 5. derle ----------
bold "5/6  Derleniyor"
xcodebuild \
  -project TodayWidget.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "id=$SIM_UDID" \
  -derivedDataPath "$BUILD_DIR" \
  -quiet \
  CODE_SIGNING_ALLOWED=NO \
  build || die "Derleme başarısız — çıktının son satırlarına bak."

APP="$BUILD_DIR/Build/Products/Debug-iphonesimulator/Today.app"
[ -d "$APP" ] || die "Uygulama üretilmedi: $APP"
echo "✓ $APP"

# ---------- 6. kur, aç, kanıtla ----------
bold "6/6  Kuruluyor ve açılıyor"
xcrun simctl install "$SIM_UDID" "$APP" || die "install başarısız."
xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" || die "launch başarısız."
sleep 3
xcrun simctl io "$SIM_UDID" screenshot "$PROJECT_DIR/sim-app.png" >/dev/null 2>&1 \
  && echo "✓ ekran görüntüsü: sim-app.png"

cat <<'NEXT'

────────────────────────────────────────────────
Kilit ekranı widget'ını simülatörde görmek için:

  1) Simülatörde birkaç görev ekle
  2) Device → Lock (Cmd+L)
  3) Kilit ekranına uzun bas → Customise → Lock Screen
  4) Saatin altındaki slot'a dokun → Today → Rectangular
     Saatin üstündeki satır için: tarihe dokun → Today (Inline)

Daha hızlı yol — Xcode canvas:
  Widget/WidgetPreviews.swift dosyasını aç, Canvas'ı göster (Cmd+Opt+Enter).
  Dört aile de gerçek vibrant render'la, boş / karışık / hepsi-bitti
  durumlarıyla yan yana gelir.
────────────────────────────────────────────────
NEXT
