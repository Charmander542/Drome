#!/usr/bin/env bash
# Sync CarPlayListPolicy into a tiny SPM package, then run headless tests
# (no CarPlay Simulator / Xcode required — same idea as test-podcasts.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/CarPlayPolicy"
SRC="$PKG/Sources/CarPlayListPolicy"
mkdir -p "$SRC"
cp "$ROOT/Drome/CarPlay/CarPlayListPolicy.swift" "$SRC/"
cd "$PKG"
swift test "$@"
