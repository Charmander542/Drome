#!/bin/bash
# Boot the paired iPhone + Apple Watch simulators for Drome watch testing.
#
# Xcode does not expose a single "iPhone + Watch" run destination. WatchConnectivity
# only works when the phone and watch simulators are a matched pair.
#
# Usage: ios/scripts/boot-watch-pair.sh

set -euo pipefail

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

read -r PHONE_ID WATCH_ID <<< "$(python3 - <<'PY'
import json, subprocess
out = subprocess.check_output(["xcrun", "simctl", "list", "pairs", "-j"], text=True)
pairs = json.loads(out).get("pairs", {})
for info in pairs.values():
    phone = info.get("phone", {}).get("udid")
    watch = info.get("watch", {}).get("udid")
    if phone and watch:
        print(phone, watch)
        break
PY
)"

if [[ -z "${PHONE_ID:-}" || -z "${WATCH_ID:-}" ]]; then
  echo "No iPhone/Watch simulator pair found."
  echo "Create one in Xcode → Window → Devices and Simulators → Simulators (+) → include a Watch."
  exit 1
fi

# If a different iPhone is booted, shut it down so Xcode targets the paired phone.
while read -r booted_id; do
  [[ -z "$booted_id" ]] && continue
  if [[ "$booted_id" != "$PHONE_ID" ]]; then
    echo "Shutting down unpaired booted iPhone ($booted_id)…"
    xcrun simctl shutdown "$booted_id" || true
  fi
done < <(python3 - <<'PY'
import json, subprocess
out = subprocess.check_output(["xcrun", "simctl", "list", "devices", "booted", "-j"], text=True)
for udid, dev in json.loads(out).get("devices", {}).items():
    for d in dev:
        if d.get("state") == "Booted" and "iPhone" in d.get("name", ""):
            print(d["udid"])
PY
)

echo "Booting paired simulators…"
xcrun simctl boot "$PHONE_ID" 2>/dev/null || true
xcrun simctl boot "$WATCH_ID" 2>/dev/null || true
open -a Simulator

echo ""
echo "Ready:"
xcrun simctl list devices booted | sed -n '/== Devices ==/,$p' | tail -n +2
echo ""
echo "Next in Xcode:"
echo "  1. Scheme: Drome (Watch Sim)  — or run: ios/scripts/run-drome-watch-sim.sh"
echo "  2. Destination: iPhone 16 Pro Max (Watch)"
echo "  3. Run, sign in, start playing"
echo "  4. On Apple Watch Ultra (Drome), open the Drome app"
echo ""
echo "Do NOT pick 'iPhone 16 Pro Max (no Watch)' — it is not paired."
