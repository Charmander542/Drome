package main

import (
	"strings"
	"testing"
)

func TestLyricsFileToEnhancedLRC(t *testing.T) {
	raw := `version: '1.0'
metadata:
  title: Wet Sand
lines:
- text: My shadow side so amplified
  start_ms: 11160
  end_ms: 13708
  words:
  - text: 'My '
    start_ms: 11160
  - text: 'shadow '
    start_ms: 11259
  - text: 'side '
    start_ms: 11878
  - text: 'so '
    start_ms: 12345
  - text: amplified
    start_ms: 12705
- text: Keeps coming back dissatisfied
  start_ms: 13810
  words:
  - text: 'Keeps '
    start_ms: 13810
  - text: 'coming '
    start_ms: 14065
  - text: dissatisfied
    start_ms: 15091
- text: "I'm betting"
  start_ms: 47890
  words:
  - text: 'I''m '
    start_ms: 47890
  - text: betting
    start_ms: 47901
`
	out, ok := lyricsFileToEnhancedLRC(raw)
	if !ok {
		t.Fatal("expected conversion success")
	}
	if !hasWordSync(out) {
		t.Fatalf("expected <> word stamps, got:\n%s", out)
	}
	if !strings.Contains(out, "[00:11.16]") {
		t.Fatalf("expected line stamp for 11160ms, got:\n%s", out)
	}
	if !strings.Contains(out, "<00:11.16>My ") {
		t.Fatalf("expected first word stamp, got:\n%s", out)
	}
	if !strings.Contains(out, "<00:11.25>shadow ") {
		t.Fatalf("expected second word stamp, got:\n%s", out)
	}
	if !strings.Contains(out, "I'm ") {
		t.Fatalf("expected YAML '' unescape for I'm, got:\n%s", out)
	}
	lines := parseLyricsFile(raw)
	if len(lines) != 3 {
		t.Fatalf("expected 3 lines, got %d", len(lines))
	}
	if len(lines[0].Words) != 5 {
		t.Fatalf("expected 5 words on first line, got %d", len(lines[0].Words))
	}
}

func TestEffectiveSyncedLyricsPrefersLyricsfile(t *testing.T) {
	r := lrclibResult{
		HasWordSync:  boolPtr(true),
		SyncedLyrics: "[00:11.17] My shadow side so amplified\n",
		Lyricsfile: `lines:
- text: My shadow side so amplified
  start_ms: 11160
  words:
  - text: 'My '
    start_ms: 11160
  - text: amplified
    start_ms: 12705
`,
	}
	got := effectiveSyncedLyrics(r)
	if !hasWordSync(got) {
		t.Fatalf("expected word sync from lyricsfile, got %q", got)
	}
	if strings.TrimSpace(got) == strings.TrimSpace(r.SyncedLyrics) {
		t.Fatal("should not fall back to line-only syncedLyrics")
	}
}

func TestFormatLRCStamp(t *testing.T) {
	if got := formatLRCStamp(11160); got != "00:11.16" {
		t.Fatalf("got %s", got)
	}
	if got := formatLRCStamp(0); got != "00:00.00" {
		t.Fatalf("got %s", got)
	}
}
