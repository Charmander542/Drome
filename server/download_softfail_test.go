package main

import (
	"strings"
	"testing"
)

func TestSpotiflacSoftFailureZeroSuccess(t *testing.T) {
	out := `
╔════════════════════════════════════════════════════════════╗
║  SESSION SUMMARY                                           ║
╠════════════════════════════════════════════════════════════╣
║  Total Tracks  : 1                                         ║
║  Successful    : 0                                         ║
║  Failed        : 1                                         ║
╠════════════════════════════════════════════════════════════╣
║  ✗ FAILURES                                               ║
║    Cut To The Feeling — Carly Rae Jeps: All providers fail  ║
╚════════════════════════════════════════════════════════════╝
  ✗  Failed: Cut To The Feeling — Carly Rae Jepsen: All providers failed after 1 attempt(s) — tidal: UNAVAILABLE
`
	got := spotiflacSoftFailure(out)
	if got == "" {
		t.Fatal("expected soft failure for Successful: 0")
	}
	if !strings.Contains(got, "All providers failed") && !strings.Contains(got, "0 successful") {
		t.Fatalf("unexpected reason: %q", got)
	}
}

func TestSpotiflacSoftFailureSuccessOK(t *testing.T) {
	out := `
║  SESSION SUMMARY                                           ║
║  Total Tracks  : 1                                         ║
║  Successful    : 1                                         ║
║  Failed        : 0                                         ║
`
	if got := spotiflacSoftFailure(out); got != "" {
		t.Fatalf("expected no soft failure, got %q", got)
	}
}

func TestSpotiflacSoftFailureInconclusive(t *testing.T) {
	if got := spotiflacSoftFailure("random log without summary"); got != "" {
		t.Fatalf("expected empty, got %q", got)
	}
}

func TestStripANSI(t *testing.T) {
	in := "\x1b[32mSuccessful\x1b[0m    : 0\r\n"
	got := stripANSI(in)
	if got != "Successful    : 0\n" {
		t.Fatalf("got %q", got)
	}
}

func TestSpotiflacFailureTail(t *testing.T) {
	out := "banner junk\nTurnstile token not obtained\nTrack not available: No verified TIDAL track match found\n  ✗  Failed: demo — All providers failed after 1 attempt(s)\n"
	got := spotiflacFailureTail(out)
	if !strings.Contains(got, "All providers failed") {
		t.Fatalf("got %q", got)
	}
	if !strings.Contains(got, "Track not available") {
		t.Fatalf("expected provider detail, got %q", got)
	}
	if strings.Contains(got, "banner") {
		t.Fatalf("should drop banner: %q", got)
	}
}
