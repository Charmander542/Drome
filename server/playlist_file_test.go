package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestFlexStringAndPlaylistListJSON(t *testing.T) {
	var id flexString
	if err := json.Unmarshal([]byte(`"abc"`), &id); err != nil || id.String() != "abc" {
		t.Fatalf("string id: %v %q", err, id)
	}
	if err := json.Unmarshal([]byte(`12345`), &id); err != nil || id.String() != "12345" {
		t.Fatalf("numeric id: %v %q", err, id)
	}

	var lists playlistList
	if err := json.Unmarshal([]byte(`{"id":1,"name":"Hits"}`), &lists); err != nil {
		t.Fatal(err)
	}
	if len(lists) != 1 || lists[0].Name != "Hits" || lists[0].ID.String() != "1" {
		t.Fatalf("single playlist object: %+v", lists)
	}
	if err := json.Unmarshal([]byte(`[{"id":"a","name":"One"},{"id":"b","name":"Two"}]`), &lists); err != nil {
		t.Fatal(err)
	}
	if len(lists) != 2 {
		t.Fatalf("array: %+v", lists)
	}
}

func TestWriteLibraryPlaylist(t *testing.T) {
	dir := t.TempDir()
	path, err := writeLibraryPlaylist(dir, "Late Night / Mix", []playlistFileTrack{
		{Title: "Song", Artist: "Artist", Rel: "Artist/Album/01 - Song.flac"},
	})
	if err != nil {
		t.Fatal(err)
	}
	wantDir := filepath.Join(dir, "Playlists")
	if filepath.Dir(path) != wantDir {
		t.Fatalf("path %s", path)
	}
	if !strings.HasSuffix(path, "Late Night - Mix.m3u8") {
		t.Fatalf("filename %s", path)
	}
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	text := string(body)
	if !strings.Contains(text, "#EXTM3U") || !strings.Contains(text, "#DROME-MANAGED") ||
		!strings.Contains(text, "Artist - Song") ||
		!strings.Contains(text, "../Artist/Album/01 - Song.flac") {
		t.Fatalf("contents:\n%s", text)
	}

	again, err := writeLibraryPlaylist(dir, "Late Night / Mix", []playlistFileTrack{
		{Title: "Other", Artist: "X", Rel: "X/Album/02 - Other.flac"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if again != path {
		t.Fatalf("expected same path, got %s", again)
	}
	body, _ = os.ReadFile(path)
	updated := string(body)
	if !strings.Contains(updated, "../X/Album/02 - Other.flac") {
		t.Fatal("should rewrite playlist file with latest tracks")
	}
	if strings.Contains(updated, "Artist/Album/01 - Song.flac") {
		t.Fatal("rewrite should replace previous entries")
	}
}

func TestPlaylistM3URelPath(t *testing.T) {
	if got := playlistM3URelPath("Various Artists/Album/01 - Song.flac"); got != "../Various Artists/Album/01 - Song.flac" {
		t.Fatalf("got %q", got)
	}
	if got := playlistM3URelPath("../Already/Relative.flac"); got != "../Already/Relative.flac" {
		t.Fatalf("got %q", got)
	}
}

func TestRepairPlaylistFilePaths(t *testing.T) {
	dir := t.TempDir()
	must := func(rel string) {
		p := filepath.Join(dir, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	must("Various Artists/Musical Theatre Bangers/22 - You'll Be Back.flac")
	plDir := filepath.Join(dir, "Playlists")
	if err := os.MkdirAll(plDir, 0o755); err != nil {
		t.Fatal(err)
	}
	pl := filepath.Join(plDir, "Musical Theatre Bangers.m3u8")
	body := "#EXTM3U\n#DROME-MANAGED\n#EXTINF:-1,You'll Be Back\n../Jonathan Groff/Musical Theatre Bangers/22 - You'll Be Back.flac\n"
	if err := os.WriteFile(pl, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	n, err := repairPlaylistFilePaths(dir, pl)
	if err != nil || n != 1 {
		t.Fatalf("n=%d err=%v", n, err)
	}
	got, _ := os.ReadFile(pl)
	if !strings.Contains(string(got), "../Various Artists/Musical Theatre Bangers/22 - You'll Be Back.flac") {
		t.Fatalf("contents:\n%s", got)
	}
}

func TestRefreshManagedPlaylistFiles(t *testing.T) {
	dir := t.TempDir()
	must := func(rel string) {
		p := filepath.Join(dir, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	must("Various Artists/Musical Theatre Bangers/01 - Satisfied.flac")
	must("Various Artists/Musical Theatre Bangers/22 - You'll Be Back.flac")
	plDir := filepath.Join(dir, "Playlists")
	_ = os.MkdirAll(plDir, 0o755)
	pl := filepath.Join(plDir, "Musical Theatre Bangers.m3u8")
	_ = os.WriteFile(pl, []byte("#EXTM3U\n#DROME-MANAGED\n#EXTINF:-1,x\n../Jonathan Groff/Musical Theatre Bangers/22 - You'll Be Back.flac\n"), 0o644)
	if n := refreshManagedPlaylistFiles(dir); n != 1 {
		t.Fatalf("refreshed %d", n)
	}
	got, _ := os.ReadFile(pl)
	text := string(got)
	if !strings.Contains(text, "01 - Satisfied.flac") || strings.Contains(text, "Jonathan Groff") {
		t.Fatalf("contents:\n%s", text)
	}
}

func TestPlaylistFileTracksNamedAlbumPrefersCompilation(t *testing.T) {
	dir := t.TempDir()
	mustMk := func(parts ...string) string {
		p := filepath.Join(append([]string{dir}, parts...)...)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
		return p
	}
	mustMk("Jonathan Groff", "Musical Theatre Bangers", "22 - You'll Be Back.flac")
	mustMk("Various Artists", "Musical Theatre Bangers", "01 - Satisfied.flac")
	mustMk("Various Artists", "Musical Theatre Bangers", "22 - You'll Be Back.flac")

	tracks := playlistFileTracksNamedAlbum(dir, "Musical Theatre Bangers")
	if len(tracks) != 2 {
		t.Fatalf("got %d tracks: %+v", len(tracks), tracks)
	}
	if tracks[0].Rel != "Various Artists/Musical Theatre Bangers/01 - Satisfied.flac" {
		t.Fatalf("track 1: %+v", tracks[0])
	}
	if tracks[1].Rel != "Various Artists/Musical Theatre Bangers/22 - You'll Be Back.flac" {
		t.Fatalf("prefers compilation copy, got %+v", tracks[1])
	}
}

func TestMatchIndexedTrackCompilationFallback(t *testing.T) {
	index := []diskTrackHit{
		{Rel: "Various Artists/Musical Theatre Bangers/06 - Memory.flac", Stem: "Memory", DirArtist: "Various Artists"},
		{Rel: "Elaine Paige/Other Album/01 - Memory.flac", Stem: "Memory", DirArtist: "Elaine Paige"},
	}
	hit := matchIndexedTrack(index, "Memory", "Elaine Paige")
	if hit == nil || !strings.Contains(hit.Rel, "Various Artists") {
		t.Fatalf("prefer retagged compilation copy: %+v", hit)
	}
	hit = matchIndexedTrack(index[1:], "Memory", "Elaine Paige")
	if hit == nil || hit.DirArtist != "Elaine Paige" {
		t.Fatalf("artist folder when no compilation: %+v", hit)
	}
}

func TestBuildPlaylistFileTracksPreservesOrder(t *testing.T) {
	dir := t.TempDir()
	files := []string{
		"Various Artists/Show Tunes/02 - Second.flac",
		"Various Artists/Show Tunes/01 - First.flac",
	}
	for _, rel := range files {
		p := filepath.Join(dir, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	tracks := buildPlaylistFileTracks(dir, []playlistTrack{
		{Title: "First", Artist: "A"},
		{Title: "Second", Artist: "B"},
	})
	if len(tracks) != 2 {
		t.Fatalf("got %+v", tracks)
	}
	if !strings.Contains(tracks[0].Rel, "01 - First") || !strings.Contains(tracks[1].Rel, "02 - Second") {
		t.Fatalf("order: %+v", tracks)
	}
}
