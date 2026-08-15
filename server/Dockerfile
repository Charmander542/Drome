# Build the Go companion binary, then ship it in a Python image with SpotiFLAC
# so wishlist adds can download FLAC into the shared Navidrome music library.
FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /out/drome-server .

FROM python:3.12-slim-bookworm
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates ffmpeg curl \
 && rm -rf /var/lib/apt/lists/* \
 && pip install --no-cache-dir "pydoll-python" "SpotiFLAC>=1.6.0" "mutagen" \
 && useradd --create-home --uid 1000 --user-group drome \
 && mkdir -p /data /music \
 && chown drome:drome /data /music

COPY --from=build /out/drome-server /usr/local/bin/drome-server
COPY download-entry.sh /usr/local/bin/drome-download
COPY retag.py /usr/local/bin/drome-retag
COPY list-playlist.py /usr/local/bin/drome-list-playlist
COPY scripts/cleanup_library.py /usr/local/bin/drome-cleanup-library
RUN chmod 755 /usr/local/bin/drome-download /usr/local/bin/drome-retag /usr/local/bin/drome-list-playlist /usr/local/bin/drome-cleanup-library \
 && sed -i '1s|^#!.*|#!/usr/bin/env python3|' /usr/local/bin/drome-retag /usr/local/bin/drome-list-playlist /usr/local/bin/drome-cleanup-library

USER drome
ENV DROME_DB_PATH=/data/drome.db \
    DROME_LISTEN_ADDR=:4534 \
    DROME_MUSIC_DIR=/music \
    DROME_SPOTIFLAC_BIN=/usr/local/bin/drome-download \
    DROME_SPOTIFLAC_LIST_BIN=/usr/local/bin/drome-list-playlist \
    DROME_RETAG_BIN=/usr/local/bin/drome-retag \
    DROME_AUTO_DOWNLOAD=true \
    DROME_DOWNLOAD_MAX_ATTEMPTS=5 \
    DROME_CLEANUP_ENABLED=true \
    DROME_CLEANUP_INTERVAL=24h \
    DROME_CLEANUP_MERGE=true \
    DROME_CLEANUP_ON_START=true \
    DROME_CLEANUP_BIN=/usr/local/bin/drome-cleanup-library \
    HOME=/home/drome
EXPOSE 4534
VOLUME ["/data", "/music"]
ENTRYPOINT ["drome-server"]
