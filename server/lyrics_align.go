package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Optional forced-alignment refinement for word-synced sidecars.
//
// When DROME_LYRICS_ALIGN=true and scripts/lyrics-eval/align_lyrics.py is
// available (plus faster-whisper), the companion snaps a constant [offset:]
// onto the .lrc next to the audio so stamps match the file actually played.
//
// CPU cost: ~0.05–0.2× realtime per track with Whisper small.en on CPU.
// Disabled by default — enable on a backfill pass when quality matters more
// than ingest speed.

type lyricsAlignConfig struct {
	Enabled   bool
	Python    string
	Script    string
	Model     string
	Timeout   time.Duration
	MinAbsMs  int // ignore tiny median offsets
}

func lyricsAlignConfigFromEnv() lyricsAlignConfig {
	enabled := strings.ToLower(envOr("DROME_LYRICS_ALIGN", "false"))
	script := envOr("DROME_LYRICS_ALIGN_SCRIPT", "")
	if script == "" {
		// Prefer the repo script when running from a checkout / image that ships it.
		candidates := []string{
			"/app/scripts/lyrics-eval/align_lyrics.py",
			filepath.Join("scripts", "lyrics-eval", "align_lyrics.py"),
		}
		for _, c := range candidates {
			if st, err := os.Stat(c); err == nil && !st.IsDir() {
				script = c
				break
			}
		}
	}
	return lyricsAlignConfig{
		Enabled:  enabled == "1" || enabled == "true" || enabled == "yes",
		Python:   envOr("DROME_LYRICS_ALIGN_PYTHON", "python3"),
		Script:   script,
		Model:    envOr("DROME_LYRICS_ALIGN_MODEL", "small.en"),
		Timeout:  envDuration("DROME_LYRICS_ALIGN_TIMEOUT", 8*time.Minute),
		MinAbsMs: envInt("DROME_LYRICS_ALIGN_MIN_ABS_MS", 40),
	}
}

type alignRefineResult struct {
	AppliedOffsetMs int  `json:"applied_offset_ms"`
	Wrote           bool `json:"wrote"`
	Before          struct {
		MedianMs    float64 `json:"median_ms"`
		MedianAbsMs float64 `json:"median_abs_ms"`
		P90AbsMs    float64 `json:"p90_abs_ms"`
		Drift       float64 `json:"drift_ms_per_min"`
		Pass        bool    `json:"pass"`
		N           int     `json:"n"`
	} `json:"before"`
	After struct {
		MedianAbsMs float64 `json:"median_abs_ms"`
		P90AbsMs    float64 `json:"p90_abs_ms"`
		Pass        bool    `json:"pass"`
		N           int     `json:"n"`
	} `json:"after"`
}

// refineLRCAgainstAudio runs the Python harness in refine --write mode.
func refineLRCAgainstAudio(ctx context.Context, cfg lyricsAlignConfig, audioPath, lrcPath string) (*alignRefineResult, error) {
	if !cfg.Enabled {
		return nil, nil
	}
	if strings.TrimSpace(cfg.Script) == "" {
		return nil, fmt.Errorf("align enabled but no script found (set DROME_LYRICS_ALIGN_SCRIPT)")
	}
	if _, err := os.Stat(audioPath); err != nil {
		return nil, err
	}
	if _, err := os.Stat(lrcPath); err != nil {
		return nil, err
	}
	runCtx, cancel := context.WithTimeout(ctx, cfg.Timeout)
	defer cancel()
	tmpJSON, err := os.CreateTemp("", "drome-lyrics-align-*.json")
	if err != nil {
		return nil, err
	}
	jsonPath := tmpJSON.Name()
	_ = tmpJSON.Close()
	defer os.Remove(jsonPath)

	cmd := exec.CommandContext( //nolint:gosec // paths from config / library
		runCtx,
		cfg.Python,
		cfg.Script,
		"refine",
		"--audio", audioPath,
		"--lrc", lrcPath,
		"--model", cfg.Model,
		"--write",
		"--json", jsonPath,
	)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		// Harness exits 1 when after stats fail the threshold — still read JSON.
		if runCtx.Err() != nil {
			return nil, fmt.Errorf("align timeout: %w (%s)", runCtx.Err(), truncate(stderr.String(), 300))
		}
	}
	raw, err := os.ReadFile(jsonPath)
	if err != nil {
		return nil, fmt.Errorf("align missing result json: %w (%s)", err, truncate(stderr.String(), 300))
	}
	var out alignRefineResult
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, fmt.Errorf("align json: %w", err)
	}
	return &out, nil
}

// ensureMillisecondStamps rewrites <> / [] stamps that only have centiseconds
// into millisecond form without changing the numeric time (pad to .xxx).
func ensureMillisecondStamps(lrc string) string {
	re := regexp.MustCompile(`([\[<])(\d{1,2}):(\d{1,2})[.:](\d{1,3})([\]>])`)
	return re.ReplaceAllStringFunc(lrc, func(m string) string {
		sub := re.FindStringSubmatch(m)
		if len(sub) != 6 {
			return m
		}
		open, mm, ss, frac, closeCh := sub[1], sub[2], sub[3], sub[4], sub[5]
		ms := parseStampFrac(mm, ss, frac)
		return fmt.Sprintf("%s%s%s", open, formatLRCStamp(ms), closeCh)
	})
}

func parseStampFrac(mm, ss, frac string) int {
	m, _ := strconv.Atoi(mm)
	s, _ := strconv.Atoi(ss)
	var fms int
	switch {
	case frac == "":
		fms = 0
	case len(frac) == 1:
		fms = atoiDefault(frac) * 100
	case len(frac) == 2:
		fms = atoiDefault(frac) * 10
	default:
		fms = atoiDefault((frac + "000")[:3])
	}
	return (m*60+s)*1000 + fms
}

func atoiDefault(s string) int {
	n, err := strconv.Atoi(s)
	if err != nil {
		return 0
	}
	return n
}

// rewriteSidecarPrecision upgrades stamp precision on an existing .lrc.
func rewriteSidecarPrecision(lrcPath string) (bool, error) {
	raw, err := os.ReadFile(lrcPath)
	if err != nil {
		return false, err
	}
	in := string(raw)
	out := ensureMillisecondStamps(in)
	if out == in {
		return false, nil
	}
	if err := os.WriteFile(lrcPath, []byte(ensureTrailingNewline(out)), 0o644); err != nil {
		return false, err
	}
	return true, nil
}
