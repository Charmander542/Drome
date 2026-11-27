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

## Measure / refine a real track (local audio only — do not commit media)

Audio must match the LRCLIB master (±0.5 s), or use a Deezer preview anchored
to the lyric text (`--preview-anchor`).

```bash
pip install -r server/scripts/requirements-lyrics-align.txt
./scripts/lyrics-eval/run.sh measure --audio /path/song.wav --lrc /path/song.lrc
./scripts/lyrics-eval/run.sh refine-words --audio /path/song.wav --lrc /path/song.lrc --write
```

Refine is two-step: constant median offset, then per-word snap within ±300 ms
when CTC confidence is high. Sidecars get `[drome-aligned:v2-ctc-demucs]`.

CPU cost: roughly 0.3–2× realtime (Demucs + MMS on CPU). Companion sets
`OMP_NUM_THREADS=1` and optional `nice`.

## Companion wiring

`DROME_LYRICS_ALIGN` defaults to **true**. After writing or upgrading a
word-synced `.lrc` sidecar, the Go companion enqueues `refine-words` (see
`server/lyrics_align.go`, `server/lyrics_align_queue.go`).

## Swift timing tests

`ios/LyricsTiming` (KaraokeResume foreground snap, LyricsClock lead/arrival)
runs on Mac CI / Xcode — this Linux VM has no Swift toolchain.
