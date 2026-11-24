package main

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
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

// playlistM3URelPath turns a music-root-relative file path into a path usable
// from Playlists/*.m3u8 (Navidrome resolves entries relative to the playlist
// file, so library tracks need a "../" prefix — matching existing .m3u files).
func playlistM3URelPath(rel string) string {
	rel = filepath.ToSlash(strings.TrimSpace(rel))
	rel = strings.TrimPrefix(rel, "/")
	if rel == "" {
		return ""
	}
	if strings.HasPrefix(rel, "../") || strings.HasPrefix(rel, "..\\") {
		return rel
	}
	if strings.HasPrefix(strings.ToLower(rel), "playlists/") {
		return filepath.ToSlash(filepath.Base(rel))
	}
	return "../" + rel
}

// writeLibraryPlaylist writes (or rewrites) a library .m3u8 so Navidrome can
// pick it up on the next scan. Drome owns these files for Spotify imports, so
// they are replaced whenever the on-disk track set changes.
func writeLibraryPlaylist(musicDir, name string, tracks []playlistFileTrack) (string, error) {
	if strings.TrimSpace(musicDir) == "" || len(tracks) == 0 {
		return "", nil
	}
	dir := filepath.Join(musicDir, "Playlists")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	path := libraryPlaylistPath(musicDir, name)
	var b strings.Builder
	b.WriteString("#EXTM3U\n")
	b.WriteString("#DROME-MANAGED\n")
	seen := map[string]struct{}{}
	wrote := 0
	for _, t := range tracks {
		rel := playlistM3URelPath(strings.TrimSpace(t.Rel))
		if rel == "" {
			continue
		}
		if _, ok := seen[rel]; ok {
			continue
		}
		seen[rel] = struct{}{}
		label := t.Title
		if t.Artist != "" && t.Title != "" {
			label = t.Artist + " - " + t.Title
		}
		fmt.Fprintf(&b, "#EXTINF:-1,%s\n%s\n", label, rel)
		wrote++
	}
	if wrote == 0 {
		return "", nil
	}
	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		return "", err
	}
	return path, nil
}

// buildPlaylistFileTracks maps Spotify playlist tracks onto files already in
// the music library, preserving Spotify order.
func buildPlaylistFileTracks(musicDir string, tracks []playlistTrack) []playlistFileTrack {
	if musicDir == "" || len(tracks) == 0 {
		return nil
	}
	index := indexMusicDir(musicDir)
	var out []playlistFileTrack
	for _, t := range tracks {
		hit := matchIndexedTrack(index, t.Title, t.Artist)
		if hit == nil {
			continue
		}
		out = append(out, playlistFileTrack{
			Title:  t.Title,
			Artist: t.Artist,
			Rel:    hit.Rel,
		})
	}
	return out
}

type numberedPlaylistTrack struct {
	track playlistFileTrack
	num   int
	rel   string
}

// playlistFileTracksNamedAlbum collects audio files whose parent folder matches
// the playlist/album name (e.g. "Musical Theatre Bangers"). Used when Spotify
// metadata is unavailable or title matching misses compilation folders.
func playlistFileTracksNamedAlbum(musicDir, albumName string) []playlistFileTrack {
	albumName = strings.TrimSpace(albumName)
	if musicDir == "" || albumName == "" {
		return nil
	}
	want := normalizeMatchKey(albumName)
	var found []numberedPlaylistTrack
	_ = filepath.WalkDir(musicDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			name := d.Name()
			if strings.HasPrefix(name, ".") || strings.EqualFold(name, "Playlists") {
				if path != musicDir {
					return filepath.SkipDir
				}
			}
			return nil
		}
		switch strings.ToLower(filepath.Ext(d.Name())) {
		case ".flac", ".m4a", ".mp3", ".ogg", ".opus", ".wav", ".aiff":
		default:
			return nil
		}
		rel, err := filepath.Rel(musicDir, path)
		if err != nil {
			return nil
		}
		parts := strings.Split(rel, string(filepath.Separator))
		if len(parts) < 2 {
			return nil
		}
		parent := parts[len(parts)-2]
		if normalizeMatchKey(parent) != want {
			return nil
		}
		artist := parts[0]
		title := fileTitleKey(d.Name())
		num := trackNumberFromFilename(d.Name())
		labelArtist := artist
		if isCompilationArtist(artist) {
			labelArtist = "" // EXTINF shows title only for compilation folders
		}
		found = append(found, numberedPlaylistTrack{
			track: playlistFileTrack{Title: title, Artist: labelArtist, Rel: filepath.ToSlash(rel)},
			num:   num,
			rel:   filepath.ToSlash(rel),
		})
		return nil
	})

	// Prefer Various Artists / compilation copies when the same track number
	// appears under both an artist folder and the compilation folder.
	bestByNum := map[int]numberedPlaylistTrack{}
	var unordered []numberedPlaylistTrack
	for _, item := range found {
		if item.num <= 0 {
			unordered = append(unordered, item)
			continue
		}
		prev, ok := bestByNum[item.num]
		if !ok || preferPlaylistRel(item.rel, prev.rel) {
			bestByNum[item.num] = item
		}
	}
	nums := make([]int, 0, len(bestByNum))
	for n := range bestByNum {
		nums = append(nums, n)
	}
	sort.Ints(nums)
	out := make([]playlistFileTrack, 0, len(nums)+len(unordered))
	for _, n := range nums {
		out = append(out, bestByNum[n].track)
	}
	sort.SliceStable(unordered, func(i, j int) bool { return unordered[i].rel < unordered[j].rel })
	for _, item := range unordered {
		out = append(out, item.track)
	}
	return out
}

func trackNumberFromFilename(name string) int {
	base := strings.TrimSuffix(name, filepath.Ext(name))
	m := trackNumPrefix.FindString(base)
	if m == "" {
		return 0
	}
	digits := strings.TrimSpace(strings.Trim(m, "-. \t"))
	n, err := strconv.Atoi(digits)
	if err != nil {
		return 0
	}
	return n
}

func preferPlaylistRel(candidate, existing string) bool {
	candArtist := strings.Split(candidate, "/")[0]
	existArtist := strings.Split(existing, "/")[0]
	candComp := isCompilationArtist(candArtist)
	existComp := isCompilationArtist(existArtist)
	if candComp && !existComp {
		return true
	}
	if !candComp && existComp {
		return false
	}
	return candidate < existing
}

func isCompilationArtist(name string) bool {
	switch normalizeMatchKey(filepath.Base(name)) {
	case "various artists", "various", "va", "soundtrack", "soundtracks", "compilation", "compilations":
		return true
	default:
		return false
	}
}

// refreshManagedPlaylistFiles rewrites Drome-owned Playlists/*.m3u8 after
// library cleanup moves files. Album-named playlists are rebuilt from disk;
// others get broken paths repaired by basename lookup.
func refreshManagedPlaylistFiles(musicDir string) int {
	if strings.TrimSpace(musicDir) == "" {
		return 0
	}
	dir := filepath.Join(musicDir, "Playlists")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0
	}
	fixed := 0
	for _, ent := range entries {
		if ent.IsDir() {
			continue
		}
		name := ent.Name()
		lower := strings.ToLower(name)
		if !strings.HasSuffix(lower, ".m3u8") && !strings.HasSuffix(lower, ".m3u") {
			continue
		}
		path := filepath.Join(dir, name)
		body, err := os.ReadFile(path)
		if err != nil || !strings.Contains(string(body), "#DROME-MANAGED") {
			continue
		}
		playlistName := strings.TrimSuffix(name, filepath.Ext(name))
		if tracks := playlistFileTracksNamedAlbum(musicDir, playlistName); len(tracks) > 0 {
			if _, err := writeLibraryPlaylist(musicDir, playlistName, tracks); err == nil {
				fixed++
			}
			continue
		}
		if n, err := repairPlaylistFilePaths(musicDir, path); err == nil && n > 0 {
			fixed++
		}
	}
	return fixed
}

// repairPlaylistFilePaths rewrites missing ../Artist/... entries by finding the
// same filename elsewhere in the library (preferring Various Artists).
func repairPlaylistFilePaths(musicDir, playlistPath string) (int, error) {
	body, err := os.ReadFile(playlistPath)
	if err != nil {
		return 0, err
	}
	lines := strings.Split(string(body), "\n")
	indexByBase := map[string][]string{}
	_ = filepath.WalkDir(musicDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			if d != nil && d.IsDir() {
				name := d.Name()
				if strings.HasPrefix(name, ".") || strings.EqualFold(name, "Playlists") {
					if path != musicDir {
						return filepath.SkipDir
					}
				}
			}
			return nil
		}
		switch strings.ToLower(filepath.Ext(d.Name())) {
		case ".flac", ".m4a", ".mp3", ".ogg", ".opus", ".wav", ".aiff":
		default:
			return nil
		}
		rel, err := filepath.Rel(musicDir, path)
		if err != nil {
			return nil
		}
		base := d.Name()
		indexByBase[base] = append(indexByBase[base], filepath.ToSlash(rel))
		return nil
	})

	changed := 0
	var out []string
	for _, line := range lines {
		trim := strings.TrimSpace(line)
		if trim == "" || strings.HasPrefix(trim, "#") {
			out = append(out, line)
			continue
		}
		rel := strings.TrimPrefix(filepath.ToSlash(trim), "../")
		abs := filepath.Join(musicDir, filepath.FromSlash(rel))
		if _, err := os.Stat(abs); err == nil {
			out = append(out, line)
			continue
		}
		base := filepath.Base(rel)
		cands := indexByBase[base]
		if len(cands) == 0 {
			out = append(out, line)
			continue
		}
		best := cands[0]
		for _, c := range cands[1:] {
			if preferPlaylistRel(c, best) {
				best = c
			}
		}
		out = append(out, playlistM3URelPath(best))
		changed++
	}
	if changed == 0 {
		return 0, nil
	}
	text := strings.Join(out, "\n")
	if !strings.HasSuffix(text, "\n") {
		text += "\n"
	}
	if err := os.WriteFile(playlistPath, []byte(text), 0o644); err != nil {
		return 0, err
	}
	return changed, nil
}
