# Drome Connect API

Spotify-style multi-device control for any Drome client (iOS, tvOS, web, desktop).
Auth is the same as wishlist: Subsonic `u` / `t` / `s` verified against Navidrome.

Base URL: companion server (e.g. `http://host:4534`).

## Concepts

- **Device** — a running client with a stable `id` (UUID in local storage).
- **Active device** — the one that should output audio.
- **Session** — opaque JSON snapshot of queue + playhead (iOS uses `PlaybackSessionSnapshot`).
- **Command** — transfer / transport directed at a `targetDeviceId`.

## Endpoints

| Method | Path | Notes |
|--------|------|--------|
| `PUT` | `/connect/devices/{id}` | Heartbeat + presence |
| `GET` | `/connect/devices` | Online devices for this user |
| `DELETE` | `/connect/devices/{id}` | Leave |
| `PUT` | `/connect/session` | Active player publishes session |
| `GET` | `/connect/session` | Latest session |
| `POST` | `/connect/commands` | Enqueue command |
| `GET` | `/connect/commands?deviceId=&after=` | Pending commands for this device |
| `POST` | `/connect/commands/ack` | `{ "ids": ["…"] }` mark consumed |
| `GET` | `/connect/events?deviceId=` | SSE stream (`event: connect`) |

## Platform values

Prefer: `ios` | `tvos` | `web` | `desktop` | `android` | `other`  
Unknown short strings are accepted so new clients do not need a server update.

## Capabilities

Optional string array on devices, e.g. `["audio","remote","transfer"]`.

## Command types

`transfer` · `takeControl` · `play` · `pause` · `next` · `previous` · `seek`

`transfer` / `takeControl` set `activeDeviceId` to the target.

## Client loop (any platform)

1. Generate stable device id once.
2. Heartbeat `PUT /connect/devices/{id}` every ~15s while foregrounded.
3. If this device is active: publish `PUT /connect/session` on track/queue changes.
4. Poll commands or listen to SSE; apply + ack.
5. UI lists `GET /connect/devices`; tap another device → publish session → `POST` `transfer`.

Devices vanish ~45s after the last heartbeat.

## Ops notes

Authenticated Connect/wishlist calls need a healthy SQLite connection. The
companion uses `MaxOpenConns(1)` — never nest a second query while a `Rows`
cursor is still open (that deadlocks the process until restart).

Rebuild after pulling Connect fixes:

```bash
docker compose up -d --build
```
