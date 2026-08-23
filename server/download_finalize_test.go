package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestIsAmazonASINBaseName(t *testing.T) {
	cases := []struct {
		in   string
		want bool
	}{
		{"B0D16T2QXP", true},
		{"b0d16t2qxp", true},
		{"B0D16T2QXP_s", true},
		{"B012345678", true},
		{"01 - Title", false},
		{"B0SHORT", false},
		{"B0D16T2QXPX", false},
		{"", false},
		{"Unknown", false},
	}
	for _, tc := range cases {
		if got := IsAmazonASINBaseName(tc.in); got != tc.want {
			t.Errorf("IsAmazonASINBaseName(%q)=%v want %v", tc.in, got, tc.want)
		}
	}
}

func TestRequireSpotifyIdentity(t *testing.T) {
	if err := RequireSpotifyIdentity("Title", "Artist"); err != nil {
		t.Fatalf("expected nil, got %v", err)
	}
	if err := RequireSpotifyIdentity("", "Artist"); err == nil {
		t.Fatal("expected error for blank title")
	}
	if err := RequireSpotifyIdentity("Title", "  "); err == nil {
		t.Fatal("expected error for blank artist")
	}
}

func TestFinalizeTaggedDownload(t *testing.T) {
	dir := t.TempDir()
	good := filepath.Join(dir, "01 - Title.flac")
	if err := os.WriteFile(good, []byte("flac"), 0o644); err != nil {
		t.Fatal(err)
	}
	meta := taggedDownloadMeta{Title: "Title", Artist: "Artist"}
	if err := FinalizeTaggedDownload(good, meta); err != nil {
		t.Fatalf("good file: %v", err)
	}

	asin := filepath.Join(dir, "B0D16T2QXP.flac")
	if err := os.WriteFile(asin, []byte("flac"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := FinalizeTaggedDownload(asin, meta); err == nil {
		t.Fatal("expected error for ASIN-named path")
	}
	if err := FinalizeTaggedDownload(good, taggedDownloadMeta{Title: "", Artist: "Artist"}); err == nil {
		t.Fatal("expected error for blank title")
	}
}

func TestPromoteOrDedupASIN(t *testing.T) {
	dir := t.TempDir()
	asin := filepath.Join(dir, "B0D16T2QXP.flac")
	dest := filepath.Join(dir, "01 - Title.flac")
	if err := os.WriteFile(asin, []byte("asin-bytes"), 0o644); err != nil {
		t.Fatal(err)
	}

	got, err := PromoteOrDedupASIN(asin, dest)
	if err != nil {
		t.Fatal(err)
	}
	if got != dest {
		t.Fatalf("got path %q want %q", got, dest)
	}
	if _, err := os.Stat(asin); !os.IsNotExist(err) {
		t.Fatalf("asin should be gone, err=%v", err)
	}

	asin2 := filepath.Join(dir, "B0ABCDEFGH.flac")
	if err := os.WriteFile(asin2, []byte("dup"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dest, []byte("keep-me"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err = PromoteOrDedupASIN(asin2, dest)
	if err != nil {
		t.Fatal(err)
	}
	if got != dest {
		t.Fatalf("got %q", got)
	}
	if _, err := os.Stat(asin2); !os.IsNotExist(err) {
		t.Fatal("asin temp should be deleted when dest exists")
	}
	b, err := os.ReadFile(dest)
	if err != nil || string(b) != "keep-me" {
		t.Fatalf("dest should be unchanged: %q", b)
	}
}

func TestCleanupRecentASINLeftovers(t *testing.T) {
	dir := t.TempDir()
	album := filepath.Join(dir, "Artist", "Album")
	if err := os.MkdirAll(album, 0o755); err != nil {
		t.Fatal(err)
	}
	good := filepath.Join(album, "01 - Title.flac")
	asin := filepath.Join(album, "B0D16T2QXP.flac")
	if err := os.WriteFile(good, []byte("good"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(asin, []byte("asin"), 0o644); err != nil {
		t.Fatal(err)
	}
	since := time.Now().Add(-time.Minute)
	if err := cleanupRecentASINLeftovers(dir, since); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(asin); !os.IsNotExist(err) {
		t.Fatal("expected ASIN sibling removed")
	}

	orphanDir := filepath.Join(dir, "Other", "Alone")
	if err := os.MkdirAll(orphanDir, 0o755); err != nil {
		t.Fatal(err)
	}
	orphan := filepath.Join(orphanDir, "B0ORPHAN01.flac")
	if err := os.WriteFile(orphan, []byte("orphan"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := cleanupRecentASINLeftovers(dir, since); err == nil {
		t.Fatal("expected error for orphan ASIN")
	}
}
