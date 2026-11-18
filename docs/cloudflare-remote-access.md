# Cloudflare remote access (no Tailscale for guests)

Expose Charlie’s home Navidrome over HTTPS so friends can use Drome without joining Tailscale.

## Goal

| Audience | How they connect |
|----------|------------------|
| Charlie (admin) | Keep Tailscale / LAN as today (`192.168.8.193` or Tailscale) |
| Guests | Public HTTPS hostname only — install Drome, log into Navidrome |

No app code changes are required for basic streaming. Guests set **Server URL** to the public music hostname. Non-LAN hosts already enable **resilient remote streaming** (MP3 + disk cache) in `PlaybackPreferences.isLocalNetworkHost`.

## What already works on this host (confirmed)

```
Home LAN / Docker
├── navidrome         :4533  FLAC library (Charlie LAN/VPN)
├── navidrome-remote  :4536  MP3 mirror (Funnel guests)
└── drome-server      :4534  wishlist companion
└── Tailscale Funnel:
    https://cvh-elitemini-series.tail96490e.ts.net       →  :4536 (MP3)
    https://cvh-elitemini-series.tail96490e.ts.net:10000 →  :4534 (wishlist)
```

- Funnel is **public** (not Tailscale-only). Guests use:
  `https://cvh-elitemini-series.tail96490e.ts.net` (MP3 Navidrome — see [`remote-mp3-funnel.md`](remote-mp3-funnel.md)).
- Companion wishlist Funnel: `https://cvh-elitemini-series.tail96490e.ts.net:10000`.
- Create matching guest users on **both** Navidrome instances (separate DBs).

Cloudflare Tunnel is the nicer guest UX (short domain like `music.yourdomain.com`). Infra is wired in this repo; you only need a Cloudflare domain + tunnel token to finish.

---

## Step-by-step: guests today (Funnel — zero Cloudflare)

1. On your phone, turn **off** Tailscale (or use a friend’s phone on cellular).
2. Install / open **Drome**.
3. Server URL:
   ```text
   https://cvh-elitemini-series.tail96490e.ts.net
   ```
4. Log in with a **non-admin** Navidrome user (e.g. `bubba`) and a strong password.
5. Play a track. On cellular, Settings should show resilient / compressed streaming.

Create more guest users in Navidrome web UI → **Settings → Users** (admin login). Do not share the admin account.

---

## Step-by-step: Cloudflare Tunnel (preferred long-term)

### A. Prerequisites (you do once)

1. Cloudflare account (free is fine).
2. A domain on Cloudflare DNS (existing, or buy ~$10/yr in Cloudflare Registrar).
3. Pick hostnames, for example:
   - `music.example.com` → Navidrome (required for guests)
   - `drome.example.com` → companion (optional; leaves wishlist/download power on the internet — usually **skip** for guests)

### B. Create the tunnel (Cloudflare dashboard)

1. Open [Zero Trust → Networks → Tunnels](https://one.dash.cloudflare.com/).
2. **Create a tunnel** → connector type **Cloudflared**.
3. Name: `drome-home`.
4. Copy the **tunnel token** (long `eyJ…` string). Do **not** commit it.

### C. Put the token on this host

```bash
cd /home/cvh/docker/Drome
nano .env   # or your editor
```

Add:

```bash
CLOUDFLARE_TUNNEL_TOKEN=eyJ...paste-token-here...
```

`.env` is gitignored.

### D. Start cloudflared

Repo already defines the service on `navidrome_default`:

```bash
cd /home/cvh/docker/Drome
./scripts/start-cloudflare-guest.sh
# or: docker compose --profile cloudflare up -d cloudflared
docker logs -f cloudflared   # should show registered/connected
```

### E. Public hostname routes (Tunnel UI)

| Public hostname | Type | URL (Docker DNS) |
|-----------------|------|------------------|
| `music.example.com` | HTTP | `http://navidrome:4533` |
| `drome.example.com` (optional) | HTTP | `http://drome-server:4534` |

- TLS terminates at Cloudflare; origin is plain HTTP inside Docker.
- Let the Tunnel UI create the CNAME DNS records.
- Confirm tunnel status **Healthy**.

### F. Guest Navidrome accounts

1. Open Navidrome locally: `http://192.168.8.193:4533` (or Funnel URL).
2. Admin → Users → add one user per guest (strong unique passwords).
3. No admin / scan rights for guests.
4. Keep open registration **off** (default).

### G. Smoke test

From a phone **off Tailscale / off LAN Wi‑Fi** (LTE):

1. Safari → `https://music.example.com` → Navidrome login.
2. Drome → Server URL `https://music.example.com` → login → play.
3. Confirm resilient streaming on cellular.
4. From LAN: `http://192.168.8.193:4533` still works for Charlie.

### H. Optional companion / share cards

Only if you exposed `drome.`:

```bash
# in .env
DROME_PUBLIC_URL=https://drome.example.com
docker compose up -d --build drome-server
```

Otherwise leave companion private; guests only need the music hostname.

---

## Security checklist

- [ ] HTTPS only for guests (Cloudflare or Funnel — no plain `http://` public URL).
- [ ] Strong per-user Navidrome passwords; no shared admin.
- [ ] Registration closed on Navidrome.
- [ ] Tunnel token only in `.env`, never git.
- [ ] Prefer **not** exposing `drome-server` publicly (wishlist downloads write the library).
- [ ] Consider Cloudflare Bot Fight / rate limiting on free plan.
- [ ] Bandwidth: resilient / MP3 for remote; raw FLAC chews home upload.

## Compose sketch (already in `docker-compose.yml`)

```yaml
cloudflared:
  profiles: ["cloudflare"]
  image: cloudflare/cloudflared:latest
  container_name: cloudflared
  restart: unless-stopped
  command: tunnel --no-autoupdate run
  environment:
    TUNNEL_TOKEN: ${CLOUDFLARE_TUNNEL_TOKEN:-}
  networks:
    - navidrome_default
```

## Acceptance criteria

1. Guest on cellular, no Tailscale, plays via public HTTPS music host.
2. Charlie still plays via LAN or Tailscale unchanged.
3. `cloudflared` restarts with the host (`restart: unless-stopped`).
4. Token / secrets not committed.
5. Live hostnames noted privately (Funnel URL above; Cloudflare host once chosen).

## Handoff checklist

- [x] Confirm live container names / network (`navidrome` + `drome-server` on `navidrome_default`).
- [x] Confirm `:4533` / `:4534` published on the host.
- [x] Wire `cloudflared` into compose (`--profile cloudflare`) + start script.
- [x] Interim guest path: Tailscale Funnel URL above.
- [ ] Charlie: pick Cloudflare domain + create tunnel + paste token into `.env`.
- [ ] Run `./scripts/start-cloudflare-guest.sh` and add `music.` hostname route.
- [ ] Create/confirm guest Navidrome users; LTE smoke test with Drome.
- [x] Default: keep `drome.` companion Tailscale/LAN-only.
