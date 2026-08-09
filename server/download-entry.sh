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

# Python SpotiFLAC uses {track} (not {track_number}). Layout matches the
# existing Navidrome library: Artist/Album/NN - Title.flac
# Drome always post-processes with retag.py so wishlist Spotify metadata wins
# even when SpotiFLAC leaves provider IDs as titles.
exec spotiflac "$URL" "$OUT" \
  --use-artist-subfolders \
  --use-album-subfolders \
  --filename-format "{track} - {title}" \
  "$@"
