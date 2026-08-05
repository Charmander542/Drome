package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"regexp"
	"strings"
)

var nonAlphaNum = regexp.MustCompile(`[^a-z0-9\s]+`)

func normalizeMatchKey(raw string) string {
	s := strings.ToLower(raw)
	for _, token := range []string{"(feat.", "(ft.", "(with ", "- remaster", "(remaster", "[remaster"} {
		if i := strings.Index(s, token); i >= 0 {
			s = s[:i]
		}
	}
	s = nonAlphaNum.ReplaceAllString(s, " ")
	return strings.Join(strings.Fields(s), " ")
}

// libraryOwns reports whether the user's Navidrome library already has a close
// title+artist match for the given track (via search3).
func (v *navidromeVerifier) libraryOwns(ctx context.Context, user, token, salt, title, artist string) bool {
	titleKey := normalizeMatchKey(title)
	if titleKey == "" {
		return false
	}
	artistKey := normalizeMatchKey(artist)
	query := strings.TrimSpace(title + " " + artist)
	if query == "" {
		return false
	}

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
	q.Set("songCount", "12")

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
		t := normalizeMatchKey(song.Title)
		if t != titleKey {
			continue
		}
		if artistKey == "" {
			return true
		}
		a := normalizeMatchKey(song.Artist)
		if a == "" {
			continue
		}
		if a == artistKey || strings.Contains(a, artistKey) || strings.Contains(artistKey, a) {
			return true
		}
		at := firstToken(artistKey)
		st := firstToken(a)
		if at != "" && at == st {
			return true
		}
	}
	return false
}

func firstToken(s string) string {
	parts := strings.Fields(s)
	if len(parts) == 0 {
		return ""
	}
	return parts[0]
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
