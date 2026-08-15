#!/usr/bin/env python3
"""List every track in a Spotify playlist the same way SpotiFLAC's GUI does.

Uses Spotify's partner GraphQL (pathfinder) with 1000-track pages — not the
public Web API's 100-track cap or the embed scrape.

Usage: drome-list-playlist <spotify-playlist-url-or-id>
Prints JSON: {"name": "...", "tracks": [{"id","url","title","artist","albumArtist","album","cover"}]}
"""
from __future__ import annotations

import json
import sys

from SpotiFLAC.core.spotify_metadata import SpotifyMetadataClient


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: drome-list-playlist <spotify-playlist-url>", file=sys.stderr)
        return 2
    raw = sys.argv[1].strip()
    if raw and "://" not in raw and not raw.startswith("spotify:"):
        raw = "https://open.spotify.com/playlist/" + raw

    client = SpotifyMetadataClient(timeout_s=60)
    name, tracks, _cover, _info = client.get_url(raw)
    out = {
        "name": name or "Spotify playlist",
        "tracks": [
            {
                "id": t.id,
                "url": t.external_url or ("https://open.spotify.com/track/" + t.id),
                "title": t.title,
                "artist": t.artists,
                "albumArtist": t.album_artist,
                "album": t.album,
                "cover": t.cover_url,
            }
            for t in tracks
            if getattr(t, "id", "")
        ],
    }
    json.dump(out, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    print(f"listed {len(out['tracks'])} tracks from {out['name']!r}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
