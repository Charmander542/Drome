package main

import (
	"context"
	"encoding/json"
	"net/http"
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

type dailyMixResponse struct {
	Date  string     `json:"date"`
	Mixes []dailyMix `json:"mixes"`
}

func (s *server) handleDailyMixes(w http.ResponseWriter, r *http.Request) {
	owner := requestUser(r)
	day := radioDay(time.Now(), requestTZ(r))
	if raw, ok, err := s.store.getDailyMixJSON(owner, day); err == nil && ok {
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
		mixes := buildDailyMixes(snapshot, similar, owner+"|"+day)
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
