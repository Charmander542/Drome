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
	if !titlesMatch("01 - Iris", "Iris") {
		t.Fatal("filename")
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
