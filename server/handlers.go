package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"
)

type server struct {
	store     *wishlistStore
	navidrome *navidromeVerifier
	spotify   *spotifyClient
	downloads *downloadWorker
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	// Single authenticated Spotify search — returns {"results":[...]} for iOS.
	mux.HandleFunc("GET /spotify/search", s.requireAuth(s.handleSearch))
	mux.HandleFunc("GET /spotify/artist-image", s.requireAuth(s.handleArtistImage))
	mux.HandleFunc("POST /wishlist", s.requireAuth(s.handleCreate))
	mux.HandleFunc("GET /wishlist", s.requireAuth(s.handleList))
	mux.HandleFunc("DELETE /wishlist/source/{playlistId}", s.requireAuth(s.handleDeleteSourcePlaylist))
	mux.HandleFunc("DELETE /wishlist/{id}", s.requireAuth(s.handleDelete))
	mux.HandleFunc("PATCH /wishlist/{id}", s.requireAuth(s.handleUpdate))
	mux.HandleFunc("POST /wishlist/{id}/retry", s.requireAuth(s.handleRetry))
	mux.HandleFunc("POST /wishlist/{id}/share", s.requireAuth(s.handleShareEntry))
	mux.HandleFunc("POST /wishlist/share", s.requireAuth(s.handleShareList))
	return logRequests(mux)
}

func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		// Never log query strings: they carry auth tokens.
		logf("%s %s (%s)", r.Method, r.URL.Path, time.Since(start).Round(time.Millisecond))
	})
}

// GET /spotify/search?q=...&type=track,album&limit=10
func (s *server) handleSearch(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	if q == "" {
		writeError(w, http.StatusBadRequest, "query parameter \"q\" is required")
		return
	}
	types := r.URL.Query().Get("type")
	limit := 10
	if raw := r.URL.Query().Get("limit"); raw != "" {
		if n, err := strconv.Atoi(raw); err == nil {
			limit = n
		}
	}
	hits, err := s.spotify.search(r.Context(), q, types, limit)
	if err != nil {
		writeError(w, http.StatusBadGateway, "spotify search failed: "+err.Error())
		return
	}
	if hits == nil {
		hits = []searchHit{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"results": hits})
}

// POST /wishlist  body: {"url": "..."} or {"urls": ["...", "..."]}
// Accepts track/album/playlist links (including multi-link clipboard pastes).
// Playlists expand into per-track wishlist downloads.
func (s *server) handleCreate(w http.ResponseWriter, r *http.Request) {
	var body struct {
		URL  string   `json:"url"`
		URLs []string `json:"urls"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "body must be JSON with a \"url\" or \"urls\" field")
		return
	}

	var rawLinks []string
	switch {
	case len(body.URLs) > 0:
		rawLinks = body.URLs
	case strings.TrimSpace(body.URL) != "":
		rawLinks = extractSpotifyLinks(body.URL)
		if len(rawLinks) == 0 {
			rawLinks = []string{body.URL}
		}
	default:
		writeError(w, http.StatusBadRequest, "body must be JSON with a non-empty \"url\" or \"urls\" field")
		return
	}

	// Cap batch size so a huge clipboard dump can't stall the worker.
	const maxBatch = 40
	if len(rawLinks) > maxBatch {
		rawLinks = rawLinks[:maxBatch]
	}

	if len(rawLinks) == 1 {
		s.handleCreateOne(w, r, rawLinks[0])
		return
	}
	s.handleCreateBatch(w, r, rawLinks)
}

func (s *server) handleCreateOne(w http.ResponseWriter, r *http.Request, raw string) {
	kind, id, _, err := normalizeSpotifyPaste(r.Context(), s.spotify.http, raw)
	if err != nil {
		writeError(w, http.StatusUnprocessableEntity, err.Error())
		return
	}

	if kind == "playlist" {
		s.handlePlaylistImport(w, r, id)
		return
	}

	entry, existed, err := s.addResolvedEntry(r, kind, id)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	status := http.StatusCreated
	if existed {
		status = http.StatusOK
	}
	writeJSON(w, status, entry)
}

func (s *server) handleCreateBatch(w http.ResponseWriter, r *http.Request, rawLinks []string) {
	var (
		entries      []entry
		added        int
		skippedOwned int
		playlistName string
		playlistID   string
		failed       []string
	)

	for _, raw := range rawLinks {
		kind, id, _, err := normalizeSpotifyPaste(r.Context(), s.spotify.http, raw)
		if err != nil {
			failed = append(failed, raw+": "+err.Error())
			continue
		}
		if kind == "playlist" {
			name, imported, owned, err := s.importPlaylistTracks(r, id)
			if err != nil {
				failed = append(failed, raw+": "+err.Error())
				continue
			}
			if playlistName == "" {
				playlistName = name
				playlistID = id
			}
			entries = append(entries, imported...)
			added += len(imported)
			skippedOwned += owned
			continue
		}
		e, _, err := s.addResolvedEntry(r, kind, id)
		if err != nil {
			failed = append(failed, raw+": "+err.Error())
			continue
		}
		entries = append(entries, *e)
		added++
	}

	if added == 0 && skippedOwned == 0 && len(failed) > 0 {
		writeError(w, http.StatusUnprocessableEntity, "could not import any links: "+failed[0])
		return
	}
	if entries == nil {
		entries = []entry{}
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"kind":               "playlistImport",
		"playlistId":         playlistID,
		"playlistName":       playlistName,
		"added":              added,
		"skippedOwned":       skippedOwned,
		"entries":            entries,
		"sourcePlaylistId":   playlistID,
		"sourcePlaylistName": playlistName,
		"failed":             failed,
	})
}

func (s *server) addResolvedEntry(r *http.Request, kind, id string) (*entry, bool, error) {
	entry, err := s.spotify.resolve(r.Context(), kind, id)
	if err != nil {
		return nil, false, fmt.Errorf("could not resolve link: %w", err)
	}
	entry.Owner = requestUser(r)
	entry.CreatedAt = time.Now()
	if s.downloads != nil && s.downloads.cfg.Enabled {
		entry.Status = statusQueued
	} else {
		entry.Status = statusSkipped
	}

	if existing, err := s.store.findActiveByTitleArtist(entry.Owner, entry.Kind, entry.Title, entry.Artist); err == nil && existing != nil {
		return existing, true, nil
	}

	if err := s.store.insert(entry); err != nil {
		return nil, false, fmt.Errorf("could not save entry: %w", err)
	}
	if entry.Status == statusQueued && s.downloads != nil {
		s.downloads.kick()
	}
	return entry, false, nil
}

func (s *server) handlePlaylistImport(w http.ResponseWriter, r *http.Request, playlistID string) {
	name, added, skippedOwned, err := s.importPlaylistTracks(r, playlistID)
	if err != nil {
		writeError(w, http.StatusBadGateway, "could not load playlist: "+err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"kind":                 "playlistImport",
		"playlistId":           playlistID,
		"playlistName":         name,
		"added":                len(added),
		"skippedOwned":         skippedOwned,
		"entries":              added,
		"sourcePlaylistId":     playlistID,
		"sourcePlaylistName":   name,
	})
}

func (s *server) importPlaylistTracks(r *http.Request, playlistID string) (name string, added []entry, skippedOwned int, err error) {
	name, tracks, err := s.spotify.playlistTracks(r.Context(), playlistID)
	if err != nil {
		return "", nil, 0, err
	}
	owner := requestUser(r)
	user, token, salt := requestCreds(r)
	status := statusSkipped
	if s.downloads != nil && s.downloads.cfg.Enabled {
		status = statusQueued
	}

	now := time.Now()
	for _, t := range tracks {
		if s.navidrome.libraryOwns(r.Context(), user, token, salt, t.Title, t.Artist) {
			skippedOwned++
			continue
		}
		e := entry{
			Owner:              owner,
			Kind:               "track",
			SpotifyID:          t.SpotifyID,
			SpotifyURL:         t.SpotifyURL,
			Title:              t.Title,
			Artist:             t.Artist,
			Album:              t.Album,
			CoverURL:           t.CoverURL,
			Status:             status,
			SourcePlaylistID:   playlistID,
			SourcePlaylistName: name,
			CreatedAt:          now,
		}
		if err := s.store.insert(&e); err != nil {
			continue
		}
		added = append(added, e)
	}
	if status == statusQueued && s.downloads != nil && len(added) > 0 {
		s.downloads.kick()
	}
	if added == nil {
		added = []entry{}
	}
	return name, added, skippedOwned, nil
}

func (s *server) handleArtistImage(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimSpace(r.URL.Query().Get("name"))
	if name == "" {
		writeError(w, http.StatusBadRequest, "query parameter \"name\" is required")
		return
	}
	url, err := s.spotify.artistImageURL(r.Context(), name)
	if err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"imageUrl": url, "name": name})
}

func (s *server) handleDeleteSourcePlaylist(w http.ResponseWriter, r *http.Request) {
	playlistID := r.PathValue("playlistId")
	if playlistID == "" {
		writeError(w, http.StatusBadRequest, "missing playlist id")
		return
	}
	n, err := s.store.deleteBySourcePlaylist(requestUser(r), playlistID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"deleted": n})
}

// GET /wishlist
func (s *server) handleList(w http.ResponseWriter, r *http.Request) {
	entries, err := s.store.listFor(requestUser(r))
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if entries == nil {
		entries = []entry{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"entries": entries})
}

// ownedEntry loads the entry from the path {id} and enforces ownership.
func (s *server) ownedEntry(w http.ResponseWriter, r *http.Request) *entry {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid entry id")
		return nil
	}
	e, err := s.store.get(id)
	if errors.Is(err, sql.ErrNoRows) {
		writeError(w, http.StatusNotFound, "entry not found")
		return nil
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return nil
	}
	if e.Owner != requestUser(r) {
		writeError(w, http.StatusForbidden, "only the owner can modify this entry")
		return nil
	}
	return e
}

// DELETE /wishlist/{id}
func (s *server) handleDelete(w http.ResponseWriter, r *http.Request) {
	e := s.ownedEntry(w, r)
	if e == nil {
		return
	}
	if err := s.store.delete(e.ID); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// PATCH /wishlist/{id}  body: {"acquired": true}
// Marking acquired removes the entry from the wishlist (file should already
// be — or will soon be — in the Navidrome library / “New in your library”).
func (s *server) handleUpdate(w http.ResponseWriter, r *http.Request) {
	e := s.ownedEntry(w, r)
	if e == nil {
		return
	}
	var body struct {
		Acquired *bool `json:"acquired"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Acquired == nil {
		writeError(w, http.StatusBadRequest, "body must be JSON with an \"acquired\" boolean")
		return
	}
	if *body.Acquired {
		if err := s.store.delete(e.ID); err != nil {
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if err := s.store.setAcquired(e.ID, false); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	e.Acquired = false
	writeJSON(w, http.StatusOK, e)
}

// POST /wishlist/{id}/retry — re-queue a failed (or skipped) download.
func (s *server) handleRetry(w http.ResponseWriter, r *http.Request) {
	e := s.ownedEntry(w, r)
	if e == nil {
		return
	}
	if s.downloads == nil || !s.downloads.cfg.Enabled {
		writeError(w, http.StatusServiceUnavailable, "auto-download is disabled on the server")
		return
	}
	if e.Acquired {
		writeError(w, http.StatusConflict, "entry was already downloaded and removed from the wishlist")
		return
	}
	// Manual retry gets a fresh attempt budget.
	if err := s.store.resetForRetry(e.ID); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	e.Status = statusQueued
	e.StatusMsg = ""
	e.Attempts = 0
	e.NextRetry = time.Time{}
	s.downloads.kick()
	writeJSON(w, http.StatusOK, e)
}

// POST /wishlist/{id}/share  body: {"user": "name", "remove": false}
func (s *server) handleShareEntry(w http.ResponseWriter, r *http.Request) {
	e := s.ownedEntry(w, r)
	if e == nil {
		return
	}
	var body struct {
		User   string `json:"user"`
		Remove bool   `json:"remove"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.User == "" {
		writeError(w, http.StatusBadRequest, "body must be JSON with a \"user\" field")
		return
	}
	var err error
	if body.Remove {
		err = s.store.unshareEntry(e.ID, body.User)
	} else {
		err = s.store.shareEntry(e.ID, body.User)
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// POST /wishlist/share  body: {"user": "name", "remove": false}
// Shares (or unshares) the caller's entire wishlist with another Navidrome user.
func (s *server) handleShareList(w http.ResponseWriter, r *http.Request) {
	var body struct {
		User   string `json:"user"`
		Remove bool   `json:"remove"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.User == "" {
		writeError(w, http.StatusBadRequest, "body must be JSON with a \"user\" field")
		return
	}
	var err error
	if body.Remove {
		err = s.store.unshareList(requestUser(r), body.User)
	} else {
		err = s.store.shareList(requestUser(r), body.User)
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}
