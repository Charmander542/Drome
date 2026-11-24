#!/usr/bin/env bash
# Sync LRCParser into a tiny SPM package, then run headless timing tests.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/LyricsTiming"
SRC="$PKG/Sources/LRCParser"
mkdir -p "$SRC"
cp "$ROOT/Drome/Core/Services/LRCParser.swift" "$SRC/"
cd "$PKG"
swift test "$@"
