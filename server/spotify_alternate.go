package main

import (
	"context"
	"fmt"
	"regexp"
	"strings"
)

// Spotify Singles (and Singles Holiday) are often exclusives that never appear
// on Tidal/Qobuz/Amazon. When the exact recording is unavailable, Drome can
// search Spotify for the nearest non-exclusive recording of the same song —
// preferably by the same artist, otherwise a well-known alternate (e.g.
// Pretenders for "2000 Miles").

var spotifySinglesSuffixRe = regexp.MustCompile(`(?i)\s*[-–—]\s*Spotify Singles(?:\s+Holiday)?\s*$`)

func isSpotifyExclusiveTitle(title, album string) bool {
	blob := strings.ToLower(title + " " + album)
	return strings.Contains(blob, "spotify singles")
}

func stripSpotifySinglesSuffix(title string) string {
	title = strings.TrimSpace(title)
	cleaned := strings.TrimSpace(spotifySinglesSuffixRe.ReplaceAllString(title, ""))
	if cleaned == "" {
		return title
	}
	return cleaned
}

func primaryArtistName(artist string) string {
	artist = strings.TrimSpace(artist)
	if artist == "" {
		return ""
	}
	for _, sep := range []string{",", ";", " feat.", " ft.", " featuring ", " with ", " & ", " x "} {
		if i := strings.Index(strings.ToLower(artist), sep); i > 0 {
			artist = artist[:i]
			break
		}
	}
	return strings.TrimSpace(artist)
}

func alternateTitleScore(want, got string) float64 {
	a, b := normalizeMatchKey(want), normalizeMatchKey(got)
	if a == "" || b == "" {
		return 0
	}
	if a == b {
		return 1
	}
	aw, bw := strings.Fields(a), strings.Fields(b)
	if len(aw) == 0 || len(bw) == 0 {
		return 0
	}
	set := map[string]struct{}{}
	for _, t := range bw {
		set[t] = struct{}{}
	}
	hit := 0
	for _, t := range aw {
		if _, ok := set[t]; ok {
			hit++
		}
	}
	// How much of the wanted title is present in the candidate. Extra remaster /
	// soundtrack suffixes on the candidate shouldn't tank a real match
	// ("Holiday Road" vs "Holiday Road National Lampoon's Vacation").
	cover := float64(hit) / float64(len(aw))
	if cover < 0.8 {
		return cover * 0.5
	}
	if cover >= 1 {
		if strings.HasPrefix(b, a) || strings.Contains(b, a) {
			return 0.92
		}
		return 0.85
	}
	return cover
}

func scoreSpotifyAlternate(wantTitle, wantArtist string, hit searchHit) float64 {
	if hit.Kind != "" && hit.Kind != "track" {
		return 0
	}
	if isSpotifyExclusiveTitle(hit.Title, hit.Album) {
		return 0
	}
	titleScore := alternateTitleScore(wantTitle, hit.Title)
	if titleScore < 0.55 {
		return 0
	}
	artistScore := 0.0
	if artistsMatch(wantArtist, hit.Artist) {
		artistScore = 1
	} else if primaryArtistName(wantArtist) != "" &&
		artistsMatch(primaryArtistName(wantArtist), primaryArtistName(hit.Artist)) {
		artistScore = 0.85
	}
	// Title dominates; same-artist is a strong bonus but not required for
	// cover songs that only exist as Spotify exclusives.
	return titleScore*0.7 + artistScore*0.3
}

// findNearestSpotifyAlternate picks a non-exclusive Spotify recording for a
// Spotify Singles wishlist track. Returns nil when nothing close enough exists.
func (c *spotifyClient) findNearestSpotifyAlternate(ctx context.Context, e *entry) (*searchHit, error) {
	if c == nil || e == nil || !c.hasAPICreds() {
		return nil, fmt.Errorf("spotify search unavailable")
	}
	if !isSpotifyExclusiveTitle(e.Title, e.Album) {
		return nil, nil
	}
	baseTitle := stripSpotifySinglesSuffix(e.Title)
	if baseTitle == "" {
		return nil, nil
	}
	wantArtist := primaryArtistName(e.Artist)
	origID := strings.TrimSpace(e.SpotifyID)

	var candidates []searchHit
	queries := []string{}
	if wantArtist != "" {
		queries = append(queries, fmt.Sprintf(`track:"%s" artist:"%s"`, baseTitle, wantArtist))
	}
	queries = append(queries, fmt.Sprintf(`track:"%s"`, baseTitle))
	queries = append(queries, baseTitle+" "+wantArtist)
	queries = append(queries, baseTitle)

	seen := map[string]bool{}
	if origID != "" {
		seen[origID] = true
	}
	for _, q := range queries {
		hits, err := c.search(ctx, q, "track", 10)
		if err != nil {
			return nil, err
		}
		for _, h := range hits {
			if h.SpotifyID == "" || seen[h.SpotifyID] {
				continue
			}
			seen[h.SpotifyID] = true
			if scoreSpotifyAlternate(baseTitle, wantArtist, h) <= 0 {
				continue
			}
			candidates = append(candidates, h)
		}
	}
	if len(candidates) == 0 {
		return nil, nil
	}

	best := candidates[0]
	bestScore := scoreSpotifyAlternate(baseTitle, wantArtist, best)
	for _, h := range candidates[1:] {
		s := scoreSpotifyAlternate(baseTitle, wantArtist, h)
		switch {
		case s > bestScore+0.02:
			best, bestScore = h, s
		case s >= bestScore-0.02 && h.Popularity > best.Popularity:
			// Near-tied title/artist scores: prefer the better-known recording
			// (Pretenders over a random indie cover of the same song).
			best, bestScore = h, s
		}
	}
	if bestScore < 0.55 {
		return nil, nil
	}
	out := best
	return &out, nil
}
