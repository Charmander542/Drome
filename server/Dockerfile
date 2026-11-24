# Build the Go companion binary, then ship it in a Python image with Mornye
# (SpotiFLAC's successor) so wishlist adds can download FLAC into the shared
# Navidrome music library.
FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /out/drome-server .

FROM python:3.12-slim-bookworm
ENV DEBIAN_FRONTEND=noninteractive
# Mornye provider extensions need Node + Chromium + a virtual display for
# Cloudflare Turnstile / signed-session solves. libmpv2 satisfies python-mpv.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates ffmpeg curl \
      nodejs \
      chromium \
      xvfb \
      xauth \
      fonts-liberation \
      libmpv2 \
 && rm -rf /var/lib/apt/lists/* \
 && pip install --no-cache-dir "pydoll-python==2.27.0" "mornye==2.2.2" "mutagen" \
 && useradd --create-home --uid 1000 --user-group drome \
 && mkdir -p /data /music \
 && chown drome:drome /data /music

COPY patches/patch_spotiflac_amazon_finalize.py /tmp/patch_spotiflac_amazon_finalize.py
RUN python3 /tmp/patch_spotiflac_amazon_finalize.py && rm -f /tmp/patch_spotiflac_amazon_finalize.py

COPY --from=build /out/drome-server /usr/local/bin/drome-server
COPY download-entry.sh /usr/local/bin/drome-download
COPY entrypoint.sh /usr/local/bin/drome-entrypoint
COPY retag.py /usr/local/bin/drome-retag
COPY genre_tag.py /usr/local/bin/drome-genre-tag
COPY list-playlist.py /usr/local/bin/drome-list-playlist
COPY scripts/cleanup_library.py /usr/local/bin/drome-cleanup-library
COPY scripts/bootstrap-spotiflac-extensions.py /usr/local/bin/drome-bootstrap-spotiflac
RUN chmod 755 /usr/local/bin/drome-download /usr/local/bin/drome-entrypoint /usr/local/bin/drome-retag /usr/local/bin/drome-genre-tag /usr/local/bin/drome-list-playlist /usr/local/bin/drome-cleanup-library /usr/local/bin/drome-bootstrap-spotiflac \
 && sed -i '1s|^#!.*|#!/usr/bin/env python3|' /usr/local/bin/drome-retag /usr/local/bin/drome-genre-tag /usr/local/bin/drome-list-playlist /usr/local/bin/drome-cleanup-library /usr/local/bin/drome-bootstrap-spotiflac

USER drome
ENV DROME_DB_PATH=/data/drome.db \
    DROME_LISTEN_ADDR=:4534 \
    DROME_MUSIC_DIR=/music \
    DROME_SPOTIFLAC_BIN=/usr/local/bin/drome-download \
    DROME_SPOTIFLAC_LIST_BIN=/usr/local/bin/drome-list-playlist \
    DROME_RETAG_BIN=/usr/local/bin/drome-retag \
    DROME_GENRE_BIN=/usr/local/bin/drome-genre-tag \
    DROME_AUTO_DOWNLOAD=true \
    DROME_DOWNLOAD_MAX_ATTEMPTS=5 \
    DROME_CLEANUP_ENABLED=true \
    DROME_CLEANUP_INTERVAL=24h \
    DROME_CLEANUP_MERGE=true \
    DROME_CLEANUP_ON_START=true \
    DROME_CLEANUP_BIN=/usr/local/bin/drome-cleanup-library \
    CHROME_PATH=/usr/bin/chromium \
    MORNYE_EXT_ALLOW_ANY_WRITE=1 \
    MORNYE_DATA_DIR=/home/drome/.mornye \
    MORNYE_REGISTRIES=https://raw.githubusercontent.com/mornyeapp/Mornye-Extension/main/registry.json,https://raw.githubusercontent.com/mornyeapp/Mornye-Extension/main/registry-python.json \
    DROME_SPOTIFLAC_EXTENSIONS=utilities,tidal-web,qobuz-web,amazon,deezer,ytmusic-spotiflac \
    HOME=/home/drome
EXPOSE 4534
VOLUME ["/data", "/music"]
ENTRYPOINT ["drome-entrypoint"]
