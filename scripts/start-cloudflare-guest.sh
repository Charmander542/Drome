#!/usr/bin/env bash
# Start cloudflared on navidrome_default once CLOUDFLARE_TUNNEL_TOKEN is set.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

if [[ -z "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]]; then
  cat >&2 <<'EOF'
CLOUDFLARE_TUNNEL_TOKEN is not set.

1. Cloudflare Zero Trust → Networks → Tunnels → Create a tunnel (cloudflared)
2. Name it drome-home (or similar) and copy the token
3. Add to /home/cvh/docker/Drome/.env:
     CLOUDFLARE_TUNNEL_TOKEN=eyJ...
4. In the tunnel UI, add public hostname:
     music.<your-domain> → http://navidrome:4533
   (optional) drome.<your-domain> → http://drome-server:4534
5. Re-run: ./scripts/start-cloudflare-guest.sh

See docs/cloudflare-remote-access.md for the full guest guide.
EOF
  exit 1
fi

echo "==> starting cloudflared (profile cloudflare)"
docker compose --profile cloudflare up -d cloudflared

echo "==> status"
docker ps --filter name=cloudflared --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
echo
echo "Logs: docker logs -f cloudflared"
echo "Confirm tunnel Healthy in Zero Trust, then LTE-test https://music.<your-domain>"
