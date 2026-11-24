package main

import "testing"

func TestStripSpotifySinglesSuffix(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"2000 Miles - Spotify Singles Holiday", "2000 Miles"},
		{"Merry Christmas Darling – Spotify Singles Holiday", "Merry Christmas Darling"},
		{"Roar - Spotify Singles", "Roar"},
		{"Normal Song", "Normal Song"},
		{"Holiday Road — Spotify Singles Holiday", "Holiday Road"},
	}
	for _, tc := range cases {
		if got := stripSpotifySinglesSuffix(tc.in); got != tc.want {
			t.Fatalf("%q: got %q want %q", tc.in, got, tc.want)
		}
	}
}

func TestIsSpotifyExclusiveTitle(t *testing.T) {
	if !isSpotifyExclusiveTitle("O Holy Night - Spotify Singles Holiday", "") {
		t.Fatal("expected exclusive title")
	}
	if isSpotifyExclusiveTitle("O Holy Night", "Home Alone Soundtrack") {
		t.Fatal("expected non-exclusive")
	}
}

func TestScoreSpotifyAlternatePrefersSameArtist(t *testing.T) {
	wantTitle, wantArtist := "Holiday Road", "Kesha"
	same := searchHit{Kind: "track", Title: "Holiday Road", Artist: "Kesha", Album: "Holiday Road"}
	classic := searchHit{Kind: "track", Title: "Holiday Road - National Lampoon's Vacation", Artist: "Lindsey Buckingham", Album: "Holiday Road"}
	exclusive := searchHit{Kind: "track", Title: "Holiday Road - Spotify Singles Holiday", Artist: "Kesha", Album: "Holiday Road - Spotify Singles Holiday"}

	if scoreSpotifyAlternate(wantTitle, wantArtist, exclusive) != 0 {
		t.Fatal("exclusive must score 0")
	}
	sameScore := scoreSpotifyAlternate(wantTitle, wantArtist, same)
	classicScore := scoreSpotifyAlternate(wantTitle, wantArtist, classic)
	if sameScore <= classicScore {
		t.Fatalf("same artist should win: same=%v classic=%v", sameScore, classicScore)
	}
	if classicScore < 0.55 {
		t.Fatalf("classic cover should still qualify: %v", classicScore)
	}
}

func TestScoreSpotifyAlternateRejectsWrongSong(t *testing.T) {
	score := scoreSpotifyAlternate("O Holy Night", "Ravyn Lenae", searchHit{
		Kind:   "track",
		Title:  "Somewhere in My Memory",
		Artist: "John Williams",
		Album:  "Home Alone",
	})
	if score > 0 {
		t.Fatalf("wrong song scored %v", score)
	}
}

func TestPrimaryArtistName(t *testing.T) {
	if got := primaryArtistName("Offset, Metro Boomin"); got != "Offset" {
		t.Fatalf("got %q", got)
	}
	if got := primaryArtistName("Philip Bailey, Phil Collins"); got != "Philip Bailey" {
		t.Fatalf("got %q", got)
	}
}
