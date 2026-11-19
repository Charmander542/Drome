package main

import (
	"net/http"
	"strconv"
	"strings"
)

func (s *server) registerLyricsRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /lyrics/search", s.requireAuth(s.handleLyricsSearch))
	mux.HandleFunc("GET /lyrics/stats", s.requireAuth(s.handleLyricsStats))
}

// GET /lyrics/search?q=...&limit=40
func (s *server) handleLyricsSearch(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	if q == "" {
		writeError(w, http.StatusBadRequest, "query parameter \"q\" is required")
		return
	}
	limit := 40
	if raw := r.URL.Query().Get("limit"); raw != "" {
		if n, err := strconv.Atoi(raw); err == nil {
			limit = n
		}
	}
	if s.lyrics == nil {
		writeJSON(w, http.StatusOK, map[string]any{"results": []lyricsHit{}})
		return
	}
	hits := s.lyrics.search(q, limit)
	if hits == nil {
		hits = []lyricsHit{}
	}
	// Best-effort: resolve missing song IDs via Navidrome search3 for top hits.
	user, token, salt := requestCreds(r)
	for i := range hits {
		if hits[i].SongID != "" || s.navidrome == nil {
			continue
		}
		if id := s.navidrome.findSongID(r.Context(), user, token, salt, hits[i].Title, hits[i].Artist); id != "" {
			hits[i].SongID = id
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"results": hits})
}

func (s *server) handleLyricsStats(w http.ResponseWriter, r *http.Request) {
	if s.lyrics == nil {
		writeJSON(w, http.StatusOK, map[string]any{"documents": 0})
		return
	}
	writeJSON(w, http.StatusOK, s.lyrics.stats())
}
