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
	if !strings.Contains(text, "#EXTM3U") || !strings.Contains(text, "Artist - Song") ||
		!strings.Contains(text, "Artist/Album/01 - Song.flac") {
		t.Fatalf("contents:\n%s", text)
	}

	again, err := writeLibraryPlaylist(dir, "Late Night / Mix", []playlistFileTrack{
		{Title: "Other", Artist: "X", Rel: "nope.flac"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if again != path {
		t.Fatalf("expected existing path, got %s", again)
	}
	body, _ = os.ReadFile(path)
	if strings.Contains(string(body), "nope.flac") {
		t.Fatal("should not overwrite an existing playlist file")
	}
}
