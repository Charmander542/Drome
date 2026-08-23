package main

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// Amazon Music stages downloads as {ASIN}.flac (e.g. B0D16T2QXP.flac).
var amazonASINBaseNameRe = regexp.MustCompile(`(?i)^B[0-9A-Z]{9}$`)

var audioExtsForASIN = map[string]bool{
	".flac": true, ".m4a": true, ".mp3": true, ".ogg": true, ".opus": true, ".wav": true, ".aiff": true,
}

// IsAmazonASINBaseName reports whether base (no extension) looks like an Amazon ASIN.
func IsAmazonASINBaseName(base string) bool {
	base = strings.TrimSpace(base)
	if base == "" {
		return false
	}
	// Staging names like B0D16T2QXP_s after remux suffixes.
	if i := strings.IndexByte(base, '_'); i > 0 {
		base = base[:i]
	}
	return amazonASINBaseNameRe.MatchString(base)
}

// RequireSpotifyIdentity errors if Spotify title or artist is blank.
func RequireSpotifyIdentity(title, artist string) error {
	if strings.TrimSpace(title) == "" {
		return fmt.Errorf("spotify title is required before Amazon finalize")
	}
	if strings.TrimSpace(artist) == "" {
		return fmt.Errorf("spotify artist is required before Amazon finalize")
	}
	return nil
}

// PromoteOrDedupASIN renames asinPath → destPath. If dest already exists and is
// non-empty, the ASIN temp is deleted and destPath is returned.
func PromoteOrDedupASIN(asinPath, destPath string) (string, error) {
	asinPath = filepath.Clean(asinPath)
	destPath = filepath.Clean(destPath)
	if asinPath == "" || destPath == "" {
		return "", fmt.Errorf("asin and dest paths are required")
	}
	if asinPath == destPath {
		return destPath, nil
	}

	if info, err := os.Stat(destPath); err == nil && info.Size() > 0 {
		if err := os.Remove(asinPath); err != nil && !os.IsNotExist(err) {
			return "", fmt.Errorf("remove asin temp %s: %w", asinPath, err)
		}
		return destPath, nil
	}

	if err := os.MkdirAll(filepath.Dir(destPath), 0o755); err != nil {
		return "", fmt.Errorf("create dest dir: %w", err)
	}
	if err := os.Rename(asinPath, destPath); err != nil {
		return "", fmt.Errorf("promote asin %s → %s: %w", asinPath, destPath, err)
	}
	return destPath, nil
}

type taggedDownloadMeta struct {
	Title  string
	Artist string
}

// FinalizeTaggedDownload rejects downloads that still look like Amazon staging
// leftovers or that lack Spotify title/artist after tagging.
func FinalizeTaggedDownload(path string, meta taggedDownloadMeta) error {
	if err := RequireSpotifyIdentity(meta.Title, meta.Artist); err != nil {
		return err
	}
	base := strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
	if IsAmazonASINBaseName(base) {
		return fmt.Errorf("download still ASIN-named after finalize: %s", filepath.Base(path))
	}
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("finalize missing file %s: %w", path, err)
	}
	if info.Size() == 0 {
		return fmt.Errorf("finalize empty file: %s", path)
	}
	return nil
}

// cleanupRecentASINLeftovers removes Amazon ASIN staging files left next to a
// good track after SpotiFLAC. Orphan ASINs (no sibling audio) fail the job so
// we do not treat the download as success for Navidrome.
func cleanupRecentASINLeftovers(musicDir string, since time.Time) error {
	cutoff := since.Add(-2 * time.Second)
	var orphans []string

	err := filepath.WalkDir(musicDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		ext := strings.ToLower(filepath.Ext(path))
		if !audioExtsForASIN[ext] {
			return nil
		}
		info, err := d.Info()
		if err != nil || info.ModTime().Before(cutoff) {
			return nil
		}
		base := strings.TrimSuffix(d.Name(), ext)
		if !IsAmazonASINBaseName(base) {
			return nil
		}
		if hasNonASINSibling(filepath.Dir(path), ext) {
			if rmErr := os.Remove(path); rmErr != nil && !os.IsNotExist(rmErr) {
				return fmt.Errorf("remove asin leftover %s: %w", path, rmErr)
			}
			logf("removed Amazon ASIN leftover (sibling exists): %s", path)
			return nil
		}
		orphans = append(orphans, path)
		return nil
	})
	if err != nil {
		return err
	}
	if len(orphans) > 0 {
		return fmt.Errorf("Amazon ASIN-named file(s) without Spotify finalize: %s", strings.Join(basenames(orphans), ", "))
	}
	return nil
}

func hasNonASINSibling(dir, preferExt string) bool {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		ext := strings.ToLower(filepath.Ext(name))
		if !audioExtsForASIN[ext] {
			continue
		}
		base := strings.TrimSuffix(name, filepath.Ext(name))
		if IsAmazonASINBaseName(base) {
			continue
		}
		info, err := e.Info()
		if err != nil || info.Size() == 0 {
			continue
		}
		_ = preferExt
		return true
	}
	return false
}

func basenames(paths []string) []string {
	out := make([]string, len(paths))
	for i, p := range paths {
		out[i] = filepath.Base(p)
	}
	return out
}
