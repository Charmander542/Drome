package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestParseProviderRetryAfter(t *testing.T) {
	cases := []struct {
		in   string
		want time.Duration
	}{
		{"verification paused after a failed attempt — next try in 45 min", 45 * time.Minute},
		{"next try in 12 minutes", 12 * time.Minute},
		{"verification paused 44m", 44 * time.Minute},
		{"All providers failed; next try in 90 s", 90 * time.Second},
		{"next try in 2 hours", 2 * time.Hour},
		{"no timing here", 0},
		{
			"paused after a failed attempt — next try in 5 min; also next try in 45 min",
			45 * time.Minute,
		},
	}
	for _, tc := range cases {
		got := parseProviderRetryAfter(tc.in)
		if got != tc.want {
			t.Fatalf("%q: got %v want %v", tc.in, got, tc.want)
		}
	}
}

func TestSpotiflacAuthBackoffRemaining(t *testing.T) {
	dir := t.TempDir()
	sessions := filepath.Join(dir, "signed_sessions")
	if err := os.MkdirAll(sessions, 0o755); err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1_700_000_000, 0)
	write := func(name string, notBefore float64) {
		b, _ := json.Marshal(authBackoffFile{Failures: 1, NotBefore: notBefore})
		if err := os.WriteFile(filepath.Join(sessions, name), b, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write(".zarz-v2-aaa.auth-backoff.json", float64(now.Add(10*time.Minute).Unix())+0.5)
	write(".zarz-v2-bbb.auth-backoff.json", float64(now.Add(40*time.Minute).Unix()))
	got := spotiflacAuthBackoffRemaining(dir, now)
	if got < 39*time.Minute || got > 41*time.Minute {
		t.Fatalf("got %v, want ~40m", got)
	}
	if rem := spotiflacAuthBackoffRemaining(dir, now.Add(50*time.Minute)); rem != 0 {
		t.Fatalf("expected 0 after expiry, got %v", rem)
	}
}

func TestRetryBackoffPrefersProviderCooldown(t *testing.T) {
	w := &downloadWorker{cfg: downloadConfig{RetryBase: 2 * time.Minute}}
	// No local backoff files → parse from error only.
	got := w.retryBackoff(1, "verification paused after a failed attempt — next try in 45 min")
	// 45m + 30s buffer
	if got < 45*time.Minute || got > 46*time.Minute {
		t.Fatalf("got %v", got)
	}
	// Normal exponential when no provider hint.
	got = w.retryBackoff(1, "retag: no recent audio files")
	if got != 2*time.Minute {
		t.Fatalf("got %v want 2m", got)
	}
}
