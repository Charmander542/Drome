package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"unicode"
)

type playlistFileTrack struct {
	Title  string
	Artist string
	Rel    string
}

func sanitizePlaylistFilename(name string) string {
	name = strings.TrimSpace(name)
	if name == "" {
		name = "Spotify playlist"
	}
	var b strings.Builder
	for _, r := range name {
		switch {
		case r == '/' || r == '\\' || r == ':' || r == '*' || r == '?' || r == '"' || r == '<' || r == '>' || r == '|':
			b.WriteByte('-')
		case unicode.IsControl(r):
			continue
		default:
			b.WriteRune(r)
		}
	}
	out := strings.TrimSpace(b.String())
	if out == "" {
		out = "Spotify playlist"
	}
	return out
}

func libraryPlaylistPath(musicDir, name string) string {
	return filepath.Join(musicDir, "Playlists", sanitizePlaylistFilename(name)+".m3u8")
}

func writeLibraryPlaylist(musicDir, name string, tracks []playlistFileTrack) (string, error) {
	if strings.TrimSpace(musicDir) == "" || len(tracks) == 0 {
		return "", nil
	}
	dir := filepath.Join(musicDir, "Playlists")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	path := libraryPlaylistPath(musicDir, name)
	if _, err := os.Stat(path); err == nil {
		return path, nil
	}
	var b strings.Builder
	b.WriteString("#EXTM3U\n")
	for _, t := range tracks {
		if t.Rel == "" {
			continue
		}
		label := t.Title
		if t.Artist != "" && t.Title != "" {
			label = t.Artist + " - " + t.Title
		}
		fmt.Fprintf(&b, "#EXTINF:-1,%s\n%s\n", label, t.Rel)
	}
	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		return "", err
	}
	return path, nil
}
