// drome-server is the companion backend for the Drome iOS app.
//
// It stores the wishlist ("songs to go get"), which cannot live in Navidrome
// because Subsonic playlists can only reference tracks that already exist in
// the library. Identity stays with Navidrome: every request carries Subsonic
// token credentials which are verified against the Navidrome server before
// being served. Spotify links are resolved from public page metadata by
// default (no API key); optional client-credentials improve metadata quality.
//
// When auto-download is enabled, new wishlist entries are queued and fetched
// via SpotiFLAC into the shared music library, then Navidrome is asked to
// rescan so the tracks become streamable.
package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

type config struct {
	ListenAddr          string
	NavidromeURL        string
	SpotifyClientID     string
	SpotifyClientSecret string
	SpotifyMarket       string
	DBPath              string
	Download            downloadConfig
	Cleanup             cleanupConfig
}

func configFromEnv() config {
	dl := downloadConfigFromEnv()
	cfg := config{
		ListenAddr:          envOr("DROME_LISTEN_ADDR", ":4534"),
		NavidromeURL:        envOr("DROME_NAVIDROME_URL", "http://navidrome:4533"),
		SpotifyClientID:     os.Getenv("DROME_SPOTIFY_CLIENT_ID"),
		SpotifyClientSecret: os.Getenv("DROME_SPOTIFY_CLIENT_SECRET"),
		SpotifyMarket:       envOr("DROME_SPOTIFY_MARKET", "US"),
		DBPath:              envOr("DROME_DB_PATH", "drome.db"),
		Download:            dl,
		Cleanup:             cleanupConfigFromEnv(dl.MusicDir),
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

	if n, err := store.purgeCompleted(); err != nil {
		log.Printf("purge completed wishlist rows: %v", err)
	} else if n > 0 {
		log.Printf("purged %d completed wishlist entries (now live in the library)", n)
	}

	spotify := newSpotifyClient(cfg.SpotifyClientID, cfg.SpotifyClientSecret, cfg.SpotifyMarket)
	if spotify.hasAPICreds() {
		log.Printf("spotify metadata: Web API (client credentials)")
	} else {
		log.Printf("spotify metadata: public Open Graph / oEmbed (no API key)")
	}

	worker := newDownloadWorker(cfg.Download, store, newNavidromeVerifier(cfg.NavidromeURL, 5*time.Minute), cfg.NavidromeURL)
	cleaner := newLibraryCleaner(cfg.Cleanup, worker.triggerScan)
	srv := &server{
		store:     store,
		navidrome: worker.navidrome,
		spotify:   spotify,
		downloads: worker,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go worker.Run(ctx)
	go cleaner.Run(ctx)

	httpSrv := &http.Server{Addr: cfg.ListenAddr, Handler: srv.routes()}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = httpSrv.Shutdown(shutdownCtx)
		worker.Close()
	}()

	log.Printf("drome-server listening on %s (navidrome: %s, db: %s, music: %s, cleanup: %v/%s)",
		cfg.ListenAddr, cfg.NavidromeURL, cfg.DBPath, cfg.Download.MusicDir,
		cfg.Cleanup.Enabled, cfg.Cleanup.Interval)
	if err := httpSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}
