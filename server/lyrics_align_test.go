package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestEnsureMillisecondStampsPadsCentiseconds(t *testing.T) {
	in := "[00:11.16] <00:11.16>My <00:11.25>shadow\n"
	out := ensureMillisecondStamps(in)
	if !strings.Contains(out, "[00:11.160]") {
		t.Fatalf("expected ms line stamp, got %q", out)
	}
	if !strings.Contains(out, "<00:11.160>My") {
		t.Fatalf("expected ms word stamp, got %q", out)
	}
	if !strings.Contains(out, "<00:11.250>shadow") {
		t.Fatalf("expected padded shadow stamp, got %q", out)
	}
}

func TestEnsureMillisecondStampsPreservesMillis(t *testing.T) {
	in := "<00:11.259>shadow"
	out := ensureMillisecondStamps(in)
	if out != in {
		t.Fatalf("ms stamp should be unchanged, got %q", out)
	}
}

func TestLyricsAlignDefaultsOff(t *testing.T) {
	prev, had := os.LookupEnv("DROME_LYRICS_ALIGN")
	os.Unsetenv("DROME_LYRICS_ALIGN")
	t.Cleanup(func() {
		if had {
			_ = os.Setenv("DROME_LYRICS_ALIGN", prev)
		} else {
			os.Unsetenv("DROME_LYRICS_ALIGN")
		}
	})
	cfg := lyricsAlignConfigFromEnv()
	if cfg.Enabled {
		t.Fatal("DROME_LYRICS_ALIGN should default to false until a valid ground-truth eval passes")
	}
}

func TestLrcAlreadyAlignedV4Marker(t *testing.T) {
	raw := "[drome-aligned:v4-ctc-line]\n[00:01.000]<00:01.000>Hi\n"
	if !lrcAlreadyAligned(raw) {
		t.Fatal("expected v4 marker to be recognized")
	}
	if lrcAlreadyAligned("[drome-aligned:v3-ctc-seg]\n") {
		t.Fatal("v3 marker should not count as current aligned version")
	}
	if lrcAlreadyAligned("[drome-aligned:v2-ctc-demucs]\n") {
		t.Fatal("v2 marker should not count as current aligned version")
	}
	if lrcAlreadyAligned("[drome-aligned:v1]\n") {
		t.Fatal("v1 marker should not count as current aligned version")
	}
	if alignedMarkerRe.FindStringSubmatch("[DROME-ALIGNED:v4-ctc-line]") == nil {
		t.Fatal("aligned marker regex should match case-insensitively")
	}
}

func TestRewriteSidecarPrecision(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "track.lrc")
	if err := os.WriteFile(path, []byte("[00:01.50]<00:01.50>Hi\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	changed, err := rewriteSidecarPrecision(path)
	if err != nil {
		t.Fatal(err)
	}
	if !changed {
		t.Fatal("expected rewrite")
	}
	raw, _ := os.ReadFile(path)
	if !strings.Contains(string(raw), "00:01.500") {
		t.Fatalf("got %s", raw)
	}
	// Second pass is a no-op.
	changed, err = rewriteSidecarPrecision(path)
	if err != nil {
		t.Fatal(err)
	}
	if changed {
		t.Fatal("second pass should not rewrite")
	}
}
