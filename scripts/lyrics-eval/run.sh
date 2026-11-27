#!/usr/bin/env bash
# Repeatable karaoke timing harness.
#   ./run.sh fixtures     # generate + check synthetic fixture (no Whisper)
#   ./run.sh measure --audio X.wav --lrc X.lrc
#   ./run.sh refine  --audio X.wav --lrc X.lrc [--write]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
PY="${PYTHON:-python3}"

cmd="${1:-fixtures}"
shift || true

case "$cmd" in
  fixtures)
    "$PY" "$ROOT/align_lyrics.py" synth-fixture --out-dir "$ROOT/fixtures/perfect"
    "$PY" "$ROOT/align_lyrics.py" check-truth \
      --lrc "$ROOT/fixtures/perfect/perfect.lrc" \
      --truth "$ROOT/fixtures/perfect/perfect.truth.json"
    "$PY" "$ROOT/align_lyrics.py" check-truth \
      --lrc "$ROOT/fixtures/offset-demo/late.lrc" \
      --truth "$ROOT/fixtures/offset-demo/truth.json" \
      && { echo "offset-demo late.lrc should FAIL" >&2; exit 1; } || true
    "$PY" "$ROOT/align_lyrics.py" check-truth \
      --lrc "$ROOT/fixtures/offset-demo/fixed.lrc" \
      --truth "$ROOT/fixtures/offset-demo/truth.json"
    echo "fixtures: PASS (perfect + [offset:] correction)"
    ;;
  measure|refine|synth-fixture|check-truth)
    exec "$PY" "$ROOT/align_lyrics.py" "$cmd" "$@"
    ;;
  *)
    echo "usage: $0 {fixtures|measure|refine|synth-fixture|check-truth} ..." >&2
    exit 2
    ;;
esac
