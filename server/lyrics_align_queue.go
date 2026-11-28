package main

import (
	"context"
	"os"
	"path/filepath"
	"sync"
)

type lyricsAlignJob struct {
	audioPath string
	lrcPath   string
}

type lyricsAlignQueue struct {
	cfg lyricsAlignConfig

	mu     sync.Mutex
	pending map[string]lyricsAlignJob // keyed by lrcPath
	notify chan struct{}
}

func newLyricsAlignQueue(cfg lyricsAlignConfig) *lyricsAlignQueue {
	if !cfg.Enabled {
		return nil
	}
	return &lyricsAlignQueue{
		cfg:     cfg,
		pending: make(map[string]lyricsAlignJob),
		notify:  make(chan struct{}, 1),
	}
}

func (q *lyricsAlignQueue) enqueueAlign(audioPath, lrcPath string) {
	if q == nil || !q.cfg.Enabled {
		return
	}
	if !alignScriptUsable(q.cfg) {
		return
	}
	raw, err := os.ReadFile(lrcPath)
	if err != nil || !hasWordSync(string(raw)) {
		return
	}
	if lrcAlreadyAligned(string(raw)) {
		return
	}

	q.mu.Lock()
	if _, dup := q.pending[lrcPath]; dup {
		q.mu.Unlock()
		return
	}
	q.pending[lrcPath] = lyricsAlignJob{audioPath: audioPath, lrcPath: lrcPath}
	q.mu.Unlock()

	select {
	case q.notify <- struct{}{}:
	default:
	}
}

func (q *lyricsAlignQueue) popNext() (lyricsAlignJob, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	for lrc, job := range q.pending {
		delete(q.pending, lrc)
		return job, true
	}
	return lyricsAlignJob{}, false
}

func (q *lyricsAlignQueue) runWorker(ctx context.Context) {
	if q == nil {
		return
	}
	if !alignScriptUsable(q.cfg) {
		return
	}
	logf("lyrics align worker: started (gap %s, line_search %dms, nice=%v)",
		q.cfg.Gap, q.cfg.LineSearchMs, q.cfg.Nice)

	for {
		if err := ctx.Err(); err != nil {
			return
		}

		job, ok := q.popNext()
		if !ok {
			select {
			case <-ctx.Done():
				return
			case <-q.notify:
				continue
			}
		}

		q.runOne(ctx, job)

		if q.cfg.Gap > 0 {
			if err := sleepCtx(ctx, q.cfg.Gap); err != nil {
				return
			}
		}
	}
}

func (q *lyricsAlignQueue) runOne(ctx context.Context, job lyricsAlignJob) {
	res, err := refineLRCAgainstAudio(ctx, q.cfg, job.audioPath, job.lrcPath)
	if err != nil {
		logf("lyrics align %s: %v", filepath.Base(job.lrcPath), err)
		return
	}
	if res == nil {
		return
	}
	if res.Skipped {
		if res.Reason != "" {
			logf("lyrics align %s: skipped (%s)", filepath.Base(job.lrcPath), res.Reason)
		}
		return
	}
	if res.Fallback == "keep_lrclib" {
		logf("lyrics align %s: fallback keep_lrclib (%s)", filepath.Base(job.lrcPath), res.Reason)
		return
	}
	logf("lyrics align %s: generated=%d interp=%d coverage=%.2f before_med_abs=%.0f after_med_abs=%.0f wrote=%v (%.1fs)",
		filepath.Base(job.lrcPath),
		res.NGenerated, res.NInterp, res.Coverage,
		res.Before.MedianAbsMs, res.After.MedianAbsMs,
		res.Wrote, res.SecondsTotal)
}