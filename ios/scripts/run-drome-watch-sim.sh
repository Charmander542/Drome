#!/bin/bash
# Build, install, and launch Drome on the paired iPhone + Watch simulators.
# Avoids picking the wrong duplicate "iPhone 16 Pro Max" in Xcode.
#
# Usage: ios/scripts/run-drome-watch-sim.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

"$ROOT/ios/scripts/boot-watch-pair.sh"

read -r PHONE_ID WATCH_ID <<< "$(python3 - <<'PY'
import json, subprocess
out = subprocess.check_output(["xcrun", "simctl", "list", "pairs", "-j"], text=True)
for info in json.loads(out).get("pairs", {}).values():
    phone = info.get("phone", {}).get("udid")
    watch = info.get("watch", {}).get("udid")
    if phone and watch:
        print(phone, watch)
        break
PY
)"

DD="$ROOT/ios/.derivedData-watch-sim"
APP="$DD/Build/Products/Debug-iphonesimulator/Drome.app"
BUNDLE_ID="drome.app"
WATCH_BUNDLE_ID="drome.app.watchkitapp"

echo ""
echo "Building for paired iPhone ($PHONE_ID)…"
xcodebuild \
  -project "$ROOT/ios/Drome.xcodeproj" \
  -scheme "Drome (Watch Sim)" \
  -destination "platform=iOS Simulator,id=$PHONE_ID" \
  -derivedDataPath "$DD" \
  build

echo "Installing on iPhone…"
xcrun simctl install "$PHONE_ID" "$APP"

echo "Installing Watch app…"
xcrun simctl install "$WATCH_ID" "$APP/Watch/DromeWatch.app"

echo "Launching iPhone app…"
xcrun simctl launch "$PHONE_ID" "$BUNDLE_ID" || true

echo ""
echo "Done. Open Drome on Apple Watch Ultra (Drome) in the Watch simulator."
echo "Sign in on iPhone, start playing, then tap Sync on the Watch if needed."
