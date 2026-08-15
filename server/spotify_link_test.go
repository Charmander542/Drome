package main

import (
	"encoding/json"
	"testing"
)

func TestParseSpotifyLink(t *testing.T) {
	cases := []struct {
		raw       string
		wantKind  string
		wantID    string
		wantError bool
	}{
		{
			raw:      "https://open.spotify.com/track/11dFghVXANMlKmJXsNCbNl",
			wantKind: "track",
			wantID:   "11dFghVXANMlKmJXsNCbNl",
		},
		{
			raw:      "https://open.spotify.com/album/4aawyAB9vmqN3uQ7FjRGTy?si=abc",
			wantKind: "album",
			wantID:   "4aawyAB9vmqN3uQ7FjRGTy",
		},
		{
			raw:      "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M",
			wantKind: "playlist",
			wantID:   "37i9dQZF1DXcBWIGoYBM5M",
		},
		{
			raw:      "https://open.spotify.com/intl-de/playlist/37i9dQZF1DXcBWIGoYBM5M",
			wantKind: "playlist",
			wantID:   "37i9dQZF1DXcBWIGoYBM5M",
		},
		{
			raw:      "https://open.spotify.com/embed/track/11dFghVXANMlKmJXsNCbNl",
			wantKind: "track",
			wantID:   "11dFghVXANMlKmJXsNCbNl",
		},
		{
			raw:      "https://open.spotify.com/user/spotify/playlist/37i9dQZF1DXcBWIGoYBM5M",
			wantKind: "playlist",
			wantID:   "37i9dQZF1DXcBWIGoYBM5M",
		},
		{
			raw:      "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M",
			wantKind: "playlist",
			wantID:   "37i9dQZF1DXcBWIGoYBM5M",
		},
		{
			raw:      "Check this out https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M please",
			wantKind: "playlist",
			wantID:   "37i9dQZF1DXcBWIGoYBM5M",
		},
		{
			raw:       "https://spotify.link/abc123",
			wantError: true,
		},
		{
			raw:       "https://example.com/playlist/nope",
			wantError: true,
		},
	}

	for _, tc := range cases {
		kind, id, err := parseSpotifyLink(tc.raw)
		if tc.wantError {
			if err == nil {
				t.Fatalf("parseSpotifyLink(%q) expected error, got %s/%s", tc.raw, kind, id)
			}
			continue
		}
		if err != nil {
			t.Fatalf("parseSpotifyLink(%q) unexpected error: %v", tc.raw, err)
		}
		if kind != tc.wantKind || id != tc.wantID {
			t.Fatalf("parseSpotifyLink(%q) = %s/%s, want %s/%s", tc.raw, kind, id, tc.wantKind, tc.wantID)
		}
	}
}

func TestExtractSpotifyLinks(t *testing.T) {
	raw := `
		https://open.spotify.com/track/11dFghVXANMlKmJXsNCbNl
		spotify:album:4aawyAB9vmqN3uQ7FjRGTy
		and also https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M.
		https://spotify.link/shortOne
	`
	got := extractSpotifyLinks(raw)
	if len(got) != 4 {
		t.Fatalf("extractSpotifyLinks len=%d want 4: %#v", len(got), got)
	}
	if got[0] != "https://open.spotify.com/track/11dFghVXANMlKmJXsNCbNl" {
		t.Fatalf("first link = %q", got[0])
	}
	if got[1] != "spotify:album:4aawyAB9vmqN3uQ7FjRGTy" {
		t.Fatalf("second link = %q", got[1])
	}
	if got[2] != "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M" {
		t.Fatalf("third link trailing punct = %q", got[2])
	}
	if got[3] != "https://spotify.link/shortOne" {
		t.Fatalf("short link = %q", got[3])
	}

	// Dedup
	dup := extractSpotifyLinks("https://open.spotify.com/track/11dFghVXANMlKmJXsNCbNl\nhttps://open.spotify.com/track/11dFghVXANMlKmJXsNCbNl")
	if len(dup) != 1 {
		t.Fatalf("dedup failed: %#v", dup)
	}
}

func TestExtractSpotifyTrackIDs(t *testing.T) {
	html := `
		{"uri":"spotify:track:11dFghVXANMlKmJXsNCbNl"}
		https://open.spotify.com/track/7ouMYWpwJ422jRcKU4soBa
		spotify:playlist:37i9dQZF1DWSqmBTGDYngZ
		spotify:track:11dFghVXANMlKmJXsNCbNl
	`
	got := extractSpotifyTrackIDs(html)
	if len(got) != 2 {
		t.Fatalf("ids=%v want 2 unique tracks", got)
	}
	if got[0] != "11dFghVXANMlKmJXsNCbNl" || got[1] != "7ouMYWpwJ422jRcKU4soBa" {
		t.Fatalf("ids=%v", got)
	}

	escaped := `{"uri":"spotify\u003atrack:7ouMYWpwJ422jRcKU4soBa"}`
	got = extractSpotifyTrackIDs(escaped)
	if len(got) != 1 || got[0] != "7ouMYWpwJ422jRcKU4soBa" {
		t.Fatalf("unicode-escaped ids=%v", got)
	}
}

func TestExtractPlaylistTracksFromHTML(t *testing.T) {
	html := `<script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"state":{"data":{"entity":{"type":"playlist","name":"Today’s Top Hits","trackList":[{"uri":"spotify:track:3ouNEk0tv5TTi8VWMe1xbX","title":"Animal","subtitle":"KATSEYE"},{"uri":"spotify:track:4LfCY65LvojKjWEnU7fNN4","title":"stupid song","subtitle":"Olivia Rodrigo"}]}}}}}}</script>`
	tracks := extractPlaylistTracksFromHTML(html)
	if len(tracks) != 2 {
		t.Fatalf("tracks=%d %#v", len(tracks), tracks)
	}
	if tracks[0].Title != "Animal" || tracks[0].Artist != "KATSEYE" {
		t.Fatalf("first=%+v", tracks[0])
	}
	if tracks[0].SpotifyID != "3ouNEk0tv5TTi8VWMe1xbX" {
		t.Fatalf("id=%s", tracks[0].SpotifyID)
	}
	if tracks[1].Title != "stupid song" || tracks[1].Artist != "Olivia Rodrigo" {
		t.Fatalf("second=%+v", tracks[1])
	}
	if name := playlistNameFromHTML(html); name != "Today’s Top Hits" {
		t.Fatalf("playlist name=%q", name)
	}
}

func TestMissingMetaAndCopyFields(t *testing.T) {
	if !missingMeta("") || !missingMeta("Unknown Album") || missingMeta("The Heist") {
		t.Fatal("missingMeta")
	}
	dst := &entry{Title: "Irish Celebration"}
	src := &entry{Title: "Other", Artist: "Macklemore", Album: "The Heist", CoverURL: "https://x"}
	copyMissingEntryFields(dst, src)
	if dst.Title != "Irish Celebration" || dst.Artist != "Macklemore" || dst.Album != "The Heist" {
		t.Fatalf("copy=%+v", dst)
	}
}

func TestExtractSpotifyAccessToken(t *testing.T) {
	html := `<html><script id="session" type="application/json">{"accessToken":"BQC_test_token","expire":1}</script></html>`
	if got := extractSpotifyAccessToken(html); got != "BQC_test_token" {
		t.Fatalf("session script token = %q", got)
	}
	html = `{"accessToken":"from_json"}`
	if got := extractSpotifyAccessToken(html); got != "from_json" {
		t.Fatalf("json token = %q", got)
	}
}

func TestPlaylistIDFromCreateResponse(t *testing.T) {
	raw := json.RawMessage(`{"status":"ok","playlist":{"id":42,"name":"Hits"}}`)
	if got := playlistIDFromCreateResponse(raw); got != "42" {
		t.Fatalf("numeric id = %q", got)
	}
	raw = json.RawMessage(`{"status":"ok","playlist":{"id":"abc-uuid","name":"Hits"}}`)
	if got := playlistIDFromCreateResponse(raw); got != "abc-uuid" {
		t.Fatalf("string id = %q", got)
	}
}
func TestSpotifyAPIPath(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"/playlists/abc/tracks?offset=100", "/playlists/abc/tracks?offset=100"},
		{"https://api.spotify.com/v1/playlists/abc/tracks?offset=100&limit=100", "/playlists/abc/tracks?offset=100&limit=100"},
		{"playlists/abc/tracks", "/playlists/abc/tracks"},
	}
	for _, tc := range cases {
		if got := spotifyAPIPath(tc.in); got != tc.want {
			t.Fatalf("spotifyAPIPath(%q)=%q want %q", tc.in, got, tc.want)
		}
	}
}

func TestPlaylistTracksFromPageSkipsNullTracks(t *testing.T) {
	raw := []byte(`{"total":2,"items":[
		{"track":null},
		{"track":{"id":"11dFghVXANMlKmJXsNCbNl","name":"Cut","artists":[{"name":"A"}],"album":{"name":"B"},"external_urls":{"spotify":"https://open.spotify.com/track/11dFghVXANMlKmJXsNCbNl"}}}
	]}`)
	var page playlistTracksPage
	if err := json.Unmarshal(raw, &page); err != nil {
		t.Fatal(err)
	}
	got := playlistTracksFromPage(page)
	if len(got) != 1 || got[0].Title != "Cut" || got[0].Artist != "A" {
		t.Fatalf("got %#v", got)
	}
}
