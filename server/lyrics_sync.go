package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	"unicode"
)

const lrclibBase = "https://lrclib.net/api"

// Reject synced LRCLIB hits whose duration differs from the library file by
// more than this — radio edits vs album cuts (e.g. BDKMV 214s vs 311s).
const lrclibMaxDurationDeltaSec = 3.0

var (
	enhancedWordStampRe = regexp.MustCompile(`<\d{1,2}:\d{1,2}(?:[.:]\d{1,3})?>`)
	lineStampRe         = regexp.MustCompile(`\[\d{1,2}:\d{1,2}(?:[.:]\d{1,3})?\]`)
	dromeLrclibIDRe     = regexp.MustCompile(`(?i)\[drome-lrclib-id:(\d+)\]`)
	dromeLrclibDurRe    = regexp.MustCompile(`(?i)\[drome-lrclib-duration:([0-9]+(?:\.[0-9]+)?)\]`)
	audioExtsForLyrics  = map[string]bool{
		".flac": true, ".m4a": true, ".mp3": true, ".ogg": true, ".opus": true, ".wav": true, ".aiff": true,
	}
)

type lrclibResult struct {
	ID           int      `json:"id"`
	TrackName    string   `json:"trackName"`
	ArtistName   string   `json:"artistName"`
	AlbumName    string   `json:"albumName"`
	Duration     *float64 `json:"duration"`
	Instrumental *bool    `json:"instrumental"`
	HasWordSync  *bool    `json:"hasWordSync"`
	PlainLyrics  string   `json:"plainLyrics"`
	SyncedLyrics string   `json:"syncedLyrics"`
	Lyricsfile   string   `json:"lyricsfile"`
}

type lyricsSyncConfig struct {
	Enabled       bool
	Backfill      bool
	Delay         time.Duration
	HTTPTimeout   time.Duration
	UserAgent     string
	StateFile     string
	MaxBackfill   int // 0 = unlimited
	Align         lyricsAlignConfig
}

func lyricsSyncConfigFromEnv(musicDir, dbPath string) lyricsSyncConfig {
	enabled := strings.ToLower(envOr("DROME_LYRICS_SYNC", "true"))
	backfill := strings.ToLower(envOr("DROME_LYRICS_BACKFILL", "true"))
	state := envOr("DROME_LYRICS_BACKFILL_STATE", "")
	if state == "" {
		// v3 re-walks so sidecars pick up millisecond stamps and optional
		// per-word CTC alignment jobs (v2 only upgraded lyricsfile).
		state = filepath.Join(filepath.Dir(dbPath), "lyrics-backfill-v3.done")
	}
	return lyricsSyncConfig{
		Enabled:     enabled == "1" || enabled == "true" || enabled == "yes",
		Backfill:    backfill == "1" || backfill == "true" || backfill == "yes",
		Delay:       envDuration("DROME_LYRICS_SYNC_DELAY", 400*time.Millisecond),
		HTTPTimeout: envDuration("DROME_LYRICS_HTTP_TIMEOUT", 20*time.Second),
		UserAgent:   envOr("DROME_LYRICS_USER_AGENT", "DromeServer/1.0 (LRCLIB sidecar sync)"),
		StateFile:   state,
		MaxBackfill: envInt("DROME_LYRICS_BACKFILL_MAX", 0),
		Align:       lyricsAlignConfigFromEnv(),
	}
}

type lyricsSyncer struct {
	cfg      lyricsSyncConfig
	musicDir string
	client   *http.Client
	index    *lyricsIndex
	alignQ   *lyricsAlignQueue
}

func newLyricsSyncer(cfg lyricsSyncConfig, musicDir string, index *lyricsIndex) *lyricsSyncer {
	s := &lyricsSyncer{
		cfg:      cfg,
		musicDir: musicDir,
		index:    index,
		client: &http.Client{
			Timeout: cfg.HTTPTimeout,
		},
	}
	if cfg.Align.Enabled {
		s.alignQ = newLyricsAlignQueue(cfg.Align)
	}
	return s
}

func (s *lyricsSyncer) runAlignWorker(ctx context.Context) {
	if s != nil && s.alignQ != nil {
		s.alignQ.runWorker(ctx)
	}
}

func lrcPathForAudio(audioPath string) string {
	return strings.TrimSuffix(audioPath, filepath.Ext(audioPath)) + ".lrc"
}

func hasWordSync(lrc string) bool {
	return enhancedWordStampRe.MatchString(lrc)
}

func hasLineSync(lrc string) bool {
	return lineStampRe.MatchString(lrc)
}

func lyricsQuality(lrc string) int {
	switch {
	case hasWordSync(lrc):
		return 3
	case hasLineSync(lrc):
		return 2
	case strings.TrimSpace(lrc) != "":
		return 1
	default:
		return 0
	}
}

// syncRecentAfterDownload writes LRCLIB synced .lrc next to files touched by this job.
func (s *lyricsSyncer) syncRecentAfterDownload(ctx context.Context, title, artist, album string, since time.Time) {
	if s == nil || !s.cfg.Enabled {
		return
	}
	paths := recentAudioPaths(s.musicDir, since)
	if len(paths) == 0 {
		return
	}
	wrote := 0
	for _, audio := range paths {
		t, a, al := title, artist, album
		if t == "" || a == "" {
			ia, ial, it := inferMetaFromPath(s.musicDir, audio)
			if t == "" {
				t = it
			}
			if a == "" {
				a = ia
			}
			if al == "" {
				al = ial
			}
		}
		if t == "" {
			continue
		}
		ok, err := s.syncAudioFile(ctx, audio, t, a, al, 0)
		if err != nil {
			logf("lyrics sync %s: %v", filepath.Base(audio), err)
			continue
		}
		if ok {
			wrote++
		}
		if err := sleepCtx(ctx, s.cfg.Delay); err != nil {
			return
		}
	}
	if wrote > 0 {
		logf("lyrics sync: wrote %d sidecar(s) for recent download", wrote)
		if s.index != nil {
			_ = s.index.rebuild()
		}
	}
}

func (s *lyricsSyncer) runBackfill(ctx context.Context) {
	if s == nil || !s.cfg.Enabled || !s.cfg.Backfill {
		return
	}
	if _, err := os.Stat(s.cfg.StateFile); err == nil {
		logf("lyrics backfill: already completed (%s)", s.cfg.StateFile)
		return
	}
	logf("lyrics backfill: starting library walk in %s", s.musicDir)
	n, err := s.backfillLibrary(ctx)
	if err != nil {
		if errors.Is(err, context.Canceled) {
			logf("lyrics backfill: canceled after %d writes", n)
			return
		}
		logf("lyrics backfill: stopped after %d writes: %v", n, err)
		return
	}
	if err := os.MkdirAll(filepath.Dir(s.cfg.StateFile), 0o755); err != nil {
		logf("lyrics backfill: mark done mkdir: %v", err)
		return
	}
	payload := fmt.Sprintf("completed=%s writes=%d\n", time.Now().UTC().Format(time.RFC3339), n)
	if err := os.WriteFile(s.cfg.StateFile, []byte(payload), 0o644); err != nil {
		logf("lyrics backfill: mark done: %v", err)
		return
	}
	logf("lyrics backfill: finished (%d sidecars written)", n)
	if s.index != nil {
		_ = s.index.rebuild()
	}
}

func (s *lyricsSyncer) backfillLibrary(ctx context.Context) (int, error) {
	var writes int
	err := filepath.WalkDir(s.musicDir, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return nil
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if d.IsDir() {
			name := d.Name()
			if strings.HasPrefix(name, ".") || strings.EqualFold(name, "Playlists") {
				if path != s.musicDir {
					return filepath.SkipDir
				}
			}
			return nil
		}
		ext := strings.ToLower(filepath.Ext(d.Name()))
		if !audioExtsForLyrics[ext] {
			return nil
		}
		artist, album, title := inferMetaFromPath(s.musicDir, path)
		if title == "" {
			return nil
		}
		ok, err := s.syncAudioFile(ctx, path, title, artist, album, 0)
		if err != nil {
			logf("lyrics backfill %s: %v", filepath.Base(path), err)
		} else if ok {
			writes++
			if s.cfg.MaxBackfill > 0 && writes >= s.cfg.MaxBackfill {
				return fs.SkipAll
			}
		}
		return sleepCtx(ctx, s.cfg.Delay)
	})
	if errors.Is(err, fs.SkipAll) {
		err = nil
	}
	return writes, err
}

func (s *lyricsSyncer) syncAudioFile(ctx context.Context, audioPath, title, artist, album string, durationSec int) (bool, error) {
	lrcPath := lrcPathForAudio(audioPath)
	existing := ""
	if raw, err := os.ReadFile(lrcPath); err == nil {
		existing = string(raw)
	}
	wrote := false
	// Sidecar stamped for a different cut (e.g. 214s radio vs 311s album) must
	// not short-circuit — force a duration-aware refetch.
	if lyricsQuality(existing) >= 3 && !sidecarDurationMatchesTrack(existing, durationSec) {
		logf("lyrics sync invalidating mismatched-duration sidecar for %q — %q (track %ds)",
			artist, title, durationSec)
		existing = ""
	}
	if lyricsQuality(existing) >= 3 {
		// Already word-synced for this duration — upgrade stamp precision and
		// optionally enqueue per-word CTC refine.
		if changed, err := rewriteSidecarPrecision(lrcPath); err != nil {
			return false, err
		} else if changed {
			wrote = true
			logf("lyrics sync upgraded stamp precision for %q — %q", artist, title)
		}
		s.maybeAlign(audioPath, lrcPath)
		return wrote, nil
	}

	hit, err := s.fetchBest(ctx, title, artist, album, durationSec)
	if err != nil {
		return false, err
	}
	if hit == nil {
		return false, nil
	}
	content := effectiveSyncedLyrics(*hit)
	if content == "" {
		return false, nil // never write plain text — blocks better sync later
	}
	if lyricsQuality(content) <= lyricsQuality(existing) {
		return false, nil
	}
	content = ensureMillisecondStamps(content)
	content = stampLrclibProvenance(content, hit)
	if err := os.WriteFile(lrcPath, []byte(ensureTrailingNewline(content)), 0o644); err != nil {
		return false, err
	}
	kind := "line"
	if hasWordSync(content) {
		kind = "word"
	}
	logf("lyrics sync wrote %s (%s, id=%d, dur=%.0fs) for %q — %q",
		filepath.Base(lrcPath), kind, hit.ID, derefFloat(hit.Duration), artist, title)
	s.maybeAlign(audioPath, lrcPath)
	return true, nil
}

func derefFloat(p *float64) float64 {
	if p == nil {
		return 0
	}
	return *p
}

// stampLrclibProvenance records id + source duration so a later cut change
// invalidates the sidecar instead of lighting the wrong edit.
func stampLrclibProvenance(content string, hit *lrclibResult) string {
	if hit == nil {
		return content
	}
	var b strings.Builder
	if hit.ID > 0 {
		b.WriteString(fmt.Sprintf("[drome-lrclib-id:%d]\n", hit.ID))
	}
	if hit.Duration != nil && *hit.Duration > 0 {
		b.WriteString(fmt.Sprintf("[drome-lrclib-duration:%.3f]\n", *hit.Duration))
	}
	if b.Len() == 0 {
		return content
	}
	// Drop prior provenance tags, keep the rest.
	var kept []string
	for _, line := range strings.Split(content, "\n") {
		trim := strings.TrimSpace(line)
		if dromeLrclibIDRe.MatchString(trim) || dromeLrclibDurRe.MatchString(trim) {
			continue
		}
		kept = append(kept, line)
	}
	return b.String() + strings.Join(kept, "\n")
}

func parseSidecarLrclibDuration(raw string) (float64, bool) {
	m := dromeLrclibDurRe.FindStringSubmatch(raw)
	if len(m) < 2 {
		return 0, false
	}
	var v float64
	if _, err := fmt.Sscanf(m[1], "%f", &v); err != nil || v <= 0 {
		return 0, false
	}
	return v, true
}

func sidecarDurationMatchesTrack(raw string, trackDurationSec int) bool {
	if trackDurationSec <= 0 {
		return true // can't judge — keep existing
	}
	src, ok := parseSidecarLrclibDuration(raw)
	if !ok {
		// Legacy sidecar without provenance: treat as suspect when the last
		// lyric stamp is wildly shorter/longer than the file (radio vs album).
		if last := lastLyricStampSec(raw); last > 0 {
			delta := absFloat(last - float64(trackDurationSec))
			// Last stamp is usually a few seconds before EOF; allow slack.
			if delta > 45 {
				return false
			}
		}
		return true
	}
	return absFloat(src-float64(trackDurationSec)) <= lrclibMaxDurationDeltaSec
}

func lastLyricStampSec(raw string) float64 {
	var last float64
	for _, line := range strings.Split(raw, "\n") {
		m := lineStampRe.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		// parse [mm:ss.xxx]
		inner := strings.TrimPrefix(strings.TrimSuffix(m[0], "]"), "[")
		parts := strings.Split(inner, ":")
		if len(parts) != 2 {
			continue
		}
		var mm int
		var ss float64
		if _, err := fmt.Sscanf(parts[0], "%d", &mm); err != nil {
			continue
		}
		if _, err := fmt.Sscanf(parts[1], "%f", &ss); err != nil {
			continue
		}
		sec := float64(mm*60) + ss
		if sec > last {
			last = sec
		}
	}
	return last
}

func (s *lyricsSyncer) maybeAlign(audioPath, lrcPath string) {
	if s == nil || s.alignQ == nil {
		return
	}
	s.alignQ.enqueueAlign(audioPath, lrcPath)
}

func ensureTrailingNewline(s string) string {
	if strings.HasSuffix(s, "\n") {
		return s
	}
	return s + "\n"
}

func (s *lyricsSyncer) fetchBest(ctx context.Context, title, artist, album string, durationSec int) (*lrclibResult, error) {
	var candidates []lrclibResult
	if exact, err := s.getExact(ctx, title, artist, album, durationSec); err == nil && exact != nil {
		if lrclibIdentityMatches(title, artist, *exact) {
			candidates = append(candidates, *exact)
		}
	}
	if searched, err := s.search(ctx, title, artist); err == nil {
		for _, hit := range searched {
			if lrclibIdentityMatches(title, artist, hit) {
				candidates = append(candidates, hit)
			}
		}
	}
	return pickBestLRCLIB(candidates, album, durationSec), nil
}

func (s *lyricsSyncer) getExact(ctx context.Context, title, artist, album string, durationSec int) (*lrclibResult, error) {
	q := url.Values{}
	q.Set("track_name", title)
	q.Set("artist_name", artist)
	if strings.TrimSpace(album) != "" {
		q.Set("album_name", album)
	}
	if durationSec > 0 {
		q.Set("duration", fmt.Sprintf("%d", durationSec))
	}
	var result lrclibResult
	ok, err := s.getJSON(ctx, lrclibBase+"/get?"+q.Encode(), &result)
	if err != nil || !ok {
		return nil, err
	}
	if result.SyncedLyrics == "" && result.PlainLyrics == "" && strings.TrimSpace(result.Lyricsfile) == "" {
		return nil, nil
	}
	return &result, nil
}

func (s *lyricsSyncer) search(ctx context.Context, title, artist string) ([]lrclibResult, error) {
	q := url.Values{}
	q.Set("track_name", title)
	q.Set("artist_name", artist)
	var results []lrclibResult
	ok, err := s.getJSON(ctx, lrclibBase+"/search?"+q.Encode(), &results)
	if err != nil || !ok {
		return nil, err
	}
	return results, nil
}

func (s *lyricsSyncer) getJSON(ctx context.Context, rawURL string, dest any) (bool, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return false, err
	}
	req.Header.Set("User-Agent", s.cfg.UserAgent)
	resp, err := s.client.Do(req)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return false, nil
	}
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return false, fmt.Errorf("lrclib HTTP %d: %s", resp.StatusCode, truncate(string(body), 200))
	}
	if err := json.NewDecoder(resp.Body).Decode(dest); err != nil {
		return false, err
	}
	return true, nil
}

func pickBestLRCLIB(results []lrclibResult, album string, durationSec int) *lrclibResult {
	if len(results) == 0 {
		return nil
	}
	seen := map[string]struct{}{}
	unique := make([]lrclibResult, 0, len(results))
	for _, r := range results {
		key := fmt.Sprintf("%d|%s|%s|%v|%d", r.ID, r.TrackName, r.ArtistName, r.Duration, len(r.SyncedLyrics))
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		unique = append(unique, r)
	}

	score := func(r lrclibResult) float64 {
		var s float64
		content := effectiveSyncedLyrics(r)
		switch {
		case hasWordSync(content):
			s += 140
		case strings.TrimSpace(content) != "":
			s += 100
		case strings.TrimSpace(r.PlainLyrics) != "":
			s += 10
		}
		if durationSec > 0 && r.Duration != nil && *r.Duration > 0 {
			delta := absFloat(*r.Duration - float64(durationSec))
			// Hard preference for ±2s; reject path below drops >3s synced hits.
			switch {
			case delta <= 1:
				s += 80
			case delta <= 2:
				s += 55
			case delta <= lrclibMaxDurationDeltaSec:
				s += 20
			default:
				s -= 200 // different cut — never beat a duration-matched hit
			}
			s -= delta * 4
		}
		if strings.TrimSpace(album) != "" && lrclibTitlesMatch(album, r.AlbumName) {
			s += 12
		}
		if r.Instrumental != nil && *r.Instrumental {
			s -= 20
		}
		return s
	}

	best := unique[0]
	bestScore := score(best)
	for _, r := range unique[1:] {
		if sc := score(r); sc > bestScore {
			best, bestScore = r, sc
		}
	}
	if effectiveSyncedLyrics(best) == "" {
		return nil
	}
	// Refuse synced lyrics for a clearly different cut (radio vs album).
	if durationSec > 0 && best.Duration != nil {
		delta := absFloat(*best.Duration - float64(durationSec))
		if delta > lrclibMaxDurationDeltaSec {
			// Fall back to plain text if available; otherwise no lyrics.
			for _, r := range unique {
				if strings.TrimSpace(effectiveSyncedLyrics(r)) != "" {
					continue
				}
				if strings.TrimSpace(r.PlainLyrics) != "" {
					cp := r
					return &cp
				}
			}
			return nil
		}
	}
	return &best
}

func lrclibIdentityMatches(title, artist string, r lrclibResult) bool {
	if !lrclibTitlesMatch(title, r.TrackName) {
		return false
	}
	if strings.TrimSpace(artist) == "" {
		return true
	}
	return lrclibTitlesMatch(artist, r.ArtistName)
}

func lrclibTitlesMatch(a, b string) bool {
	na := lrclibNormalize(a)
	nb := lrclibNormalize(b)
	if na == "" || nb == "" {
		return false
	}
	if na == nb {
		return true
	}
	shorter, longer := na, nb
	if len(nb) < len(na) {
		shorter, longer = nb, na
	}
	if len(shorter) < 5 {
		return strings.HasPrefix(longer, shorter) || strings.HasSuffix(longer, shorter)
	}
	if !strings.Contains(longer, shorter) {
		return false
	}
	return float64(len(shorter))/float64(len(longer)) >= 0.72
}

func lrclibNormalize(raw string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(strings.TrimSpace(raw)) {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(r)
		}
	}
	return b.String()
}

func absFloat(v float64) float64 {
	if v < 0 {
		return -v
	}
	return v
}

func recentAudioPaths(root string, since time.Time) []string {
	cutoff := since.Add(-2 * time.Second)
	var out []string
	_ = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		ext := strings.ToLower(filepath.Ext(path))
		if !audioExtsForLyrics[ext] {
			return nil
		}
		info, err := d.Info()
		if err != nil || info.ModTime().Before(cutoff) {
			return nil
		}
		base := strings.TrimSuffix(d.Name(), ext)
		if IsAmazonASINBaseName(base) {
			return nil
		}
		out = append(out, path)
		return nil
	})
	return out
}

func sleepCtx(ctx context.Context, d time.Duration) error {
	if d <= 0 {
		return ctx.Err()
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// findSidecarLRC locates the best matching .lrc under musicDir for a track.
func findSidecarLRC(musicDir, title, artist string) (path string, content string, ok bool) {
	if musicDir == "" || strings.TrimSpace(title) == "" {
		return "", "", false
	}
	wantTitle := lrclibNormalize(title)
	wantArtist := lrclibNormalize(artist)
	var bestPath, bestContent string
	bestScore := -1
	_ = filepath.WalkDir(musicDir, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			if d != nil && d.IsDir() {
				name := d.Name()
				if strings.HasPrefix(name, ".") || strings.EqualFold(name, "Playlists") {
					if p != musicDir {
						return filepath.SkipDir
					}
				}
			}
			return nil
		}
		if strings.ToLower(filepath.Ext(d.Name())) != ".lrc" {
			return nil
		}
		a, _, t := inferMetaFromPath(musicDir, p)
		if lrclibNormalize(t) != wantTitle {
			return nil
		}
		score := 1
		if wantArtist != "" && lrclibNormalize(a) == wantArtist {
			score = 3
		} else if wantArtist != "" && strings.Contains(lrclibNormalize(a), wantArtist) {
			score = 2
		}
		raw, err := os.ReadFile(p)
		if err != nil || len(raw) == 0 {
			return nil
		}
		body := string(raw)
		if hasWordSync(body) {
			score += 2
		} else if hasLineSync(body) {
			score++
		}
		if score > bestScore {
			bestScore = score
			bestPath = p
			bestContent = body
		}
		return nil
	})
	if bestPath == "" {
		return "", "", false
	}
	return bestPath, bestContent, true
}
