package main

import (
	"encoding/json"
	"testing"
)

func TestAlbumTracksPageMapping(t *testing.T) {
	// Sanity-check the JSON shape we rely on for album track pages.
	raw := []byte(`{
		"total": 2,
		"items": [
			{"id":"aaa","name":"Song A","artists":[{"name":"Artist A"}]},
			{"id":"bbb","name":"Song B","artists":[{"name":"Artist B"},{"name":"Feat"}]}
		]
	}`)
	var page struct {
		Total int `json:"total"`
		Items []struct {
			ID      string          `json:"id"`
			Name    string          `json:"name"`
			Artists []spotifyArtist `json:"artists"`
		} `json:"items"`
	}
	if err := json.Unmarshal(raw, &page); err != nil {
		t.Fatal(err)
	}
	if page.Total != 2 || len(page.Items) != 2 {
		t.Fatalf("unexpected page: %+v", page)
	}
	if joinArtists(page.Items[1].Artists) != "Artist B, Feat" {
		t.Fatalf("artists=%q", joinArtists(page.Items[1].Artists))
	}
}
