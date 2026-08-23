package backend

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// Amazon Music stages downloads as {ASIN}.flac (e.g. B0D16T2QXP.flac).
var amazonASINBaseNameRe = regexp.MustCompile(`(?i)^B[0-9A-Z]{9}$`)

// IsAmazonASINBaseName reports whether base (no extension) looks like an Amazon ASIN.
func IsAmazonASINBaseName(base string) bool {
	base = strings.TrimSpace(base)
	if base == "" {
		return false
	}
	// Allow staging names like B0D16T2QXP_s after remux suffixes.
	if i := strings.IndexByte(base, '_'); i > 0 {
		base = base[:i]
	}
	return amazonASINBaseNameRe.MatchString(base)
}

// RequireSpotifyIdentity errors if Spotify title or artist is blank.
// Without both, Amazon leaves ASIN-named files with empty title/artist tags.
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
// non-empty, the ASIN temp is deleted and destPath is returned (keep the good file).
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
		// Cross-device or dest race: try copy-remove via read/write is overkill;
		// surface the error so the download is not marked success with an ASIN name.
		return "", fmt.Errorf("promote asin %s → %s: %w", asinPath, destPath, err)
	}
	return destPath, nil
}

// FinalizeTaggedDownload rejects downloads that still look like Amazon staging
// leftovers or that lack Spotify title/artist after tagging.
func FinalizeTaggedDownload(path string, meta Metadata) error {
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
