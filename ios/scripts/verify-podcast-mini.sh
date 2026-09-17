#!/usr/bin/env bash
# Verify podcast mini player replaces music mini on Simulator.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IOS="$ROOT/ios"
OUT="${MINI_VERIFY_OUT:-$ROOT/tmp/mini-player-verify}"
DD="${DERIVED_DATA:-/tmp/drome-mini-verify}"
UDID="${SIM_UDID:-}"

mkdir -p "$OUT"

echo "== MiniPlayerKind unit check =="
swift "$IOS/scripts/verify-mini-player-kind.swift"

if [[ -z "$UDID" ]]; then
  UDID="$(xcrun simctl list devices booted | sed -n 's/.*(\([A-F0-9-]\{36\}\)).*/\1/p' | head -1)"
fi
if [[ -z "$UDID" ]]; then
  echo "No booted simulator. Boot one, then re-run." >&2
  exit 1
fi

echo "== Build + install (udid=$UDID) =="
cd "$IOS"
xcodebuild -scheme Drome -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DD" build | tee /tmp/drome-mini-verify-build.txt | tail -5
APP="$DD/Build/Products/Debug-iphonesimulator/Drome.app"
xcrun simctl terminate booted drome.app 2>/dev/null || true
xcrun simctl install booted "$APP"

echo "== Music baseline =="
xcrun simctl launch booted drome.app
sleep 10
xcrun simctl io booted screenshot "$OUT/music-mini.png"

echo "== Podcast replaces music (UITest seed) =="
xcrun simctl terminate booted drome.app
sleep 1
xcrun simctl launch booted drome.app -UITestPodcastMini
sleep 10
xcrun simctl io booted screenshot "$OUT/podcast-replaces-music.png"

if command -v idb >/dev/null 2>&1; then
  idb connect "$UDID" >/dev/null
  idb ui describe-all --udid "$UDID" > "$OUT/ax-podcast.json"
  python3 - <<PY
import json, sys
data=json.load(open("$OUT/ax-podcast.json"))
skip30=any("30" in (n.get("AXLabel") or "") for n in data)
forward=any((n.get("AXLabel") or "")=="Forward" for n in data)
open_np=any((n.get("AXLabel") or "")=="Open now playing" for n in data)
ok = skip30 and open_np and not forward
print(f"skip30={skip30} forward={forward} open_np={open_np}")
if not ok:
    print("FAIL: expected podcast mini chrome (skip 30, not music Forward)", file=sys.stderr)
    sys.exit(1)
print("OK podcast mini chrome present")
PY
fi

echo "Screenshots in $OUT"
ls -la "$OUT"
