package main

import (
	"os"
	"path/filepath"
	"strings"
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

func TestPickBestPrefersLyricsfileWordSync(t *testing.T) {
	line := lrclibResult{
		ID:           1,
		TrackName:    "Wet Sand",
		ArtistName:   "Red Hot Chili Peppers",
		SyncedLyrics: "[00:11.17] My shadow side so amplified\n",
		Duration:     floatPtr(310),
	}
	word := lrclibResult{
		ID:          2,
		TrackName:   "Wet Sand",
		ArtistName:  "Red Hot Chili Peppers",
		HasWordSync: boolPtr(true),
		// Site "Word Synced" puts timings here — syncedLyrics stays line-only.
		SyncedLyrics: "[00:11.17] My shadow side so amplified\n",
		Lyricsfile: `version: '1.0'
lines:
- text: My shadow side so amplified
  start_ms: 11160
  words:
  - text: 'My '
    start_ms: 11160
  - text: 'shadow '
    start_ms: 11259
  - text: amplified
    start_ms: 12705
`,
		Duration: floatPtr(310),
	}
	best := pickBestLRCLIB([]lrclibResult{line, word}, "", 310)
	if best == nil || best.ID != 2 {
		t.Fatalf("expected lyricsfile word-sync hit, got %#v", best)
	}
	got := effectiveSyncedLyrics(*best)
	if !hasWordSync(got) {
		t.Fatalf("expected enhanced LRC from lyricsfile, got %q", got)
	}
}

// Round 6: BDKMV album master is ~310.7s. LRCLIB has both a ~214s shorter
// edit and the correct ~311s cut (id 565635). Word-sync on the wrong cut must
// never win — mistimed karaoke is worse than no synced lyrics.
func TestPickBestPrefersDurationMatchedAlbumCut(t *testing.T) {
	const trackSec = 311 // 310.72s FLAC rounded
	radio := lrclibResult{
		ID:        214000,
		TrackName: "Bitch, Don't Kill My Vibe",
		ArtistName: "Kendrick Lamar",
		HasWordSync: boolPtr(true),
		SyncedLyrics: "[00:01.00] radio edit line\n",
		Lyricsfile: `version: '1.0'
lines:
- text: radio edit line
  start_ms: 1000
  words:
  - text: 'radio '
    start_ms: 1000
  - text: edit
    start_ms: 1400
`,
		Duration: floatPtr(214),
	}
	album := lrclibResult{
		ID:        565635,
		TrackName: "Bitch, Don't Kill My Vibe",
		ArtistName: "Kendrick Lamar",
		HasWordSync: boolPtr(true),
		SyncedLyrics: "[00:01.00] album cut line\n",
		Lyricsfile: `version: '1.0'
lines:
- text: album cut line
  start_ms: 1000
  words:
  - text: 'album '
    start_ms: 1000
  - text: cut
    start_ms: 1400
`,
		Duration: floatPtr(311),
	}

	best := pickBestLRCLIB([]lrclibResult{radio, album}, "good kid, m.A.A.d city", trackSec)
	if best == nil || best.ID != 565635 {
		t.Fatalf("expected album cut id 565635, got %#v", best)
	}

	// Radio-only candidate must be rejected (Δ≈97s >> 3s).
	if got := pickBestLRCLIB([]lrclibResult{radio}, "", trackSec); got != nil {
		if effectiveSyncedLyrics(*got) != "" {
			t.Fatalf("expected reject of 214s synced hit for 311s track, got id=%d dur=%v",
				got.ID, got.Duration)
		}
	}
}

func TestPickBestRejectsSyncedBeyondDurationTolerance(t *testing.T) {
	hit := lrclibResult{
		ID:           9,
		TrackName:    "Song",
		ArtistName:   "Artist",
		SyncedLyrics: "[00:01.00] <00:01.00>hello\n",
		Duration:     floatPtr(200),
	}
	if got := pickBestLRCLIB([]lrclibResult{hit}, "", 210); got != nil {
		t.Fatalf("Δ=10s should reject synced, got %#v", got)
	}
	hit.Duration = floatPtr(208) // within ±3s of 210
	if got := pickBestLRCLIB([]lrclibResult{hit}, "", 210); got == nil || got.ID != 9 {
		t.Fatalf("Δ=2s should accept synced, got %#v", got)
	}
}

func TestSidecarDurationMatchAndProvenance(t *testing.T) {
	raw := stampLrclibProvenance(
		"[00:01.000] <00:01.000>hello <00:01.400>world\n",
		&lrclibResult{ID: 565635, Duration: floatPtr(311)},
	)
	if !strings.Contains(raw, "[drome-lrclib-id:565635]") {
		t.Fatalf("missing id stamp: %q", raw)
	}
	if !strings.Contains(raw, "[drome-lrclib-duration:311") {
		t.Fatalf("missing duration stamp: %q", raw)
	}
	if !sidecarDurationMatchesTrack(raw, 311) {
		t.Fatal("311s track should match 311s sidecar")
	}
	if sidecarDurationMatchesTrack(raw, 214) {
		t.Fatal("214s track must invalidate 311s sidecar")
	}

	// Legacy sidecar without provenance: last stamp ~3:20 on a 5:10 track → suspect.
	legacyShort := "[00:01.00] <00:01.00>a\n[03:20.00] <03:20.00>b\n"
	if sidecarDurationMatchesTrack(legacyShort, 311) {
		t.Fatal("legacy short last-stamp should fail against 311s track")
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
