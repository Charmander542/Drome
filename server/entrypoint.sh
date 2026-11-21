#!/usr/bin/env bash
# Bootstrap SpotiFLAC extensions (once per volume) then start drome-server.
set -euo pipefail

if [[ -x /usr/local/bin/drome-bootstrap-spotiflac ]]; then
  /usr/local/bin/drome-bootstrap-spotiflac || echo "warning: spotiflac extension bootstrap failed" >&2
fi

exec drome-server "$@"
