#!/usr/bin/env bash
# Repeatable karaoke timing harness (CTC + Demucs, not Whisper).
#   ./run.sh fixtures        # synthetic check-truth (no ML)
#   ./run.sh measure ...
#   ./run.sh generate-words ...
#   ./run.sh refine-words ...   # alias → generate-words
#   ./run.sh check-deps|benchmark|validate-aligner ...
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
PY="${PYTHON:-python3}"

cmd="${1:-fixtures}"
shift || true

case "$cmd" in
  fixtures)
    # check-truth only — do not regenerate wavs over committed fixtures
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
  measure|generate-words|refine-words|refine|synth-fixture|check-truth|validate-aligner|separate|check-deps|benchmark)
    # `refine` / `refine-words` kept as aliases for older docs
    if [[ "$cmd" == "refine" || "$cmd" == "refine-words" ]]; then cmd="generate-words"; fi
    exec "$PY" "$ROOT/align_lyrics.py" "$cmd" "$@"
    ;;
  *)
    echo "usage: $0 {fixtures|measure|generate-words|check-deps|benchmark|validate-aligner|synth-fixture|check-truth} ..." >&2
    exit 2
    ;;
esac
