# Karaoke timing harness

Measures word-synced lyric stamps against **independent ground truth** (TTS
onsets) or, for qualitative checks only, real masters. Do **not** treat
CTC-vs-self scores as proof of karaoke quality.

## Quick self-check (CI-friendly)

```bash
./scripts/lyrics-eval/run.sh fixtures
```

## Valid measurement (round 4)

Full-length TTS vocals mixed over a synthetic music bed, with known per-word
onsets. Tempo and length variants. Scores the LRCLIB-style prior and
`generate-words` output **against the TTS truth JSON** — no Deezer previews,
no guessed offsets, no CTC self-score.

```bash
python3 scripts/lyrics-eval/align_lyrics.py synth-full \
  --out-dir /tmp/lyrics-eval/round4 --run-align \
  --json /tmp/lyrics-eval/round4/report.json
```

Hard pass bar: median abs ≤ 40 ms, p90 ≤ 100 ms, |drift| ≤ 30 ms/min.
Soft bar discussed for shipping: p90 ≲ 150 ms on valid truth.

Results checked into `results/round4/synth-full-report.json`. As of round 4 the
aligner **does not** meet the soft bar on valid truth (and often regresses vs
the coarse prior). Companion align stays **off by default**.

## Optional CTC tooling

```bash
python3 scripts/lyrics-eval/align_lyrics.py synth-fixture --out-dir scripts/lyrics-eval/fixtures/speech
python3 scripts/lyrics-eval/align_lyrics.py validate-aligner \
  --audio scripts/lyrics-eval/fixtures/speech/speech.wav \
  --truth scripts/lyrics-eval/fixtures/speech/speech.truth.json
python3 scripts/lyrics-eval/align_lyrics.py check-deps
python3 scripts/lyrics-eval/align_lyrics.py generate-words \
  --audio /path/song.wav --lrc /path/song.lrc --write
```

`generate-words` keeps LRCLIB **text + coarse line anchors**, then runs
segment-constrained CTC (`[drome-aligned:v3-ctc-seg]`). A **quality gate**
refuses to rewrite the sidecar unless coverage ≥ 0.6, median abs improves, and
p90 is not worse vs the LRCLIB input (CTC self-check is only a relative gate —
not a validity claim).

## Companion wiring

`DROME_LYRICS_ALIGN` defaults to **false**. To opt in after installing
torch/torchaudio/demucs and reviewing `results/round4/`:

```bash
DROME_LYRICS_ALIGN=true
# optional: DROME_LYRICS_ALIGN_LINE_SEARCH_MS=3000
# optional: DROME_LYRICS_ALIGN_GAP=5s
# optional: DROME_LYRICS_ALIGN_NICE=true
```

Missing deps → `keep_lrclib`. Gate failure → `keep_lrclib` (sidecar unchanged).

## Swift timing tests

`ios/LyricsTiming` runs on Mac CI / Xcode — this Linux VM has no Swift toolchain.
