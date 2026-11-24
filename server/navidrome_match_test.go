package main

import "testing"

func TestNormalizeMatchKeyStripsThe(t *testing.T) {
	if got := normalizeMatchKey("The Goo Goo Dolls"); got != "goo goo dolls" {
		t.Fatalf("got %q", got)
	}
	if got := normalizeMatchKey("Iris (feat. Someone)"); got != "iris" {
		t.Fatalf("got %q", got)
	}
}

func TestArtistsMatch(t *testing.T) {
	if !artistsMatch("The Goo Goo Dolls", "Goo Goo Dolls") {
		t.Fatal("the-prefix")
	}
	if !artistsMatch("Macklemore & Ryan Lewis, Macklemore, Ryan Lewis", "Macklemore") {
		t.Fatal("multi vs primary")
	}
	if artistsMatch("Radiohead", "Nirvana") {
		t.Fatal("false positive")
	}
}

func TestTitlesMatch(t *testing.T) {
	if !titlesMatch("Iris", "Iris") {
		t.Fatal("exact")
	}
	if !titlesMatch(fileTitleKey("01 - Iris.flac"), "Iris") {
		t.Fatal("filename stem")
	}
	if !titlesMatch("買你", "買你") {
		t.Fatal("cjk exact")
	}
	if got := normalizeMatchKey("買你"); got == "" {
		t.Fatal("cjk normalize emptied title")
	}
	if !titlesMatch("新・仁義なき戦いのテーマ", "新・仁義なき戦いのテーマ") {
		t.Fatal("japanese title")
	}
	// Short substrings must not claim ownership of unrelated songs.
	if titlesMatch("Jingle Bell Rock", "i") || titlesMatch("i", "Jingle Bell Rock") {
		t.Fatal("kendrick i vs jingle bell rock")
	}
	if titlesMatch("All I Want for Christmas Is You", "yo!") {
		t.Fatal("yo vs all i want")
	}
	if titlesMatch("It's Beginning to Look a Lot like Christmas", "a lot") {
		t.Fatal("a lot vs christmas")
	}
	if titlesMatch("Sleigh Ride", "Ride") {
		t.Fatal("ride vs sleigh ride — short side too short")
	}
	if !titlesMatch("See You Again (feat. Kali Uchis)", "See You Again") {
		t.Fatal("long phrase containment should still work")
	}
}

func TestMatchIndexedTrackIgnoresWrongArtist(t *testing.T) {
	index := []diskTrackHit{
		{Rel: "Kendrick Lamar/TPAB/40 - i.flac", Stem: "i", DirArtist: "Kendrick Lamar"},
		{Rel: "Vacations/Vibes/26 - Home.flac", Stem: "Home", DirArtist: "Vacations"},
	}
	if hit := matchIndexedTrack(index, "Jingle Bell Rock", "Bobby Helms"); hit != nil {
		t.Fatalf("false owned via short title: %+v", hit)
	}
	if hit := matchIndexedTrack(index, "Please Come Home for Christmas", "Eagles"); hit != nil {
		t.Fatalf("false owned via home: %+v", hit)
	}
}

func TestFileTitleKey(t *testing.T) {
	if got := fileTitleKey("01 - Iris.flac"); normalizeMatchKey(got) != "iris" {
		t.Fatalf("got %q", got)
	}
}

func TestIsCompilationArtist(t *testing.T) {
	if !isCompilationArtist("Various Artists") || !isCompilationArtist("VA") {
		t.Fatal("expected compilation")
	}
	if isCompilationArtist("Elaine Paige") {
		t.Fatal("solo artist")
	}
}
