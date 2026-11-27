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
	"sync"
	"time"
)

// Per-word CTC forced alignment (torchaudio MMS_FA + Demucs vocals) for word-synced
// LRCLIB sidecars. Runs from a background queue — see lyrics_align_queue.go.
//
// CPU: roughly 0.3–2× realtime per track (Demucs + MMS on CPU). Limit threads via
// OMP/MKL/OPENBLAS=1; optional nice -n 19 when DROME_LYRICS_ALIGN_NICE=true.

const lyricsAlignedVersion = "v2-ctc-demucs"

var (
	alignedMarkerRe = regexp.MustCompile(`(?i)\[drome-aligned:([^\]]+)\]`)
	alignDepsWarnOnce sync.Once
)

type lyricsAlignConfig struct {
	Enabled     bool
	Python      string
	Script      string
	Timeout     time.Duration
	WindowMs    int
	DemucsModel string
	Nice        bool
	Gap         time.Duration
}

func lyricsAlignConfigFromEnv() lyricsAlignConfig {
	enabled := strings.ToLower(envOr("DROME_LYRICS_ALIGN", "true"))
	script := envOr("DROME_LYRICS_ALIGN_SCRIPT", "")
	if script == "" {
		candidates := []string{
			"/usr/local/share/drome/align_lyrics.py",
			"/app/scripts/lyrics-eval/align_lyrics.py",
			filepath.Join("scripts", "lyrics-eval", "align_lyrics.py"),
			filepath.Join("scripts", "align_lyrics.py"),
		}
		for _, c := range candidates {
			if st, err := os.Stat(c); err == nil && !st.IsDir() {
				script = c
				break
			}
		}
	}
	nice := strings.ToLower(envOr("DROME_LYRICS_ALIGN_NICE", "true"))
	return lyricsAlignConfig{
		Enabled:     enabled == "1" || enabled == "true" || enabled == "yes",
		Python:      envOr("DROME_LYRICS_ALIGN_PYTHON", "python3"),
		Script:      script,
		Timeout:     envDuration("DROME_LYRICS_ALIGN_TIMEOUT", 12*time.Minute),
		WindowMs:    envInt("DROME_LYRICS_ALIGN_WINDOW_MS", 300),
		DemucsModel: envOr("DROME_LYRICS_ALIGN_DEMUCS_MODEL", "htdemucs"),
		Nice:        nice == "1" || nice == "true" || nice == "yes",
		Gap:         envDuration("DROME_LYRICS_ALIGN_GAP", 2*time.Second),
	}
}

type alignStats struct {
	MedianAbsMs float64 `json:"median_abs_ms"`
	P90AbsMs    float64 `json:"p90_abs_ms"`
	MedianMs    float64 `json:"median_ms"`
	N           int     `json:"n"`
	Pass        bool    `json:"pass"`
}

type alignRefineResult struct {
	Mode         string     `json:"mode"`
	Skipped      bool       `json:"skipped"`
	Reason       string     `json:"reason"`
	NSnapped     int        `json:"n_snapped"`
	NKept        int        `json:"n_kept"`
	Before       alignStats `json:"before"`
	After        alignStats `json:"after"`
	Wrote        bool       `json:"wrote"`
	SecondsTotal float64    `json:"seconds_total"`
}

func lrcAlreadyAligned(raw string) bool {
	if m := alignedMarkerRe.FindStringSubmatch(raw); len(m) == 2 {
		return strings.EqualFold(strings.TrimSpace(m[1]), lyricsAlignedVersion)
	}
	return false
}

func alignScriptUsable(cfg lyricsAlignConfig) bool {
	if strings.TrimSpace(cfg.Script) == "" {
		alignDepsWarnOnce.Do(func() {
			logf("lyrics align: disabled — no align_lyrics.py (set DROME_LYRICS_ALIGN_SCRIPT or DROME_LYRICS_ALIGN=false)")
		})
		return false
	}
	if _, err := os.Stat(cfg.Script); err != nil {
		alignDepsWarnOnce.Do(func() {
			logf("lyrics align: disabled — script missing at %q (%v)", cfg.Script, err)
		})
		return false
	}
	return true
}

// refineLRCAgainstAudio runs align_lyrics.py refine-words --write.
func refineLRCAgainstAudio(ctx context.Context, cfg lyricsAlignConfig, audioPath, lrcPath string) (*alignRefineResult, error) {
	if !cfg.Enabled {
		return nil, nil
	}
	if !alignScriptUsable(cfg) {
		return nil, nil
	}
	if _, err := os.Stat(audioPath); err != nil {
		return nil, err
	}
	raw, err := os.ReadFile(lrcPath)
	if err != nil {
		return nil, err
	}
	if lrcAlreadyAligned(string(raw)) {
		return &alignRefineResult{Skipped: true, Reason: "already aligned"}, nil
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

	args := []string{
		cfg.Script,
		"refine-words",
		"--audio", audioPath,
		"--lrc", lrcPath,
		"--write",
		"--json", jsonPath,
		"--window-ms", strconv.Itoa(cfg.WindowMs),
		"--demucs-model", cfg.DemucsModel,
		"--aligned-version", lyricsAlignedVersion,
	}
	exe := cfg.Python
	if cfg.Nice {
		if nicePath, err := exec.LookPath("nice"); err == nil {
			exe = nicePath
			args = append([]string{"-n", "19", cfg.Python}, args...)
		}
	}

	cmd := exec.CommandContext(runCtx, exe, args...) //nolint:gosec // controlled argv
	cmd.Env = append(os.Environ(),
		"OMP_NUM_THREADS=1",
		"MKL_NUM_THREADS=1",
		"OPENBLAS_NUM_THREADS=1",
	)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		if runCtx.Err() != nil {
			return nil, fmt.Errorf("align timeout: %w (%s)", runCtx.Err(), truncate(stderr.String(), 300))
		}
		// Exit 1 when quality thresholds fail — still read JSON.
	}
	resultRaw, err := os.ReadFile(jsonPath)
	if err != nil {
		alignDepsWarnOnce.Do(func() {
			logf("lyrics align: refine failed (%s); check python deps (torch, demucs)", truncate(stderr.String(), 400))
		})
		return nil, fmt.Errorf("align missing result json: %w (%s)", err, truncate(stderr.String(), 300))
	}
	var out alignRefineResult
	if err := json.Unmarshal(resultRaw, &out); err != nil {
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