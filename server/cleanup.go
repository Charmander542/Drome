package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

type cleanupConfig struct {
	Enabled  bool
	Interval time.Duration
	Bin      string
	MusicDir string
	// MergeDupes consolidates Artist/Album folders that differ only by
	// year/path noise. On by default — disable with DROME_CLEANUP_MERGE=false.
	MergeDupes bool
	// RunOnStart runs one pass shortly after boot (after a short delay).
	RunOnStart bool
}

func cleanupConfigFromEnv(musicDir string) cleanupConfig {
	enabled := strings.ToLower(envOr("DROME_CLEANUP_ENABLED", "true"))
	merge := strings.ToLower(envOr("DROME_CLEANUP_MERGE", "true"))
	onStart := strings.ToLower(envOr("DROME_CLEANUP_ON_START", "true"))
	return cleanupConfig{
		Enabled:    enabled == "1" || enabled == "true" || enabled == "yes",
		Interval:   envDuration("DROME_CLEANUP_INTERVAL", 24*time.Hour),
		Bin:        envOr("DROME_CLEANUP_BIN", "drome-cleanup-library"),
		MusicDir:   musicDir,
		MergeDupes: merge == "1" || merge == "true" || merge == "yes",
		RunOnStart: onStart == "1" || onStart == "true" || onStart == "yes",
	}
}

type libraryCleaner struct {
	cfg    cleanupConfig
	scanFn func(context.Context) error
}

func newLibraryCleaner(cfg cleanupConfig, scanFn func(context.Context) error) *libraryCleaner {
	return &libraryCleaner{cfg: cfg, scanFn: scanFn}
}

func (c *libraryCleaner) Run(ctx context.Context) {
	if !c.cfg.Enabled {
		logf("library cleanup disabled (DROME_CLEANUP_ENABLED=false)")
		return
	}
	if c.cfg.Interval < time.Minute {
		c.cfg.Interval = time.Minute
	}
	logf("library cleanup enabled every %s (merge=%v, bin=%s)",
		c.cfg.Interval, c.cfg.MergeDupes, c.cfg.Bin)

	if c.cfg.RunOnStart {
		// Delay so downloads/migrations settle after boot.
		select {
		case <-ctx.Done():
			return
		case <-time.After(2 * time.Minute):
			c.runOnce(ctx)
		}
	}

	ticker := time.NewTicker(c.cfg.Interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			c.runOnce(ctx)
		}
	}
}

func (c *libraryCleaner) runOnce(ctx context.Context) {
	bin := c.resolveBin()
	if bin == "" {
		logf("library cleanup skipped: binary not found (%s)", c.cfg.Bin)
		return
	}
	if st, err := os.Stat(c.cfg.MusicDir); err != nil || !st.IsDir() {
		logf("library cleanup skipped: music dir %s: %v", c.cfg.MusicDir, err)
		return
	}

	reportPath := filepath.Join(os.TempDir(), fmt.Sprintf("drome-cleanup-%d.json", time.Now().Unix()))
	args := []string{
		"--music-dir", c.cfg.MusicDir,
		"--report", reportPath,
		"--quiet",
	}
	if c.cfg.MergeDupes {
		args = append(args, "--apply", "--merge-dupes")
	}

	var cmd *exec.Cmd
	if strings.HasSuffix(bin, ".py") {
		cmd = exec.CommandContext(ctx, "python3", append([]string{bin}, args...)...)
	} else {
		cmd = exec.CommandContext(ctx, bin, args...)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	logf("library cleanup starting…")
	err := cmd.Run()
	out := strings.TrimSpace(stdout.String() + "\n" + stderr.String())
	if err != nil {
		logf("library cleanup failed: %v\n%s", err, truncate(out, 1500))
		return
	}
	if out != "" {
		logf("library cleanup: %s", truncate(out, 800))
	} else {
		logf("library cleanup finished")
	}

	// After merges, ask Navidrome to rescan so moved files reappear cleanly.
	if c.cfg.MergeDupes && c.scanFn != nil {
		if err := c.scanFn(ctx); err != nil {
			logf("library cleanup: navidrome scan: %v", err)
		}
	}
	_ = os.Remove(reportPath)
}

func (c *libraryCleaner) resolveBin() string {
	candidates := []string{
		c.cfg.Bin,
		"/usr/local/bin/drome-cleanup-library",
		"scripts/cleanup_library.py",
		"cleanup_library.py",
	}
	for _, cand := range candidates {
		if cand == "" {
			continue
		}
		if path, err := exec.LookPath(cand); err == nil {
			return path
		}
		if st, err := os.Stat(cand); err == nil && !st.IsDir() {
			return cand
		}
	}
	return ""
}
