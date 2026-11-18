# Guest Funnel via pre-transcoded MP3 Navidrome

Charlie keeps full FLAC on LAN/VPN (`:4533`). Guests on Tailscale Funnel hit an MP3-only Navidrome (`:4536`) built from `/srv/storage/Media/Music-Remote`.

| Audience | URL | Backend |
|----------|-----|---------|
| Charlie (LAN) | `http://192.168.8.193:4533` | FLAC library |
| Charlie (VPN) | `http://100.101.17.120:4533` | FLAC library |
| Guests (no VPN) | `https://cvh-elitemini-series.tail96490e.ts.net` | Funnel → `:4536` MP3 |
| Wishlist | `https://cvh-elitemini-series.tail96490e.ts.net:10000` | `drome-server:4534` |

## Build / refresh the mirror

```bash
cd /home/cvh/docker/Drome
./scripts/pretranscode-remote-library.py \
  --source /srv/storage/Media/Music \
  --dest /srv/storage/Media/Music-Remote
```

Nightly (example crontab):

```cron
15 3 * * * /usr/bin/python3 /home/cvh/docker/Drome/scripts/pretranscode-remote-library.py >> /home/cvh/docker/Drome/data/pretranscode.log 2>&1
```

## Run navidrome-remote

Compose lives in `/home/cvh/docker/navidrome/compose.yaml` (also mirrored at [`deploy/navidrome-remote.compose.yaml`](../deploy/navidrome-remote.compose.yaml)):

```bash
cd /home/cvh/docker/navidrome
docker compose up -d navidrome-remote
# First boot: open http://127.0.0.1:4536/app/ and create admin + guest users
# (separate DB from the FLAC instance — use the same usernames/passwords as :4533
# so guests do not need a second login in Drome).
```

## Point Funnel at MP3

```bash
tailscale funnel --bg --https=443 http://localhost:4536
tailscale funnel status
```

Wishlist Funnel stays on `:10000` → `4534`.

## Smoke test

```bash
curl -sf http://127.0.0.1:4536/app/ | head
curl -sf https://cvh-elitemini-series.tail96490e.ts.net/rest/ping.view?v=1.16.1&c=drome&f=json
# After login + play: navidrome-remote logs should show format=raw on mp3, not live FLAC transcode
docker logs navidrome-remote 2>&1 | tail -20
```
