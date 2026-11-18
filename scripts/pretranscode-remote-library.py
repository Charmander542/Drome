#!/usr/bin/env python3
"""Incrementally mirror a FLAC/lossy library to 192 kbps MP3 for Funnel guests.

Source tree layout is preserved; each audio file becomes a .mp3 under --dest.
Skips work when the destination exists and is newer than (or equal mtime to)
the source. Safe to run from cron.

Example:
  ./scripts/pretranscode-remote-library.py \\
    --source /srv/storage/Media/Music \\
    --dest /srv/storage/Media/Music-Remote
"""
from __future__ import annotations

import argparse
import contextlib
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

AUDIO_EXTS = {".flac", ".m4a", ".mp3", ".ogg", ".opus", ".wav", ".aiff", ".aif", ".wma"}
# Already-small lossy files can be remuxed/re-encoded to a uniform 192k MP3 so
# the remote library is one format for Navidrome.
BITRATE = "192k"


def rel_mp3_path(source_root: Path, dest_root: Path, src: Path) -> Path:
    rel = src.relative_to(source_root)
    return dest_root / rel.with_suffix(".mp3")


def needs_encode(src: Path, dest: Path) -> bool:
    if not dest.is_file():
        return True
    try:
        if dest.stat().st_size < 1024:
            return True
        return src.stat().st_mtime > dest.stat().st_mtime + 1.0
    except OSError:
        return True


def encode(src: Path, dest: Path, ffmpeg: str, dry_run: bool) -> tuple[str, str]:
    dest.parent.mkdir(parents=True, exist_ok=True)
    # Suffix must stay .mp3 so ffmpeg picks the mp3 muxer (".mp3.partial" fails).
    tmp = dest.with_name(dest.stem + ".partial.mp3")
    if dry_run:
        return "dry-run", str(dest)
    cmd = [
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        str(src),
        "-vn",
        "-map_metadata",
        "0",
        "-codec:a",
        "libmp3lame",
        "-b:a",
        BITRATE,
        "-f",
        "mp3",
        str(tmp),
    ]
    try:
        subprocess.run(cmd, check=True, timeout=600)
        os.replace(tmp, dest)
        # Match source mtime so later runs stay cheap.
        try:
            mtime = src.stat().st_mtime
            os.utime(dest, (mtime, mtime))
        except OSError:
            pass
        return "encoded", str(dest)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as err:
        with contextlib.suppress(OSError):
            tmp.unlink(missing_ok=True)
        return "error", f"{src}: {err}"


def iter_audio(root: Path):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        # Skip obvious junk / AppleDouble
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for name in sorted(filenames):
            if name.startswith("."):
                continue
            path = Path(dirpath) / name
            if path.suffix.lower() in AUDIO_EXTS:
                yield path


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--source", type=Path, default=Path("/srv/storage/Media/Music"))
    ap.add_argument("--dest", type=Path, default=Path("/srv/storage/Media/Music-Remote"))
    ap.add_argument("--ffmpeg", default=shutil.which("ffmpeg") or "ffmpeg")
    ap.add_argument(
        "--limit",
        type=int,
        default=0,
        help="Stop after N encode attempts (including errors; 0 = no limit)",
    )
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--jobs", type=int, default=1, help="Reserved; currently serial")
    args = ap.parse_args()

    if not args.source.is_dir():
        print(f"source missing: {args.source}", file=sys.stderr)
        return 2
    if shutil.which(args.ffmpeg) is None and not Path(args.ffmpeg).is_file():
        print(f"ffmpeg not found: {args.ffmpeg}", file=sys.stderr)
        return 2

    args.dest.mkdir(parents=True, exist_ok=True)
    started = time.time()
    scanned = encoded = skipped = errors = 0

    for src in iter_audio(args.source):
        scanned += 1
        dest = rel_mp3_path(args.source, args.dest, src)
        if not needs_encode(src, dest):
            skipped += 1
            continue
        status, detail = encode(src, dest, args.ffmpeg, args.dry_run)
        attempted = encoded + errors + 1
        if status == "encoded" or status == "dry-run":
            encoded += 1
            if encoded % 25 == 0 or encoded <= 3 or status == "dry-run":
                print(f"[{status}] {src.relative_to(args.source)} → {dest.relative_to(args.dest)}")
        else:
            errors += 1
            print(f"[error] {detail}", file=sys.stderr)
        if args.limit and (encoded + errors) >= args.limit:
            print(f"limit {args.limit} reached (attempted={attempted})")
            break

    elapsed = time.time() - started
    print(
        f"done scanned={scanned} encoded={encoded} skipped={skipped} "
        f"errors={errors} elapsed={elapsed:.1f}s dest={args.dest}"
    )
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
