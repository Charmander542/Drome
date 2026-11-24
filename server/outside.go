package main

import (
	"context"
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

// tasteArtistNames is who to look outside the library for: the artists this
// listener has already starred, strongest first.
func tasteArtistNames(tracks []mixTrack, n int) []string {
	if n < 1 {
		return nil
	}
	stats := topArtists(tracks, n)
	seen := map[string]struct{}{}
	names := make([]string, 0, len(stats))
	for _, a := range stats {
		name := strings.TrimSpace(a.name)
		if name == "" {
			continue
		}
		key := strings.ToLower(name)
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		names = append(names, name)
		if len(names) >= n {
			break
		}
	}
	return names
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

	starred := s.navidrome.getStarredSongs(ctx, creds)
	tracks := make([]mixTrack, 0, len(starred))
	for _, song := range starred {
		t := song.asMix()
		if t.ID == "" {
			continue
		}
		t.Starred = "true"
		tracks = append(tracks, t)
	}
	names := tasteArtistNames(tracks, 4)
	if len(names) == 0 {
		writeJSON(w, http.StatusOK, outsideResponse{
			Picks: []outsidePick{},
			Note:  "Star a few songs and Drome can look for more you don't have yet.",
		})
		return
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
	if rows, err := s.store.listFor(requestUser(r)); err == nil {
		for _, row := range rows {
			if row.SpotifyID != "" {
				wished[row.SpotifyID] = struct{}{}
			}
		}
	}

	picks := chooseOutsidePicks(candidates, func(title, artist string) bool {
		return s.navidrome.libraryOwns(ctx, creds.user, creds.token, creds.salt, title, artist)
	}, wished, 3, 12)
	if picks == nil {
		picks = []outsidePick{}
	}
	writeJSON(w, http.StatusOK, outsideResponse{Picks: picks})
}
