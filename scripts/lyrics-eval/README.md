# Karaoke timing harness

Measures word-synced lyric stamps against forced alignment (Whisper word
onsets) and can write a constant `[offset:]` that snaps the sidecar to the
audio file actually played.

## Quick self-check (no Whisper, CI-friendly)

```bash
./scripts/lyrics-eval/run.sh fixtures
```

Pass bar: median abs word error ≤ 40 ms, p90 ≤ 100 ms, |drift| ≤ 30 ms/min.

## Measure a real track (local audio only — do not commit media)

```bash
pip install faster-whisper
./scripts/lyrics-eval/run.sh measure --audio /path/song.wav --lrc /path/song.lrc
./scripts/lyrics-eval/run.sh refine  --audio /path/song.wav --lrc /path/song.lrc --write
```

CPU cost: roughly 0.05–0.2× realtime with `small.en` on CPU.

## Companion wiring

Set `DROME_LYRICS_ALIGN=true` on the Go companion to run refine after writing
or upgrading a word-synced `.lrc` sidecar (see `server/lyrics_align.go`).
