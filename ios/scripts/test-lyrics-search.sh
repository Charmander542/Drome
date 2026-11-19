#!/usr/bin/env bash
# Sync pure lyrics fuzzy helpers from the app target into LyricsSearchKit, then test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KIT="$ROOT/LyricsSearchKit"
SRC="$KIT/Sources/LyricsSearchKit"
mkdir -p "$SRC"

cp "$ROOT/Drome/Core/Services/LyricsFuzzySearch.swift" "$SRC/"

cd "$KIT"
swift test "$@"
