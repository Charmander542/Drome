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

Connect (multi-device) uses the **same** companion on `:4534`. After pulling
Connect changes, rebuild so `/connect/devices` exists:

```bash
docker compose up -d --build
curl -s -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:4534/connect/devices"
# expect 401 (auth required), not 404
```

Both iPhone and Apple TV need the companion URL set (Settings → Wishlist companion /
pairing). Same Navidrome login on each device.

### Environment

| Variable | Purpose |
|---|---|
| `DROME_NAVIDROME_URL` | Where this container reaches Navidrome (default `http://navidrome:4533`) |
| `DROME_SPOTIFY_CLIENT_ID` / `SECRET` | Required for in-app Spotify search; also improves link metadata |
| `DROME_SPOTIFY_MARKET` | ISO country for Search (default `US`; needed with client-credentials) |
| `DROME_MUSIC_DIR` | Shared library mount (default `/music`) |
| `DROME_AUTO_DOWNLOAD` | Queue SpotiFLAC on every wishlist add (`true`/`false`) |
| `DROME_SPOTIFLAC_SERVICES` | Provider priority, comma-separated |
| `DROME_NAVIDROME_SCAN_USER` / `PASSWORD` | Optional; triggers immediate library scan |

Auth reuses Subsonic `u` / `t` / `s` query params — same credentials as Navidrome login.
