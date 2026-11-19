package main

import (
	"strings"
	"testing"
)

func TestNormalizeLyricsText(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"Don't Stop Believin'", "dont stop believin"},
		{"café au lait", "cafe au lait"},
		{"HELLO, WORLD!!!", "hello world"},
		{"it’s a beautiful day", "its a beautiful day"},
		{"  spaced\tout  ", "spaced out"},
	}
	for _, tc := range cases {
		got := normalizeLyricsText(tc.in)
		if got != tc.want {
			t.Fatalf("normalize(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestFuzzyMisspelledLine(t *testing.T) {
	doc := newLyricsDocument("1", "Never Gonna Give You Up", "Rick Astley", "Whenever",
		"Never gonna give you up\nNever gonna let you down")
	hits := searchLyricsDocuments([]lyricsDocument{doc}, buildLyricsBuckets([]lyricsDocument{doc}),
		"never gonna giv you up", 5, 100)
	if len(hits) != 1 {
		t.Fatalf("expected 1 hit, got %d", len(hits))
	}
	if !strings.Contains(strings.ToLower(hits[0].MatchedLine), "give you up") {
		t.Fatalf("unexpected matched line %q", hits[0].MatchedLine)
	}
	if hits[0].Score <= 0 {
		t.Fatalf("expected positive score")
	}
}

func TestFuzzyReorderedLine(t *testing.T) {
	doc := newLyricsDocument("1", "Song", "Artist", "Album",
		"we're no strangers to love\nyou know the rules and so do I")
	hits := searchLyricsDocuments([]lyricsDocument{doc}, buildLyricsBuckets([]lyricsDocument{doc}),
		"strangers love no", 5, 100)
	if len(hits) != 1 {
		t.Fatalf("expected reordered bag-of-tokens hit, got %d", len(hits))
	}
	// Exact in-order query should score higher than reordered.
	ordered := searchLyricsDocuments([]lyricsDocument{doc}, buildLyricsBuckets([]lyricsDocument{doc}),
		"no strangers to love", 5, 100)
	if len(ordered) != 1 {
		t.Fatalf("expected ordered hit")
	}
	if ordered[0].Score <= hits[0].Score {
		t.Fatalf("ordered score %.1f should beat reordered %.1f", ordered[0].Score, hits[0].Score)
	}
}

func TestFuzzyPunctuationHeavyLine(t *testing.T) {
	doc := newLyricsDocument("1", "Song", "Artist", "Album",
		`She said, "Don't you know?" — it's over now!!!`)
	hits := searchLyricsDocuments([]lyricsDocument{doc}, buildLyricsBuckets([]lyricsDocument{doc}),
		"dont you know its over", 5, 100)
	if len(hits) != 1 {
		t.Fatalf("expected punctuation-tolerant hit, got %d", len(hits))
	}
}

func TestFuzzyNonMatch(t *testing.T) {
	doc := newLyricsDocument("1", "Song", "Artist", "Album",
		"Never gonna give you up\nNever gonna let you down")
	hits := searchLyricsDocuments([]lyricsDocument{doc}, buildLyricsBuckets([]lyricsDocument{doc}),
		"purple elephant sandwich", 5, 100)
	if len(hits) != 0 {
		t.Fatalf("expected no hit, got %+v", hits)
	}
}

func TestTokenSimilarityTypoTolerance(t *testing.T) {
	if tokenSimilarity("give", "give") != 1 {
		t.Fatal("exact")
	}
	if tokenSimilarity("giv", "give") < 0.5 {
		t.Fatal("short typo / prefix should match")
	}
	if tokenSimilarity("believin", "believing") < 0.5 {
		t.Fatal("longer token DL≤2 should match")
	}
	if tokenSimilarity("xyz", "give") != 0 {
		t.Fatal("unrelated should be 0")
	}
}
