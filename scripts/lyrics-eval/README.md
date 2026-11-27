# Karaoke timing harness

Measures word-synced lyric stamps against **CTC forced alignment** (torchaudio
MMS_FA) on **Demucs-separated vocals** — not Whisper ASR timestamps.

## Quick self-check (CI-friendly)

```bash
./scripts/lyrics-eval/run.sh fixtures
```

Optional CTC self-test (needs torch / torchaudio / espeak):

```bash
python3 scripts/lyrics-eval/align_lyrics.py synth-fixture --out-dir scripts/lyrics-eval/fixtures/speech
python3 scripts/lyrics-eval/align_lyrics.py validate-aligner \
  --audio scripts/lyrics-eval/fixtures/speech/speech.wav \
  --truth scripts/lyrics-eval/fixtures/speech/speech.truth.json
```

Pass bar: median abs word error ≤ 40 ms, p90 ≤ 100 ms, |drift| ≤ 30 ms/min.

## Measure / generate a real track (local audio only — do not commit media)

Audio must match the LRCLIB master (±0.5 s), or use a Deezer preview anchored
to the lyric text (`--preview-anchor`).

```bash
pip install -r server/scripts/requirements-lyrics-align.txt
./scripts/lyrics-eval/run.sh measure --audio /path/song.wav --lrc /path/song.lrc
python3 scripts/lyrics-eval/align_lyrics.py generate-words \
  --audio /path/song.wav --lrc /path/song.lrc --write
python3 scripts/lyrics-eval/align_lyrics.py check-deps
python3 scripts/lyrics-eval/align_lyrics.py benchmark --audio /path/song.wav
```

`generate-words` (round 3) keeps LRCLIB **text + coarse line anchors**, then
runs segment-constrained CTC inside each line (±`--line-search-ms`, default
3000). High-conf words come from CTC; low-conf words interpolate; star / ad-lib
/ intro lines stay skippable. Sidecars get `[drome-aligned:v3-ctc-seg]`.

`refine-words` remains as an alias that forwards to `generate-words`.

CPU cost (≈30 s preview benchmark): ~0.5× realtime, ~2.65 GB peak RSS (Demucs
dominates). Companion sets `OMP_NUM_THREADS=1` and optional `nice`. Missing
torch/demucs → keep LRCLIB (`check-deps` / `keep_lrclib` fallback).

Round-3 preview numbers live in `results/e2e-report.json` and
`results/round3/`. Dense rap (BDKMV) still misses the 40/100 bar on previews;
production path is full-file companion align.

## Companion wiring

`DROME_LYRICS_ALIGN` defaults to **true**. After writing or upgrading a
word-synced `.lrc` sidecar, the Go companion enqueues `generate-words` (see
`server/lyrics_align.go`, `server/lyrics_align_queue.go`). Env:

- `DROME_LYRICS_ALIGN_LINE_SEARCH_MS` (default 3000; legacy `WINDOW_MS` still accepted)
- `DROME_LYRICS_ALIGN_GAP` (default 5s)
- `DROME_LYRICS_ALIGN_NICE` (default true)

## Swift timing tests

`ios/LyricsTiming` (KaraokeResume foreground snap, rebuild/post-seek guards,
LyricsClock lead/arrival) runs on Mac CI / Xcode — this Linux VM has no Swift
toolchain.
