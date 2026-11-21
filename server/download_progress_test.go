package main

import (
	"strings"
	"testing"
	"time"
)

func TestIsInterestingProgressLine(t *testing.T) {
	cases := []struct {
		in   string
		want bool
	}{
		{"Downloading via tidal…", true},
		{"║  Successful    : 1", true},
		{"║  Total Tracks  : 12", true},
		{"Track 3/12", true},
		{"════════════════", false},
		{"random noise", false},
		{"✗ Failed: demo — All providers failed", true},
		{"drome-download: no audio files written", true},
	}
	for _, tc := range cases {
		if got := isInterestingProgressLine(tc.in); got != tc.want {
			t.Fatalf("%q: got %v want %v", tc.in, got, tc.want)
		}
	}
}

func TestApplyProgressHints(t *testing.T) {
	a := &activeDownload{}
	applyProgressHints(a, "║  Total Tracks  : 8")
	applyProgressHints(a, "║  Successful    : 3")
	applyProgressHints(a, "Track 4/8 fetching tidal")
	if a.TracksTotal != 8 {
		t.Fatalf("TracksTotal=%d", a.TracksTotal)
	}
	if a.TracksDone != 4 {
		t.Fatalf("TracksDone=%d (want 4 from track-of)", a.TracksDone)
	}
}

func TestFormatActiveStatus(t *testing.T) {
	msg := formatActiveStatus(&activeDownload{
		Phase:       "spotiflac",
		Detail:      "Downloading via tidal",
		TracksDone:  2,
		TracksTotal: 5,
	})
	if !strings.Contains(msg, "spotiflac 2/5") || !strings.Contains(msg, "tidal") {
		t.Fatalf("unexpected status: %q", msg)
	}
}

func TestDownloadProgressHTMLContainsSections(t *testing.T) {
	html := downloadProgressHTML(downloadStatusReport{
		Enabled:   true,
		UpdatedAt: time.Date(2026, 11, 20, 12, 0, 0, 0, time.UTC),
		Queue:     downloadQueueStats{Queued: 2, Downloading: 1, Failed: 1, Retrying: 1, Total: 4},
		Active: &activeDownload{
			Title:       "Cut To The Feeling",
			Artist:      "Carly Rae Jepsen",
			Kind:        "track",
			Phase:       "spotiflac",
			Detail:      "Downloading via tidal",
			Attempt:     1,
			MaxAttempts: 5,
			TracksDone:  0,
			TracksTotal: 1,
		},
		Playlists: []playlistDownloadProgress{{
			PlaylistID:   "abc",
			PlaylistName: "Road Trip",
			Queued:       4,
			Downloading:  1,
			Total:        5,
			Percent:      10,
			CurrentTitle: "Cut To The Feeling",
		}},
		Items: []entry{{
			ID:     1,
			Kind:   "track",
			Title:  "Cut To The Feeling",
			Artist: "Carly Rae Jepsen",
			Status: statusDownloading,
		}},
		RecentLog: []string{"Downloading via tidal"},
	})
	for _, want := range []string{
		"Download progress",
		"Cut To The Feeling",
		"Road Trip",
		"Recent SpotiFLAC log",
		"Downloading via tidal",
	} {
		if !strings.Contains(html, want) {
			t.Fatalf("HTML missing %q", want)
		}
	}
}

func TestWorkerProgressSnapshot(t *testing.T) {
	w := &downloadWorker{cfg: downloadConfig{MaxAttempts: 5}}
	e := &entry{
		ID: 42, Owner: "charlie", Kind: "track",
		Title: "Demo", Artist: "Artist", SpotifyURL: "https://open.spotify.com/track/x",
	}
	w.beginProgress(e, 1)
	w.setPhase("spotiflac", "running SpotiFLAC")
	w.noteProgressLine("Total Tracks  : 1")
	w.noteProgressLine("Downloading via tidal")
	active, log := w.snapshotProgress()
	if active == nil || active.EntryID != 42 {
		t.Fatalf("active=%v", active)
	}
	if active.Phase != "spotiflac" {
		t.Fatalf("phase=%q", active.Phase)
	}
	if active.TracksTotal != 1 {
		t.Fatalf("tracksTotal=%d", active.TracksTotal)
	}
	if len(log) == 0 {
		t.Fatal("expected recent log lines")
	}
	w.endProgress()
	active, _ = w.snapshotProgress()
	if active != nil {
		t.Fatal("expected nil after endProgress")
	}
}
