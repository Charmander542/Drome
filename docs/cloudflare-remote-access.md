# Cloudflare remote access (no Tailscale for guests)

Agent-ready plan to expose Charlie’s home Navidrome + Drome companion over HTTPS so friends can use Drome without joining Tailscale.

## Goal

| Audience | How they connect |
|----------|------------------|
| Charlie (admin) | Keep Tailscale / LAN as today (`192.168.8.193`) |
| Guests | Public HTTPS hostname only — install Drome, log into Navidrome |

No app code changes are required for basic streaming. Guests set **Server URL** to the public music hostname. Non-LAN hosts already enable **resilient remote streaming** (MP3 + disk cache) in `PlaybackPreferences.isLocalNetworkHost`.

## Current architecture (do not break)

```
Home LAN
├── Docker network: navidrome_default (external)
│   ├── navidrome          :4533   ← Subsonic / streaming (source of truth)
│   └── drome-server       :4534   ← wishlist, Connect, SpotiFLAC, mixes
│         volume: /srv/storage/Media/Music
└── Charlie’s phone / TV via LAN IP or Tailscale
```

Repo facts:

- Companion only: `docker-compose.yml` publishes `4534`, joins `navidrome_default`, talks to `http://navidrome:4533`.
- Navidrome itself is **not** defined in this repo — it already runs as container `navidrome`.
- Optional `DROME_PUBLIC_URL` is for iMessage share cards / Associated Domains — separate from streaming.
- Multi-user already works: one Navidrome user per person; companion data is keyed by username.

## Recommended approach: Cloudflare Tunnel (cheap / usually $0)

### Why tunnel (not port-forward)

- No open WAN ports on the home router.
- Works behind CGNAT / flaky ISP NAT.
- Free HTTPS on a Cloudflare-managed domain.
- Guests never install Tailscale.

### Prerequisites

1. Cloudflare account (free).
2. A domain on Cloudflare DNS (existing domain or ~$10/yr new one).
3. SSH / console access to the Docker host that runs `navidrome` + `drome-server`.
4. Decision on hostnames, e.g.:
   - `music.example.com` → Navidrome `:4533`
   - `drome.example.com` → companion `:4534` (only if guests need wishlist / Connect / Spotify search)

Streaming **only** needs `music.`. Companion is optional for guests.

### Backend work (infra agent)

1. **Install `cloudflared` on the Docker host**
   - Prefer a small `cloudflared` container on `navidrome_default` so it can resolve `navidrome` / `drome-server` by Docker DNS.
   - Or install the binary on the host and point at `127.0.0.1:4533` / `4534` if those ports are published.

2. **Create a Cloudflare Tunnel** (Zero Trust → Networks → Tunnels)
   - Name: `drome-home` (or similar).
   - Copy the tunnel token into host secrets (never commit).

3. **Public hostname routes**

   | Public hostname | Service URL |
   |-----------------|-------------|
   | `music.example.com` | `http://navidrome:4533` |
   | `drome.example.com` | `http://drome-server:4534` |

   Use HTTP to origin (TLS terminates at Cloudflare). Do **not** orange-cloud proxy a raw port-forward for large media if you also have a tunnel — pick one path.

4. **Compose sketch** (add beside existing `drome-server`; adjust to match host layout):

   ```yaml
   # Suggested addition — do not paste blindly; merge with the live compose that owns navidrome_default.
   services:
     cloudflared:
       image: cloudflare/cloudflared:latest
       container_name: cloudflared
       restart: unless-stopped
       command: tunnel --no-autoupdate run
       environment:
         TUNNEL_TOKEN: ${CLOUDFLARE_TUNNEL_TOKEN}
       networks:
         - navidrome_default
   ```

   Put `CLOUDFLARE_TUNNEL_TOKEN` in the host `.env` (gitignored).

5. **DNS**
   - Cloudflare Tunnel UI can create CNAME records automatically for the public hostnames.
   - Confirm `music.example.com` resolves and `https://music.example.com` loads Navidrome’s web UI / login.

6. **Navidrome users for guests**
   - Admin → Users → create one account per person (strong unique passwords).
   - Disable open registration if enabled.
   - Guests do **not** need admin / scan rights.
   - Optional: create a shared “family” user only if you accept shared ratings/history.

7. **Companion (optional)**
   - If exposing `drome.example.com`, set guest app **Wishlist companion URL** to that origin.
   - Set `DROME_PUBLIC_URL=https://drome.example.com` if share links should use the public host (and update Associated Domains if needed).
   - Wishlist downloads write into the shared music library — treat guest wishlist power carefully (or leave companion LAN/Tailscale-only for Charlie).

8. **Smoke tests**
   - From a phone **off Tailscale / off LAN Wi‑Fi** (LTE):
     - Open `https://music.example.com` in Safari → Navidrome login works.
     - Drome → Server URL `https://music.example.com` → login → play a track.
     - Confirm diagnostics show `resilient:true` (or compressed stream) on cellular.
     - Confirm Connect / wishlist only if those hostnames were exposed.
   - From LAN: existing `http://192.168.8.193:4533` still works for Charlie.

### Security checklist

- [ ] HTTPS only for guests (no plain `http://` public hostname).
- [ ] Strong per-user Navidrome passwords; no shared admin.
- [ ] Registration closed on Navidrome.
- [ ] Tunnel token stored as a secret, not in git.
- [ ] Consider Cloudflare WAF / Bot Fight / rate limiting on free plan.
- [ ] Do not expose unnecessary admin UIs.
- [ ] Bandwidth: prefer resilient / MP3 for remote; raw FLAC over the tunnel will chew home upload.

### Out of scope / non-goals

- Replacing Tailscale for Charlie’s own admin access.
- Changing Subsonic auth in the iOS app.
- Building a full reverse-proxy auth portal (Authelia, etc.) unless abuse appears.
- Moving the music library off the home NAS.

## Fallback if Tunnel is blocked / insufficient

1. **Port-forward 443 → Caddy** on the LAN with Let’s Encrypt (needs a real public IP, not CGNAT).
2. **Cheap VPS relay (~$4–6/mo)** — WireGuard home→VPS, public HTTPS on the VPS, origin still Navidrome at home.

Same guest UX either way: public `https://music.…` URL in Drome.

## App / product notes (iOS — usually no work)

- Login already accepts any URL (`LoginView` Server URL).
- `PlaybackPreferences.resilientRemoteStreaming` defaults on; Tailscale/`100.x`/public hosts are treated as remote.
- If guests report stalls, point them at Settings → resilient streaming / compress on cellular (already present).
- Optional later product work (not required for this infra plan): onboarding copy that suggests the public hostname, or a “share invite” deep link.

## Acceptance criteria

1. Guest on cellular, no Tailscale, plays music via `https://music.example.com`.
2. Charlie still plays via LAN or Tailscale unchanged.
3. Tunnel container restarts with the host (`restart: unless-stopped`).
4. Token / secrets not committed.
5. Document the live hostnames in the private ops notes (not necessarily this public repo).

## Handoff checklist for the infra agent

- [ ] Confirm live container names / network (`docker network inspect navidrome_default`).
- [ ] Confirm whether `:4533` is published on the host or Docker-internal only.
- [ ] Pick domain + hostnames with Charlie.
- [ ] Create tunnel + token.
- [ ] Deploy `cloudflared` on `navidrome_default`.
- [ ] Create guest Navidrome users.
- [ ] LTE smoke test with Drome.
- [ ] Decide whether `drome.` companion is public or Tailscale-only.
