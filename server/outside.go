package main

import (
	"context"
	"math"
	"net/http"
	"strings"
	"time"
)

// outsidePick is a song that is not in this listener's Navidrome library.
// spotifyUrl is ready for POST /wishlist, which is what downloads it.
type outsidePick struct {
	Title      string `json:"title"`
	Artist     string `json:"artist"`
	Album      string `json:"album,omitempty"`
	CoverURL   string `json:"coverUrl,omitempty"`
	SpotifyURL string `json:"spotifyUrl"`
	SpotifyID  string `json:"spotifyId"`
	// Why this showed up, e.g. "Not in your library · Radiohead".
	Reason string `json:"reason"`
}

type outsideResponse struct {
	Picks []outsidePick `json:"picks"`
	Note  string        `json:"note,omitempty"`
}

// outsideCandidate is one Spotify hit tied to the artist we searched for.
type outsideCandidate struct {
	Title      string
	Artist     string
	Album      string
	CoverURL   string
	SpotifyURL string
	SpotifyID  string
	Because    string
}

// chooseOutsidePicks keeps songs the library does not already have, skips
// anything already on the wishlist, and won't let one artist fill the list.
// owned may be nil when the caller has no library to check.
func chooseOutsidePicks(
	candidates []outsideCandidate,
	owned func(title, artist string) bool,
	alreadyWished map[string]struct{},
	perArtist, limit int,
) []outsidePick {
	if perArtist < 1 {
		perArtist = 1
	}
	if limit < 1 {
		return nil
	}
	seen := map[string]struct{}{}
	count := map[string]int{}
	out := make([]outsidePick, 0, limit)
	for _, c := range candidates {
		title := strings.TrimSpace(c.Title)
		artist := strings.TrimSpace(c.Artist)
		link := strings.TrimSpace(c.SpotifyURL)
		if title == "" || link == "" {
			continue
		}
		id := strings.TrimSpace(c.SpotifyID)
		key := strings.ToLower(id)
		if key == "" {
			key = normalizeMatchKey(title) + "|" + normalizeMatchKey(artist)
		}
		if _, ok := seen[key]; ok {
			continue
		}
		if id != "" {
			if _, ok := alreadyWished[id]; ok {
				continue
			}
		}
		because := strings.TrimSpace(c.Because)
		if because == "" {
			because = artist
		}
		if count[strings.ToLower(because)] >= perArtist {
			continue
		}
		if owned != nil && owned(title, artist) {
			continue
		}
		seen[key] = struct{}{}
		count[strings.ToLower(because)]++
		reason := "Not in your library"
		if because != "" {
			reason += " · " + because
		}
		out = append(out, outsidePick{
			Title:      title,
			Artist:     artist,
			Album:      strings.TrimSpace(c.Album),
			CoverURL:   c.CoverURL,
			SpotifyURL: link,
			SpotifyID:  id,
			Reason:     reason,
		})
		if len(out) >= limit {
			break
		}
	}
	return out
}

// requestArtistSeeds reads repeated ?artists= query values. These are the
// names this phone has learned from play history. Stars are not required.
func requestArtistSeeds(r *http.Request) []string {
	raw := r.URL.Query()["artists"]
	seen := map[string]struct{}{}
	out := make([]string, 0, len(raw))
	for _, item := range raw {
		name := strings.TrimSpace(item)
		if name == "" || len(name) > 80 {
			continue
		}
		key := strings.ToLower(name)
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		out = append(out, name)
		if len(out) >= 6 {
			break
		}
	}
	return out
}

// listeningArtistNames ranks artists by how much they are played. A star or
// a high rating adds to the score. It does not gate it — an unstarred artist
// played a lot outranks a one-off star.
func listeningArtistNames(tracks []mixTrack, n int) []string {
	if n < 1 {
		return nil
	}
	type acc struct {
		name  string
		score float64
	}
	by := map[string]*acc{}
	for _, t := range tracks {
		name := strings.TrimSpace(t.Artist)
		if name == "" {
			continue
		}
		score := 0.0
		if t.PlayCount > 0 {
			score += 1.5 * math.Log2(1+float64(t.PlayCount))
		}
		if t.UserRating > 0 {
			score += float64(t.UserRating) * 0.6
		}
		if t.isStarred() {
			score += 2
		}
		if score <= 0 {
			continue
		}
		key := strings.ToLower(name)
		row := by[key]
		if row == nil {
			row = &acc{name: name}
			by[key] = row
		}
		row.score += score
	}
	type scored struct {
		name  string
		score float64
	}
	ranked := make([]scored, 0, len(by))
	for _, row := range by {
		ranked = append(ranked, scored{name: row.name, score: row.score})
	}
	for i := 1; i < len(ranked); i++ {
		for j := i; j > 0 && ranked[j].score > ranked[j-1].score; j-- {
			ranked[j], ranked[j-1] = ranked[j-1], ranked[j]
		}
	}
	if len(ranked) > n {
		ranked = ranked[:n]
	}
	names := make([]string, 0, len(ranked))
	for _, row := range ranked {
		names = append(names, row.name)
	}
	return names
}

// planOutsidePicks finds Spotify tracks for seed artists that are not already
// in the library or wishlist. phoneSeeds come from the iOS play-history query
// string; when empty (background planner), listening history from Navidrome is
// used alone.
func (s *server) planOutsidePicks(
	ctx context.Context,
	owner string,
	creds subsonicCreds,
	phoneSeeds []string,
	seedArtists, perArtist, limit int,
) (picks []outsidePick, note string) {
	if s.spotify == nil || !s.spotify.hasAPICreds() {
		return nil, "Spotify search isn't configured on the companion."
	}
	if s.navidrome == nil || creds.user == "" {
		return nil, ""
	}
	if seedArtists < 1 {
		seedArtists = 4
	}
	if perArtist < 1 {
		perArtist = 1
	}
	if limit < 1 {
		return nil, ""
	}

	names := append([]string{}, phoneSeeds...)
	if len(names) > seedArtists {
		names = names[:seedArtists]
	}
	if len(names) < seedArtists {
		seen := map[string]struct{}{}
		for _, name := range names {
			seen[strings.ToLower(name)] = struct{}{}
		}
		snapshot := s.navidrome.mixSnapshot(ctx, creds)
		for _, name := range listeningArtistNames(snapshot, seedArtists) {
			key := strings.ToLower(name)
			if _, ok := seen[key]; ok {
				continue
			}
			seen[key] = struct{}{}
			names = append(names, name)
			if len(names) >= seedArtists {
				break
			}
		}
	}
	if len(names) == 0 {
		return nil, "Play a few songs and Drome can look for more you don't have yet."
	}

	var candidates []outsideCandidate
	for _, name := range names {
		query := `artist:"` + strings.ReplaceAll(name, `"`, "") + `"`
		hits, err := s.spotify.search(ctx, query, "track", 10)
		if err != nil {
			continue
		}
		for _, hit := range hits {
			if hit.Kind != "" && hit.Kind != "track" {
				continue
			}
			candidates = append(candidates, outsideCandidate{
				Title:      hit.Title,
				Artist:     hit.Artist,
				Album:      hit.Album,
				CoverURL:   hit.CoverURL,
				SpotifyURL: hit.SpotifyURL,
				SpotifyID:  hit.SpotifyID,
				Because:    name,
			})
		}
	}

	wished := map[string]struct{}{}
	if rows, err := s.store.listFor(owner); err == nil {
		for _, row := range rows {
			if row.SpotifyID != "" {
				wished[row.SpotifyID] = struct{}{}
			}
		}
	}

	musicDir := ""
	if s.downloads != nil {
		musicDir = s.downloads.cfg.MusicDir
	}
	picks = chooseOutsidePicks(candidates, func(title, artist string) bool {
		if s.navidrome.libraryOwns(ctx, creds.user, creds.token, creds.salt, title, artist) {
			return true
		}
		return musicDir != "" && diskHasTrack(musicDir, title, artist)
	}, wished, perArtist, limit)
	return picks, ""
}

// enqueueOutsidePick inserts one planned track onto the owner's wishlist as a
// queued download. Returns false when it was skipped (already owned/wishlisted).
func (s *server) enqueueOutsidePick(ctx context.Context, owner string, pick outsidePick, creds subsonicCreds) (bool, error) {
	id := strings.TrimSpace(pick.SpotifyID)
	if id == "" && pick.SpotifyURL != "" {
		if kind, sid, err := parseSpotifyLink(pick.SpotifyURL); err == nil && kind == "track" {
			id = sid
		}
	}
	if id == "" {
		return false, nil
	}
	entry, err := s.spotify.resolve(ctx, "track", id)
	if err != nil {
		return false, err
	}
	entry.Owner = owner
	entry.CreatedAt = time.Now()
	entry.SourcePlaylistID = autoPicksSourceID
	entry.SourcePlaylistName = autoPicksSourceName
	if s.downloads != nil && s.downloads.cfg.Enabled {
		entry.Status = statusQueued
	} else {
		entry.Status = statusSkipped
	}

	if existing, err := s.store.findActiveByTitleArtist(owner, entry.Kind, entry.Title, entry.Artist); err == nil && existing != nil {
		return false, nil
	}
	if s.navidrome != nil && creds.user != "" &&
		s.navidrome.libraryOwns(ctx, creds.user, creds.token, creds.salt, entry.Title, entry.Artist) {
		return false, nil
	}
	if s.downloads != nil && diskHasTrack(s.downloads.cfg.MusicDir, entry.Title, entry.Artist) {
		return false, nil
	}
	if err := s.store.insert(entry); err != nil {
		return false, err
	}
	return entry.Status == statusQueued, nil
}

// GET /recommendations/outside
//
// Songs Spotify knows for this listener's favorite artists that Navidrome does
// not already have. Adding one is POST /wishlist with spotifyUrl — the
// download worker already turns that into a library file.
func (s *server) handleOutsidePicks(w http.ResponseWriter, r *http.Request) {
	if s.spotify == nil || !s.spotify.hasAPICreds() {
		writeJSON(w, http.StatusOK, outsideResponse{
			Picks: []outsidePick{},
			Note:  "Spotify search isn't configured on the companion.",
		})
		return
	}
	creds, ok := s.playlistCreds(r)
	if !ok || s.navidrome == nil {
		writeJSON(w, http.StatusOK, outsideResponse{Picks: []outsidePick{}})
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 25*time.Second)
	defer cancel()

	picks, note := s.planOutsidePicks(ctx, requestUser(r), creds, requestArtistSeeds(r), 4, 3, 12)
	if picks == nil {
		picks = []outsidePick{}
	}
	writeJSON(w, http.StatusOK, outsideResponse{Picks: picks, Note: note})
}
