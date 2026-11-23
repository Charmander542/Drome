#!/usr/bin/env bash
# Pull latest main and rebuild/restart drome-server.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> git pull"
git pull --ff-only

echo "==> docker compose up -d --build"
docker compose up -d --build

echo "==> waiting for health"
for i in $(seq 1 15); do
  if curl -sf http://127.0.0.1:4534/health >/dev/null; then
    echo "health: ok"
    break
  fi
  if [[ "$i" -eq 15 ]]; then
    echo "health check failed" >&2
    docker logs drome-server 2>&1 | tail -20 >&2
    exit 1
  fi
  sleep 1
done

echo "==> $(git log -1 --oneline)"
docker ps --filter name=drome-server --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
