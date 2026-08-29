package main

import (
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

type mixHub struct {
	mu       sync.Mutex
	inflight map[string]*mixWait
}

type mixWait struct {
	done chan struct{}
	body []byte
	err  error
}

func newMixHub() *mixHub {
	return &mixHub{inflight: map[string]*mixWait{}}
}

func (s *server) registerMixRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /mixes/daily", s.requireAuth(s.handleDailyMixes))
	mux.HandleFunc("GET /mixes/vibe/{id}", s.requireAuth(s.handleVibeMix))
}

func radioDay(now time.Time, tzName string) string {
	loc, err := time.LoadLocation(tzName)
	if err != nil || tzName == "" {
		loc = time.Local
	}
	t := now.In(loc)
	if t.Hour() < 4 {
		t = t.AddDate(0, 0, -1)
	}
	return t.Format("2006-01-02")
}

func requestTZ(r *http.Request) string {
	tz := strings.TrimSpace(r.URL.Query().Get("tz"))
	if tz == "" {
		tz = "UTC"
	}
	return tz
}

func requestRecencyHours(r *http.Request) int {
	raw := strings.TrimSpace(r.URL.Query().Get("recencyHours"))
	if raw == "" {
		return 72
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n <= 0 {
		return 72
	}
	if n > 720 {
		return 720
	}
	return n
}

func requestExcludeIDs(r *http.Request) map[string]struct{} {
	raw := strings.TrimSpace(r.URL.Query().Get("exclude"))
	if raw == "" {
		return nil
	}
	parts := strings.Split(raw, ",")
	out := make(map[string]struct{}, len(parts))
	for _, p := range parts {
		id := strings.TrimSpace(p)
		if id == "" {
			continue
		}
		out[id] = struct{}{}
		if len(out) >= 500 {
			break
		}
	}
	return out
}

func mergeExclude(base map[string]struct{}, extra map[string]struct{}) map[string]struct{} {
	if len(extra) == 0 {
		return base
	}
	if base == nil {
		base = map[string]struct{}{}
	}
	for id := range extra {
		base[id] = struct{}{}
	}
	return base
}

type dailyMixResponse struct {
	Date  string     `json:"date"`
	Mixes []dailyMix `json:"mixes"`
}

// filterDailyMixResponse drops excluded song IDs from a cached payload without
// regenerating mixes (keeps the day's lineup stable).
func filterDailyMixResponse(raw []byte, exclude map[string]struct{}) ([]byte, bool) {
	if len(exclude) == 0 {
		return raw, false
	}
	var resp dailyMixResponse
	if json.Unmarshal(raw, &resp) != nil {
		return raw, false
	}
	changed := false
	out := make([]dailyMix, 0, len(resp.Mixes))
	for _, mix := range resp.Mixes {
		songs := filterExcluded(mix.Songs, exclude)
		if len(songs) != len(mix.Songs) {
			changed = true
		}
		if len(songs) < minClusterSongs {
			changed = true
			continue
		}
		mix.Songs = songs
		// Cover art is fixed at build time — do not recompute when filtering
		// played songs mid-day (that rotated the collage on every reload).
		out = append(out, mix)
	}
	if !changed {
		return raw, false
	}
	resp.Mixes = out
	payload, err := json.Marshal(resp)
	if err != nil {
		return raw, false
	}
	return payload, true
}

func (s *server) handleDailyMixes(w http.ResponseWriter, r *http.Request) {
	owner := requestUser(r)
	day := radioDay(time.Now(), requestTZ(r))
	exclude := requestExcludeIDs(r)
	recencyHours := requestRecencyHours(r)

	if creds, ok := s.playlistCreds(r); ok {
		ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
		oor := s.navidrome.outOfRotationIDs(ctx, creds)
		cancel()
		exclude = mergeExclude(exclude, oor)
	}

	// Songs that appeared in recent Daily Mixes (even if never played) stay out
	// for the same window as client play history — fixes day-to-day repeats.
	recentDays := previousRadioDays(day, recencyHours/24)
	if len(recentDays) > 0 {
		if recentMixSongs, err := s.store.recentDailyMixSongIDs(owner, recentDays); err == nil {
			exclude = mergeExclude(exclude, recentMixSongs)
		}
	}

	// Cache key is the radio day only — exclude/recency must NOT rotate mixes
	// mid-day (that made Daily Mixes reshuffle every time you played a song).
	if raw, ok, err := s.store.getDailyMixJSON(owner, day); err == nil && ok {
		// Return the day's cached lineup unchanged. Stripping played songs on
		// every fetch was removing entire mixes from the home rail.
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(raw))
		return
	}

	key := owner + "|daily|" + day
	body, err := s.mixOnce(key, func() ([]byte, error) {
		if raw, ok, err := s.store.getDailyMixJSON(owner, day); err == nil && ok {
			return []byte(raw), nil
		}
		creds, ok := s.playlistCreds(r)
		if !ok {
			return nil, errNoCreds
		}
		ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
		defer cancel()
		snapshot := s.navidrome.mixSnapshot(ctx, creds)
		artists := topArtistKeys(snapshot, 16)
		similar := s.navidrome.similarByArtists(ctx, creds, artists, 20)
		// First build of the radio day: bake in then-current excludes (recent + OOR).
		mixes := buildDailyMixes(snapshot, similar, owner+"|"+day, exclude)
		if mixes == nil {
			mixes = []dailyMix{}
		}
		resp := dailyMixResponse{Date: day, Mixes: mixes}
		payload, err := json.Marshal(resp)
		if err != nil {
			return nil, err
		}
		_ = s.store.putDailyMixJSON(owner, day, string(payload))
		return payload, nil
	})
	if err != nil {
		writeError(w, http.StatusBadGateway, "could not build daily mixes: "+err.Error())
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}

func (s *server) handleVibeMix(w http.ResponseWriter, r *http.Request) {
	owner := requestUser(r)
	vibe := strings.TrimSpace(r.PathValue("id"))
	if _, ok := vibeSpecs[vibe]; !ok {
		writeError(w, http.StatusBadRequest, "unknown vibe")
		return
	}
	day := radioDay(time.Now(), requestTZ(r))
	if raw, ok, err := s.store.getVibeMixJSON(owner, vibe, day); err == nil && ok {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(raw))
		return
	}

	key := owner + "|vibe|" + vibe + "|" + day
	body, err := s.mixOnce(key, func() ([]byte, error) {
		if raw, ok, err := s.store.getVibeMixJSON(owner, vibe, day); err == nil && ok {
			return []byte(raw), nil
		}
		creds, ok := s.playlistCreds(r)
		if !ok {
			return nil, errNoCreds
		}
		ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
		defer cancel()
		snapshot := s.navidrome.mixSnapshot(ctx, creds)
		genreSongs := s.navidrome.vibeGenreSongs(ctx, creds, vibe)
		snapshot = uniqueTracks(append(snapshot, genreSongs...))
		artists := topArtistKeys(snapshot, 12)
		similar := s.navidrome.similarByArtists(ctx, creds, artists, 16)
		mix := buildVibeMix(snapshot, similar, vibe, owner+"|"+day)
		payload, err := json.Marshal(mix)
		if err != nil {
			return nil, err
		}
		_ = s.store.putVibeMixJSON(owner, vibe, day, string(payload))
		return payload, nil
	})
	if err != nil {
		writeError(w, http.StatusBadGateway, "could not build vibe mix: "+err.Error())
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}

var errNoCreds = errString("missing navidrome credentials")

type errString string

func (e errString) Error() string { return string(e) }

func (s *server) mixOnce(key string, run func() ([]byte, error)) ([]byte, error) {
	if s.mixes == nil {
		s.mixes = newMixHub()
	}
	s.mixes.mu.Lock()
	if w, ok := s.mixes.inflight[key]; ok {
		s.mixes.mu.Unlock()
		<-w.done
		return w.body, w.err
	}
	w := &mixWait{done: make(chan struct{})}
	s.mixes.inflight[key] = w
	s.mixes.mu.Unlock()

	w.body, w.err = run()
	close(w.done)

	s.mixes.mu.Lock()
	delete(s.mixes.inflight, key)
	s.mixes.mu.Unlock()
	return w.body, w.err
}
