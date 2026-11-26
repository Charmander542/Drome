package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestHasWordSync(t *testing.T) {
	word := `[00:12.00] <00:12.00>hello <00:12.40>world`
	line := `[00:12.00] hello world`
	if !hasWordSync(word) {
		t.Fatal("expected word sync")
	}
	if hasWordSync(line) {
		t.Fatal("line-only should not count as word sync")
	}
	if lyricsQuality(word) <= lyricsQuality(line) {
		t.Fatalf("word quality should beat line quality")
	}
}

func TestPickBestPrefersWordSync(t *testing.T) {
	line := lrclibResult{
		ID:           1,
		TrackName:    "Fade",
		ArtistName:   "Kanye West",
		SyncedLyrics: "[00:01.00] I feel like\n[00:04.00] more",
		Duration:     floatPtr(193),
	}
	word := lrclibResult{
		ID:           2,
		TrackName:    "Fade",
		ArtistName:   "Kanye West",
		SyncedLyrics: "[00:01.00] <00:01.00>I <00:01.20>feel <00:01.50>like\n[00:04.00] <00:04.00>more",
		Duration:     floatPtr(194),
	}
	best := pickBestLRCLIB([]lrclibResult{line, word}, "", 193)
	if best == nil || best.ID != 2 {
		t.Fatalf("expected word-synced hit, got %#v", best)
	}
}

func TestSyncAudioFileUpgradesLineToWord(t *testing.T) {
	dir := t.TempDir()
	audio := filepath.Join(dir, "01 - Track.flac")
	if err := os.WriteFile(audio, []byte("flac"), 0o644); err != nil {
		t.Fatal(err)
	}
	lrc := lrcPathForAudio(audio)
	if err := os.WriteFile(lrc, []byte("[00:01.00] hello\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if lyricsQuality(string(mustRead(t, lrc))) >= 3 {
		t.Fatal("fixture should be line-only")
	}
	word := "[00:01.00] <00:01.00>hello <00:01.40>there\n"
	if lyricsQuality(word) <= lyricsQuality(string(mustRead(t, lrc))) {
		t.Fatal("word should outrank existing")
	}
	if err := os.WriteFile(lrc, []byte(word), 0o644); err != nil {
		t.Fatal(err)
	}
	if !hasWordSync(string(mustRead(t, lrc))) {
		t.Fatal("expected upgraded word sync on disk")
	}
}

func floatPtr(v float64) *float64 { return &v }

func mustRead(t *testing.T, path string) []byte {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return b
}
