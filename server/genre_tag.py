#!/usr/bin/env python3
"""Assign a single curated GENRE tag from public metadata databases.

Sources (in order):
  1. Discogs release genres/styles for the artist  (primary — free, no key)
  2. MusicBrainz artist genres/tags               (fallback — free, rate-limited)

Results are cached under --cache-dir (default: $DROME_DB_PATH sibling /
/data/genre_cache.sqlite) so library backfills and per-download calls stay
cheap. Writes one GENRE value onto each audio file (replacing provider junk
like "Films/Games; Film Scores").
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from pathlib import Path

from mutagen import File as MutagenFile

AUDIO_EXTS = {".flac", ".m4a", ".mp3", ".ogg", ".opus", ".wav", ".aiff"}
USER_AGENT = "DromeGenreTagger/1.0 (https://github.com/Charmander542/Drome)"

# Curated set — keep in sync with server/genre.go.
GENRE_ALIASES: dict[str, str] = {
    "rock": "Rock",
    "classic rock": "Rock",
    "hard rock": "Rock",
    "soft rock": "Rock",
    "progressive rock": "Rock",
    "prog rock": "Rock",
    "prog": "Rock",
    "psychedelic rock": "Rock",
    "psych rock": "Rock",
    "grunge": "Rock",
    "post rock": "Rock",
    "garage rock": "Rock",
    "blues rock": "Rock",
    "album rock": "Rock",
    "pop rock": "Rock",
    "rock and roll": "Rock",
    "rock & roll": "Rock",
    "pop": "Pop",
    "synth pop": "Pop",
    "synthpop": "Pop",
    "electropop": "Pop",
    "k pop": "Pop",
    "kpop": "Pop",
    "dance pop": "Pop",
    "britpop": "Pop",
    "art pop": "Pop",
    "chamber pop": "Pop",
    "indie pop": "Indie",
    "hip hop": "Hip-Hop",
    "hiphop": "Hip-Hop",
    "rap": "Hip-Hop",
    "trap": "Hip-Hop",
    "gangsta rap": "Hip-Hop",
    "hip hop rap": "Hip-Hop",
    "r and b": "R&B",
    "rnb": "R&B",
    "neo soul": "R&B",
    "rhythm and blues": "R&B",
    "soul": "Soul",
    "electronic": "Electronic",
    "edm": "Electronic",
    "electronica": "Electronic",
    "idm": "Electronic",
    "downtempo": "Electronic",
    "synthwave": "Electronic",
    "new wave": "Electronic",
    "dance": "Dance",
    "house": "Dance",
    "techno": "Dance",
    "trance": "Dance",
    "disco": "Dance",
    "drum and bass": "Dance",
    "dubstep": "Dance",
    "jazz": "Jazz",
    "smooth jazz": "Jazz",
    "acid jazz": "Jazz",
    "classical": "Classical",
    "orchestral": "Classical",
    "soundtrack": "Soundtrack",
    "ost": "Soundtrack",
    "score": "Soundtrack",
    "film scores": "Soundtrack",
    "films games": "Soundtrack",
    "stage and screen": "Musical",
    "musical": "Musical",
    "broadway": "Musical",
    "show tunes": "Musical",
    "musical theatre": "Musical",
    "musical theater": "Musical",
    "metal": "Metal",
    "heavy metal": "Metal",
    "death metal": "Metal",
    "black metal": "Metal",
    "punk": "Punk",
    "pop punk": "Punk",
    "emo": "Punk",
    "folk": "Folk",
    "singer songwriter": "Folk",
    "americana": "Folk",
    "folk rock": "Folk",
    # Deliberately do NOT map bare "Acoustic" — Discogs attaches it broadly.
    "country": "Country",
    "indie": "Indie",
    "indie rock": "Indie",
    "lo fi": "Indie",
    "lofi": "Indie",
    "dream pop": "Indie",
    "noise": "Indie",
    "alternative": "Alternative",
    "alt rock": "Alternative",
    "alternative rock": "Alternative",
    "shoegaze": "Alternative",
    "funk": "Funk",
    "blues": "Blues",
    "reggae": "Reggae",
    "ska": "Reggae",
    "latin": "Latin",
    "world": "World",
    "ambient": "Ambient",
    "chillout": "Ambient",
    "new age": "Ambient",
    "experimental": "Experimental",
    "acoustic": "Folk",
}

# Priority when multiple curated genres are candidates (more specific first).
GENRE_PRIORITY = [
    "Musical",
    "Classical",
    "Jazz",
    "Hip-Hop",
    "Metal",
    "Punk",
    "Reggae",
    "Blues",
    "Soul",
    "Funk",
    "Country",
    "Indie",
    "Alternative",
    "Electronic",
    "Dance",
    "Rock",
    "Pop",
    "Folk",
    "Soundtrack",
    "Latin",
    "World",
    "Ambient",
    "Experimental",
]


def genre_key(raw: str) -> str:
    raw = (raw or "").lower().strip()
    out: list[str] = []
    pending_space = False
    for ch in raw:
        if ch.isalnum():
            if pending_space and out:
                out.append(" ")
            pending_space = False
            out.append(ch)
        elif ch == "&":
            # Collapse any pending whitespace into a single separator before "and".
            pending_space = False
            if out:
                out.append(" ")
            out.append("and")
            pending_space = True
        else:
            pending_space = True
    return "".join(out).strip()


# Self-mappings for curated names.
for _name in GENRE_PRIORITY:
    GENRE_ALIASES[genre_key(_name)] = _name


def normalize_genre(raw: str) -> str:
    key = genre_key(raw)
    if not key:
        return ""
    return GENRE_ALIASES.get(key, "")


def pick_curated(candidates: list[str]) -> str:
    """Pick a curated genre. Prefer higher frequency, then GENRE_PRIORITY."""
    counts: Counter[str] = Counter()
    for c in candidates:
        g = normalize_genre(c)
        if g:
            counts[g] += 1
    if not counts:
        return ""
    priority = {name: i for i, name in enumerate(GENRE_PRIORITY)}

    def sort_key(item: tuple[str, int]) -> tuple[int, int]:
        name, count = item
        return (-count, priority.get(name, 999))

    return sorted(counts.items(), key=sort_key)[0][0]


def normalize_artist(name: str) -> str:
    s = (name or "").strip()
    s = re.split(r"\s+(?:feat\.?|ft\.?|featuring|with)\s+", s, maxsplit=1, flags=re.I)[0]
    s = re.sub(r"\s+", " ", s).strip()
    return s


class GenreCache:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(str(path))
        self.conn.execute(
            """
            CREATE TABLE IF NOT EXISTS artist_genre (
              artist_key TEXT PRIMARY KEY,
              genre TEXT NOT NULL,
              source TEXT NOT NULL DEFAULT '',
              raw_json TEXT NOT NULL DEFAULT '',
              updated_at REAL NOT NULL
            )
            """
        )
        self.conn.commit()

    def get(self, artist_key: str) -> tuple[str, str] | None:
        row = self.conn.execute(
            "SELECT genre, source FROM artist_genre WHERE artist_key = ?",
            (artist_key,),
        ).fetchone()
        if not row:
            return None
        return row[0], row[1]

    def set(self, artist_key: str, genre: str, source: str, raw: dict) -> None:
        self.conn.execute(
            """
            INSERT INTO artist_genre (artist_key, genre, source, raw_json, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(artist_key) DO UPDATE SET
              genre=excluded.genre, source=excluded.source,
              raw_json=excluded.raw_json, updated_at=excluded.updated_at
            """,
            (artist_key, genre, source, json.dumps(raw, ensure_ascii=False), time.time()),
        )
        self.conn.commit()


class RateLimitedClient:
    def __init__(self, min_interval: float):
        self.min_interval = min_interval
        self._last = 0.0

    def wait(self) -> None:
        now = time.monotonic()
        delay = self.min_interval - (now - self._last)
        if delay > 0:
            time.sleep(delay)
        self._last = time.monotonic()

    def get_json(self, url: str, headers: dict[str, str], retries: int = 4) -> dict | list | None:
        last_err: Exception | None = None
        for attempt in range(retries):
            self.wait()
            req = urllib.request.Request(url, headers=headers)
            try:
                with urllib.request.urlopen(req, timeout=30) as resp:
                    return json.load(resp)
            except urllib.error.HTTPError as e:
                last_err = e
                if e.code in (429, 503, 502):
                    time.sleep(1.5 * (attempt + 1))
                    continue
                if e.code == 404:
                    return None
                raise
            except Exception as e:  # noqa: BLE001
                last_err = e
                time.sleep(1.0 * (attempt + 1))
        if last_err:
            print(f"warn: GET {url}: {last_err}", file=sys.stderr)
        return None


def discogs_lookup(artist: str, client: RateLimitedClient) -> tuple[str, dict] | None:
    headers = {"User-Agent": USER_AGENT, "Accept": "application/json"}
    q = urllib.parse.urlencode({"artist": artist, "type": "release", "per_page": "15"})
    data = client.get_json(f"https://api.discogs.com/database/search?{q}", headers)
    if not isinstance(data, dict):
        return None
    results = data.get("results") or []
    if not results:
        # broader query
        q = urllib.parse.urlencode({"q": artist, "type": "release", "per_page": "15"})
        data = client.get_json(f"https://api.discogs.com/database/search?{q}", headers)
        if not isinstance(data, dict):
            return None
        results = data.get("results") or []
    genres: list[str] = []
    styles: list[str] = []
    for rel in results:
        # Prefer releases whose artist credit roughly matches.
        title = (rel.get("title") or "").lower()
        if artist.lower() not in title and not any(
            tok in title for tok in artist.lower().split() if len(tok) > 3
        ):
            # still collect but lower weight later by putting at end
            pass
        for g in rel.get("genre") or []:
            genres.append(g)
        for s in rel.get("style") or []:
            styles.append(s)
    if not genres and not styles:
        return None
    # Prefer styles (more specific), then genres. Weight by frequency.
    style_counts = Counter(styles)
    genre_counts = Counter(genres)
    ordered = [s for s, _ in style_counts.most_common()] + [
        g for g, _ in genre_counts.most_common()
    ]
    curated = pick_curated(ordered)
    if not curated:
        return None
    return curated, {"genres": genre_counts, "styles": style_counts, "source": "discogs"}


def musicbrainz_lookup(artist: str, client: RateLimitedClient) -> tuple[str, dict] | None:
    headers = {"User-Agent": USER_AGENT, "Accept": "application/json"}
    q = urllib.parse.quote(f'artist:"{artist}"')
    data = client.get_json(
        f"https://musicbrainz.org/ws/2/artist/?query={q}&fmt=json", headers
    )
    if not isinstance(data, dict) or not data.get("artists"):
        q = urllib.parse.quote(artist)
        data = client.get_json(
            f"https://musicbrainz.org/ws/2/artist/?query={q}&fmt=json", headers
        )
    if not isinstance(data, dict) or not data.get("artists"):
        return None
    aid = data["artists"][0]["id"]
    detail = client.get_json(
        f"https://musicbrainz.org/ws/2/artist/{aid}?inc=genres+tags&fmt=json",
        headers,
    )
    if not isinstance(detail, dict):
        return None
    genres = sorted(
        detail.get("genres") or [], key=lambda g: -int(g.get("count") or 0)
    )
    tags = sorted(detail.get("tags") or [], key=lambda t: -int(t.get("count") or 0))
    ordered = [g.get("name", "") for g in genres] + [t.get("name", "") for t in tags]
    curated = pick_curated(ordered)
    if not curated:
        return None
    return curated, {
        "genres": [(g.get("name"), g.get("count")) for g in genres[:12]],
        "tags": [(t.get("name"), t.get("count")) for t in tags[:12]],
        "source": "musicbrainz",
        "mbid": aid,
    }


def deezer_lookup(artist: str, client: RateLimitedClient) -> tuple[str, dict] | None:
    """Fast fallback. Filters known junk labels unless they map to Musical."""
    headers = {"User-Agent": USER_AGENT}
    q = urllib.parse.urlencode({"q": artist, "limit": "1"})
    data = client.get_json(f"https://api.deezer.com/search/artist?{q}", headers)
    if not isinstance(data, dict) or not data.get("data"):
        return None
    aid = data["data"][0]["id"]
    albums = client.get_json(
        f"https://api.deezer.com/artist/{aid}/albums?limit=5", headers
    )
    if not isinstance(albums, dict):
        return None
    names: list[str] = []
    for al in albums.get("data") or []:
        ad = client.get_json(f"https://api.deezer.com/album/{al['id']}", headers)
        if not isinstance(ad, dict):
            continue
        for g in (ad.get("genres") or {}).get("data") or []:
            name = g.get("name") or ""
            if name.lower() in {"films/games", "film scores"} and "musical" not in name.lower():
                continue
            names.append(name)
    curated = pick_curated(names)
    if not curated:
        return None
    return curated, {"genres": names, "source": "deezer"}


def lookup_genre(
    artist: str,
    cache: GenreCache,
    discogs: RateLimitedClient,
    musicbrainz: RateLimitedClient,
    deezer: RateLimitedClient,
    force: bool = False,
) -> tuple[str, str]:
    artist = normalize_artist(artist)
    if not artist or artist.lower() in {"various artists", "various", "unknown artist", "unknown"}:
        return "", "skipped"
    key = genre_key(artist)
    if not force:
        hit = cache.get(key)
        if hit is not None:
            return hit[0], hit[1] + "+cache"

    for name, fn, client in (
        ("discogs", discogs_lookup, discogs),
        ("musicbrainz", musicbrainz_lookup, musicbrainz),
        ("deezer", deezer_lookup, deezer),
    ):
        try:
            result = fn(artist, client)
        except Exception as e:  # noqa: BLE001
            print(f"warn: {name} lookup {artist!r}: {e}", file=sys.stderr)
            continue
        if result:
            genre, raw = result
            cache.set(key, genre, name, raw)
            return genre, name
    cache.set(key, "", "none", {})
    return "", "none"


def read_tags(path: Path) -> tuple[str, str, str]:
    audio = MutagenFile(path, easy=True)
    if audio is None:
        return "", "", ""
    def first(key: str) -> str:
        v = audio.get(key)
        if isinstance(v, list) and v:
            return str(v[0])
        return str(v) if v else ""
    return first("albumartist") or first("artist"), first("artist"), first("genre")


def write_genre(path: Path, genre: str) -> bool:
    audio = MutagenFile(path, easy=True)
    if audio is None:
        return False
    try:
        audio["genre"] = [genre]
        audio.save()
        return True
    except Exception as e:  # noqa: BLE001
        print(f"warn: write {path}: {e}", file=sys.stderr)
        return False


def iter_audio(music_dir: Path, since_epoch: float | None = None):
    for path in music_dir.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in AUDIO_EXTS:
            continue
        if "Playlists" in path.parts:
            continue
        if since_epoch is not None and path.stat().st_mtime < since_epoch:
            continue
        yield path


def resolve_artist(path: Path, music_dir: Path) -> str:
    aa, ar, _ = read_tags(path)
    aa_n = normalize_artist(aa)
    ar_n = normalize_artist(ar)
    if aa_n and aa_n.lower() not in {"various artists", "various", "soundtrack", "compilation"}:
        return aa_n
    if ar_n:
        return ar_n.split(",")[0].strip()
    try:
        rel = path.relative_to(music_dir)
        if len(rel.parts) >= 2:
            return rel.parts[0]
    except ValueError:
        pass
    return aa_n or ar_n


def process_files(
    paths: list[Path],
    music_dir: Path,
    cache: GenreCache,
    force: bool,
    dry_run: bool,
) -> tuple[int, int, int]:
    discogs = RateLimitedClient(1.05)
    musicbrainz = RateLimitedClient(1.15)
    deezer = RateLimitedClient(0.35)
    wrote = skipped = failed = 0
    for path in paths:
        artist = resolve_artist(path, music_dir)
        if not artist:
            skipped += 1
            continue
        _, _, current = read_tags(path)
        genre, source = lookup_genre(
            artist, cache, discogs, musicbrainz, deezer, force=force
        )
        if not genre:
            skipped += 1
            continue
        # Skip rewrite when the file already maps to the curated genre.
        if not force and (current == genre or normalize_genre(current) == genre):
            skipped += 1
            continue
        if dry_run:
            print(f"DRY {path}: {current!r} -> {genre!r} ({source}, artist={artist})")
            wrote += 1
            continue
        if write_genre(path, genre):
            wrote += 1
            print(f"OK  {path.name}: {current!r} -> {genre!r} [{source}] ({artist})")
        else:
            failed += 1
    return wrote, skipped, failed


def default_cache_path() -> Path:
    db = os.environ.get("DROME_DB_PATH", "")
    if db:
        return Path(db).resolve().parent / "genre_cache.sqlite"
    return Path(os.environ.get("HOME", "/tmp")) / ".drome" / "genre_cache.sqlite"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--music-dir", default=os.environ.get("DROME_MUSIC_DIR", "/music"))
    ap.add_argument("--cache-dir", default="", help="Directory or sqlite file for genre cache")
    ap.add_argument("--artist", default="", help="Lookup/tag for one artist name")
    ap.add_argument("--path", action="append", default=[], help="Audio file to tag (repeatable)")
    ap.add_argument("--all", action="store_true", help="Backfill every audio file under music-dir")
    ap.add_argument("--since-epoch", type=float, default=0, help="Only files mtime >= epoch")
    ap.add_argument("--force", action="store_true", help="Re-query and overwrite existing genres")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--lookup-only", action="store_true", help="Print genre for --artist and exit")
    args = ap.parse_args(argv)

    music_dir = Path(args.music_dir)
    cache_path = Path(args.cache_dir) if args.cache_dir else default_cache_path()
    if cache_path.suffix != ".sqlite":
        cache_path = cache_path / "genre_cache.sqlite"
    cache = GenreCache(cache_path)

    if args.lookup_only or (args.artist and not args.path and not args.all and args.since_epoch <= 0):
        if not args.artist:
            print("need --artist", file=sys.stderr)
            return 2
        discogs = RateLimitedClient(1.05)
        musicbrainz = RateLimitedClient(1.15)
        deezer = RateLimitedClient(0.35)
        genre, source = lookup_genre(
            args.artist, cache, discogs, musicbrainz, deezer, force=args.force
        )
        print(json.dumps({"artist": args.artist, "genre": genre, "source": source}))
        return 0 if genre else 1

    paths: list[Path] = []
    if args.path:
        paths = [Path(p) for p in args.path]
    elif args.all or args.since_epoch > 0:
        since = args.since_epoch if args.since_epoch > 0 else None
        paths = list(iter_audio(music_dir, since))
        if args.artist:
            want = genre_key(normalize_artist(args.artist))
            paths = [p for p in paths if genre_key(resolve_artist(p, music_dir)) == want]
    elif args.artist:
        # Tag every file under music-dir whose resolved artist matches.
        want = genre_key(normalize_artist(args.artist))
        for p in iter_audio(music_dir):
            if genre_key(resolve_artist(p, music_dir)) == want:
                paths.append(p)
    else:
        ap.print_help()
        return 2

    wrote, skipped, failed = process_files(
        paths, music_dir, cache, force=args.force, dry_run=args.dry_run
    )
    print(f"done wrote={wrote} skipped={skipped} failed={failed} files={len(paths)}")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
