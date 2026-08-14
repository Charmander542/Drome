package main

import (
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
