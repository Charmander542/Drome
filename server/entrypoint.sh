#!/usr/bin/env bash
# Bootstrap Mornye extensions (once per volume) then start drome-server.
set -euo pipefail

if [[ -x /usr/local/bin/drome-bootstrap-spotiflac ]]; then
  /usr/local/bin/drome-bootstrap-spotiflac || echo "warning: mornye extension bootstrap failed" >&2
fi

exec drome-server "$@"
