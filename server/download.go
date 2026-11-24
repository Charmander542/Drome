package main

import (
	"bytes"
	"context"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
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
	GenreBin     string
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
		SpotiflacBin: envOr("DROME_SPOTIFLAC_BIN", "mornye"),
		RetagBin:     envOr("DROME_RETAG_BIN", "drome-retag"),
		GenreBin:     envOr("DROME_GENRE_BIN", "drome-genre-tag"),
		Timeout:      envDuration("DROME_DOWNLOAD_TIMEOUT", 45*time.Minute),
		MaxAttempts:  envInt("DROME_DOWNLOAD_MAX_ATTEMPTS", 5),
		RetryBase:    envDuration("DROME_DOWNLOAD_RETRY_BASE", 2*time.Minute),
	}
	raw := envOr("DROME_SPOTIFLAC_SERVICES", "tidal,qobuz,amazon,deezer,youtube")
	for _, part := range strings.Split(raw, ",") {
		part = strings.TrimSpace(part)
		if part != "" {
			cfg.Services = append(cfg.Services, part)
		}
	}
	if len(cfg.Services) == 0 {
		cfg.Services = []string{"tidal", "qobuz", "amazon", "youtube"}
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

	// Pace Mornye jobs so the signed-session / link-resolver APIs (api.zarz.moe)
	// don't 429 mid-queue and make every subsequent provider look "not found".
	jobGap time.Duration

	// Live progress for GET /wishlist/downloads (and status_msg on the active row).
	progress progressState
}

func newDownloadWorker(cfg downloadConfig, store *wishlistStore, navidrome *navidromeVerifier, spotify *spotifyClient, baseURL string) *downloadWorker {
	return &downloadWorker{
		cfg:       cfg,
		store:     store,
		navidrome: navidrome,
		spotify:   spotify,
		baseURL:   baseURL,
		wake:      make(chan struct{}, 1),
		jobGap:    envDuration("DROME_DOWNLOAD_JOB_GAP", 8*time.Second),
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
			if w.jobGap > 0 {
				select {
				case <-ctx.Done():
					return
				case <-time.After(w.jobGap):
				}
			}
		}
	}
}

func (w *downloadWorker) process(parent context.Context, e *entry) {
	attempt := e.Attempts + 1

	// Legacy whole-album / whole-playlist jobs expand without SpotiFLAC, so do
	// that before provider-cooldown gating (no Turnstile needed to list tracks).
	if e.Kind == "album" || e.Kind == "playlist" {
		logf("download expand id=%d %s %q — %q", e.ID, e.Kind, e.Artist, e.Title)
		_ = w.store.setStatus(e.ID, statusDownloading, "expanding to per-track downloads")
		ctx, cancel := context.WithTimeout(parent, 2*time.Minute)
		defer cancel()
		n, err := w.expandGroupedEntry(ctx, e)
		if err != nil {
			w.fail(e, attempt, err)
			return
		}
		logf("expanded %s id=%d into %d track download(s); removing parent", e.Kind, e.ID, n)
		if err := w.store.delete(e.ID); err != nil {
			_ = w.store.setStatus(e.ID, statusDone, fmt.Sprintf("expanded to %d tracks", n))
		}
		w.kick()
		return
	}

	// Respect SpotiFLAC verification cooldowns before burning an attempt.
	if wait := w.providerCooldownRemaining(); wait > 0 {
		msg := fmt.Sprintf("waiting for SpotiFLAC verification slot (%s)", wait.Round(time.Second))
		logf("download defer id=%d attempt=%d/%d %s — cooldown %s",
			e.ID, e.Attempts, w.cfg.MaxAttempts, e.Title, wait.Round(time.Second))
		if err := w.store.scheduleRetry(e.ID, msg, e.Attempts, wait); err != nil {
			logf("schedule cooldown retry id=%d: %v", e.ID, err)
		}
		return
	}

	logf("download start id=%d attempt=%d/%d %s %q — %q",
		e.ID, attempt, w.cfg.MaxAttempts, e.Kind, e.Artist, e.Title)
	w.beginProgress(e, attempt)
	defer w.endProgress()
	_ = w.store.setStatus(e.ID, statusDownloading, "starting")

	ctx, cancel := context.WithTimeout(parent, w.cfg.Timeout)
	defer cancel()

	started := time.Now()
	if w.spotify != nil && e.Kind != "playlist" {
		w.setPhase("metadata", "resolving Spotify metadata")
		w.spotify.completeEntry(ctx, e)
		if err := w.store.updateMetadata(e); err != nil {
			logf("update metadata id=%d: %v", e.ID, err)
		}
	}

	if e.Kind == "track" && w.alreadyHave(ctx, e.Title, e.Artist) {
		logf("skip download id=%d already have %q — %q", e.ID, e.Artist, e.Title)
		w.setPhase("skipped", "already in library")
		w.addEntryToNavidromePlaylist(ctx, e, false)
		w.syncSourcePlaylistArtifacts(ctx, e)
		if err := w.store.delete(e.ID); err != nil {
			_ = w.store.setStatus(e.ID, statusSkipped, "already in library")
		}
		return
	}

	w.setPhase("spotiflac", "running SpotiFLAC")
	if err := w.runSpotiflac(ctx, e.SpotifyURL); err != nil {
		w.fail(e, attempt, err)
		return
	}

	w.setPhase("retag", "applying Spotify tags")
	if err := w.retagRecent(ctx, e, started); err != nil {
		// Audio may already be on disk — still treat as failure so we retry
		// retag rather than deleting the wishlist row with broken tags.
		w.fail(e, attempt, fmt.Errorf("retag: %w", err))
		return
	}

	w.setPhase("genre", "looking up genre")
	if err := w.tagGenreRecent(ctx, e, started); err != nil {
		// Genre is best-effort — don't fail the download over a Discogs blip.
		logf("genre tag id=%d: %v", e.ID, err)
	}

	// Amazon stages as {ASIN}.flac; if rename/embed was soft-failed upstream,
	// drop dupes next to a good file or fail so we don't keep B0… / Unknown tracks.
	w.setPhase("cleanup", "checking for leftover ASINs")
	if err := cleanupRecentASINLeftovers(w.cfg.MusicDir, started); err != nil {
		w.fail(e, attempt, err)
		return
	}

	logf("download done id=%d — removing from wishlist", e.ID)
	w.setPhase("scan", "triggering Navidrome scan")
	if err := w.triggerScan(parent); err != nil {
		logf("navidrome scan trigger: %v (library will pick up on next scheduled scan)", err)
	}
	w.setPhase("finishing", "syncing playlists")
	if e.Kind == "playlist" {
		w.syncWholePlaylist(parent, e)
	} else {
		w.addEntryToNavidromePlaylist(parent, e, true)
	}
	w.syncSourcePlaylistArtifacts(parent, e)
	if err := w.store.delete(e.ID); err != nil {
		logf("delete completed wishlist entry id=%d: %v", e.ID, err)
		_ = w.store.setAcquired(e.ID, true)
		_ = w.store.setStatus(e.ID, statusDone, "")
	}
}

// expandGroupedEntry turns a whole-album / whole-playlist wishlist row into
// per-track queued downloads so each song retries independently.
func (w *downloadWorker) expandGroupedEntry(ctx context.Context, e *entry) (int, error) {
	if w.spotify == nil {
		return 0, fmt.Errorf("spotify client unavailable to expand %s", e.Kind)
	}
	var (
		name        string
		albumArtist string
		cover       string
		tracks      []playlistTrack
		err         error
	)
	switch e.Kind {
	case "album":
		name, albumArtist, cover, tracks, err = w.spotify.albumTracks(ctx, e.SpotifyID)
	case "playlist":
		name, tracks, err = w.spotify.playlistTracks(ctx, e.SpotifyID)
	default:
		return 0, fmt.Errorf("cannot expand kind %q", e.Kind)
	}
	if err != nil {
		return 0, err
	}
	if name == "" {
		name = e.Title
	}
	if name == "" {
		name = "Spotify " + e.Kind
	}
	status := statusQueued
	if !w.cfg.Enabled {
		status = statusSkipped
	}
	now := time.Now()
	added := 0
	for _, t := range tracks {
		if strings.TrimSpace(t.Title) == "" || t.SpotifyID == "" {
			continue
		}
		if w.alreadyHave(ctx, t.Title, t.Artist) {
			continue
		}
		if existing, err := w.store.findActiveByTitleArtist(e.Owner, "track", t.Title, t.Artist); err == nil && existing != nil {
			continue
		}
		if t.Album == "" && e.Kind == "album" {
			t.Album = name
		}
		if t.AlbumArtist == "" {
			t.AlbumArtist = albumArtist
		}
		if t.CoverURL == "" {
			t.CoverURL = cover
		}
		te := entry{
			Owner:              e.Owner,
			Kind:               "track",
			SpotifyID:          t.SpotifyID,
			SpotifyURL:         t.SpotifyURL,
			Title:              t.Title,
			Artist:             t.Artist,
			AlbumArtist:        t.AlbumArtist,
			Album:              t.Album,
			CoverURL:           t.CoverURL,
			Status:             status,
			SourcePlaylistID:   e.SpotifyID,
			SourcePlaylistName: name,
			CreatedAt:          now,
		}
		if te.SpotifyURL == "" {
			te.SpotifyURL = "https://open.spotify.com/track/" + t.SpotifyID
		}
		if err := w.store.insert(&te); err != nil {
			logf("expand insert track %s: %v", t.SpotifyID, err)
			continue
		}
		added++
	}
	if e.Kind == "playlist" {
		w.ensurePlaylistMirror(ctx, e.Owner, e.SpotifyID, name)
		if path, err := w.writePlaylistFileNow(ctx, e.Owner, e.SpotifyID, name); err != nil {
			logf("write playlist file %q: %v", name, err)
		} else if path != "" {
			logf("playlist file ready %q → %s", name, path)
		}
	}
	if added == 0 && len(tracks) > 0 {
		// Everything already owned / queued — still treat expand as success.
		return 0, nil
	}
	if added == 0 {
		return 0, fmt.Errorf("%s %s expanded to 0 tracks", e.Kind, e.SpotifyID)
	}
	return added, nil
}

func (w *downloadWorker) fail(e *entry, attempt int, err error) {
	msg := truncate(err.Error(), 500)
	backoff := w.retryBackoff(attempt, err.Error())
	logf("download failed id=%d attempt=%d: %v (retry in %s)", e.ID, attempt, err, backoff.Round(time.Second))
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

func maxDuration(a, b time.Duration) time.Duration {
	if a > b {
		return a
	}
	return b
}

// retryBackoff picks the later of exponential backoff and any SpotiFLAC
// provider verification cooldown parsed from the error / local backoff files.
func (w *downloadWorker) retryBackoff(attempt int, errMsg string) time.Duration {
	exp := w.cfg.RetryBase * time.Duration(1<<min(attempt-1, 4))
	if exp > 30*time.Minute {
		exp = 30 * time.Minute
	}
	provider := maxDuration(parseProviderRetryAfter(errMsg), w.providerCooldownRemaining())
	if provider > 0 {
		provider += 30 * time.Second // wake slightly after not_before
	}
	if provider > exp {
		if provider > 2*time.Hour {
			provider = 2 * time.Hour
		}
		return provider
	}
	return exp
}

func (w *downloadWorker) spotiflacHome() string {
	// Mornye stores extensions + signed sessions under ~/.mornye (or
	// $MORNYE_DATA_DIR). Fall back to the legacy SpotiFLAC path.
	if d := strings.TrimSpace(os.Getenv("MORNYE_DATA_DIR")); d != "" {
		return d
	}
	if h := strings.TrimSpace(os.Getenv("HOME")); h != "" {
		mornye := filepath.Join(h, ".mornye")
		if st, err := os.Stat(mornye); err == nil && st.IsDir() {
			return mornye
		}
		legacy := filepath.Join(h, ".spotiflac")
		if st, err := os.Stat(legacy); err == nil && st.IsDir() {
			return legacy
		}
		return mornye
	}
	return "/home/drome/.mornye"
}

func (w *downloadWorker) providerCooldownRemaining() time.Duration {
	return spotiflacAuthBackoffRemaining(w.spotiflacHome(), time.Now())
}

var providerRetryAfterRe = regexp.MustCompile(`(?i)(?:next try in|verification paused)\s*(?:after a failed attempt[^0-9]{0,60})?(\d+)\s*(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b`)

// parseProviderRetryAfter extracts the longest "next try in N min" style delay
// from SpotiFLAC / extension error text.
func parseProviderRetryAfter(msg string) time.Duration {
	clean := stripANSI(msg)
	var best time.Duration
	for _, m := range providerRetryAfterRe.FindAllStringSubmatch(clean, -1) {
		if len(m) < 3 {
			continue
		}
		n, err := strconv.Atoi(m[1])
		if err != nil || n <= 0 {
			continue
		}
		unit := strings.ToLower(m[2])
		var d time.Duration
		switch {
		case strings.HasPrefix(unit, "h"):
			d = time.Duration(n) * time.Hour
		case strings.HasPrefix(unit, "m"):
			d = time.Duration(n) * time.Minute
		default:
			d = time.Duration(n) * time.Second
		}
		if d > best {
			best = d
		}
	}
	return best
}

type authBackoffFile struct {
	Failures  int     `json:"failures"`
	NotBefore float64 `json:"not_before"`
}

// spotiflacAuthBackoffRemaining returns how long until local SpotiFLAC
// signed-session auth backoff files allow another verification attempt.
func spotiflacAuthBackoffRemaining(spotiflacHome string, now time.Time) time.Duration {
	dir := filepath.Join(spotiflacHome, "signed_sessions")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0
	}
	var best time.Duration
	for _, ent := range entries {
		name := ent.Name()
		if ent.IsDir() || !strings.Contains(name, "auth-backoff") || !strings.HasSuffix(name, ".json") {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			continue
		}
		var ab authBackoffFile
		if err := json.Unmarshal(raw, &ab); err != nil || ab.NotBefore <= 0 {
			continue
		}
		until := time.Unix(int64(ab.NotBefore), int64((ab.NotBefore-float64(int64(ab.NotBefore)))*1e9))
		if rem := until.Sub(now); rem > best {
			best = rem
		}
	}
	if best < 0 {
		return 0
	}
	return best
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
	cmd.Env = append(os.Environ(), "PYTHONUNBUFFERED=1")

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("spotiflac stdout: %w", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("spotiflac stderr: %w", err)
	}

	started := time.Now().Add(-2 * time.Second)
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("spotiflac: %w", err)
	}

	var (
		capture   strings.Builder
		captureMu sync.Mutex
		wg        sync.WaitGroup
	)
	wg.Add(2)
	go func() {
		defer wg.Done()
		w.readProgressStream(stdout, &capture, &captureMu)
	}()
	go func() {
		defer wg.Done()
		w.readProgressStream(stderr, &capture, &captureMu)
	}()
	wg.Wait()
	err = cmd.Wait()

	out := strings.TrimSpace(capture.String())
	if soft := spotiflacSoftFailure(out); soft != "" {
		// SpotiFLAC (and older wrappers) often exit 0 after "Successful: 0".
		// Prefer the soft reason; append only the useful tail (not the banner).
		tail := truncate(spotiflacFailureTail(out), 800)
		if tail != "" {
			return fmt.Errorf("spotiflac: %s\n%s", soft, tail)
		}
		return fmt.Errorf("spotiflac: %s", soft)
	}
	if err != nil {
		if out == "" {
			return fmt.Errorf("spotiflac: %w", err)
		}
		return fmt.Errorf("spotiflac: %w\n%s", err, truncate(out, 2000))
	}
	// Silent no-op (no extensions / no summary): treat as failure so retag
	// is not blamed for empty output.
	if !recentAudioExists(w.cfg.MusicDir, started) {
		detail := "no audio files written"
		if soft := strings.TrimSpace(out); soft != "" {
			detail = truncate(soft, 500)
		}
		return fmt.Errorf("spotiflac: %s", detail)
	}
	return nil
}

func recentAudioExists(root string, since time.Time) bool {
	cutoff := since.Unix()
	found := false
	_ = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		ext := strings.ToLower(filepath.Ext(path))
		switch ext {
		case ".flac", ".m4a", ".mp3", ".ogg", ".opus", ".wav", ".aiff":
		default:
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		if info.ModTime().Unix() >= cutoff {
			found = true
			return fs.SkipAll
		}
		return nil
	})
	return found
}

// spotiflacSoftFailure detects session summaries where every track failed but
// the process still exited 0. Returns a short reason, or "" if OK / inconclusive.
func spotiflacSoftFailure(out string) string {
	clean := stripANSI(out)
	if !strings.Contains(clean, "Successful") {
		return ""
	}
	for _, line := range strings.Split(clean, "\n") {
		line = strings.TrimSpace(strings.TrimPrefix(line, "║"))
		line = strings.TrimSpace(strings.TrimSuffix(line, "║"))
		if !strings.HasPrefix(line, "Successful") {
			continue
		}
		// "Successful    : 0"
		parts := strings.SplitN(line, ":", 2)
		if len(parts) != 2 {
			continue
		}
		n := strings.TrimSpace(parts[1])
		if n == "0" {
			for _, l := range strings.Split(clean, "\n") {
				l = strings.TrimSpace(l)
				if strings.Contains(l, "All providers failed") || strings.Contains(l, "Failed:") {
					return truncate(l, 400)
				}
			}
			return "0 successful downloads (providers failed)"
		}
	}
	return ""
}

// spotiflacFailureTail keeps the last provider-failure lines from a noisy log.
func spotiflacFailureTail(out string) string {
	clean := stripANSI(out)
	var keep []string
	for _, line := range strings.Split(clean, "\n") {
		l := strings.TrimSpace(line)
		if l == "" {
			continue
		}
		if strings.Contains(l, "All providers failed") ||
			strings.Contains(l, "Failed:") ||
			strings.Contains(l, "Track not available") ||
			strings.Contains(l, "No verified") ||
			strings.Contains(l, "not_found") ||
			strings.Contains(l, "RATE_LIMITED") ||
			strings.Contains(l, "UNAVAILABLE") ||
			strings.Contains(l, "AUTH_FAILED") ||
			strings.Contains(l, "Turnstile") ||
			strings.Contains(l, "verification paused") ||
			strings.Contains(l, "not installed") ||
			strings.Contains(l, "No registry") {
			keep = append(keep, l)
		}
	}
	if len(keep) == 0 {
		return ""
	}
	if len(keep) > 8 {
		keep = keep[len(keep)-8:]
	}
	return strings.Join(keep, "\n")
}

func stripANSI(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for i := 0; i < len(s); i++ {
		if s[i] == 0x1b && i+1 < len(s) && s[i+1] == '[' {
			i += 2
			for i < len(s) {
				c := s[i]
				if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') {
					break
				}
				i++
			}
			continue
		}
		if s[i] == '\r' {
			continue
		}
		b.WriteByte(s[i])
	}
	return b.String()
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

// tagGenreRecent writes curated GENRE tags onto files touched by this download
// using Discogs (primary) / MusicBrainz / Deezer lookups.
func (w *downloadWorker) tagGenreRecent(ctx context.Context, e *entry, started time.Time) error {
	bin := w.cfg.GenreBin
	if bin == "" {
		return nil
	}
	if _, err := exec.LookPath(bin); err != nil {
		candidates := []string{
			"/usr/local/bin/drome-genre-tag",
			filepath.Join(filepath.Dir(w.cfg.SpotiflacBin), "genre_tag.py"),
			"genre_tag.py",
		}
		found := ""
		for _, c := range candidates {
			if st, err := os.Stat(c); err == nil && !st.IsDir() {
				found = c
				break
			}
		}
		if found == "" {
			return fmt.Errorf("genre binary not found (%s)", bin)
		}
		bin = found
	}

	args := []string{
		"--music-dir", w.cfg.MusicDir,
		"--since-epoch", fmt.Sprintf("%d", started.Unix()),
	}
	if artist := strings.TrimSpace(e.AlbumArtist); artist != "" {
		args = append(args, "--artist", artist)
	} else if artist := strings.TrimSpace(e.Artist); artist != "" {
		// Primary only — genre lookup strips feat. credits too.
		if i := strings.Index(strings.ToLower(artist), " feat"); i > 0 {
			artist = strings.TrimSpace(artist[:i])
		}
		args = append(args, "--artist", artist)
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
		return fmt.Errorf("%w: %s", err, truncate(out, 500))
	}
	if msg := strings.TrimSpace(stdout.String()); msg != "" {
		logf("genre ok id=%d: %s", e.ID, truncate(msg, 300))
	}
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

// ensurePlaylistMirror creates a public Navidrome playlist for the Spotify
// import when one is not mirrored yet. Prefer the scan user (admin) so songs
// can keep being appended during background downloads; the playlist is public
// so everyone can see the requester's import.
func (w *downloadWorker) ensurePlaylistMirror(ctx context.Context, owner, spotifyID, name string) {
	if w == nil || w.navidrome == nil || spotifyID == "" {
		return
	}
	name = strings.TrimSpace(name)
	if name == "" {
		name = "Spotify playlist"
	}
	if plID, _, err := w.store.playlistMirror(owner, spotifyID); err == nil && plID != "" {
		return
	}
	creds, ok := w.scanCreds()
	if !ok {
		return
	}
	id, _, err := w.navidrome.ensureNamedPlaylist(ctx, creds, name, owner, true)
	if err != nil {
		logf("ensure navidrome playlist %q: %v", name, err)
		return
	}
	if err := w.store.upsertPlaylistMirror(owner, spotifyID, id, name); err != nil {
		logf("save playlist mirror: %v", err)
	}
}

// writePlaylistFileNow rebuilds Playlists/<name>.m3u8 from Spotify order when
// possible, otherwise from on-disk album folders matching the playlist name.
func (w *downloadWorker) writePlaylistFileNow(ctx context.Context, owner, spotifyID, name string) (string, error) {
	if w == nil || w.cfg.MusicDir == "" {
		return "", nil
	}
	name = strings.TrimSpace(name)
	if name == "" {
		name = "Spotify playlist"
	}
	var tracks []playlistFileTrack
	if w.spotify != nil && spotifyID != "" {
		spotName, spotTracks, err := w.spotify.playlistTracks(ctx, spotifyID)
		if err == nil {
			if strings.TrimSpace(spotName) != "" {
				name = spotName
			}
			tracks = buildPlaylistFileTracks(w.cfg.MusicDir, spotTracks)
		} else {
			logf("playlist file %q: spotify list: %v", name, err)
		}
	}
	if len(tracks) == 0 {
		tracks = playlistFileTracksNamedAlbum(w.cfg.MusicDir, name)
	}
	if len(tracks) == 0 {
		return "", nil
	}
	path, err := writeLibraryPlaylist(w.cfg.MusicDir, name, tracks)
	if err != nil {
		return "", err
	}
	if path != "" {
		logf("playlist file ready %q → %s (%d tracks) owner=%s", name, path, len(tracks), owner)
	}
	return path, nil
}

// syncSourcePlaylistArtifacts refreshes the on-disk .m3u8 (always) and ensures
// a Navidrome mirror exists when scan credentials are configured. A full
// Spotify-ordered rewrite runs when no more active downloads remain for the
// source playlist; otherwise we still refresh from whatever is already on disk.
func (w *downloadWorker) syncSourcePlaylistArtifacts(ctx context.Context, e *entry) {
	if w == nil || e == nil || e.SourcePlaylistID == "" {
		return
	}
	name := e.SourcePlaylistName
	if strings.TrimSpace(name) == "" {
		name = "Spotify playlist"
	}
	w.ensurePlaylistMirror(ctx, e.Owner, e.SourcePlaylistID, name)
	remaining, err := w.store.countActiveBySourcePlaylist(e.Owner, e.SourcePlaylistID)
	if err != nil {
		logf("count active playlist downloads: %v", err)
	}
	// remaining still includes the current row until delete — treat <=1 as done.
	if remaining <= 1 {
		if _, werr := w.writePlaylistFileNow(ctx, e.Owner, e.SourcePlaylistID, name); werr != nil {
			logf("write playlist file %q: %v", name, werr)
		}
		return
	}
	// Incremental: keep the file growing from album-folder contents so the
	// playlist is usable before the full download finishes.
	tracks := playlistFileTracksNamedAlbum(w.cfg.MusicDir, name)
	if len(tracks) == 0 {
		return
	}
	if path, werr := writeLibraryPlaylist(w.cfg.MusicDir, name, tracks); werr != nil {
		logf("write playlist file %q: %v", name, werr)
	} else if path != "" {
		logf("playlist file updated %q → %s (%d tracks, %d still queued)", name, path, len(tracks), remaining-1)
	}
}

func (w *downloadWorker) addEntryToNavidromePlaylist(ctx context.Context, e *entry, waitForScan bool) {
	if w.navidrome == nil || e == nil || e.SourcePlaylistID == "" || strings.TrimSpace(e.Title) == "" {
		return
	}
	creds, ok := w.scanCreds()
	if !ok {
		// Still write the .m3u8 so the playlist appears after Navidrome's next scan.
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
		id, _, perr := w.navidrome.ensureNamedPlaylist(ctx, creds, name, e.Owner, true)
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
		id, _, perr := w.navidrome.ensureNamedPlaylist(ctx, creds, name, e.Owner, true)
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
