#!/usr/bin/env bash
# Sync podcast sources from the app target into PodcastKit, then run tests.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KIT="$ROOT/PodcastKit"
SRC="$KIT/Sources/PodcastKit"
mkdir -p "$SRC"

cp "$ROOT/Drome/Core/Models/PodcastModels.swift" "$SRC/"
cp "$ROOT/Drome/Core/Podcasts/RSSPodcastParser.swift" "$SRC/"
cp "$ROOT/Drome/Core/Podcasts/PodcastStore.swift" "$SRC/"

cd "$KIT"
swift test "$@"
