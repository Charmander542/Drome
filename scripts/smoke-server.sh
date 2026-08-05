#!/usr/bin/env bash
# End-to-end smoke test for drome-server using a fake Navidrome that accepts
# any credentials. Exercises auth, routing, and the wishlist store.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.local/go/bin:$PATH"
export GOPATH="${GOPATH:-$ROOT/.gopath}" GOMODCACHE="${GOMODCACHE:-$ROOT/.gopath/pkg/mod}"

cd "$ROOT/server"
go build -o bin/drome-server .

python3 - <<'PY' &
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"subsonic-response": {"status": "ok", "version": "1.16.1"}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 19533), H).serve_forever()
PY
FAKE_PID=$!

rm -f smoke-test.db smoke-test.db-wal smoke-test.db-shm
DROME_NAVIDROME_URL=http://127.0.0.1:19533 \
DROME_DB_PATH=smoke-test.db \
DROME_LISTEN_ADDR=127.0.0.1:19534 \
DROME_AUTO_DOWNLOAD=false \
./bin/drome-server &
SRV_PID=$!
trap 'kill $FAKE_PID $SRV_PID 2>/dev/null || true' EXIT
sleep 1

BASE=http://127.0.0.1:19534
AUTH='u=alice&t=abc&s=xyz'

echo "--- health"
curl -sf "$BASE/health"; echo

echo "--- unauthenticated list (expect 401)"
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/wishlist")
echo "$code"; test "$code" = "401"

echo "--- authenticated empty list"
curl -sf "$BASE/wishlist?$AUTH"; echo

echo "--- add non-spotify link (expect 422)"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/wishlist?$AUTH" \
  -H 'Content-Type: application/json' -d '{"url":"https://example.com/nope"}')
echo "$code"; test "$code" = "422"

echo "--- add spotify link without API creds (public metadata; expect 201)"
# With DROME_AUTO_DOWNLOAD=false and no Spotify API key, public OG resolve should succeed.
# This hit needs outbound network; skip gracefully if offline.
code=$(curl -s -o /tmp/drome-smoke-add.json -w '%{http_code}' -X POST "$BASE/wishlist?$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://open.spotify.com/track/11dFghVXANMlKmJXsNCbNl"}' || true)
echo "$code"
if [[ "$code" == "201" ]]; then
  grep -q 'Cut To The Feeling' /tmp/drome-smoke-add.json
elif [[ "$code" == "502" ]]; then
  echo "(public metadata unreachable in this environment — acceptable)"
else
  echo "unexpected status $code"; cat /tmp/drome-smoke-add.json; exit 1
fi

echo "--- share whole list with bob (expect 204)"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/wishlist/share?$AUTH" \
  -H 'Content-Type: application/json' -d '{"user":"bob"}')
echo "$code"; test "$code" = "204"

echo "--- bob sees an empty (but authorized) list"
curl -sf "$BASE/wishlist?u=bob&t=abc&s=xyz"; echo

echo "SMOKE OK"
