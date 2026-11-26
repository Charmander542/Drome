#!/usr/bin/env bash
# Bootstrap Mornye extensions (once per volume) then start drome-server.
set -euo pipefail

if [[ -x /usr/local/bin/drome-bootstrap-spotiflac ]]; then
  # Registries can hang; don't block lyrics backfill / downloads forever.
  timeout="${DROME_BOOTSTRAP_TIMEOUT_SEC:-90}"
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout" /usr/local/bin/drome-bootstrap-spotiflac \
      || echo "warning: mornye extension bootstrap failed or timed out after ${timeout}s" >&2
  else
    /usr/local/bin/drome-bootstrap-spotiflac \
      || echo "warning: mornye extension bootstrap failed" >&2
  fi
fi

exec drome-server "$@"
