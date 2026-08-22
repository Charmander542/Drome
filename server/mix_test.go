package main

import (
	"testing"
	"time"
)

func TestNormalizeGenre(t *testing.T) {
	cases := map[string]string{
		"Hip-Hop/Rap": "Hip-Hop",
		"lofi":        "Indie",
		"R&B":         "R&B",
		"synth-pop":   "Pop",
		"":            "",
		"xyzzy":       "",
	}
	for in, want := range cases {
		if got := normalizeGenre(in); got != want {
			t.Errorf("normalizeGenre(%q)=%q want %q", in, got, want)
		}
	}
}

func TestRadioDayRollsAt4am(t *testing.T) {
	loc, err := time.LoadLocation("America/Los_Angeles")
	if err != nil {
		t.Fatal(err)
	}
	// 3:30am Pacific on Aug 22 should still be the 21st radio day.
	now := time.Date(2026, 8, 22, 3, 30, 0, 0, loc)
	if got := radioDay(now, "America/Los_Angeles"); got != "2026-08-21" {
		t.Fatalf("got %s", got)
	}
	now = time.Date(2026, 8, 22, 4, 0, 0, 0, loc)
	if got := radioDay(now, "America/Los_Angeles"); got != "2026-08-22" {
		t.Fatalf("got %s", got)
	}
}

func sampleLibrary() []mixTrack {
	mk := func(id, artist, artistID, genre string, play, rating int, starred bool) mixTrack {
		t := mixTrack{
			ID: id, Title: "Song " + id, Artist: artist, ArtistID: artistID,
			Genre: genre, Album: "LP", AlbumID: "alb-" + artistID, CoverArt: "cov-" + id,
			PlayCount: play, UserRating: rating,
		}
		if starred {
			t.Starred = "2024-01-01"
		}
		return t
	}
	var tracks []mixTrack
	// Cluster A: indie / alternative
	for i := 1; i <= 12; i++ {
		tracks = append(tracks, mk("ind-"+itoa(i), "The National", "a-nat", "Indie", 20+i, 5, i <= 3))
	}
	for i := 1; i <= 8; i++ {
		tracks = append(tracks, mk("rad-"+itoa(i), "Radiohead", "a-rad", "Alternative", 30, 5, i == 1))
	}
	// Cluster B: hip-hop
	for i := 1; i <= 10; i++ {
		tracks = append(tracks, mk("kend-"+itoa(i), "Kendrick Lamar", "a-ken", "Hip-Hop", 40, 5, i <= 2))
	}
	for i := 1; i <= 6; i++ {
		tracks = append(tracks, mk("col-"+itoa(i), "J. Cole", "a-col", "Rap", 15, 4, false))
	}
	// Cluster C: electronic
	for i := 1; i <= 9; i++ {
		tracks = append(tracks, mk("flume-"+itoa(i), "Flume", "a-flu", "Electronic", 18, 4, false))
	}
	for i := 1; i <= 7; i++ {
		tracks = append(tracks, mk("oda-"+itoa(i), "ODESZA", "a-oda", "EDM", 12, 3, false))
	}
	// Cluster D: jazz
	for i := 1; i <= 8; i++ {
		tracks = append(tracks, mk("kam-"+itoa(i), "Kamasi Washington", "a-kam", "Jazz", 8, 5, true))
	}
	return tracks
}

func TestDailyMixesAreDistinctAndCapped(t *testing.T) {
	lib := sampleLibrary()
	similar := map[string][]mixTrack{
		"a-nat": {{ID: "disc-nat", Title: "Deep Cut", Artist: "The National", ArtistID: "a-nat", Genre: "Indie"}},
		"a-ken": {{ID: "disc-ken", Title: "B-side", Artist: "Kendrick Lamar", ArtistID: "a-ken", Genre: "Hip-Hop"}},
	}
	mixes := buildDailyMixes(lib, similar, "charlie|2026-08-22")
	if len(mixes) < minDailyMixes {
		t.Fatalf("got %d mixes, want at least %d", len(mixes), minDailyMixes)
	}
	seen := map[string]string{}
	for _, m := range mixes {
		if len(m.Songs) < minClusterSongs {
			t.Errorf("%s too short: %d", m.Title, len(m.Songs))
		}
		if m.Subtitle == "" {
			t.Errorf("%s missing subtitle", m.Title)
		}
		if len(m.CoverArtIDs) == 0 {
			t.Errorf("%s missing covers", m.Title)
		}
		perArtist := map[string]int{}
		for _, s := range m.Songs {
			if prev, ok := seen[s.ID]; ok {
				t.Errorf("song %s in both %s and %s", s.ID, prev, m.Title)
			}
			seen[s.ID] = m.Title
			perArtist[s.ArtistID]++
			if perArtist[s.ArtistID] > maxSongsPerArtist*2 {
				t.Errorf("%s has %d songs by %s", m.Title, perArtist[s.ArtistID], s.Artist)
			}
		}
	}
}

func TestDailyMixesAreStableForTheDay(t *testing.T) {
	lib := sampleLibrary()
	a := buildDailyMixes(lib, nil, "charlie|2026-08-22")
	b := buildDailyMixes(lib, nil, "charlie|2026-08-22")
	if len(a) != len(b) {
		t.Fatalf("length drift %d vs %d", len(a), len(b))
	}
	for i := range a {
		if a[i].Subtitle != b[i].Subtitle {
			t.Errorf("mix %d subtitle changed", i)
		}
		if len(a[i].Songs) != len(b[i].Songs) {
			t.Errorf("mix %d length changed", i)
			continue
		}
		for j := range a[i].Songs {
			if a[i].Songs[j].ID != b[i].Songs[j].ID {
				t.Errorf("mix %d song %d changed %s -> %s", i, j, a[i].Songs[j].ID, b[i].Songs[j].ID)
				break
			}
		}
	}
}

func TestVibeMixPrefersMatchingGenres(t *testing.T) {
	lib := sampleLibrary()
	mix := buildVibeMix(lib, nil, "hype", "seed")
	if len(mix.Songs) == 0 {
		t.Fatal("empty hype mix")
	}
	matched := 0
	for _, s := range mix.Songs {
		g := normalizeGenre(s.Genre)
		if g == "Hip-Hop" || g == "Electronic" || g == "Dance" || g == "Rock" || g == "Metal" || g == "Punk" {
			matched++
		}
	}
	if matched < len(mix.Songs)/2 {
		t.Fatalf("hype mix not genre-forward: %d/%d", matched, len(mix.Songs))
	}

	chill := buildVibeMix(lib, nil, "chill", "seed")
	if chill.ID != "chill" || chill.Title == "" {
		t.Fatalf("bad chill mix %+v", chill)
	}
}

func TestLowRatedTracksExcluded(t *testing.T) {
	lib := sampleLibrary()
	lib = append(lib, mixTrack{ID: "skip-me", Title: "Nope", Artist: "X", ArtistID: "a-x", Genre: "Pop", UserRating: 1})
	mixes := buildDailyMixes(lib, nil, "seed")
	for _, m := range mixes {
		for _, s := range m.Songs {
			if s.ID == "skip-me" {
				t.Fatal("1-star track leaked into a mix")
			}
		}
	}
}
