package main

import (
	"net/http"
	"strconv"
	"strings"
)

func (s *server) registerLyricsRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /lyrics/search", s.requireAuth(s.handleLyricsSearch))
	mux.HandleFunc("GET /lyrics/stats", s.requireAuth(s.handleLyricsStats))
	mux.HandleFunc("GET /lyrics/track", s.requireAuth(s.handleLyricsTrack))
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

// GET /lyrics/track?title=...&artist=...
// Returns the raw .lrc sidecar from the music library (preserves word stamps).
func (s *server) handleLyricsTrack(w http.ResponseWriter, r *http.Request) {
	title := strings.TrimSpace(r.URL.Query().Get("title"))
	artist := strings.TrimSpace(r.URL.Query().Get("artist"))
	if title == "" {
		writeError(w, http.StatusBadRequest, "query parameter \"title\" is required")
		return
	}
	musicDir := ""
	if s.lyricsSync != nil {
		musicDir = s.lyricsSync.musicDir
	} else if s.lyrics != nil {
		musicDir = s.lyrics.musicDir
	}
	path, content, ok := findSidecarLRC(musicDir, title, artist)
	if !ok {
		writeJSON(w, http.StatusOK, map[string]any{"found": false})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"found":      true,
		"path":       path,
		"content":    content,
		"synced":     hasLineSync(content) || hasWordSync(content),
		"wordSynced": hasWordSync(content),
		"source":     "sidecar",
	})
}
