package main

import (
	"fmt"
	"strconv"
	"strings"
)

// LRCLIB "Word Synced" stores per-word timings in the lyricsfile YAML field
// (hasWordSync=true). syncedLyrics stays line-only Enhanced-less LRC — so we
// convert lyricsfile → Enhanced LRC (`[mm:ss.cc] <mm:ss.cc>word …`) for the
// sidecar format the iOS LRCParser already understands.

type lyricsFileWord struct {
	Text    string
	StartMs int
}

type lyricsFileLine struct {
	Text    string
	StartMs int
	Words   []lyricsFileWord
}

// effectiveSyncedLyrics prefers Word Synced lyricsfile when present, else
// falls back to syncedLyrics (line karaoke).
func effectiveSyncedLyrics(r lrclibResult) string {
	if r.HasWordSync != nil && *r.HasWordSync {
		if enhanced, ok := lyricsFileToEnhancedLRC(r.Lyricsfile); ok {
			return enhanced
		}
	}
	// Some hits omit hasWordSync but still ship a usable lyricsfile.
	if strings.TrimSpace(r.Lyricsfile) != "" {
		if enhanced, ok := lyricsFileToEnhancedLRC(r.Lyricsfile); ok {
			return enhanced
		}
	}
	return strings.TrimSpace(r.SyncedLyrics)
}

func lyricsFileToEnhancedLRC(raw string) (string, bool) {
	lines := parseLyricsFile(raw)
	if len(lines) == 0 {
		return "", false
	}
	var b strings.Builder
	wordCount := 0
	for _, line := range lines {
		if len(line.Words) == 0 {
			// Keep blank / instrumental placeholders as line stamps only.
			b.WriteString(fmt.Sprintf("[%s] %s\n", formatLRCStamp(line.StartMs), strings.TrimSpace(line.Text)))
			continue
		}
		b.WriteString(fmt.Sprintf("[%s]", formatLRCStamp(line.StartMs)))
		for _, w := range line.Words {
			text := w.Text
			if text == "" {
				continue
			}
			wordCount++
			// Enhanced LRC words are space-separated tokens; preserve trailing
			// spaces already present in LRCLIB word text, otherwise add one
			// between tokens so the parser can reassemble the line.
			b.WriteByte(' ')
			b.WriteString(fmt.Sprintf("<%s>", formatLRCStamp(w.StartMs)))
			b.WriteString(text)
		}
		b.WriteByte('\n')
	}
	if wordCount == 0 {
		return "", false
	}
	return b.String(), true
}

func formatLRCStamp(ms int) string {
	if ms < 0 {
		ms = 0
	}
	centi := ms / 10
	m := centi / 6000
	s := (centi % 6000) / 100
	cs := centi % 100
	return fmt.Sprintf("%02d:%02d.%02d", m, s, cs)
}

// parseLyricsFile reads the LRCLIB lyricsfile YAML subset we care about.
// Full YAML would be overkill — the schema is fixed and shallow.
func parseLyricsFile(raw string) []lyricsFileLine {
	raw = strings.ReplaceAll(raw, "\r\n", "\n")
	var out []lyricsFileLine
	var cur *lyricsFileLine
	inWords := false

	for _, line := range strings.Split(raw, "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		indent := countLeadingSpaces(line)

		switch {
		case strings.HasPrefix(trimmed, "- text:"):
			val := yamlScalar(strings.TrimPrefix(trimmed, "- text:"))
			// Top-level list items are lyric lines; nested `- text:` under
			// `words:` are per-word cues (indent ≥ 2 in LRCLIB's dump).
			if indent == 0 {
				out = append(out, lyricsFileLine{Text: val})
				cur = &out[len(out)-1]
				inWords = false
			} else if cur != nil && inWords {
				cur.Words = append(cur.Words, lyricsFileWord{Text: val})
			}
		case strings.HasPrefix(trimmed, "start_ms:"):
			ms, ok := yamlInt(strings.TrimPrefix(trimmed, "start_ms:"))
			if !ok || cur == nil {
				continue
			}
			if inWords && len(cur.Words) > 0 && indent >= 4 {
				cur.Words[len(cur.Words)-1].StartMs = ms
			} else {
				cur.StartMs = ms
			}
		case trimmed == "words:" || strings.HasPrefix(trimmed, "words:"):
			if cur != nil {
				inWords = true
			}
		}
	}
	return out
}

func countLeadingSpaces(s string) int {
	n := 0
	for _, r := range s {
		if r == ' ' {
			n++
			continue
		}
		if r == '\t' {
			n += 2
			continue
		}
		break
	}
	return n
}

func yamlScalar(raw string) string {
	s := strings.TrimSpace(raw)
	if s == "" || s == "null" || s == "~" {
		return ""
	}
	if len(s) >= 2 && s[0] == '\'' && s[len(s)-1] == '\'' {
		return strings.ReplaceAll(s[1:len(s)-1], "''", "'")
	}
	if len(s) >= 2 && s[0] == '"' && s[len(s)-1] == '"' {
		inner := s[1 : len(s)-1]
		inner = strings.ReplaceAll(inner, `\"`, `"`)
		inner = strings.ReplaceAll(inner, `\\`, `\`)
		return inner
	}
	return s
}

func yamlInt(raw string) (int, bool) {
	s := strings.TrimSpace(raw)
	if i := strings.IndexAny(s, " \t#"); i >= 0 {
		s = s[:i]
	}
	n, err := strconv.Atoi(s)
	return n, err == nil
}

func boolPtr(v bool) *bool { return &v }
