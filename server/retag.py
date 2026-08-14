#!/usr/bin/env python3
"""Apply Spotify wishlist metadata to freshly downloaded audio files.

Navidrome groups albums by Album Artist + Album (+ UPC / MusicBrainz album id).
Guest features belong on the track Artist tag only — never in Album Artist or
the on-disk folder path.

Layout:  {primary_artist}/{album}/{NN} - {title}.ext
Tags:    albumartist=primary, artist=may include features, shared album/upc/mbid
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
from collections import Counter
from pathlib import Path

from mutagen import File as MutagenFile
from mutagen.mp4 import MP4

AUDIO_EXTS = {".flac", ".m4a", ".mp3", ".ogg", ".opus", ".wav", ".aiff"}

GARBAGE_TITLE = re.compile(
    r"^(?:\[[0-9a-fA-F]{5,}\]|B0[0-9A-Z]{8,}|[0-9a-fA-F]{6,}|\{[^}]*\})$"
)
FEAT_SPLIT = re.compile(
    r"\s+(?:feat\.?|ft\.?|featuring|with)\s+", re.IGNORECASE
)
GUEST_JOIN = re.compile(r",\s+")


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


def sanitize_path(name: str) -> str:
    name = name.strip() or "Unknown"
    for ch in '<>:"/\\|?*':
        name = name.replace(ch, "_")
    name = name.rstrip(" .")
    return name[:180] or "Unknown"


def is_guest_join(name: str) -> bool:
    """True for Spotify-style multi-artist joins ('Lil Wayne, JAY-Z'), false for
    single artists that happen to contain a comma ('Tyler, The Creator',
    'Earth, Wind & Fire')."""
    s = (name or "").strip()
    segs = GUEST_JOIN.split(s)
    if len(segs) < 2:
        return False
    rest = ", ".join(segs[1:])
    if "&" in rest or re.search(r"\band\b", rest, re.I):
        return False
    if re.match(r"^(The|A)\s+\S+", segs[1].strip(), re.I):
        return False
    return True


def primary_artist(name: str) -> str:
    """Primary / album artist only. Strip feat./ft. credits; peel Spotify
    guest joins; keep band names with internal commas."""
    s = (name or "").strip()
    if not s:
        return "Unknown Artist"
    parts = FEAT_SPLIT.split(s, maxsplit=1)
    s = parts[0].strip()
    if is_guest_join(s):
        return GUEST_JOIN.split(s, maxsplit=1)[0].strip() or s
    return s


def easy_get(audio, key: str) -> str:
    if audio is None:
        return ""
    try:
        val = audio.get(key)
        if not val:
            return ""
        return str(val[0]).strip()
    except Exception:
        return ""


def easy_get_all(audio, key: str) -> list[str]:
    if audio is None:
        return []
    try:
        val = audio.get(key)
        if not val:
            return []
        return [str(v).strip() for v in val if str(v).strip()]
    except Exception:
        return []


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


def drop_splitter_tags(audio) -> None:
    """Provider catalog/ASIN/release-group ids split one album in Navidrome."""
    for key in ("catalognumber", "asin", "musicbrainz_releasegroupid"):
        try:
            if key in audio:
                del audio[key]
        except Exception:
            pass


def write_tags(
    path: Path,
    *,
    title: str,
    artist: str | list[str],
    album_artist: str,
    album: str,
    trackno: int | None,
    upc: str,
    mbid: str,
) -> None:
    audio = MutagenFile(path, easy=True)
    if audio is None:
        raise RuntimeError(f"unsupported audio: {path}")

    if title:
        audio["title"] = [title]

    if isinstance(artist, list):
        arts = [a for a in artist if a]
    else:
        arts = [artist] if artist else []
    if arts:
        audio["artist"] = arts

    if album_artist:
        try:
            audio["albumartist"] = [album_artist]
        except Exception:
            pass
        # Never leave a stale "Various Artists" sort on a single-artist album.
        try:
            sort_val = easy_get(audio, "albumartistsort")
            if not sort_val or sort_val.lower() in {"various artists", "various"}:
                audio["albumartistsort"] = [album_artist]
        except Exception:
            pass

    if album:
        audio["album"] = [album]

    drop_splitter_tags(audio)

    if trackno and trackno > 0:
        try:
            audio["tracknumber"] = [str(trackno)]
        except Exception:
            pass

    if upc:
        for key in ("upc", "barcode"):
            try:
                audio[key] = [upc]
            except Exception:
                pass

    if mbid:
        try:
            audio["musicbrainz_albumid"] = [mbid]
        except Exception:
            pass
    else:
        # Drop conflicting per-track MBIDs so Navidrome doesn't split the album.
        try:
            if "musicbrainz_albumid" in audio:
                del audio["musicbrainz_albumid"]
        except Exception:
            pass

    audio.save()


def target_path(
    music_dir: Path,
    album_artist: str,
    album: str,
    title: str,
    trackno: int | None,
    ext: str,
) -> Path:
    folder = (
        music_dir
        / sanitize_path(album_artist or "Unknown Artist")
        / sanitize_path(album or "Unknown Album")
    )
    folder.mkdir(parents=True, exist_ok=True)
    if trackno and trackno > 0:
        base = f"{trackno:02d} - {sanitize_path(title)}"
    else:
        base = sanitize_path(title)
    return folder / f"{base}{ext}"


def move_replace(source: Path, dest: Path, music_dir: Path) -> Path:
    """Move source → dest. Same album+title under primary artist replaces the
    existing file — never create a second folder/file set for guests."""
    dest.parent.mkdir(parents=True, exist_ok=True)

    def title_key(p: Path) -> str:
        stem = p.stem
        m = re.match(r"^\d+\s*[-.]\s*(.+)$", stem)
        return (m.group(1) if m else stem).strip().lower()

    try:
        if dest.exists() and dest.resolve() != source.resolve():
            if title_key(dest) == title_key(source):
                dest.unlink(missing_ok=True)
            else:
                # Different track already at this exact path — keep both.
                n = 2
                stem, ext = dest.stem, dest.suffix
                while dest.exists():
                    dest = dest.parent / f"{stem} ({n}){ext}"
                    n += 1
        # Also drop any other file in the destination album folder with the
        # same title (e.g. guest-folder move left a differently numbered copy).
        if dest.parent.is_dir():
            key = title_key(source)
            for other in dest.parent.iterdir():
                if not other.is_file() or other.suffix.lower() not in AUDIO_EXTS:
                    continue
                try:
                    if other.resolve() == source.resolve():
                        continue
                    if title_key(other) == key and other.name != dest.name:
                        other.unlink(missing_ok=True)
                except OSError:
                    continue
    except OSError:
        pass

    shutil.move(str(source), str(dest))
    for parent in source.parents:
        if parent == music_dir or not parent.is_relative_to(music_dir):
            break
        try:
            parent.rmdir()
        except OSError:
            break
    return dest


def folder_identity(folder: Path) -> tuple[str, str, str]:
    """Reuse albumartist / UPC / MBID already on disk so new tracks merge."""
    if not folder.is_dir():
        return "", "", ""
    artists: Counter[str] = Counter()
    upcs: Counter[str] = Counter()
    mbids: Counter[str] = Counter()
    for path in folder.iterdir():
        if path.suffix.lower() not in AUDIO_EXTS:
            continue
        try:
            audio = MutagenFile(path, easy=True)
        except Exception:
            continue
        aa = easy_get(audio, "albumartist")
        if aa:
            artists[aa] += 1
        for key in ("upc", "barcode"):
            v = easy_get(audio, key)
            if v:
                upcs[v] += 1
        v = easy_get(audio, "musicbrainz_albumid")
        if v:
            mbids[v] += 1
    album_artist = artists.most_common(1)[0][0] if artists else ""
    upc = upcs.most_common(1)[0][0] if upcs else ""
    mbid = mbids.most_common(1)[0][0] if len(mbids) == 1 else ""
    return album_artist, upc, mbid


def unify_album_folder(
    folder: Path, *, album_artist: str, album: str, upc: str, mbid: str
) -> None:
    """Force every file in the album folder onto one Navidrome album identity."""
    if not folder.is_dir():
        return
    for path in folder.iterdir():
        if path.suffix.lower() not in AUDIO_EXTS:
            continue
        try:
            audio = MutagenFile(path, easy=True)
            if audio is None:
                continue
            if album_artist:
                try:
                    audio["albumartist"] = [album_artist]
                except Exception:
                    pass
            if album:
                audio["album"] = [album]
            if upc:
                for key in ("upc", "barcode"):
                    try:
                        audio[key] = [upc]
                    except Exception:
                        pass
            try:
                if mbid:
                    audio["musicbrainz_albumid"] = [mbid]
                elif "musicbrainz_albumid" in audio:
                    del audio["musicbrainz_albumid"]
            except Exception:
                pass
            drop_splitter_tags(audio)
            audio.save()
        except Exception:
            continue


def process_file(
    path: Path,
    *,
    music_dir: Path,
    kind: str,
    title: str,
    artist: str,
    album_artist: str,
    album: str,
    trackno: int | None,
    upc: str,
    mbid: str,
    dry_run: bool,
) -> str:
    current_title = ""
    existing_artists: list[str] = []
    existing_album = ""
    existing_aa = ""
    try:
        audio = MutagenFile(path, easy=True)
        current_title = read_title(MutagenFile(path)) if audio is None else easy_get(audio, "title") or read_title(audio)
        existing_artists = easy_get_all(audio, "artist")
        existing_album = easy_get(audio, "album")
        existing_aa = easy_get(audio, "albumartist")
    except Exception:
        current_title = path.stem

    if kind == "track":
        new_title = title or current_title or path.stem
    else:
        new_title = title if looks_garbage(current_title) and title else (current_title or title or path.stem)
        if looks_garbage(new_title) and title:
            new_title = title

    if kind == "playlist":
        # Keep each file's own album/title — the wishlist row is the playlist, not an album.
        new_title = current_title or path.stem
        new_album = existing_album or path.parent.name or "Unknown Album"
        primary = primary_artist(existing_aa or (existing_artists[0] if existing_artists else "") or artist)
        if looks_garbage(new_album):
            new_album = path.parent.name or "Unknown Album"
    else:
        primary = primary_artist(album_artist) if album_artist else primary_artist(artist)
        new_album = album or (title if kind == "album" else "") or "Unknown Album"
    new_album = " ".join(new_album.split())

    dest = target_path(
        music_dir, primary, new_album, new_title, trackno, path.suffix.lower()
    )
    inherited_aa, inherited_upc, inherited_mbid = folder_identity(dest.parent)
    if inherited_aa:
        primary = inherited_aa
        dest = target_path(
            music_dir, primary, new_album, new_title, trackno, path.suffix.lower()
        )
    if inherited_upc:
        upc = inherited_upc
    if inherited_mbid:
        mbid = inherited_mbid
    elif kind == "track":
        mbid = ""

    # Track artist may include features. Prefer embedded multi-artist tags on
    # album downloads; for single-track wishlist jobs use the Spotify string.
    if kind == "track":
        track_artist: str | list[str] = artist or primary
    else:
        track_artist = existing_artists if existing_artists else (artist or primary)
    action = f"{path} -> {dest} (albumartist={primary!r})"
    if dry_run:
        return action

    write_tags(
        path,
        title=new_title,
        artist=track_artist,
        album_artist=primary,
        album=new_album,
        trackno=trackno,
        upc=upc,
        mbid=mbid,
    )
    if path.resolve() != dest.resolve():
        dest = move_replace(path, dest, music_dir)
        write_tags(
            dest,
            title=new_title,
            artist=track_artist,
            album_artist=primary,
            album=new_album,
            trackno=trackno,
            upc=upc,
            mbid=mbid,
        )
    unify_album_folder(dest.parent, album_artist=primary, album=new_album, upc=upc, mbid=mbid)
    return action


def canonical_ids(files: list[Path], preferred_upc: str) -> tuple[str, str]:
    """Pick one UPC + MusicBrainz album id for the whole album batch."""
    upcs: Counter[str] = Counter()
    mbids: Counter[str] = Counter()
    for path in files:
        try:
            audio = MutagenFile(path, easy=True)
        except Exception:
            continue
        for key in ("upc", "barcode"):
            v = easy_get(audio, key)
            if v:
                upcs[v] += 1
        v = easy_get(audio, "musicbrainz_albumid")
        if v:
            mbids[v] += 1
    upc = preferred_upc.strip() if preferred_upc else ""
    if not upc and upcs:
        upc = upcs.most_common(1)[0][0]
    mbid = mbids.most_common(1)[0][0] if mbids else ""
    # If multiple MBIDs fight, drop them so Navidrome groups by albumartist+album+upc.
    if len(mbids) > 1:
        mbid = ""
    return upc, mbid


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--music-dir", required=True)
    ap.add_argument("--kind", choices=("track", "album", "playlist"), required=True)
    ap.add_argument("--title", default="")
    ap.add_argument("--artist", default="", help="Track artists; may include features")
    ap.add_argument("--album-artist", default="", help="Primary only — used for path + albumartist tag")
    ap.add_argument("--album", default="")
    ap.add_argument("--upc", default="", help="Album UPC/barcode shared across all tracks")
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
        since = args.since_epoch - 2.0
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

    if args.kind == "track" and not args.files_json and len(files) > 1:
        files = [max(files, key=lambda p: p.stat().st_mtime)]

    files.sort(key=lambda p: p.name.lower())
    upc, mbid = canonical_ids(files, args.upc)
    album_artist = args.album_artist or primary_artist(args.artist)
    # Single-track wishlist jobs must not keep provider MusicBrainz album IDs —
    # those differ per file and make Navidrome create a new album every time.
    if args.kind == "track":
        mbid = ""
    if args.kind == "playlist":
        # Mixed albums in one job — don't share one identity across files.
        upc, mbid, album_artist = "", "", ""

    results = []
    for i, path in enumerate(files, start=1):
        trackno = i if args.kind == "album" and len(files) > 1 else (1 if args.kind == "track" else None)
        # Prefer track number already in the filename ("02 - Title").
        m = re.match(r"^(\d+)\s*[-.]\s*", path.stem)
        if m:
            trackno = int(m.group(1))
        title = args.title if args.kind == "track" else ""
        album = args.album or (args.title if args.kind == "album" else "")
        results.append(
            process_file(
                path,
                music_dir=music_dir,
                kind=args.kind,
                title=title,
                artist=args.artist,
                album_artist=album_artist,
                album=album,
                trackno=trackno,
                upc=upc,
                mbid=mbid,
                dry_run=args.dry_run,
            )
        )

    print(json.dumps({"count": len(results), "albumArtist": album_artist, "upc": upc, "files": results}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
