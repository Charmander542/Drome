# Drome

A native iOS streaming client for a self-hosted Navidrome server, plus a Go
companion backend for the wishlist.

## Companion server

The iOS app can paste Spotify track/album links into **Library → Wishlist**.
The companion:

1. Resolves metadata from Spotify's public page / oEmbed (no API key required)
2. Queues a SpotiFLAC download into your Navidrome music library (`Artist/Album/NN - Title.flac`)
3. Marks the entry acquired (Navidrome picks it up on the next scheduled scan)

### Deploy next to an existing Navidrome

```bash
cd /path/to/Drome
cp .env.example .env   # credentials optional
docker compose up -d --build
```

App wishlist URL (on this LAN): `http://192.168.8.193:4534`

Health check: `curl http://127.0.0.1:4534/health`

### Environment

| Variable | Purpose |
|---|---|
| `DROME_NAVIDROME_URL` | Where this container reaches Navidrome (default `http://navidrome:4533`) |
| `DROME_SPOTIFY_CLIENT_ID` / `SECRET` | Optional; richer Web API metadata if set |
| `DROME_MUSIC_DIR` | Shared library mount (default `/music`) |
| `DROME_AUTO_DOWNLOAD` | Queue SpotiFLAC on every wishlist add (`true`/`false`) |
| `DROME_SPOTIFLAC_SERVICES` | Provider priority, comma-separated |
| `DROME_NAVIDROME_SCAN_USER` / `PASSWORD` | Optional; triggers immediate library scan |

Auth reuses Subsonic `u` / `t` / `s` query params — same credentials as Navidrome login.
