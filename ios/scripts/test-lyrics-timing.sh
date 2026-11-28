#!/usr/bin/env bash
# Sync LRCParser + LRCLIBClient into a tiny SPM package, then run headless tests.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/LyricsTiming"
SRC="$PKG/Sources/LRCParser"
mkdir -p "$SRC"
cp "$ROOT/Drome/Core/Services/LRCParser.swift" "$SRC/"
cp "$ROOT/Drome/Core/API/LRCLIBClient.swift" "$SRC/"
cd "$PKG"
swift test "$@"
