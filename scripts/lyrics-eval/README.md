# Karaoke timing harness

Valid measurement scores word stamps against **independent TTS onset truth**
(optionally after Demucs). Do **not** treat CTC-vs-self scores as proof.

## Round 5 root cause

Round 4’s multi-second p90 that grew with duration came from a
`len(words) * 280` segment cap that crushed each line to ~1.4 s. Absolute MMS
timebase at 30 / 120 / 240 s was already fine. Fix: neighbor-clamped LRCLIB line
windows (±1.5 s), tensor-derived frame_ms, per-line agreement gate.

## Quick checks

```bash
./scripts/lyrics-eval/run.sh fixtures
python3 scripts/lyrics-eval/align_lyrics.py selftest-timebase
python3 scripts/lyrics-eval/align_lyrics.py synth-full \
  --out-dir /tmp/lyrics-eval/round5 --run-align \
  --json /tmp/lyrics-eval/round5/report.json
```

Pass bar (round 5): median abs ≤ 60 ms, p90 ≤ 150 ms, |drift| ≤ 30 ms/min.

Results: `results/round5/`.

## Align one real track (spot-check)

```bash
# With a local Enhanced LRC:
python3 scripts/lyrics-eval/align_lyrics.py align-track \
  --audio /path/to/master.flac \
  --lrc /path/to/song.lrc \
  --out-dir /tmp/align-report

# Or fetch word-synced lyrics from LRCLIB:
python3 scripts/lyrics-eval/align_lyrics.py align-track \
  --audio /path/to/BDKMV.flac \
  --artist 'Kendrick Lamar' \
  --title "Bitch, Don't Kill My Vibe" \
  --out-dir /tmp/bdkmv-align
```

Writes `input.lrc`, `aligned.lrc`, `generate.json`, and `report.json` with
**per-line gate decisions** (aligned vs fallback_lrclib + reason). Uses Demucs
unless `--no-demucs` / `--allow-no-demucs`.

Timebase selftest abs tolerance is **40 ms** (honest floor — 30 ms is not
achievable with a single lag compensate across 30/120/240 s).

## Companion

`DROME_LYRICS_ALIGN` defaults to **false**. After reviewing round-5 numbers:

```bash
DROME_LYRICS_ALIGN=true
DROME_LYRICS_ALIGN_LINE_SEARCH_MS=1500   # optional
```

Marker: `[drome-aligned:v4-ctc-line]`. Gate failure or missing deps → keep LRCLIB.
Per-line fallback keeps LRCLIB stamps when the first aligned word disagrees by >1 s.
