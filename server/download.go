package main

import (
	"bytes"
	"context"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

func md5Hex(s string) string {
	sum := md5.Sum([]byte(s))
	return hex.EncodeToString(sum[:])
}

// download statuses persisted on wishlist entries.
const (
	statusQueued      = "queued"
	statusDownloading = "downloading"
	statusDone        = "done"
	statusFailed      = "failed"
	statusSkipped     = "skipped"
)

type downloadConfig struct {
	Enabled      bool
	MusicDir     string
	SpotiflacBin string
	Services     []string
	Timeout      time.Duration
}

func downloadConfigFromEnv() downloadConfig {
	enabled := strings.ToLower(envOr("DROME_AUTO_DOWNLOAD", "true"))
	cfg := downloadConfig{
		Enabled:      enabled == "1" || enabled == "true" || enabled == "yes",
		MusicDir:     envOr("DROME_MUSIC_DIR", "/music"),
		SpotiflacBin: envOr("DROME_SPOTIFLAC_BIN", "spotiflac"),
		Timeout:      envDuration("DROME_DOWNLOAD_TIMEOUT", 45*time.Minute),
	}
	raw := envOr("DROME_SPOTIFLAC_SERVICES", "tidal,qobuz,amazon,deezer")
	for _, part := range strings.Split(raw, ",") {
		part = strings.TrimSpace(part)
		if part != "" {
			cfg.Services = append(cfg.Services, part)
		}
	}
	if len(cfg.Services) == 0 {
		cfg.Services = []string{"tidal", "qobuz", "amazon"}
	}
	return cfg
}

func envDuration(key string, fallback time.Duration) time.Duration {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return fallback
	}
	return d
}

// downloadWorker serializes SpotiFLAC jobs so we don't hammer providers.
type downloadWorker struct {
	cfg       downloadConfig
	store     *wishlistStore
	navidrome *navidromeVerifier
	baseURL   string

	mu     sync.Mutex
	wake   chan struct{}
	closed bool
}

func newDownloadWorker(cfg downloadConfig, store *wishlistStore, navidrome *navidromeVerifier, baseURL string) *downloadWorker {
	return &downloadWorker{
		cfg:       cfg,
		store:     store,
		navidrome: navidrome,
		baseURL:   baseURL,
		wake:      make(chan struct{}, 1),
	}
}

func (w *downloadWorker) kick() {
	select {
	case w.wake <- struct{}{}:
	default:
	}
}

func (w *downloadWorker) Close() {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.closed {
		return
	}
	w.closed = true
	close(w.wake)
}

func (w *downloadWorker) Run(ctx context.Context) {
	if !w.cfg.Enabled {
		logf("auto-download disabled (DROME_AUTO_DOWNLOAD=false)")
		return
	}
	logf("auto-download enabled → %s via %s (%s)", w.cfg.MusicDir, w.cfg.SpotiflacBin, strings.Join(w.cfg.Services, ","))

	// Recover jobs interrupted by a previous restart.
	if n, err := w.store.requeueDownloading(); err != nil {
		logf("requeue downloading: %v", err)
	} else if n > 0 {
		logf("re-queued %d interrupted download(s)", n)
	}
	w.kick()

	for {
		select {
		case <-ctx.Done():
			return
		case _, ok := <-w.wake:
			if !ok {
				return
			}
		}
		for {
			e, err := w.store.nextQueued()
			if err != nil {
				logf("poll queue: %v", err)
				break
			}
			if e == nil {
				break
			}
			w.process(ctx, e)
		}
	}
}

func (w *downloadWorker) process(parent context.Context, e *entry) {
	logf("download start id=%d %s %q — %q", e.ID, e.Kind, e.Artist, e.Title)
	_ = w.store.setStatus(e.ID, statusDownloading, "")

	ctx, cancel := context.WithTimeout(parent, w.cfg.Timeout)
	defer cancel()

	if err := w.runSpotiflac(ctx, e.SpotifyURL); err != nil {
		msg := truncate(err.Error(), 500)
		logf("download failed id=%d: %v", e.ID, err)
		_ = w.store.setStatus(e.ID, statusFailed, msg)
		return
	}

	logf("download done id=%d — removing from wishlist", e.ID)
	if err := w.triggerScan(parent); err != nil {
		logf("navidrome scan trigger: %v (library will pick up on next scheduled scan)", err)
	}
	// Leave the wishlist once the file is in the music library; Home’s
	// “New in your library” rail is driven by Navidrome’s newest albums.
	if err := w.store.delete(e.ID); err != nil {
		logf("delete completed wishlist entry id=%d: %v", e.ID, err)
		_ = w.store.setAcquired(e.ID, true)
		_ = w.store.setStatus(e.ID, statusDone, "")
	}
}

func (w *downloadWorker) runSpotiflac(ctx context.Context, spotifyURL string) error {
	if err := os.MkdirAll(w.cfg.MusicDir, 0o755); err != nil {
		return fmt.Errorf("music dir: %w", err)
	}

	args := []string{
		spotifyURL,
		w.cfg.MusicDir,
		"--service",
	}
	args = append(args, w.cfg.Services...)

	cmd := exec.CommandContext(ctx, w.cfg.SpotiflacBin, args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	cmd.Env = append(os.Environ(), "PYTHONUNBUFFERED=1")

	err := cmd.Run()
	if err == nil {
		return nil
	}
	out := strings.TrimSpace(stdout.String() + "\n" + stderr.String())
	if out == "" {
		return fmt.Errorf("spotiflac: %w", err)
	}
	return fmt.Errorf("spotiflac: %w\n%s", err, truncate(out, 2000))
}

// triggerScan asks Navidrome to rescan via the OpenSubsonic startScan endpoint
// using optional admin credentials. If unset, we rely on ND_SCANSCHEDULE.
func (w *downloadWorker) triggerScan(ctx context.Context) error {
	user := os.Getenv("DROME_NAVIDROME_SCAN_USER")
	pass := os.Getenv("DROME_NAVIDROME_SCAN_PASSWORD")
	if user == "" || pass == "" {
		return fmt.Errorf("DROME_NAVIDROME_SCAN_USER/PASSWORD not set")
	}

	// Prefer token auth so we never log the password in URLs elsewhere.
	salt := fmt.Sprintf("drome%d", time.Now().UnixNano())
	sum := md5Hex(pass + salt)

	q := url.Values{}
	q.Set("u", user)
	q.Set("t", sum)
	q.Set("s", salt)
	q.Set("v", "1.16.1")
	q.Set("c", "drome-server")
	q.Set("f", "json")

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, w.baseURL+"/rest/startScan?"+q.Encode(), nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	var body struct {
		SubsonicResponse struct {
			Status string `json:"status"`
			Error  struct {
				Message string `json:"message"`
			} `json:"error"`
		} `json:"subsonic-response"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return err
	}
	if body.SubsonicResponse.Status != "ok" {
		return fmt.Errorf("%s", body.SubsonicResponse.Error.Message)
	}
	logf("navidrome library scan started")
	return nil
}

func truncate(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
