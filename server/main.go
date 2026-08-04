// drome-server is the companion backend for the Drome iOS app.
//
// It stores the wishlist ("songs to go get"), which cannot live in Navidrome
// because Subsonic playlists can only reference tracks that already exist in
// the library. Identity stays with Navidrome: every request carries Subsonic
// token credentials which are verified against the Navidrome server before
// being served. Spotify links are resolved server-side with a
// client-credentials app so the secret never reaches the iOS client.
package main

import (
	"log"
	"net/http"
	"os"
	"time"
)

type config struct {
	ListenAddr          string
	NavidromeURL        string
	SpotifyClientID     string
	SpotifyClientSecret string
	DBPath              string
}

func configFromEnv() config {
	cfg := config{
		ListenAddr:          envOr("DROME_LISTEN_ADDR", ":4534"),
		NavidromeURL:        envOr("DROME_NAVIDROME_URL", "http://navidrome:4533"),
		SpotifyClientID:     os.Getenv("DROME_SPOTIFY_CLIENT_ID"),
		SpotifyClientSecret: os.Getenv("DROME_SPOTIFY_CLIENT_SECRET"),
		DBPath:              envOr("DROME_DB_PATH", "drome.db"),
	}
	return cfg
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func main() {
	cfg := configFromEnv()

	store, err := openStore(cfg.DBPath)
	if err != nil {
		log.Fatalf("open store: %v", err)
	}
	defer store.Close()

	if cfg.SpotifyClientID == "" || cfg.SpotifyClientSecret == "" {
		log.Printf("warning: DROME_SPOTIFY_CLIENT_ID / DROME_SPOTIFY_CLIENT_SECRET not set; wishlist adds will fail")
	}

	srv := &server{
		store:     store,
		navidrome: newNavidromeVerifier(cfg.NavidromeURL, 5*time.Minute),
		spotify:   newSpotifyClient(cfg.SpotifyClientID, cfg.SpotifyClientSecret),
	}

	log.Printf("drome-server listening on %s (navidrome: %s, db: %s)", cfg.ListenAddr, cfg.NavidromeURL, cfg.DBPath)
	if err := http.ListenAndServe(cfg.ListenAddr, srv.routes()); err != nil {
		log.Fatal(err)
	}
}
