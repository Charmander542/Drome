#!/usr/bin/env python3
"""Clean up a Navidrome music library after bad SpotiFLAC downloads.

Finds:
  1. Files with garbage titles (Amazon ASINs, [hex] stubs, empty tags)
  2. Duplicate album folders (same artist+album, different paths / years)

Usage (dry-run by default):
  python3 scripts/cleanup_library.py --music-dir /music
  python3 scripts/cleanup_library.py --music-dir /music --apply --fix-tags
  python3 scripts/cleanup_library.py --music-dir /music --apply --merge-dupes

--fix-tags only rewrites tags that look garbage when you also pass
--spotify-json with a map of path→{title,artist,album}, or leaves a report
for manual fix. Prefer re-adding the Spotify link to the wishlist for a
full re-download + retag via drome-server.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
from collections import defaultdict
from pathlib import Path

try:
    from mutagen import File as MutagenFile
except ImportError:
    print("mutagen required: pip install mutagen", file=sys.stderr)
    sys.exit(1)

AUDIO_EXTS = {".flac", ".m4a", ".mp3", ".ogg", ".opus", ".wav", ".aiff"}
GARBAGE_TITLE = re.compile(
    r"^(?:\[[0-9a-fA-F]{5,}\]|B0[0-9A-Z]{8,}|[0-9a-fA-F]{6,}|\{[^}]*\})$"
)
YEAR_SUFFIX = re.compile(r"\s*[\(\[]?(?:19|20)\d{2}[\)\]]?\s*$")


def looks_garbage(value: str | None) -> bool:
    if not value:
        return True
    s = value.strip()
    if len(s) < 2:
        return True
    if GARBAGE_TITLE.match(s):
        return True
    if " " not in s and re.fullmatch(r"[0-9A-Za-z._-]{6,16}", s):
        hexish = sum(c.isdigit() or c in "abcdefABCDEF" for c in s)
        if hexish >= len(s) * 0.6:
            return True
    return False


def easy_get(audio, key: str) -> str:
    if audio is None or audio.tags is None:
        return ""
    try:
        val = audio.get(key)
        if not val:
            return ""
        return str(val[0]).strip()
    except Exception:
        return ""


def normalize_album_key(artist: str, album: str) -> str:
    a = YEAR_SUFFIX.sub("", album or "").strip().lower()
    a = re.sub(r"\s+", " ", a)
    ar = (artist or "").strip().lower()
    return f"{ar}|{a}"


def scan(music_dir: Path):
    bad = []
    albums: dict[str, list[dict]] = defaultdict(list)

    for path in music_dir.rglob("*"):
        if path.suffix.lower() not in AUDIO_EXTS or not path.is_file():
            continue
        try:
            audio = MutagenFile(path, easy=True)
        except Exception:
            audio = None
        title = easy_get(audio, "title") or path.stem
        artist = easy_get(audio, "artist") or (path.parents[1].name if len(path.parents) > 1 else "")
        album = easy_get(audio, "album") or (path.parent.name if path.parent != music_dir else "")
        albumartist = easy_get(audio, "albumartist") or artist

        rec = {
            "path": str(path),
            "title": title,
            "artist": artist,
            "album": album,
            "albumartist": albumartist,
            "folder": str(path.parent),
            "size": path.stat().st_size,
            "mtime": path.stat().st_mtime,
        }
        if looks_garbage(title) or looks_garbage(album) or looks_garbage(artist):
            bad.append(rec)

        key = normalize_album_key(albumartist or artist, album)
        if key != "|":
            albums[key].append(rec)

    dupes = []
    for key, tracks in albums.items():
        folders = sorted({t["folder"] for t in tracks})
        if len(folders) > 1:
            dupes.append({
                "key": key,
                "folders": folders,
                "track_count": len(tracks),
                "tracks": tracks,
            })
    return bad, dupes


def merge_dupe_group(group: dict, apply: bool) -> list[str]:
    """Keep the folder with the most tracks (tie: newest mtime); move others in."""
    actions = []
    by_folder: dict[str, list[dict]] = defaultdict(list)
    for t in group["tracks"]:
        by_folder[t["folder"]].append(t)

    def folder_score(folder: str):
        tracks = by_folder[folder]
        return (len(tracks), max(t["mtime"] for t in tracks), -sum(1 for t in tracks if looks_garbage(t["title"])))

    keep = max(by_folder.keys(), key=folder_score)
    keep_path = Path(keep)
    for folder, tracks in by_folder.items():
        if folder == keep:
            continue
        for t in tracks:
            src = Path(t["path"])
            dest = keep_path / src.name
            if dest.exists():
                # Prefer larger / better-tagged file.
                if dest.stat().st_size >= src.stat().st_size and not looks_garbage(t["title"]):
                    actions.append(f"DROP duplicate {src} (keeping {dest})")
                    if apply:
                        src.unlink(missing_ok=True)
                    continue
                stem, ext = src.stem, src.suffix
                n = 2
                while dest.exists():
                    dest = keep_path / f"{stem} ({n}){ext}"
                    n += 1
            actions.append(f"MOVE {src} -> {dest}")
            if apply:
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(src), str(dest))
        folder_path = Path(folder)
        if apply:
            try:
                # Remove empty dirs upward until music root.
                for parent in [folder_path, *folder_path.parents]:
                    if parent == keep_path.parent.parent:
                        break
                    try:
                        parent.rmdir()
                    except OSError:
                        break
            except Exception:
                pass
    return actions


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--music-dir", required=True)
    ap.add_argument("--apply", action="store_true", help="Perform changes (default is dry-run)")
    ap.add_argument("--merge-dupes", action="store_true", help="Merge duplicate album folders")
    ap.add_argument("--report", default="", help="Write JSON report path")
    ap.add_argument("--quiet", action="store_true", help="One-line summary (for scheduled runs)")
    args = ap.parse_args()

    music_dir = Path(args.music_dir)
    if not music_dir.is_dir():
        print(f"missing music dir: {music_dir}", file=sys.stderr)
        return 2

    bad, dupes = scan(music_dir)
    report = {
        "bad_metadata_count": len(bad),
        "duplicate_album_groups": len(dupes),
        "bad_metadata": bad[:200],
        "duplicates": [
            {"key": d["key"], "folders": d["folders"], "track_count": d["track_count"]}
            for d in dupes
        ],
    }

    actions = []
    for d in dupes:
        if args.merge_dupes:
            actions.extend(merge_dupe_group(d, apply=args.apply))

    if args.report:
        Path(args.report).write_text(json.dumps(report, indent=2))

    if args.quiet:
        mode = "apply" if args.apply and args.merge_dupes else "report"
        print(
            f"mode={mode} bad_tags={len(bad)} duplicate_albums={len(dupes)} "
            f"merge_actions={len(actions)}"
        )
        return 0

    print(f"Bad metadata files: {len(bad)}")
    for rec in bad[:40]:
        print(f"  BAD  {rec['path']}")
        print(f"       title={rec['title']!r} artist={rec['artist']!r} album={rec['album']!r}")
    if len(bad) > 40:
        print(f"  … {len(bad) - 40} more")

    print(f"\nDuplicate album groups: {len(dupes)}")
    for d in dupes:
        print(f"  DUPE {d['key']}")
        for folder in d["folders"]:
            print(f"       {folder}")

    if actions:
        print(f"\nMerge actions ({'APPLY' if args.apply else 'dry-run'}): {len(actions)}")
        for a in actions[:80]:
            print(f"  {a}")
        if len(actions) > 80:
            print(f"  … {len(actions) - 80} more")

    if args.report:
        print(f"\nWrote report → {args.report}")

    print("\nTip: for bad tags, re-add the Spotify link in Drome wishlist so the")
    print("server re-downloads and runs retag.py with correct Spotify metadata.")
    if not args.apply:
        print("Dry-run only. Pass --apply --merge-dupes to consolidate duplicates.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
