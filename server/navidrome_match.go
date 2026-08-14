package main

import (
	"context"
	"encoding/json"
	"io/fs"
	"net/http"
	"net/url"
	"path/filepath"
	"regexp"
	"strings"
)

var (
	nonAlphaNum    = regexp.MustCompile(`[^a-z0-9\s]+`)
	trackNumPrefix = regexp.MustCompile(`^\d{1,3}\s*[-.]\s*`)
)

func normalizeMatchKey(raw string) string {
	s := strings.ToLower(raw)
	for _, token := range []string{"(feat.", "(ft.", "(with ", "- remaster", "(remaster", "[remaster"} {
		if i := strings.Index(s, token); i >= 0 {
			s = s[:i]
		}
	}
	s = nonAlphaNum.ReplaceAllString(s, " ")
	s = strings.Join(strings.Fields(s), " ")
	s = strings.TrimPrefix(s, "the ")
	return strings.TrimSpace(s)
}

func artistsMatch(a, b string) bool {
	a, b = normalizeMatchKey(a), normalizeMatchKey(b)
	if a == "" || b == "" {
		return false
	}
	if a == b || strings.Contains(a, b) || strings.Contains(b, a) {
		return true
	}
	for _, tok := range strings.Fields(a) {
		if len(tok) < 4 {
			continue
		}
		for _, other := range strings.Fields(b) {
			if tok == other {
				return true
			}
		}
	}
	return false
}

func titlesMatch(a, b string) bool {
	a, b = normalizeMatchKey(a), normalizeMatchKey(b)
	if a == "" || b == "" {
		return false
	}
	return a == b || strings.Contains(a, b) || strings.Contains(b, a)
}

// libraryOwns reports whether the user's Navidrome library already has a close
// title+artist match for the given track (via search3).
func (v *navidromeVerifier) libraryOwns(ctx context.Context, user, token, salt, title, artist string) bool {
	if v == nil {
		return false
	}
	if normalizeMatchKey(title) == "" {
		return false
	}

	queries := []string{strings.TrimSpace(title)}
	if strings.TrimSpace(artist) != "" {
		queries = append(queries, strings.TrimSpace(title+" "+artist))
	}

	seen := map[string]bool{}
	for _, query := range queries {
		if query == "" || seen[query] {
			continue
		}
		seen[query] = true
		if v.searchOwns(ctx, user, token, salt, query, title, artist) {
			return true
		}
	}
	return false
}

func (v *navidromeVerifier) searchOwns(ctx context.Context, user, token, salt, query, title, artist string) bool {
	q := url.Values{}
	q.Set("u", user)
	q.Set("t", token)
	q.Set("s", salt)
	q.Set("v", "1.16.1")
	q.Set("c", "drome-server")
	q.Set("f", "json")
	q.Set("query", query)
	q.Set("artistCount", "0")
	q.Set("albumCount", "0")
	q.Set("songCount", "50")

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, v.baseURL+"/rest/search3.view?"+q.Encode(), nil)
	if err != nil {
		return false
	}
	resp, err := v.client.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()

	var body struct {
		SubsonicResponse struct {
			Status        string `json:"status"`
			SearchResult3 *struct {
				Song []struct {
					Title  string `json:"title"`
					Artist string `json:"artist"`
				} `json:"song"`
			} `json:"searchResult3"`
		} `json:"subsonic-response"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return false
	}
	if body.SubsonicResponse.Status != "ok" || body.SubsonicResponse.SearchResult3 == nil {
		return false
	}
	for _, song := range body.SubsonicResponse.SearchResult3.Song {
		if !titlesMatch(song.Title, title) {
			continue
		}
		if strings.TrimSpace(artist) == "" || artistsMatch(song.Artist, artist) {
			return true
		}
	}
	return false
}

func requestCreds(r *http.Request) (user, token, salt string) {
	user = r.URL.Query().Get("u")
	token = r.URL.Query().Get("t")
	salt = r.URL.Query().Get("s")
	if user == "" {
		user = r.Header.Get("X-Drome-User")
		token = r.Header.Get("X-Drome-Token")
		salt = r.Header.Get("X-Drome-Salt")
	}
	return user, token, salt
}

func fileTitleKey(filename string) string {
	stem := strings.TrimSuffix(filename, filepath.Ext(filename))
	stem = trackNumPrefix.ReplaceAllString(stem, "")
	if i := strings.Index(stem, " ("); i > 0 {
		stem = stem[:i]
	}
	return stem
}

func diskHasTrack(musicDir, title, artist string) bool {
	if musicDir == "" || normalizeMatchKey(title) == "" {
		return false
	}
	found := false
	_ = filepath.WalkDir(musicDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil || found {
			return nil
		}
		if d.IsDir() {
			if strings.HasPrefix(d.Name(), ".") {
				return filepath.SkipDir
			}
			return nil
		}
		switch strings.ToLower(filepath.Ext(d.Name())) {
		case ".flac", ".m4a", ".mp3", ".ogg", ".opus", ".wav", ".aiff":
		default:
			return nil
		}
		if !titlesMatch(fileTitleKey(d.Name()), title) {
			return nil
		}
		rel, err := filepath.Rel(musicDir, path)
		if err != nil {
			return nil
		}
		parts := strings.Split(rel, string(filepath.Separator))
		dirArtist := ""
		if len(parts) >= 2 {
			dirArtist = parts[0]
		}
		if artist == "" || dirArtist == "" || artistsMatch(dirArtist, artist) {
			found = true
			return fs.SkipAll
		}
		return nil
	})
	return found
}
