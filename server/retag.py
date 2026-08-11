#!/usr/bin/env python3
"""Apply Spotify wishlist metadata to freshly downloaded audio files.

SpotiFLAC sometimes leaves provider IDs (Amazon ASINs, hex stubs) as titles
when its own Spotify metadata fetch fails. Drome already resolved good
title/artist/album into the wishlist DB — this script writes those tags and
renames files into Artist/Album/NN - Title.ext.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
from pathlib import Path

from mutagen import File as MutagenFile
from mutagen.mp4 import MP4

AUDIO_EXTS = {".flac", ".m4a", ".mp3", ".ogg", ".opus", ".wav", ".aiff"}

# Amazon ASINs, bracketed hex stubs like [b578902], bare hex, Spotify-looking ids.
GARBAGE_TITLE = re.compile(
    r"^(?:\[[0-9a-fA-F]{5,}\]|B0[0-9A-Z]{8,}|[0-9a-fA-F]{6,}|\{[^}]*\})$"
)


def looks_garbage(value: str | None) -> bool:
    if not value:
        return True
    s = value.strip()
    if len(s) < 2:
        return True
    if GARBAGE_TITLE.match(s):
        return True
    # Filename leftovers without spaces that are mostly hex/digits
    if " " not in s and re.fullmatch(r"[0-9A-Za-z._-]{6,16}", s) and sum(c.isdigit() or c in "abcdefABCDEF" for c in s) >= len(s) * 0.6:
        return True
    return False


def sanitize_path(name: str) -> str:
    name = name.strip() or "Unknown"
    for ch in '<>:"/\\|?*':
        name = name.replace(ch, "_")
    name = name.rstrip(" .")
    return name[:180] or "Unknown"


def read_title(audio) -> str:
    if audio is None:
        return ""
    if isinstance(audio, MP4):
        return (audio.tags.get("\xa9nam") or [""])[0] if audio.tags else ""
    for key in ("title", "TITLE", "TIT2"):
        if key in audio:
            val = audio[key]
            return str(val[0]) if val else ""
    return ""


def write_tags(path: Path, *, title: str, artist: str, album: str, trackno: int | None) -> None:
    audio = MutagenFile(path, easy=True)
    if audio is None:
        raise RuntimeError(f"unsupported audio: {path}")
    if title:
        audio["title"] = [title]
    if artist:
        audio["artist"] = [artist]
        try:
            audio["albumartist"] = [artist]
        except Exception:
            pass
    if album:
        audio["album"] = [album]
    if trackno and trackno > 0:
        try:
            audio["tracknumber"] = [str(trackno)]
        except Exception:
            pass
    audio.save()


def target_path(
    music_dir: Path,
    artist: str,
    album: str,
    title: str,
    trackno: int | None,
    ext: str,
    source: Path,
) -> Path:
    folder = music_dir / sanitize_path(artist or "Unknown Artist") / sanitize_path(album or "Unknown Album")
    folder.mkdir(parents=True, exist_ok=True)
    if trackno and trackno > 0:
        base = f"{trackno:02d} - {sanitize_path(title)}"
    else:
        base = sanitize_path(title)
    dest = folder / f"{base}{ext}"
    try:
        if dest.exists() and dest.resolve() != source.resolve():
            n = 2
            while True:
                candidate = folder / f"{base} ({n}){ext}"
                if not candidate.exists():
                    return candidate
                n += 1
    except OSError:
        pass
    return dest


def process_file(
    path: Path,
    *,
    music_dir: Path,
    kind: str,
    title: str,
    artist: str,
    album: str,
    trackno: int | None,
    dry_run: bool,
) -> str:
    current_title = ""
    try:
        current_title = read_title(MutagenFile(path))
    except Exception:
        current_title = path.stem

    # For single-track wishlist jobs, always prefer Spotify metadata.
    # For albums, only override title when the embedded/file name looks broken.
    if kind == "track":
        new_title = title or current_title or path.stem
    else:
        new_title = title if looks_garbage(current_title) and title else (current_title or title or path.stem)
        if looks_garbage(new_title) and title:
            new_title = title

    new_artist = artist or "Unknown Artist"
    new_album = album or (title if kind == "album" else "") or "Unknown Album"

    dest = target_path(
        music_dir, new_artist, new_album, new_title, trackno, path.suffix.lower(), path
    )
    action = f"{path} -> {dest}"
    if dry_run:
        return action

    write_tags(path, title=new_title, artist=new_artist, album=new_album, trackno=trackno)
    if path.resolve() != dest.resolve():
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(path), str(dest))
        # Re-write tags after move (some containers store path-relative state).
        write_tags(dest, title=new_title, artist=new_artist, album=new_album, trackno=trackno)
        # Drop empty parent dirs left behind by SpotiFLAC's ASIN folders.
        for parent in path.parents:
            if parent == music_dir or not parent.is_relative_to(music_dir):
                break
            try:
                parent.rmdir()
            except OSError:
                break
    return action


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--music-dir", required=True)
    ap.add_argument("--kind", choices=("track", "album"), required=True)
    ap.add_argument("--title", default="")
    ap.add_argument("--artist", default="")
    ap.add_argument("--album", default="")
    ap.add_argument("--since-epoch", type=float, required=True, help="Only touch files mtime >= this")
    ap.add_argument("--files-json", default="", help="Optional explicit file list JSON array")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    music_dir = Path(args.music_dir)
    if not music_dir.is_dir():
        print(f"music dir missing: {music_dir}", file=sys.stderr)
        return 2

    files: list[Path] = []
    if args.files_json:
        for raw in json.loads(args.files_json):
            p = Path(raw)
            if p.is_file():
                files.append(p)
    else:
        since = args.since_epoch - 2.0  # small skew cushion
        for p in music_dir.rglob("*"):
            if p.suffix.lower() not in AUDIO_EXTS or not p.is_file():
                continue
            try:
                if p.stat().st_mtime >= since:
                    files.append(p)
            except OSError:
                continue

    if not files:
        print("no recent audio files to retag", file=sys.stderr)
        return 3

    # Track wishlist jobs download one file. The mtime window often still
    # includes files from the previous job; applying args.title to all of
    # them renames every recent track to the latest entry.
    if args.kind == "track" and not args.files_json and len(files) > 1:
        files = [max(files, key=lambda p: p.stat().st_mtime)]

    files.sort(key=lambda p: p.name.lower())
    # For album downloads, assign track numbers by filename order when missing.
    results = []
    for i, path in enumerate(files, start=1):
        trackno = i if args.kind == "album" and len(files) > 1 else (1 if args.kind == "track" else None)
        # Album wishlist title is the album name, not each track title.
        title = args.title if args.kind == "track" else ""
        album = args.album or (args.title if args.kind == "album" else "")
        results.append(
            process_file(
                path,
                music_dir=music_dir,
                kind=args.kind,
                title=title,
                artist=args.artist,
                album=album,
                trackno=trackno,
                dry_run=args.dry_run,
            )
        )

    print(json.dumps({"count": len(results), "files": results}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
