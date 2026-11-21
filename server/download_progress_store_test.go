package main

import (
	"path/filepath"
	"testing"
	"time"
)

func TestDownloadQueueStoreHelpers(t *testing.T) {
	dir := t.TempDir()
	store, err := openStore(filepath.Join(dir, "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	now := time.Now().UTC()
	mustInsert := func(e *entry) {
		e.CreatedAt = now
		if err := store.insert(e); err != nil {
			t.Fatal(err)
		}
	}
	mustInsert(&entry{
		Owner: "charlie", Kind: "track", SpotifyID: "a1", SpotifyURL: "u1",
		Title: "One", Artist: "A", Status: statusQueued,
		SourcePlaylistID: "pl1", SourcePlaylistName: "Road Trip",
	})
	mustInsert(&entry{
		Owner: "charlie", Kind: "track", SpotifyID: "a2", SpotifyURL: "u2",
		Title: "Two", Artist: "A", Status: statusDownloading,
		SourcePlaylistID: "pl1", SourcePlaylistName: "Road Trip",
		StatusMsg: "spotiflac: downloading",
	})
	mustInsert(&entry{
		Owner: "charlie", Kind: "album", SpotifyID: "alb1", SpotifyURL: "u3",
		Title: "Solo Album", Artist: "B", Status: statusQueued,
	})
	mustInsert(&entry{
		Owner: "other", Kind: "track", SpotifyID: "x", SpotifyURL: "ux",
		Title: "Other", Artist: "Z", Status: statusQueued,
	})

	st, err := store.downloadQueueStats("charlie")
	if err != nil {
		t.Fatal(err)
	}
	if st.Queued != 2 || st.Downloading != 1 || st.Total != 3 {
		t.Fatalf("stats=%+v", st)
	}

	playlists, err := store.playlistDownloadProgress("charlie")
	if err != nil {
		t.Fatal(err)
	}
	if len(playlists) != 1 || playlists[0].PlaylistName != "Road Trip" {
		t.Fatalf("playlists=%+v", playlists)
	}
	if playlists[0].Queued != 1 || playlists[0].Downloading != 1 || playlists[0].Total != 2 {
		t.Fatalf("playlist counts=%+v", playlists[0])
	}

	items, err := store.listDownloadQueue("charlie")
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 3 {
		t.Fatalf("items=%d", len(items))
	}
	if items[0].Status != statusDownloading {
		t.Fatalf("expected downloading first, got %s", items[0].Status)
	}
}
