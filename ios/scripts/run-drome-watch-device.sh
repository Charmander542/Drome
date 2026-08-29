#!/bin/bash
# Build, install, and launch Drome on a paired iPhone + Apple Watch.
#
# Usage:
#   ios/scripts/run-drome-watch-device.sh
#   PHONE_ID=... WATCH_ID=... ios/scripts/run-drome-watch-device.sh
#
# Prerequisites:
#   - Xcode.app (not Command Line Tools alone)
#   - iPhone connected + trusted
#   - Apple Watch paired, unlocked, on wrist
#   - Developer Mode ON on both iPhone and Watch
#     (Watch: Settings → Privacy & Security → Developer Mode)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

if [[ ! -d "$DEVELOPER_DIR" ]]; then
  echo "error: Xcode not found at $DEVELOPER_DIR" >&2
  exit 1
fi

pick_devices() {
  python3 - <<'PY'
import subprocess, sys, os

out = subprocess.check_output(["xcrun", "devicectl", "list", "devices"], text=True)
phones = []
watches = []
for line in out.splitlines():
    if line.startswith("Name") or line.startswith("---") or not line.strip():
        continue
    parts = line.split()
    if len(parts) < 4:
        continue
    # Identifier is a UUID at index 3 in the fixed-width table
    ident = parts[3]
    model = " ".join(parts[5:]) if len(parts) > 5 else ""
    name = parts[0]
    if "iPhone" in model or "iPhone" in name:
        phones.append((ident, name, model))
    elif "Watch" in model or "Watch" in name:
        watches.append((ident, name, model))

phone_id = os.environ.get("PHONE_ID")
watch_id = os.environ.get("WATCH_ID")

if not phone_id and phones:
    phone_id = phones[0][0]
if not watch_id and watches:
    watch_id = watches[0][0]

if not phone_id:
    print("error: no iPhone found — connect your phone and trust this Mac", file=sys.stderr)
    sys.exit(1)

print(phone_id, watch_id or "")
PY
}

read -r PHONE_ID WATCH_ID <<< "$(pick_devices)"

DD="$ROOT/ios/.derivedData-device"
APP="$DD/Build/Products/Debug-iphoneos/Drome.app"
BUNDLE_ID="drome.app"
WATCH_APP="$APP/Watch/DromeWatch.app"

echo "iPhone: $PHONE_ID"
echo "Watch:  ${WATCH_ID:-unavailable}"
echo ""

echo "Building Drome (iPhone + embedded Watch)…"
xcodebuild \
  -project "$ROOT/ios/Drome.xcodeproj" \
  -scheme Drome \
  -destination "platform=iOS,id=$PHONE_ID" \
  -derivedDataPath "$DD" \
  -allowProvisioningUpdates \
  build

echo ""
echo "Installing on iPhone…"
xcrun devicectl device install app --device "$PHONE_ID" "$APP"

if [[ -n "$WATCH_ID" ]]; then
  echo ""
  echo "Installing Watch app directly…"
  if xcrun devicectl device install app --device "$WATCH_ID" "$WATCH_APP"; then
    echo "Watch app installed."
  else
    echo ""
    echo "Direct Watch install failed (watch often shows as unavailable over USB)."
    echo "Install via iPhone instead:"
    echo "  1. Open the Watch app on iPhone"
    echo "  2. My Watch → scroll to Available Apps → Drome → Install"
    echo "  Or run this scheme from Xcode with destination 'Charlie iPhone'."
  fi
else
  echo ""
  echo "No Watch visible to devicectl — install from iPhone Watch app after unlock."
fi

echo ""
echo "Launching Drome on iPhone…"
xcrun devicectl device process launch --device "$PHONE_ID" "$BUNDLE_ID" || true

cat <<EOF

Done.

On your Watch:
  1. Confirm Developer Mode is ON (Settings → Privacy & Security → Developer Mode)
  2. Open Drome on the Watch
  3. Sign in on iPhone, start playing music
  4. Keep both apps open (foreground) for fastest sync, or tap "Sync with iPhone"

If the Watch shows "Install Drome on the paired iPhone":
  - Open Drome on iPhone once, then reopen Drome on Watch

EOF
