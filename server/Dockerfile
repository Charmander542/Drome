FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /out/drome-server .

FROM alpine:3.22
RUN adduser -D -H drome && mkdir /data && chown drome /data
USER drome
COPY --from=build /out/drome-server /usr/local/bin/drome-server
ENV DROME_DB_PATH=/data/drome.db \
    DROME_LISTEN_ADDR=:4534
EXPOSE 4534
VOLUME /data
ENTRYPOINT ["drome-server"]
