package main

import "testing"

func TestChooseOutsidePicksSkipsOwnedAndWishlist(t *testing.T) {
	cands := []outsideCandidate{
		{Title: "Karma Police", Artist: "Radiohead", SpotifyURL: "https://open.spotify.com/track/owned", SpotifyID: "owned", Because: "Radiohead"},
		{Title: "Weird Fishes", Artist: "Radiohead", SpotifyURL: "https://open.spotify.com/track/wished", SpotifyID: "wished", Because: "Radiohead"},
		{Title: "Decks Dark", Artist: "Radiohead", SpotifyURL: "https://open.spotify.com/track/new1", SpotifyID: "new1", Because: "Radiohead"},
		{Title: "Daydreaming", Artist: "Radiohead", SpotifyURL: "https://open.spotify.com/track/new2", SpotifyID: "new2", Because: "Radiohead"},
		{Title: "Burn the Witch", Artist: "Radiohead", SpotifyURL: "https://open.spotify.com/track/new3", SpotifyID: "new3", Because: "Radiohead"},
		{Title: "Ful Stop", Artist: "Radiohead", SpotifyURL: "https://open.spotify.com/track/capped", SpotifyID: "capped", Because: "Radiohead"},
		{Title: "Nikes", Artist: "Frank Ocean", SpotifyURL: "https://open.spotify.com/track/ocean", SpotifyID: "ocean", Because: "Frank Ocean"},
	}
	owned := func(title, artist string) bool {
		return title == "Karma Police"
	}
	wished := map[string]struct{}{"wished": {}}
	picks := chooseOutsidePicks(cands, owned, wished, 3, 12)
	if len(picks) != 4 {
		t.Fatalf("got %d picks, want 4 (3 Radiohead + Frank Ocean)", len(picks))
	}
	for _, p := range picks {
		if p.SpotifyID == "owned" || p.SpotifyID == "wished" || p.SpotifyID == "capped" {
			t.Fatalf("kept %s", p.SpotifyID)
		}
		if p.SpotifyURL == "" || p.Reason == "" {
			t.Fatalf("missing link or reason: %+v", p)
		}
	}
	if picks[0].Reason != "Not in your library · Radiohead" {
		t.Fatalf("reason %q", picks[0].Reason)
	}
}

func TestTasteArtistNamesPrefersStarred(t *testing.T) {
	var tracks []mixTrack
	for i := 0; i < 3; i++ {
		tracks = append(tracks, mixTrack{
			ID: "a" + itoa(i), Title: "t", Artist: "Radiohead", ArtistID: "rh",
			UserRating: 5, Starred: "true",
		})
	}
	tracks = append(tracks, mixTrack{
		ID: "b", Title: "t", Artist: "Someone Else", ArtistID: "x", UserRating: 3,
	})
	names := listeningArtistNames(tracks, 1)
	if len(names) != 1 || names[0] != "Radiohead" {
		t.Fatalf("got %v", names)
	}
}

func TestListeningArtistNamesDoNotRequireStars(t *testing.T) {
	tracks := []mixTrack{
		{ID: "1", Title: "a", Artist: "Played A Lot", ArtistID: "a", PlayCount: 40},
		{ID: "2", Title: "b", Artist: "Played A Lot", ArtistID: "a", PlayCount: 25},
		{ID: "3", Title: "c", Artist: "Starred Once", ArtistID: "b", Starred: "true", PlayCount: 1, UserRating: 5},
	}
	names := listeningArtistNames(tracks, 2)
	if len(names) < 2 || names[0] != "Played A Lot" {
		t.Fatalf("got %v", names)
	}
}
