package main

import (
	"bufio"
	"fmt"
	"io"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	progressLogCap     = 40
	progressStatusEvery = 2 * time.Second
)

// activeDownload is the job currently running through SpotiFLAC / retag.
type activeDownload struct {
	EntryID            int64     `json:"entryId"`
	Owner              string    `json:"owner"`
	Kind               string    `json:"kind"`
	Title              string    `json:"title"`
	Artist             string    `json:"artist"`
	Album              string    `json:"album,omitempty"`
	SpotifyURL         string    `json:"spotifyUrl,omitempty"`
	SourcePlaylistID   string    `json:"sourcePlaylistId,omitempty"`
	SourcePlaylistName string    `json:"sourcePlaylistName,omitempty"`
	Attempt            int       `json:"attempt"`
	MaxAttempts        int       `json:"maxAttempts"`
	StartedAt          time.Time `json:"startedAt"`
	Phase              string    `json:"phase"`
	Detail             string    `json:"detail,omitempty"`
	TracksDone         int       `json:"tracksDone,omitempty"`
	TracksTotal        int       `json:"tracksTotal,omitempty"`
	ElapsedSec         int       `json:"elapsedSec"`
}

// downloadQueueStats summarizes wishlist rows waiting on the download worker.
type downloadQueueStats struct {
	Queued      int `json:"queued"`
	Downloading int `json:"downloading"`
	Failed      int `json:"failed"`
	Retrying    int `json:"retrying"` // failed with a scheduled next_retry_at
	Total       int `json:"total"`
}

// playlistDownloadProgress aggregates per-track wishlist rows from one Spotify playlist import.
type playlistDownloadProgress struct {
	PlaylistID   string `json:"playlistId"`
	PlaylistName string `json:"playlistName"`
	Queued       int    `json:"queued"`
	Downloading  int    `json:"downloading"`
	Failed       int    `json:"failed"`
	Total        int    `json:"total"`
	CurrentTitle string `json:"currentTitle,omitempty"`
	CurrentArtist string `json:"currentArtist,omitempty"`
	Percent      int    `json:"percent"` // of remaining queue only (done rows are removed)
}

// downloadStatusReport is what GET /wishlist/downloads returns.
type downloadStatusReport struct {
	Enabled            bool                       `json:"enabled"`
	UpdatedAt          time.Time                  `json:"updatedAt"`
	CooldownRemaining  string                     `json:"cooldownRemaining,omitempty"`
	CooldownSeconds    int                        `json:"cooldownSeconds,omitempty"`
	Active             *activeDownload            `json:"active,omitempty"`
	Queue              downloadQueueStats         `json:"queue"`
	Playlists          []playlistDownloadProgress `json:"playlists"`
	Items              []entry                    `json:"items"`
	RecentLog          []string                   `json:"recentLog"`
}

type progressState struct {
	mu             sync.Mutex
	active         *activeDownload
	recentLog      []string
	lastStatusWrite time.Time
}

func (w *downloadWorker) beginProgress(e *entry, attempt int) {
	if w == nil || e == nil {
		return
	}
	now := time.Now().UTC()
	w.progress.mu.Lock()
	defer w.progress.mu.Unlock()
	w.progress.active = &activeDownload{
		EntryID:            e.ID,
		Owner:              e.Owner,
		Kind:               e.Kind,
		Title:              e.Title,
		Artist:             e.Artist,
		Album:              e.Album,
		SpotifyURL:         e.SpotifyURL,
		SourcePlaylistID:   e.SourcePlaylistID,
		SourcePlaylistName: e.SourcePlaylistName,
		Attempt:            attempt,
		MaxAttempts:        w.cfg.MaxAttempts,
		StartedAt:          now,
		Phase:              "starting",
		Detail:             "queued job picked up",
	}
	w.progress.recentLog = nil
	w.progress.lastStatusWrite = time.Time{}
}

func (w *downloadWorker) endProgress() {
	if w == nil {
		return
	}
	w.progress.mu.Lock()
	defer w.progress.mu.Unlock()
	w.progress.active = nil
}

func (w *downloadWorker) setPhase(phase, detail string) {
	if w == nil {
		return
	}
	w.progress.mu.Lock()
	active := w.progress.active
	if active == nil {
		w.progress.mu.Unlock()
		return
	}
	active.Phase = phase
	if detail != "" {
		active.Detail = truncate(detail, 240)
	}
	active.ElapsedSec = int(time.Since(active.StartedAt).Seconds())
	msg := formatActiveStatus(active)
	id := active.EntryID
	shouldWrite := time.Since(w.progress.lastStatusWrite) >= progressStatusEvery || phase != ""
	if shouldWrite {
		w.progress.lastStatusWrite = time.Now()
	}
	w.progress.mu.Unlock()

	if shouldWrite && id > 0 && w.store != nil {
		_ = w.store.setStatus(id, statusDownloading, msg)
	}
}

func (w *downloadWorker) appendProgressLog(line string) {
	line = strings.TrimSpace(stripANSI(line))
	if line == "" {
		return
	}
	w.progress.mu.Lock()
	defer w.progress.mu.Unlock()
	w.progress.recentLog = append(w.progress.recentLog, truncate(line, 300))
	if len(w.progress.recentLog) > progressLogCap {
		w.progress.recentLog = w.progress.recentLog[len(w.progress.recentLog)-progressLogCap:]
	}
	if w.progress.active != nil {
		applyProgressHints(w.progress.active, line)
		w.progress.active.Detail = truncate(line, 240)
		w.progress.active.ElapsedSec = int(time.Since(w.progress.active.StartedAt).Seconds())
	}
}

func (w *downloadWorker) noteProgressLine(line string) {
	if w == nil {
		return
	}
	clean := strings.TrimSpace(stripANSI(line))
	if clean == "" || !isInterestingProgressLine(clean) {
		return
	}
	w.appendProgressLog(clean)

	w.progress.mu.Lock()
	active := w.progress.active
	var msg string
	var id int64
	shouldWrite := false
	if active != nil {
		msg = formatActiveStatus(active)
		id = active.EntryID
		if time.Since(w.progress.lastStatusWrite) >= progressStatusEvery {
			w.progress.lastStatusWrite = time.Now()
			shouldWrite = true
		}
	}
	w.progress.mu.Unlock()

	if shouldWrite && id > 0 && w.store != nil {
		_ = w.store.setStatus(id, statusDownloading, msg)
	}
}

func formatActiveStatus(a *activeDownload) string {
	if a == nil {
		return ""
	}
	var b strings.Builder
	phase := a.Phase
	if phase == "" {
		phase = "downloading"
	}
	b.WriteString(phase)
	if a.TracksTotal > 0 {
		fmt.Fprintf(&b, " %d/%d", a.TracksDone, a.TracksTotal)
	}
	if a.Detail != "" {
		b.WriteString(": ")
		b.WriteString(a.Detail)
	}
	return truncate(b.String(), 500)
}

func (w *downloadWorker) snapshotProgress() (active *activeDownload, log []string) {
	if w == nil {
		return nil, nil
	}
	w.progress.mu.Lock()
	defer w.progress.mu.Unlock()
	if w.progress.active != nil {
		cp := *w.progress.active
		cp.ElapsedSec = int(time.Since(cp.StartedAt).Seconds())
		active = &cp
	}
	if n := len(w.progress.recentLog); n > 0 {
		log = append([]string(nil), w.progress.recentLog...)
	}
	return active, log
}

func (w *downloadWorker) buildStatusReport(user string) (downloadStatusReport, error) {
	rep := downloadStatusReport{
		Enabled:   w != nil && w.cfg.Enabled,
		UpdatedAt: time.Now().UTC(),
		Playlists: []playlistDownloadProgress{},
		Items:     []entry{},
		RecentLog: []string{},
	}
	if w == nil {
		return rep, nil
	}
	active, log := w.snapshotProgress()
	rep.Active = active
	if log != nil {
		rep.RecentLog = log
	}
	if cool := w.providerCooldownRemaining(); cool > 0 {
		rep.CooldownSeconds = int(cool.Seconds())
		rep.CooldownRemaining = cool.Round(time.Second).String()
	}

	if w.store == nil {
		return rep, nil
	}
	queue, err := w.store.downloadQueueStats(user)
	if err != nil {
		return rep, err
	}
	rep.Queue = queue

	playlists, err := w.store.playlistDownloadProgress(user)
	if err != nil {
		return rep, err
	}
	if active != nil && active.SourcePlaylistID != "" {
		for i := range playlists {
			if playlists[i].PlaylistID == active.SourcePlaylistID {
				playlists[i].CurrentTitle = active.Title
				playlists[i].CurrentArtist = active.Artist
				playlists[i].Downloading = maxInt(playlists[i].Downloading, 1)
			}
		}
	}
	rep.Playlists = playlists

	items, err := w.store.listDownloadQueue(user)
	if err != nil {
		return rep, err
	}
	if items == nil {
		items = []entry{}
	}
	rep.Items = items
	return rep, nil
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

var (
	totalTracksRe  = regexp.MustCompile(`(?i)Total\s+Tracks\s*:?\s*(\d+)`)
	successfulRe   = regexp.MustCompile(`(?i)Successful\s*:?\s*(\d+)`)
	trackOfRe      = regexp.MustCompile(`(?i)(?:track|song)\s*(\d+)\s*(?:/|of)\s*(\d+)`)
	percentRe      = regexp.MustCompile(`(\d{1,3})\s*%`)
	downloadingRe  = regexp.MustCompile(`(?i)\b(download(?:ing)?|fetching|searching|matching|retag(?:ging)?|writing|saving|provider|tidal|qobuz|amazon|deezer|turnstile|verif)\b`)
)

func applyProgressHints(a *activeDownload, line string) {
	if a == nil {
		return
	}
	if m := totalTracksRe.FindStringSubmatch(line); len(m) == 2 {
		if n, err := strconv.Atoi(m[1]); err == nil && n > 0 {
			a.TracksTotal = n
		}
	}
	if m := successfulRe.FindStringSubmatch(line); len(m) == 2 {
		if n, err := strconv.Atoi(m[1]); err == nil && n >= 0 {
			a.TracksDone = n
			if a.TracksTotal > 0 && n > a.TracksTotal {
				a.TracksTotal = n
			}
		}
	}
	if m := trackOfRe.FindStringSubmatch(line); len(m) == 3 {
		done, _ := strconv.Atoi(m[1])
		total, _ := strconv.Atoi(m[2])
		if total > 0 {
			a.TracksTotal = total
		}
		if done > 0 {
			a.TracksDone = done
		}
	}
}

func isInterestingProgressLine(line string) bool {
	if len(line) < 3 {
		return false
	}
	// Skip pure box-drawing / separators.
	trimmed := strings.Trim(line, " ╔╗╚╝║═─-|+")
	if trimmed == "" {
		return false
	}
	lower := strings.ToLower(line)
	switch {
	case strings.Contains(lower, "successful"):
		return true
	case strings.Contains(lower, "failed"):
		return true
	case strings.Contains(lower, "total tracks"):
		return true
	case strings.Contains(lower, "all providers"):
		return true
	case downloadingRe.MatchString(line):
		return true
	case trackOfRe.MatchString(line):
		return true
	case percentRe.MatchString(line) && downloadingRe.MatchString(line):
		return true
	case strings.HasPrefix(trimmed, "✓") || strings.HasPrefix(trimmed, "✗"):
		return true
	case strings.Contains(line, "drome-download:"):
		return true
	default:
		return false
	}
}

// readProgressStream consumes SpotiFLAC stdout/stderr, feeding progress updates
// while also capturing the full output for soft-failure detection.
func (w *downloadWorker) readProgressStream(r io.Reader, capture *strings.Builder, captureMu *sync.Mutex) {
	br := bufio.NewReader(r)
	var line strings.Builder
	flush := func() {
		s := line.String()
		line.Reset()
		if s == "" {
			return
		}
		if capture != nil {
			if captureMu != nil {
				captureMu.Lock()
			}
			capture.WriteString(s)
			capture.WriteByte('\n')
			if captureMu != nil {
				captureMu.Unlock()
			}
		}
		w.noteProgressLine(s)
	}
	for {
		b, err := br.ReadByte()
		if err != nil {
			flush()
			return
		}
		switch b {
		case '\n':
			flush()
		case '\r':
			// Progress bars rewrite the same line; keep the latest text.
			flush()
		default:
			if b != 0 {
				line.WriteByte(b)
			}
		}
	}
}
