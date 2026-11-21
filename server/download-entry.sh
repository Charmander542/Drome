#!/usr/bin/env bash
# Thin wrapper around SpotiFLAC so the Go server can call a stable CLI.
# Usage: drome-download <spotify-url> <music-dir> [--service a b ...] [extra flags...]
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: drome-download <spotify-url> <music-dir> [spotiflac args...]" >&2
  exit 2
fi

URL="$1"
OUT="$2"
shift 2

AUDIO_FIND=(find "$OUT" -type f \( -iname '*.flac' -o -iname '*.m4a' -o -iname '*.mp3' -o -iname '*.ogg' -o -iname '*.opus' -o -iname '*.wav' -o -iname '*.aiff' \))

count_audio() {
  if [[ ! -d "$OUT" ]]; then
    echo 0
    return
  fi
  "${AUDIO_FIND[@]}" 2>/dev/null | wc -l | tr -d ' '
}

# SpotiFLAC 5+ JS extensions need a display for Chromium Turnstile solves.
run_spotiflac() {
  if command -v xvfb-run >/dev/null 2>&1; then
    xvfb-run -a "$@"
  else
    "$@"
  fi
}

# Python SpotiFLAC uses {track} (not {track_number}). Layout matches the
# existing Navidrome library: Artist/Album/NN - Title.flac
# Drome always post-processes with retag.py so wishlist Spotify metadata wins
# even when SpotiFLAC leaves provider IDs as titles.
#
# SpotiFLAC often exits 0 even when every track failed (or when no extensions
# are installed). Capture output + audio file counts and treat empty runs as
# failure so the Go worker retries instead of blaming retag.
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

before="$(count_audio)"

set +e
run_spotiflac spotiflac "$URL" "$OUT" \
  --use-artist-subfolders \
  --use-album-subfolders \
  --filename-format "{track} - {title}" \
  "$@" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e

after="$(count_audio)"

if [[ "$rc" -ne 0 ]]; then
  exit "$rc"
fi

# Strip ANSI / progress-bar noise before matching the session summary.
clean="$(sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$LOG" | tr -d '\r')"

if echo "$clean" | grep -Eq 'Successful[[:space:]]*:[[:space:]]*0'; then
  detail="$(echo "$clean" | grep -E 'All providers failed|Failed:' | tail -1 | sed 's/^[[:space:]]*//')"
  if [[ -z "$detail" ]]; then
    detail="SpotiFLAC reported 0 successful downloads"
  fi
  echo "drome-download: $detail" >&2
  exit 1
fi

if [[ "$after" -le "$before" ]]; then
  detail="$(echo "$clean" | grep -E 'All providers failed|Failed:|No registry|not installed|Extension' | tail -1 | sed 's/^[[:space:]]*//')"
  if [[ -z "$detail" ]]; then
    detail="no audio files written under $OUT (before=$before after=$after)"
  fi
  echo "drome-download: $detail" >&2
  exit 1
fi

exit 0
