#!/usr/bin/env python3
"""Measure / refine word-synced lyric stamps against forced alignment.

Usage:
  align_lyrics.py measure --audio song.wav --lrc song.lrc [--json out.json]
  align_lyrics.py refine  --audio song.wav --lrc song.lrc [--write] [--json out.json]
  align_lyrics.py synth-fixture --out-dir fixtures/perfect

Pass criteria (measure / refine):
  median absolute word error <= 40 ms
  p90 absolute word error   <= 100 ms
  |drift|                   <= 30 ms/min

`measure` compares Enhanced LRC / lyricsfile stamps to Whisper word onsets
(faster-whisper). `refine` estimates a constant [offset:] that minimizes
median error and optionally rewrites the .lrc. CPU cost on a laptop CPU is
roughly 0.05–0.2× realtime with the small.en model (no GPU required).

Audio is for local evaluation only — do not commit copyrighted media.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import statistics
import subprocess
import sys
import wave
from pathlib import Path
from typing import Any


ANGLE_RE = re.compile(r"<(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?>([^<\n]+)")
BRACKET_RE = re.compile(r"\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]")
OFFSET_RE = re.compile(r"\[offset:\s*([+-]?\d+)\s*\]", re.I)

MEDIAN_ABS_LIMIT_MS = 40
P90_ABS_LIMIT_MS = 100
DRIFT_LIMIT_MS_PER_MIN = 30


def normalize(tok: str) -> str:
    return re.sub(r"[^a-z0-9']+", "", tok.lower())


def stamp_to_ms(mm: str, ss: str, frac: str | None) -> int:
    raw = frac or ""
    if raw == "":
        fms = 0
    elif len(raw) == 1:
        fms = int(raw) * 100
    elif len(raw) == 2:
        fms = int(raw) * 10
    else:
        fms = int(raw.ljust(3, "0")[:3])
    return (int(mm) * 60 + int(ss)) * 1000 + fms


def format_stamp(ms: int) -> str:
    ms = max(0, int(ms))
    m, rem = divmod(ms, 60_000)
    s, frac = divmod(rem, 1000)
    return f"{m:02d}:{s:02d}.{frac:03d}"


def parse_lrc_words(raw: str) -> tuple[list[dict[str, Any]], int]:
    embedded = 0
    words: list[dict[str, Any]] = []
    for line in raw.splitlines():
        if m := OFFSET_RE.match(line.strip()):
            embedded = int(m.group(1))
            continue
        for m in ANGLE_RE.finditer(line):
            text = m.group(4).strip()
            if not text:
                continue
            ms = stamp_to_ms(m.group(1), m.group(2), m.group(3))
            words.append({"text": text, "start_ms": ms, "norm": normalize(text)})
    if embedded:
        for w in words:
            w["start_ms"] = max(0, w["start_ms"] + embedded)
    return words, embedded


def parse_lyricsfile_words(raw: str) -> list[dict[str, Any]]:
    out_lines: list[dict[str, Any]] = []
    cur = None
    in_words = False
    for line in raw.splitlines():
        trimmed = line.strip()
        if not trimmed or trimmed.startswith("#"):
            continue
        indent = 0
        for ch in line:
            if ch == " ":
                indent += 1
            elif ch == "\t":
                indent += 2
            else:
                break
        if trimmed.startswith("- text:"):
            val = trimmed[len("- text:") :].strip()
            if len(val) >= 2 and val[0] == "'" and val[-1] == "'":
                val = val[1:-1].replace("''", "'")
            elif len(val) >= 2 and val[0] == '"' and val[-1] == '"':
                val = val[1:-1]
            if indent == 0:
                out_lines.append({"words": []})
                cur = out_lines[-1]
                in_words = False
            elif cur is not None and in_words:
                cur["words"].append({"text": val, "start_ms": 0})
        elif trimmed.startswith("start_ms:"):
            try:
                ms = int(trimmed.split("start_ms:", 1)[1].strip().split()[0])
            except ValueError:
                continue
            if cur is None:
                continue
            if in_words and cur["words"] and indent >= 4:
                cur["words"][-1]["start_ms"] = ms
        elif trimmed == "words:" or trimmed.startswith("words:"):
            if cur is not None:
                in_words = True
    words: list[dict[str, Any]] = []
    for line in out_lines:
        for w in line["words"]:
            text = w["text"].strip()
            if text:
                words.append({"text": text, "start_ms": w["start_ms"], "norm": normalize(text)})
    return words


def load_lyric_words(path: Path) -> tuple[list[dict[str, Any]], str]:
    raw = path.read_text(encoding="utf-8", errors="replace")
    if path.suffix.lower() in {".yml", ".yaml"} or "start_ms:" in raw[:500]:
        return parse_lyricsfile_words(raw), "lyricsfile"
    words, _ = parse_lrc_words(raw)
    return words, "lrc"


def whisper_words(audio: Path, model_size: str = "small.en") -> list[dict[str, Any]]:
    try:
        from faster_whisper import WhisperModel
    except ImportError as exc:  # pragma: no cover
        raise SystemExit(
            "faster-whisper is required for measure/refine against real audio.\n"
            "pip install faster-whisper"
        ) from exc

    model = WhisperModel(model_size, device="cpu", compute_type="int8")
    segments, _ = model.transcribe(
        str(audio),
        word_timestamps=True,
        language="en",
        vad_filter=False,
        condition_on_previous_text=False,
        beam_size=5,
    )
    out: list[dict[str, Any]] = []
    for seg in segments:
        for w in seg.words or []:
            tok = (w.word or "").strip()
            if not tok:
                continue
            out.append(
                {
                    "text": tok,
                    "start_ms": int(round(w.start * 1000)),
                    "end_ms": int(round(w.end * 1000)),
                    "norm": normalize(tok),
                }
            )
    return out


def windowed_pairs(
    lrc: list[dict[str, Any]], asr: list[dict[str, Any]], window_ms: int = 2500
) -> list[dict[str, Any]]:
    """Match each LRC token to the nearest same-token ASR onset within ±window."""
    pairs: list[dict[str, Any]] = []
    used: set[int] = set()
    for lw in lrc:
        if not lw["norm"] or len(lw["norm"]) < 2:
            continue
        best_i = None
        best_d = window_ms + 1
        for i, a in enumerate(asr):
            if i in used:
                continue
            an = a["norm"]
            ln = lw["norm"]
            if an != ln and not (
                len(an) >= 3 and len(ln) >= 3 and (an.startswith(ln) or ln.startswith(an))
            ):
                continue
            d = abs(a["start_ms"] - lw["start_ms"])
            if d < best_d:
                best_d = d
                best_i = i
        if best_i is None:
            continue
        used.add(best_i)
        a = asr[best_i]
        pairs.append(
            {
                "text": lw["text"],
                "lrc_ms": lw["start_ms"],
                "asr_ms": a["start_ms"],
                "err_ms": lw["start_ms"] - a["start_ms"],
            }
        )
    return pairs


def summarize(pairs: list[dict[str, Any]]) -> dict[str, Any]:
    if len(pairs) < 5:
        return {"n": len(pairs), "pass": False, "reason": "too_few_pairs"}
    errs = [p["err_ms"] for p in pairs]
    abs_e = [abs(e) for e in errs]
    xs = [p["lrc_ms"] for p in pairs]
    ys = errs
    n = len(xs)
    mx = sum(xs) / n
    my = sum(ys) / n
    den = sum((x - mx) ** 2 for x in xs) or 1.0
    slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den
    drift = slope * 60_000
    median_err = statistics.median(errs)
    median_abs = statistics.median(abs_e)
    p90_abs = sorted(abs_e)[int(0.9 * (n - 1))]
    # Residual after removing constant offset — separates offset from jitter/drift.
    resid = [abs(e - median_err) for e in errs]
    return {
        "n": n,
        "mean_ms": statistics.mean(errs),
        "median_ms": median_err,
        "mean_abs_ms": statistics.mean(abs_e),
        "median_abs_ms": median_abs,
        "p90_abs_ms": p90_abs,
        "drift_ms_per_min": drift,
        "offset_kind": "constant" if abs(drift) <= DRIFT_LIMIT_MS_PER_MIN else "drifting",
        "after_offset_median_abs_ms": statistics.median(resid),
        "after_offset_p90_abs_ms": sorted(resid)[int(0.9 * (n - 1))],
        "pass": (
            median_abs <= MEDIAN_ABS_LIMIT_MS
            and p90_abs <= P90_ABS_LIMIT_MS
            and abs(drift) <= DRIFT_LIMIT_MS_PER_MIN
        ),
        "limits": {
            "median_abs_ms": MEDIAN_ABS_LIMIT_MS,
            "p90_abs_ms": P90_ABS_LIMIT_MS,
            "drift_ms_per_min": DRIFT_LIMIT_MS_PER_MIN,
        },
    }


def apply_offset_to_lrc(raw: str, offset_ms: int) -> str:
    """Rewrite stamps with millisecond precision and a single [offset:] tag."""
    # Strip existing offset tags; bake previous embedded offset into stamps first.
    words, embedded = parse_lrc_words(raw)
    # Re-parse line structure for rewrite.
    lines_out: list[str] = []
    if offset_ms:
        lines_out.append(f"[offset:{offset_ms}]")
    for line in raw.splitlines():
        stripped = line.strip()
        if not stripped or OFFSET_RE.match(stripped):
            continue
        if not BRACKET_RE.search(line) and not ANGLE_RE.search(line):
            # Keep metadata other than offset.
            if stripped.startswith("[") and stripped.endswith("]") and ":" in stripped:
                lines_out.append(stripped)
            continue
        # Shift every stamp on the line by -embedded (undo) then leave raw;
        # final listener offset is the new [offset:] tag only.
        def repl_angle(m: re.Match[str]) -> str:
            ms = stamp_to_ms(m.group(1), m.group(2), m.group(3)) - embedded
            return f"<{format_stamp(ms)}>{m.group(4)}"

        def repl_bracket(m: re.Match[str]) -> str:
            ms = stamp_to_ms(m.group(1), m.group(2), m.group(3)) - embedded
            return f"[{format_stamp(ms)}]"

        rewritten = ANGLE_RE.sub(repl_angle, line)
        rewritten = BRACKET_RE.sub(repl_bracket, rewritten)
        lines_out.append(rewritten.rstrip())
    return "\n".join(lines_out) + "\n"


def cmd_measure(args: argparse.Namespace) -> int:
    lrc_words, kind = load_lyric_words(Path(args.lrc))
    asr = whisper_words(Path(args.audio), model_size=args.model)
    pairs = windowed_pairs(lrc_words, asr, window_ms=args.window_ms)
    stats = summarize(pairs)
    payload = {
        "mode": "measure",
        "audio": str(args.audio),
        "lyrics": str(args.lrc),
        "lyrics_kind": kind,
        "n_lrc": len(lrc_words),
        "n_asr": len(asr),
        "stats": stats,
        "sample": pairs[:8],
    }
    _emit(payload, args.json)
    return 0 if stats.get("pass") else 1


def cmd_refine(args: argparse.Namespace) -> int:
    lrc_path = Path(args.lrc)
    raw = lrc_path.read_text(encoding="utf-8", errors="replace")
    lrc_words, _ = parse_lrc_words(raw)
    asr = whisper_words(Path(args.audio), model_size=args.model)
    pairs = windowed_pairs(lrc_words, asr, window_ms=args.window_ms)
    before = summarize(pairs)
    offset = int(round(before["median_ms"])) if before.get("n", 0) >= 5 else 0
    # LRC late vs vocal ⇒ positive median_ms ⇒ need negative [offset:] so UI lights earlier.
    # Our parser applies [offset:] by adding to stamps. Karaoke compares playhead to stamps.
    # If stamps are late (too large), we want smaller stamps ⇒ negative offset.
    applied = -offset if abs(offset) >= 40 else 0
    refined_raw = apply_offset_to_lrc(raw, applied)
    refined_words, _ = parse_lrc_words(refined_raw)
    after_pairs = windowed_pairs(refined_words, asr, window_ms=args.window_ms)
    after = summarize(after_pairs)
    if args.write and applied != 0:
        lrc_path.write_text(refined_raw, encoding="utf-8")
    payload = {
        "mode": "refine",
        "audio": str(args.audio),
        "lyrics": str(args.lrc),
        "before": before,
        "applied_offset_ms": applied,
        "after": after,
        "wrote": bool(args.write and applied != 0),
    }
    _emit(payload, args.json)
    return 0 if after.get("pass") else 1


def cmd_synth_fixture(args: argparse.Namespace) -> int:
    """Build a synthetic beep track + perfect LRC for harness self-test."""
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    sr = 16000
    duration_s = 8.0
    # Word onsets (ms) — deliberately not on centisecond boundaries.
    cues = [
        (820, "one"),
        (1510, "two"),
        (2235, "three"),
        (3100, "four"),
        (4055, "five"),
        (5200, "six"),
    ]
    samples = [0.0] * int(sr * duration_s)
    for ms, _ in cues:
        start = int(sr * ms / 1000)
        for i in range(start, min(len(samples), start + int(0.08 * sr))):
            t = (i - start) / sr
            samples[i] = 0.35 * math.sin(2 * math.pi * 880 * t)
    # Write wav
    wav_path = out / "perfect.wav"
    with wave.open(str(wav_path), "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        frames = b"".join(
            int(max(-1, min(1, s)) * 32767).to_bytes(2, "little", signed=True) for s in samples
        )
        w.writeframes(frames)
    # Perfect LRC with millisecond stamps
    lines = ["[ti:perfect-fixture]", "[offset:0]"]
    word_bits = " ".join(f"<{format_stamp(ms)}>{text}" for ms, text in cues)
    lines.append(f"[{format_stamp(cues[0][0])}] {word_bits}")
    lines.append(f"[{format_stamp(7000)}] end")
    lrc_path = out / "perfect.lrc"
    lrc_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    # Ground-truth JSON for the no-Whisper unit check
    truth = {"words": [{"text": t, "start_ms": ms} for ms, t in cues]}
    (out / "perfect.truth.json").write_text(json.dumps(truth, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"wav": str(wav_path), "lrc": str(lrc_path), "words": len(cues)}))
    return 0


def cmd_check_truth(args: argparse.Namespace) -> int:
    """Compare an LRC file to a truth JSON (no ASR). Used by CI-friendly fixtures."""
    words, _ = load_lyric_words(Path(args.lrc))
    truth = json.loads(Path(args.truth).read_text(encoding="utf-8"))
    tw = truth["words"]
    pairs = []
    for a, b in zip(words, tw):
        pairs.append(
            {
                "text": a["text"],
                "lrc_ms": a["start_ms"],
                "asr_ms": b["start_ms"],
                "err_ms": a["start_ms"] - b["start_ms"],
            }
        )
    stats = summarize(pairs)
    _emit({"mode": "check_truth", "stats": stats, "sample": pairs}, args.json)
    return 0 if stats.get("pass") else 1


def _emit(payload: dict[str, Any], json_path: str | None) -> None:
    text = json.dumps(payload, indent=2)
    if json_path:
        Path(json_path).write_text(text + "\n", encoding="utf-8")
    print(text)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    m = sub.add_parser("measure", help="Report stamp-vs-vocal error stats")
    m.add_argument("--audio", required=True)
    m.add_argument("--lrc", required=True)
    m.add_argument("--model", default="small.en")
    m.add_argument("--window-ms", type=int, default=2500)
    m.add_argument("--json")
    m.set_defaults(func=cmd_measure)

    r = sub.add_parser("refine", help="Estimate [offset:] and optionally rewrite .lrc")
    r.add_argument("--audio", required=True)
    r.add_argument("--lrc", required=True)
    r.add_argument("--model", default="small.en")
    r.add_argument("--window-ms", type=int, default=2500)
    r.add_argument("--write", action="store_true")
    r.add_argument("--json")
    r.set_defaults(func=cmd_refine)

    s = sub.add_parser("synth-fixture", help="Write a perfect beep+LRC fixture")
    s.add_argument("--out-dir", required=True)
    s.set_defaults(func=cmd_synth_fixture)

    c = sub.add_parser("check-truth", help="Compare LRC to truth JSON (no ASR)")
    c.add_argument("--lrc", required=True)
    c.add_argument("--truth", required=True)
    c.add_argument("--json")
    c.set_defaults(func=cmd_check_truth)

    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
