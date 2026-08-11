#!/usr/bin/env python3
"""Clean up a Navidrome music library after bad SpotiFLAC downloads.

Finds / fixes:
  1. Files with garbage titles (Amazon ASINs, [hex] stubs, empty tags)
  2. Duplicate album folders (same primary artist + album, including guest
     folders like "Lil Wayne, JAY-Z/Tha Carter III")
  3. Inconsistent albumartist / UPC / MusicBrainz album id that split one
     album into many in Navidrome

Usage:
  python3 scripts/cleanup_library.py --music-dir /music
  python3 scripts/cleanup_library.py --music-dir /music --apply --merge-dupes --normalize-tags
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
from collections import Counter, defaultdict
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
FEAT_SPLIT = re.compile(
    r"\s+(?:feat\.?|ft\.?|featuring|with)\s+", re.IGNORECASE
)
# Spotify joins guest credits with ", " — folder names like "Drake, Wizkid, Kyla".
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


def easy_get_all(audio, key: str) -> list[str]:
    if audio is None or audio.tags is None:
        return []
    try:
        val = audio.get(key)
        if not val:
            return []
        return [str(v).strip() for v in val if str(v).strip()]
    except Exception:
        return []


def sanitize_path(name: str) -> str:
    name = (name or "").strip() or "Unknown"
    for ch in '<>:"/\\|?*':
        name = name.replace(ch, "_")
    return name.rstrip(" .")[:180] or "Unknown"


def is_guest_join(name: str) -> bool:
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
    """Primary only. Strip feat. credits; peel Spotify guest joins; keep
    band names with internal commas ('Earth, Wind & Fire')."""
    s = (name or "").strip()
    if not s:
        return "Unknown Artist"
    parts = FEAT_SPLIT.split(s, maxsplit=1)
    s = parts[0].strip()
    if is_guest_join(s):
        return GUEST_JOIN.split(s, maxsplit=1)[0].strip() or s
    return s


def normalize_album_name(album: str) -> str:
    a = YEAR_SUFFIX.sub("", album or "").strip().lower()
    return re.sub(r"\s+", " ", a)


def normalize_album_key(artist: str, album: str) -> str:
    return f"{primary_artist(artist).strip().lower()}|{normalize_album_name(album)}"


def title_key(path: Path) -> str:
    stem = path.stem
    m = re.match(r"^\d+\s*[-.]\s*(.+)$", stem)
    return (m.group(1) if m else stem).strip().lower()


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
        artist = easy_get(audio, "artist") or (
            path.parents[1].name if len(path.parents) > 1 else ""
        )
        album = easy_get(audio, "album") or (
            path.parent.name if path.parent != music_dir else ""
        )
        albumartist = easy_get(audio, "albumartist") or artist
        folder_artist = path.parents[1].name if len(path.parents) > 1 else ""
        # Trust exact folder↔albumartist matches (keeps "Black Country, New Road").
        if albumartist and folder_artist and albumartist == folder_artist:
            primary = albumartist
        elif albumartist and not is_guest_join(albumartist):
            primary = albumartist
        else:
            primary = primary_artist(albumartist or folder_artist or artist)

        rec = {
            "path": str(path),
            "title": title,
            "artist": artist,
            "album": album,
            "albumartist": albumartist,
            "primary": primary,
            "upc": easy_get(audio, "upc") or easy_get(audio, "barcode"),
            "mbid": easy_get(audio, "musicbrainz_albumid"),
            "albumartistsort": easy_get(audio, "albumartistsort"),
            "folder": str(path.parent),
            "size": path.stat().st_size,
            "mtime": path.stat().st_mtime,
        }
        if looks_garbage(title) or looks_garbage(album) or looks_garbage(artist):
            bad.append(rec)

        key = normalize_album_key(primary, album)
        if key != "|":
            albums[key].append(rec)

    dupes = []
    inconsistent = []
    for key, tracks in albums.items():
        folders = sorted({t["folder"] for t in tracks})
        aas = sorted({t["albumartist"] for t in tracks if t["albumartist"]})
        upcs = sorted({t["upc"] for t in tracks if t["upc"]})
        mbids = sorted({t["mbid"] for t in tracks if t["mbid"]})
        if len(folders) > 1:
            dupes.append({
                "key": key,
                "folders": folders,
                "track_count": len(tracks),
                "tracks": tracks,
            })
        elif len(aas) > 1 or len(upcs) > 1 or len(mbids) > 1 or any(
            (t["albumartistsort"] or "").lower() in {"various artists", "various"}
            for t in tracks
        ):
            inconsistent.append({
                "key": key,
                "folders": folders,
                "albumartists": aas,
                "upcs": upcs,
                "mbids": mbids,
                "track_count": len(tracks),
                "tracks": tracks,
            })
    return bad, dupes, inconsistent


def write_album_tags(path: Path, *, album_artist: str, album: str, upc: str, mbid: str) -> None:
    audio = MutagenFile(path, easy=True)
    if audio is None:
        return
    if album_artist:
        try:
            audio["albumartist"] = [album_artist]
        except Exception:
            pass
        try:
            sort_val = easy_get(audio, "albumartistsort")
            if not sort_val or sort_val.lower() in {"various artists", "various"}:
                audio["albumartistsort"] = [album_artist]
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
    if mbid:
        try:
            audio["musicbrainz_albumid"] = [mbid]
        except Exception:
            pass
    else:
        try:
            if "musicbrainz_albumid" in audio:
                del audio["musicbrainz_albumid"]
        except Exception:
            pass
    audio.save()


def canonical_album_fields(tracks: list[dict]) -> tuple[str, str, str, str]:
    """primary, album display name, upc, mbid for a group."""
    primaries = Counter(t["primary"] for t in tracks if t["primary"])
    primary = primaries.most_common(1)[0][0] if primaries else "Unknown Artist"
    # Prefer an albumartist that already equals primary.
    for t in tracks:
        if t["albumartist"] and primary_artist(t["albumartist"]) == primary and "," not in t["albumartist"]:
            primary = t["albumartist"]
            break
    albums = Counter(t["album"] for t in tracks if t["album"] and not looks_garbage(t["album"]))
    album = albums.most_common(1)[0][0] if albums else (tracks[0]["album"] if tracks else "Unknown Album")
    upcs = Counter(t["upc"] for t in tracks if t["upc"])
    upc = upcs.most_common(1)[0][0] if upcs else ""
    mbids = Counter(t["mbid"] for t in tracks if t["mbid"])
    mbid = mbids.most_common(1)[0][0] if len(mbids) == 1 else ""
    return primary, album, upc, mbid


def merge_dupe_group(group: dict, music_dir: Path, apply: bool, normalize: bool) -> list[str]:
    """Merge into {primary}/{album}/ and optionally normalize tags."""
    actions = []
    tracks = group["tracks"]
    primary, album, upc, mbid = canonical_album_fields(tracks)
    keep_path = music_dir / sanitize_path(primary) / sanitize_path(album)

    by_folder: dict[str, list[dict]] = defaultdict(list)
    for t in tracks:
        by_folder[t["folder"]].append(t)

    def folder_score(folder: str):
        ts = by_folder[folder]
        # Prefer the canonical primary/album path, then most tracks, then newest.
        is_canonical = 1 if Path(folder) == keep_path else 0
        return (
            is_canonical,
            len(ts),
            max(t["mtime"] for t in ts),
            -sum(1 for t in ts if looks_garbage(t["title"])),
        )

    # Ensure keep dir exists when applying.
    if apply:
        keep_path.mkdir(parents=True, exist_ok=True)

    seen_titles: dict[str, Path] = {}
    for folder in sorted(by_folder.keys(), key=folder_score, reverse=True):
        for t in by_folder[folder]:
            src = Path(t["path"])
            if not src.exists():
                continue
            dest = keep_path / src.name
            key = title_key(src)
            if key in seen_titles and seen_titles[key].exists():
                existing = seen_titles[key]
                if existing.stat().st_size >= src.stat().st_size:
                    actions.append(f"DROP duplicate {src} (keeping {existing})")
                    if apply:
                        src.unlink(missing_ok=True)
                    continue
                actions.append(f"REPLACE {existing} with {src}")
                if apply:
                    existing.unlink(missing_ok=True)
                    dest = keep_path / src.name
            if dest.exists() and dest.resolve() != src.resolve():
                if title_key(dest) == key:
                    actions.append(f"REPLACE {dest} with {src}")
                    if apply:
                        dest.unlink(missing_ok=True)
                else:
                    stem, ext = src.stem, src.suffix
                    n = 2
                    while dest.exists():
                        dest = keep_path / f"{stem} ({n}){ext}"
                        n += 1
            if src.resolve() != dest.resolve():
                actions.append(f"MOVE {src} -> {dest}")
                if apply:
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    shutil.move(str(src), str(dest))
                seen_titles[key] = dest
            else:
                seen_titles[key] = src if not apply else dest

            final = dest if apply else src
            if normalize:
                actions.append(
                    f"TAG  {final} albumartist={primary!r} album={album!r} upc={upc!r}"
                )
                if apply and final.exists():
                    write_album_tags(
                        final, album_artist=primary, album=album, upc=upc, mbid=mbid
                    )

        folder_path = Path(folder)
        if apply and folder_path != keep_path:
            for parent in [folder_path, *folder_path.parents]:
                if parent == music_dir or not str(parent).startswith(str(music_dir)):
                    break
                try:
                    parent.rmdir()
                except OSError:
                    break
    return actions


def normalize_group(group: dict, apply: bool) -> list[str]:
    """Retag a single-folder album that has inconsistent albumartist/upc/mbid."""
    actions = []
    primary, album, upc, mbid = canonical_album_fields(group["tracks"])
    for t in group["tracks"]:
        path = Path(t["path"])
        needs = (
            primary_artist(t["albumartist"] or "") != primary_artist(primary)
            or t["albumartist"] != primary
            or (upc and t["upc"] != upc)
            or (len({x["mbid"] for x in group["tracks"] if x["mbid"]}) > 1)
            or (t["albumartistsort"] or "").lower() in {"various artists", "various"}
        )
        if not needs:
            continue
        actions.append(f"TAG  {path} albumartist={primary!r} upc={upc!r}")
        if apply and path.exists():
            write_album_tags(path, album_artist=primary, album=album, upc=upc, mbid=mbid)
    return actions


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--music-dir", required=True)
    ap.add_argument("--apply", action="store_true", help="Perform changes (default is dry-run)")
    ap.add_argument("--merge-dupes", action="store_true", help="Merge duplicate album folders")
    ap.add_argument(
        "--normalize-tags",
        action="store_true",
        help="Unify albumartist/UPC/MBID (and clear Various Artists sort) per album",
    )
    ap.add_argument("--report", default="", help="Write JSON report path")
    ap.add_argument("--quiet", action="store_true", help="One-line summary (for scheduled runs)")
    args = ap.parse_args()

    music_dir = Path(args.music_dir)
    if not music_dir.is_dir():
        print(f"missing music dir: {music_dir}", file=sys.stderr)
        return 2

    # Scheduled drome-server cleanup enables merge by default — also normalize.
    if args.merge_dupes and args.apply and not args.normalize_tags:
        args.normalize_tags = True

    bad, dupes, inconsistent = scan(music_dir)
    report = {
        "bad_metadata_count": len(bad),
        "duplicate_album_groups": len(dupes),
        "inconsistent_tag_groups": len(inconsistent),
        "bad_metadata": bad[:200],
        "duplicates": [
            {"key": d["key"], "folders": d["folders"], "track_count": d["track_count"]}
            for d in dupes
        ],
        "inconsistent": [
            {
                "key": g["key"],
                "albumartists": g["albumartists"],
                "upcs": g["upcs"],
                "mbids": g["mbids"],
                "track_count": g["track_count"],
            }
            for g in inconsistent
        ],
    }

    actions: list[str] = []
    if args.merge_dupes:
        for d in dupes:
            actions.extend(
                merge_dupe_group(
                    d, music_dir, apply=args.apply, normalize=args.normalize_tags
                )
            )
    if args.normalize_tags:
        for g in inconsistent:
            actions.extend(normalize_group(g, apply=args.apply))

    if args.report:
        Path(args.report).write_text(json.dumps(report, indent=2))

    if args.quiet:
        mode = "apply" if args.apply else "report"
        print(
            f"mode={mode} bad_tags={len(bad)} duplicate_albums={len(dupes)} "
            f"inconsistent_albums={len(inconsistent)} actions={len(actions)}"
        )
        return 0

    print(f"Bad metadata files: {len(bad)}")
    for rec in bad[:40]:
        print(f"  BAD  {rec['path']}")
        print(
            f"       title={rec['title']!r} artist={rec['artist']!r} album={rec['album']!r}"
        )
    if len(bad) > 40:
        print(f"  … {len(bad) - 40} more")

    print(f"\nDuplicate album groups: {len(dupes)}")
    for d in dupes:
        print(f"  DUPE {d['key']}")
        for folder in d["folders"]:
            print(f"       {folder}")

    print(f"\nInconsistent tag groups: {len(inconsistent)}")
    for g in inconsistent[:30]:
        print(
            f"  TAGS {g['key']} AAs={g['albumartists'][:4]} UPCs={g['upcs'][:3]} MBIDs={len(g['mbids'])}"
        )

    if actions:
        print(f"\nActions ({'APPLY' if args.apply else 'dry-run'}): {len(actions)}")
        for a in actions[:100]:
            print(f"  {a}")
        if len(actions) > 100:
            print(f"  … {len(actions) - 100} more")

    if args.report:
        print(f"\nWrote report → {args.report}")
    if not args.apply:
        print("Dry-run only. Pass --apply --merge-dupes --normalize-tags to fix.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
