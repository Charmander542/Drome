package main

import (
	"context"
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
	connect   *connectHub
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
	mux.HandleFunc("POST /share/track", s.requireAuth(s.handleCreateTrackShare))
	mux.HandleFunc("GET /s/{token}", s.handleTrackSharePage)
	mux.HandleFunc("GET /s/{token}/cover", s.handleTrackShareCover)
	mux.HandleFunc("GET /.well-known/apple-app-site-association", s.handleAppleAppSiteAssociation)
	mux.HandleFunc("GET /apple-app-site-association", s.handleAppleAppSiteAssociation)
	s.registerConnectRoutes(mux)
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
			res, err := s.importPlaylistTracks(r, id)
			if err != nil {
				failed = append(failed, raw+": "+err.Error())
				continue
			}
			if playlistName == "" {
				playlistName = res.Name
				playlistID = id
			}
			entries = append(entries, res.Added...)
			added += len(res.Added)
			skippedOwned += res.SkippedOwned
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

	if entry.Kind == "track" && s.alreadyHave(r, entry.Title, entry.Artist) {
		entry.Status = statusSkipped
		entry.StatusMsg = "already in library"
		return entry, true, nil
	}

	if err := s.store.insert(entry); err != nil {
		return nil, false, fmt.Errorf("could not save entry: %w", err)
	}
	if entry.Status == statusQueued && s.downloads != nil {
		s.downloads.kick()
	}
	return entry, false, nil
}

func (s *server) alreadyHave(r *http.Request, title, artist string) bool {
	if strings.TrimSpace(title) == "" {
		return false
	}
	user, token, salt := requestCreds(r)
	if s.navidrome != nil && user != "" &&
		s.navidrome.libraryOwns(r.Context(), user, token, salt, title, artist) {
		return true
	}
	if s.downloads != nil && diskHasTrack(s.downloads.cfg.MusicDir, title, artist) {
		return true
	}
	return false
}

func (s *server) handlePlaylistImport(w http.ResponseWriter, r *http.Request, playlistID string) {
	res, err := s.importPlaylistTracks(r, playlistID)
	if err != nil {
		writeError(w, http.StatusBadGateway, "could not load playlist: "+err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, playlistImportJSON(playlistID, res, nil))
}

type playlistImportResult struct {
	Name             string
	Added            []entry
	SkippedOwned     int
	NavidromeID      string
	NavidromeCreated bool
	NavidromeSongs   int
	PlaylistFile     string
}

func playlistImportJSON(spotifyID string, res playlistImportResult, failed []string) map[string]any {
	if res.Added == nil {
		res.Added = []entry{}
	}
	return map[string]any{
		"kind":                     "playlistImport",
		"playlistId":               spotifyID,
		"playlistName":             res.Name,
		"added":                    len(res.Added),
		"skippedOwned":             res.SkippedOwned,
		"entries":                  res.Added,
		"sourcePlaylistId":         spotifyID,
		"sourcePlaylistName":       res.Name,
		"failed":                   failed,
		"navidromePlaylistId":      res.NavidromeID,
		"navidromePlaylistCreated": res.NavidromeCreated,
		"navidromeSongsAdded":      res.NavidromeSongs,
		"playlistFile":             res.PlaylistFile,
	}
}

func (s *server) importPlaylistTracks(r *http.Request, playlistID string) (playlistImportResult, error) {
	name, tracks, err := s.spotify.playlistTracks(r.Context(), playlistID)
	if errors.Is(err, errPlaylistDirectDownload) {
		e, qerr := s.enqueueWholePlaylist(r, playlistID, name)
		if qerr != nil {
			return playlistImportResult{}, qerr
		}
		return playlistImportResult{Name: e.Title, Added: []entry{*e}}, nil
	}
	if err != nil {
		return playlistImportResult{}, err
	}
	owner := requestUser(r)
	status := statusSkipped
	if s.downloads != nil && s.downloads.cfg.Enabled {
		status = statusQueued
	}

	user, token, salt := requestCreds(r)
	musicDir := ""
	if s.downloads != nil {
		musicDir = s.downloads.cfg.MusicDir
	}

	now := time.Now()
	var (
		added        []entry
		skippedOwned int
		ownedSongIDs []string
		fileTracks   []playlistFileTrack
		diskIndex    []diskTrackHit
		indexed      bool
	)
	ensureIndex := func() {
		if indexed {
			return
		}
		indexed = true
		diskIndex = indexMusicDir(musicDir)
	}

	for _, t := range tracks {
		sid := ""
		if s.navidrome != nil && user != "" {
			sid = s.navidrome.findSongID(r.Context(), user, token, salt, t.Title, t.Artist)
		}
		rel := ""
		if sid == "" && musicDir != "" {
			ensureIndex()
			if hit := matchIndexedTrack(diskIndex, t.Title, t.Artist); hit != nil {
				rel = hit.Rel
				fileTracks = append(fileTracks, playlistFileTrack{Title: t.Title, Artist: t.Artist, Rel: hit.Rel})
				if s.navidrome != nil && user != "" {
					sid = s.navidrome.findSongID(r.Context(), user, token, salt, hit.Stem, hit.DirArtist)
					if sid == "" {
						sid = s.navidrome.findSongID(r.Context(), user, token, salt, hit.Stem, t.Artist)
					}
				}
			}
		}
		if sid != "" {
			skippedOwned++
			ownedSongIDs = append(ownedSongIDs, sid)
			continue
		}
		if rel != "" {
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
			AlbumArtist:        t.AlbumArtist,
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

	res := playlistImportResult{Name: name, Added: added, SkippedOwned: skippedOwned}
	if added == nil {
		res.Added = []entry{}
	}

	if s.navidrome != nil && len(tracks) > 0 {
		plCreds, ok := s.playlistCreds(r)
		if !ok {
			logf("navidrome playlist %q: no credentials", name)
		} else if err := s.syncImportedPlaylist(r.Context(), plCreds, owner, playlistID, name, ownedSongIDs, &res); err != nil {
			if s.downloads != nil {
				if scan, scanOK := s.downloads.scanCreds(); scanOK && (scan.user != plCreds.user || scan.token != plCreds.token) {
					if err2 := s.syncImportedPlaylist(r.Context(), scan, owner, playlistID, name, ownedSongIDs, &res); err2 != nil {
						logf("navidrome playlist %q: %v; scan user: %v", name, err, err2)
					}
				} else {
					logf("navidrome playlist %q: %v", name, err)
				}
			} else {
				logf("navidrome playlist %q: %v", name, err)
			}
		}
	}

	if len(fileTracks) > 0 && musicDir != "" && res.NavidromeID == "" {
		if path, err := writeLibraryPlaylist(musicDir, name, fileTracks); err != nil {
			logf("write playlist file %q: %v", name, err)
		} else {
			res.PlaylistFile = path
		}
	}

	if status == statusQueued && s.downloads != nil && len(added) > 0 {
		s.downloads.kick()
	}
	return res, nil
}

func (s *server) playlistCreds(r *http.Request) (subsonicCreds, bool) {
	user, token, salt := requestCreds(r)
	if user != "" && token != "" {
		return subsonicCreds{user: user, token: token, salt: salt}, true
	}
	if s.downloads != nil {
		return s.downloads.scanCreds()
	}
	return subsonicCreds{}, false
}

func (s *server) syncImportedPlaylist(ctx context.Context, creds subsonicCreds, owner, spotifyID, name string, songIDs []string, res *playlistImportResult) error {
	if s.navidrome == nil {
		return fmt.Errorf("navidrome is not configured")
	}
	lists, err := s.navidrome.listPlaylists(ctx, creds)
	if err != nil {
		return err
	}
	existing := s.navidrome.findPlaylistID(lists, name, owner)
	if existing == "" {
		existing = s.navidrome.findPlaylistID(lists, name, "")
	}
	if existing != "" {
		res.NavidromeID = existing
		res.NavidromeCreated = false
		if err := s.store.upsertPlaylistMirror(owner, spotifyID, existing, name); err != nil {
			logf("save playlist mirror: %v", err)
		}
		return s.appendSongsToPlaylist(ctx, creds, existing, songIDs, res)
	}
	if len(songIDs) == 0 {
		id, created, err := s.navidrome.ensureNamedPlaylist(ctx, creds, name, owner, false)
		if err != nil {
			return err
		}
		res.NavidromeID = id
		res.NavidromeCreated = created
		_ = s.store.upsertPlaylistMirror(owner, spotifyID, id, name)
		return nil
	}
	id, err := s.navidrome.createPlaylist(ctx, creds, name, songIDs)
	if err != nil {
		return err
	}
	res.NavidromeID = id
	res.NavidromeCreated = true
	res.NavidromeSongs = len(songIDs)
	_ = s.store.upsertPlaylistMirror(owner, spotifyID, id, name)
	logf("created navidrome playlist %q id=%s songs=%d", name, id, len(songIDs))
	return nil
}

func (s *server) appendSongsToPlaylist(ctx context.Context, creds subsonicCreds, playlistID string, songIDs []string, res *playlistImportResult) error {
	if len(songIDs) == 0 {
		return nil
	}
	have, err := s.navidrome.playlistSongIDs(ctx, creds, playlistID)
	if err != nil {
		have = map[string]struct{}{}
	}
	var toAdd []string
	seen := map[string]struct{}{}
	for _, sid := range songIDs {
		if _, ok := have[sid]; ok {
			continue
		}
		if _, ok := seen[sid]; ok {
			continue
		}
		seen[sid] = struct{}{}
		toAdd = append(toAdd, sid)
	}
	if err := s.navidrome.addSongsToPlaylist(ctx, creds, playlistID, toAdd); err != nil {
		return err
	}
	res.NavidromeSongs = len(toAdd)
	return nil
}

func (s *server) enqueueWholePlaylist(r *http.Request, playlistID, fallbackName string) (*entry, error) {
	e, err := s.spotify.resolve(r.Context(), "playlist", playlistID)
	if err != nil {
		e = &entry{
			Kind:       "playlist",
			SpotifyID:  playlistID,
			SpotifyURL: "https://open.spotify.com/playlist/" + playlistID,
			Title:      fallbackName,
		}
	}
	if e.Title == "" {
		e.Title = fallbackName
	}
	if e.Title == "" {
		e.Title = "Spotify playlist"
	}
	e.Owner = requestUser(r)
	e.CreatedAt = time.Now()
	e.SourcePlaylistID = playlistID
	e.SourcePlaylistName = e.Title
	if s.downloads != nil && s.downloads.cfg.Enabled {
		e.Status = statusQueued
	} else {
		e.Status = statusSkipped
	}
	if existing, err := s.store.findActiveByTitleArtist(e.Owner, e.Kind, e.Title, e.Artist); err == nil && existing != nil {
		return existing, nil
	}
	user, token, salt := requestCreds(r)
	if s.navidrome != nil && user != "" && token != "" {
		id, _, perr := s.navidrome.ensureNamedPlaylist(r.Context(),
			subsonicCreds{user: user, token: token, salt: salt}, e.Title, e.Owner, false)
		if perr != nil {
			logf("navidrome playlist %q: %v", e.Title, perr)
		} else if err := s.store.upsertPlaylistMirror(e.Owner, playlistID, id, e.Title); err != nil {
			logf("save playlist mirror: %v", err)
		}
	}
	if err := s.store.insert(e); err != nil {
		return nil, fmt.Errorf("could not save playlist: %w", err)
	}
	if e.Status == statusQueued && s.downloads != nil {
		s.downloads.kick()
	}
	return e, nil
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
