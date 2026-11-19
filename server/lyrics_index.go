package main

import (
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unicode"
)

// lyricsIndex holds a library-wide fuzzy corpus built from .lrc sidecars
// next to music files (and optional plain .txt lyrics). Shared across users —
// content comes from disk, not per-account caches.
type lyricsIndex struct {
	mu        sync.RWMutex
	docs      []lyricsDocument
	buckets   map[string][]int
	builtAt   time.Time
	musicDir  string
	docCount  int
	lineCount int
	buildMS   int64
	approxMem int64
}

func newLyricsIndex(musicDir string) *lyricsIndex {
	return &lyricsIndex{
		musicDir: musicDir,
		buckets:  map[string][]int{},
	}
}

func (idx *lyricsIndex) stats() map[string]any {
	idx.mu.RLock()
	defer idx.mu.RUnlock()
	return map[string]any{
		"documents":   idx.docCount,
		"lines":       idx.lineCount,
		"buildMs":     idx.buildMS,
		"approxBytes": idx.approxMem,
		"builtAt":     idx.builtAt.UTC().Format(time.RFC3339),
		"musicDir":    idx.musicDir,
	}
}

func (idx *lyricsIndex) search(query string, limit int) []lyricsHit {
	idx.mu.RLock()
	docs := idx.docs
	buckets := idx.buckets
	idx.mu.RUnlock()
	if limit <= 0 {
		limit = 40
	}
	return searchLyricsDocuments(docs, buckets, query, limit, 600)
}

func (idx *lyricsIndex) rebuild() error {
	start := time.Now()
	docs, err := scanLyricsFromMusicDir(idx.musicDir)
	if err != nil {
		return err
	}
	buckets := buildLyricsBuckets(docs)
	lineCount := 0
	approx := int64(0)
	for _, d := range docs {
		lineCount += len(d.Lines)
		approx += int64(len(d.Title) + len(d.Artist) + len(d.Album) + len(d.SongID))
		for _, line := range d.Lines {
			approx += int64(len(line))
		}
		for _, toks := range d.LineTokens {
			for _, t := range toks {
				approx += int64(len(t))
			}
		}
	}
	idx.mu.Lock()
	idx.docs = docs
	idx.buckets = buckets
	idx.docCount = len(docs)
	idx.lineCount = lineCount
	idx.approxMem = approx
	idx.buildMS = time.Since(start).Milliseconds()
	idx.builtAt = time.Now()
	idx.mu.Unlock()
	logf("lyrics index: %d docs / %d lines in %dms (~%dKB)", len(docs), lineCount, idx.buildMS, approx/1024)
	return nil
}

func (idx *lyricsIndex) run(ctxDone <-chan struct{}) {
	// Initial build, then refresh periodically so new .lrc imports show up.
	_ = idx.rebuild()
	ticker := time.NewTicker(30 * time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ctxDone:
			return
		case <-ticker.C:
			_ = idx.rebuild()
		}
	}
}

func scanLyricsFromMusicDir(musicDir string) ([]lyricsDocument, error) {
	if musicDir == "" {
		return nil, nil
	}
	info, err := os.Stat(musicDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	if !info.IsDir() {
		return nil, nil
	}

	var docs []lyricsDocument
	err = filepath.WalkDir(musicDir, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
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
		ext := strings.ToLower(filepath.Ext(d.Name()))
		if ext != ".lrc" && ext != ".txt" {
			return nil
		}
		// Skip giant non-lyric text dumps.
		st, statErr := d.Info()
		if statErr != nil || st.Size() > 256*1024 {
			return nil
		}
		raw, readErr := os.ReadFile(path)
		if readErr != nil || len(raw) == 0 {
			return nil
		}
		plain := strings.TrimSpace(stripLRCTimestamps(string(raw)))
		if plain == "" || !looksLikeLyrics(plain) {
			return nil
		}
		artist, album, title := inferMetaFromPath(musicDir, path)
		if title == "" {
			title = strings.TrimSuffix(d.Name(), filepath.Ext(d.Name()))
		}
		docs = append(docs, newLyricsDocument("", title, artist, album, plain))
		return nil
	})
	return docs, err
}

func looksLikeLyrics(plain string) bool {
	lines := 0
	letters := 0
	for _, line := range strings.Split(plain, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		lines++
		for _, r := range line {
			if unicode.IsLetter(r) {
				letters++
			}
		}
		if lines >= 2 && letters >= 20 {
			return true
		}
	}
	return lines >= 1 && letters >= 12
}

// Navidrome-style layout: /music/Artist/Album/Track.lrc
func inferMetaFromPath(root, path string) (artist, album, title string) {
	rel, err := filepath.Rel(root, path)
	if err != nil {
		return "", "", ""
	}
	parts := strings.Split(rel, string(filepath.Separator))
	stem := strings.TrimSuffix(parts[len(parts)-1], filepath.Ext(parts[len(parts)-1]))
	stem = trackNumPrefix.ReplaceAllString(stem, "")
	title = strings.TrimSpace(stem)
	if len(parts) >= 3 {
		artist = parts[0]
		album = parts[1]
	} else if len(parts) == 2 {
		artist = parts[0]
	}
	return artist, album, title
}
