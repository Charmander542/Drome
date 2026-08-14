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
	"path/filepath"
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
	RetagBin     string
	Services     []string
	Timeout      time.Duration
	MaxAttempts  int
	RetryBase    time.Duration
}

func downloadConfigFromEnv() downloadConfig {
	enabled := strings.ToLower(envOr("DROME_AUTO_DOWNLOAD", "true"))
	cfg := downloadConfig{
		Enabled:      enabled == "1" || enabled == "true" || enabled == "yes",
		MusicDir:     envOr("DROME_MUSIC_DIR", "/music"),
		SpotiflacBin: envOr("DROME_SPOTIFLAC_BIN", "spotiflac"),
		RetagBin:     envOr("DROME_RETAG_BIN", "drome-retag"),
		Timeout:      envDuration("DROME_DOWNLOAD_TIMEOUT", 45*time.Minute),
		MaxAttempts:  envInt("DROME_DOWNLOAD_MAX_ATTEMPTS", 5),
		RetryBase:    envDuration("DROME_DOWNLOAD_RETRY_BASE", 2*time.Minute),
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
	if cfg.MaxAttempts < 1 {
		cfg.MaxAttempts = 1
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

func envInt(key string, fallback int) int {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	var n int
	if _, err := fmt.Sscanf(v, "%d", &n); err != nil || n <= 0 {
		return fallback
	}
	return n
}

// downloadWorker serializes SpotiFLAC jobs so we don't hammer providers.
// The queue lives in SQLite, so jobs survive process restarts and outages.
type downloadWorker struct {
	cfg       downloadConfig
	store     *wishlistStore
	navidrome *navidromeVerifier
	spotify   *spotifyClient
	baseURL   string

	mu     sync.Mutex
	wake   chan struct{}
	closed bool
}

func newDownloadWorker(cfg downloadConfig, store *wishlistStore, navidrome *navidromeVerifier, spotify *spotifyClient, baseURL string) *downloadWorker {
	return &downloadWorker{
		cfg:       cfg,
		store:     store,
		navidrome: navidrome,
		spotify:   spotify,
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
	logf("auto-download enabled → %s via %s (%s); retag=%s maxAttempts=%d",
		w.cfg.MusicDir, w.cfg.SpotiflacBin, strings.Join(w.cfg.Services, ","),
		w.cfg.RetagBin, w.cfg.MaxAttempts)

	// Recover jobs interrupted by a previous restart; re-arm due retries.
	if n, err := w.store.requeueDownloading(); err != nil {
		logf("requeue downloading: %v", err)
	} else if n > 0 {
		logf("re-queued %d interrupted download(s)", n)
	}
	if n, err := w.store.requeueDueRetries(w.cfg.MaxAttempts); err != nil {
		logf("requeue retries: %v", err)
	} else if n > 0 {
		logf("re-queued %d failed download(s) ready for retry", n)
	}
	w.kick()

	ticker := time.NewTicker(45 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case _, ok := <-w.wake:
			if !ok {
				return
			}
		case <-ticker.C:
			if n, err := w.store.requeueDueRetries(w.cfg.MaxAttempts); err != nil {
				logf("requeue retries: %v", err)
			} else if n > 0 {
				logf("re-queued %d due retry download(s)", n)
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
	attempt := e.Attempts + 1
	logf("download start id=%d attempt=%d/%d %s %q — %q",
		e.ID, attempt, w.cfg.MaxAttempts, e.Kind, e.Artist, e.Title)
	_ = w.store.setStatus(e.ID, statusDownloading, "")

	ctx, cancel := context.WithTimeout(parent, w.cfg.Timeout)
	defer cancel()

	started := time.Now()
	if w.spotify != nil && e.Kind != "playlist" {
		w.spotify.completeEntry(ctx, e)
		if err := w.store.updateMetadata(e); err != nil {
			logf("update metadata id=%d: %v", e.ID, err)
		}
	}

	if e.Kind == "track" && w.alreadyHave(ctx, e.Title, e.Artist) {
		logf("skip download id=%d already have %q — %q", e.ID, e.Artist, e.Title)
		w.addEntryToNavidromePlaylist(ctx, e, false)
		if err := w.store.delete(e.ID); err != nil {
			_ = w.store.setStatus(e.ID, statusSkipped, "already in library")
		}
		return
	}

	if err := w.runSpotiflac(ctx, e.SpotifyURL); err != nil {
		w.fail(e, attempt, err)
		return
	}

	if err := w.retagRecent(ctx, e, started); err != nil {
		// Audio may already be on disk — still treat as failure so we retry
		// retag rather than deleting the wishlist row with broken tags.
		w.fail(e, attempt, fmt.Errorf("retag: %w", err))
		return
	}

	logf("download done id=%d — removing from wishlist", e.ID)
	if err := w.triggerScan(parent); err != nil {
		logf("navidrome scan trigger: %v (library will pick up on next scheduled scan)", err)
	}
	if e.Kind == "playlist" {
		w.syncWholePlaylist(parent, e)
	} else {
		w.addEntryToNavidromePlaylist(parent, e, true)
	}
	if err := w.store.delete(e.ID); err != nil {
		logf("delete completed wishlist entry id=%d: %v", e.ID, err)
		_ = w.store.setAcquired(e.ID, true)
		_ = w.store.setStatus(e.ID, statusDone, "")
	}
}

func (w *downloadWorker) fail(e *entry, attempt int, err error) {
	msg := truncate(err.Error(), 500)
	backoff := w.cfg.RetryBase * time.Duration(1<<min(attempt-1, 4))
	if backoff > 30*time.Minute {
		backoff = 30 * time.Minute
	}
	logf("download failed id=%d attempt=%d: %v (retry in %s)", e.ID, attempt, err, backoff)
	if markErr := w.store.markFailed(e.ID, msg, attempt, w.cfg.MaxAttempts, backoff); markErr != nil {
		logf("mark failed id=%d: %v", e.ID, markErr)
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
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

// retagRecent applies wishlist Spotify metadata onto files touched by the job
// so Navidrome never indexes Amazon ASINs / hex stubs as titles.
func (w *downloadWorker) retagRecent(ctx context.Context, e *entry, started time.Time) error {
	bin := w.cfg.RetagBin
	if bin == "" {
		return nil
	}
	if _, err := exec.LookPath(bin); err != nil {
		// Fall back to alongside the spotiflac wrapper / repo script.
		candidates := []string{
			"/usr/local/bin/drome-retag",
			filepath.Join(filepath.Dir(w.cfg.SpotiflacBin), "retag.py"),
			"retag.py",
		}
		found := ""
		for _, c := range candidates {
			if st, err := os.Stat(c); err == nil && !st.IsDir() {
				found = c
				break
			}
		}
		if found == "" {
			return fmt.Errorf("retag binary not found (%s)", bin)
		}
		bin = found
	}

	kind := e.Kind
	if kind != "album" && kind != "playlist" {
		kind = "track"
	}
	album := e.Album
	if album == "" && kind == "album" {
		album = e.Title
	}
	title, artist := e.Title, e.Artist
	albumArtist, upc := "", ""
	if kind != "playlist" && w.spotify != nil {
		albumArtist, upc = w.spotify.albumIdentity(ctx, e)
	}
	if albumArtist == "" {
		albumArtist = e.AlbumArtist
	}
	if albumArtist == "" {
		albumArtist = e.Artist
	}
	if kind == "playlist" {
		// SpotiFLAC pulled many albums; never stamp the playlist name on them.
		title, artist, album, albumArtist, upc = "", "", "", "", ""
	}

	args := []string{
		"--music-dir", w.cfg.MusicDir,
		"--kind", kind,
		"--title", title,
		"--artist", artist,
		"--album-artist", albumArtist,
		"--album", album,
		"--upc", upc,
		"--since-epoch", fmt.Sprintf("%d", started.Unix()),
	}
	var cmd *exec.Cmd
	if strings.HasSuffix(bin, ".py") {
		cmd = exec.CommandContext(ctx, "python3", append([]string{bin}, args...)...)
	} else {
		cmd = exec.CommandContext(ctx, bin, args...)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		out := strings.TrimSpace(stdout.String() + "\n" + stderr.String())
		return fmt.Errorf("%w: %s", err, truncate(out, 1000))
	}
	logf("retag ok id=%d: %s", e.ID, truncate(strings.TrimSpace(stdout.String()), 300))
	return nil
}

func (w *downloadWorker) alreadyHave(ctx context.Context, title, artist string) bool {
	if strings.TrimSpace(title) == "" {
		return false
	}
	if diskHasTrack(w.cfg.MusicDir, title, artist) {
		return true
	}
	if w.navidrome == nil {
		return false
	}
	user := os.Getenv("DROME_NAVIDROME_SCAN_USER")
	pass := os.Getenv("DROME_NAVIDROME_SCAN_PASSWORD")
	if user == "" || pass == "" {
		return false
	}
	salt := "drome-owns"
	return w.navidrome.libraryOwns(ctx, user, md5Hex(pass+salt), salt, title, artist)
}

func (w *downloadWorker) scanCreds() (subsonicCreds, bool) {
	user := os.Getenv("DROME_NAVIDROME_SCAN_USER")
	pass := os.Getenv("DROME_NAVIDROME_SCAN_PASSWORD")
	if user == "" || pass == "" {
		return subsonicCreds{}, false
	}
	salt := "drome-playlist"
	return subsonicCreds{user: user, token: md5Hex(pass + salt), salt: salt}, true
}

func (w *downloadWorker) addEntryToNavidromePlaylist(ctx context.Context, e *entry, waitForScan bool) {
	if w.navidrome == nil || e == nil || e.SourcePlaylistID == "" || strings.TrimSpace(e.Title) == "" {
		return
	}
	creds, ok := w.scanCreds()
	if !ok {
		return
	}
	plID, name, err := w.store.playlistMirror(e.Owner, e.SourcePlaylistID)
	if err != nil {
		logf("playlist mirror lookup: %v", err)
		return
	}
	if plID == "" {
		name = e.SourcePlaylistName
		if strings.TrimSpace(name) == "" {
			name = "Spotify playlist"
		}
		id, perr := w.navidrome.ensureNamedPlaylist(ctx, creds, name, e.Owner, true)
		if perr != nil {
			logf("ensure navidrome playlist %q: %v", name, perr)
			return
		}
		plID = id
		_ = w.store.upsertPlaylistMirror(e.Owner, e.SourcePlaylistID, plID, name)
	}
	attempts := 1
	if waitForScan {
		attempts = 8
	}
	var last error
	for i := 0; i < attempts; i++ {
		last = w.navidrome.addTrackToNamedPlaylist(ctx, creds, plID, e.Title, e.Artist)
		if last == nil {
			return
		}
		if i+1 == attempts {
			break
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(2 * time.Second):
		}
	}
	logf("add %q to playlist: %v", e.Title, last)
}

func (w *downloadWorker) syncWholePlaylist(ctx context.Context, e *entry) {
	if w.navidrome == nil || w.spotify == nil || e == nil {
		return
	}
	creds, ok := w.scanCreds()
	if !ok {
		return
	}
	name := e.SourcePlaylistName
	if name == "" {
		name = e.Title
	}
	spotifyID := e.SourcePlaylistID
	if spotifyID == "" {
		spotifyID = e.SpotifyID
	}
	_, tracks, err := w.spotify.playlistTracks(ctx, spotifyID)
	if err != nil || len(tracks) == 0 {
		logf("sync playlist %s: %v (%d tracks)", spotifyID, err, len(tracks))
		return
	}
	plID, _, merr := w.store.playlistMirror(e.Owner, spotifyID)
	if merr != nil {
		logf("playlist mirror lookup: %v", merr)
		return
	}
	if plID == "" {
		id, perr := w.navidrome.ensureNamedPlaylist(ctx, creds, name, e.Owner, true)
		if perr != nil {
			logf("ensure navidrome playlist %q: %v", name, perr)
			return
		}
		plID = id
		_ = w.store.upsertPlaylistMirror(e.Owner, spotifyID, plID, name)
	}
	have, _ := w.navidrome.playlistSongIDs(ctx, creds, plID)
	var toAdd []string
	for i := 0; i < 6; i++ {
		toAdd = toAdd[:0]
		for _, t := range tracks {
			sid := w.navidrome.findSongID(ctx, creds.user, creds.token, creds.salt, t.Title, t.Artist)
			if sid == "" {
				continue
			}
			if _, ok := have[sid]; ok {
				continue
			}
			toAdd = append(toAdd, sid)
			have[sid] = struct{}{}
		}
		if len(toAdd) > 0 || i == 5 {
			break
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(2 * time.Second):
		}
	}
	if err := w.navidrome.addSongsToPlaylist(ctx, creds, plID, toAdd); err != nil {
		logf("sync playlist %q add: %v", name, err)
		return
	}
	logf("synced %d tracks into navidrome playlist %q", len(have), name)
}

// triggerScan asks Navidrome to rescan via the OpenSubsonic startScan endpoint
// using optional admin credentials. If unset, we rely on ND_SCANSCHEDULE.
func (w *downloadWorker) triggerScan(ctx context.Context) error {
	user := os.Getenv("DROME_NAVIDROME_SCAN_USER")
	pass := os.Getenv("DROME_NAVIDROME_SCAN_PASSWORD")
	if user == "" || pass == "" {
		return fmt.Errorf("DROME_NAVIDROME_SCAN_USER/PASSWORD not set")
	}

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
