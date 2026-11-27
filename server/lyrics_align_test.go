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
