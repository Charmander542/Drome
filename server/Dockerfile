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
 && pip install --no-cache-dir "pydoll-python" "SpotiFLAC>=1.6.0" \
 && useradd --create-home --uid 1000 --user-group drome \
 && mkdir -p /data /music \
 && chown drome:drome /data /music

COPY --from=build /out/drome-server /usr/local/bin/drome-server
COPY download-entry.sh /usr/local/bin/drome-download
RUN chmod 755 /usr/local/bin/drome-download

USER drome
ENV DROME_DB_PATH=/data/drome.db \
    DROME_LISTEN_ADDR=:4534 \
    DROME_MUSIC_DIR=/music \
    DROME_SPOTIFLAC_BIN=/usr/local/bin/drome-download \
    DROME_AUTO_DOWNLOAD=true \
    HOME=/home/drome
EXPOSE 4534
VOLUME ["/data", "/music"]
ENTRYPOINT ["drome-server"]
