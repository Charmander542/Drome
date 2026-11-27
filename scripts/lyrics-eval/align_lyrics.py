#!/usr/bin/env python3
"""Generate word-synced karaoke stamps via segment-constrained CTC.

LRCLIB supplies lyric *text* and coarse line anchors only. Word timings are
generated outright from Demucs vocals + torchaudio MMS_FA — not snapped from
LRCLIB word stamps.

Pipeline (generate-words):
  1. Demucs vocals of the library file
  2. Line-level CTC in a wide window (±line-search) around each LRCLIB line start
  3. Word-level CTC inside each aligned line segment
  4. Low-confidence words → interpolate between confident neighbours
  5. Parenthetical / skippable tokens and intro/outro silence handled softly
     (MMS star token + vocal-activity bounds)

Commands:
  synth-fixture / check-truth / validate-aligner / measure / generate-words
  benchmark / check-deps / separate

Pass bar: median abs ≤ 40 ms, p90 ≤ 100 ms, |drift| ≤ 30 ms/min.

Audio is for local evaluation only — do not commit copyrighted media.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
import wave
from pathlib import Path
from typing import Any

ANGLE_RE = re.compile(r"<(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?>([^<\n]+)")
BRACKET_RE = re.compile(r"\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]")
OFFSET_RE = re.compile(r"\[offset:\s*([+-]?\d+)\s*\]", re.I)
ALIGNED_RE = re.compile(r"\[drome-aligned:([^\]]+)\]", re.I)
PAREN_RE = re.compile(r"^[\(\[]|[\)\]]$")

MEDIAN_ABS_LIMIT_MS = 40
P90_ABS_LIMIT_MS = 100
DRIFT_LIMIT_MS_PER_MIN = 30
ALIGNED_VERSION = "v3-ctc-seg"
DEFAULT_LINE_SEARCH_MS = 3000
DEFAULT_MIN_SCORE = 0.12
FRAME_MS = 20.0  # MMS_FA hop at 16 kHz
_MMS_CHARS = set("abcdefghijklmnopqrstuvwxyz'")


def normalize_token(tok: str) -> str:
    return re.sub(r"[^a-z0-9']+", "", tok.lower())


def mms_word(tok: str) -> str:
    raw = normalize_token(tok)
    return "".join(c for c in raw if c in _MMS_CHARS)


def is_skippable_token(text: str) -> bool:
    """Parentheticals / backing-vocal cues — soft: align if confident, else interp."""
    t = text.strip()
    if not t:
        return True
    if t.startswith("(") or t.startswith("[") or t.endswith(")") or t.endswith("]"):
        return True
    # Common ad-lib marks
    low = normalize_token(t)
    return low in {"yeah", "uh", "ooh", "ooo", "ah", "ha", "hey", "woah", "whoa"}


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


def parse_lrc_words(raw: str) -> tuple[list[dict[str, Any]], int, str | None]:
    embedded = 0
    aligned_ver = None
    words: list[dict[str, Any]] = []
    for line in raw.splitlines():
        stripped = line.strip()
        if m := OFFSET_RE.match(stripped):
            embedded = int(m.group(1))
            continue
        if m := ALIGNED_RE.match(stripped):
            aligned_ver = m.group(1).strip()
            continue
        for m in ANGLE_RE.finditer(line):
            text = m.group(4).strip()
            if not text:
                continue
            ms = stamp_to_ms(m.group(1), m.group(2), m.group(3))
            words.append(
                {
                    "text": text,
                    "start_ms": ms,
                    "norm": normalize_token(text),
                    "mms": mms_word(text),
                    "skippable": is_skippable_token(text),
                }
            )
    if embedded:
        for w in words:
            w["start_ms"] = max(0, w["start_ms"] + embedded)
    return words, embedded, aligned_ver


def parse_lrc_lines(raw: str) -> tuple[list[dict[str, Any]], int, str | None]:
    """Parse Enhanced LRC into lines of words (text + coarse LRCLIB priors)."""
    embedded = 0
    aligned_ver = None
    lines: list[dict[str, Any]] = []
    for line in raw.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if m := OFFSET_RE.match(stripped):
            embedded = int(m.group(1))
            continue
        if m := ALIGNED_RE.match(stripped):
            aligned_ver = m.group(1).strip()
            continue
        bm = BRACKET_RE.search(line)
        angles = list(ANGLE_RE.finditer(line))
        if not angles:
            continue
        words = []
        for m in angles:
            text = m.group(4).strip()
            if not text:
                continue
            ms = stamp_to_ms(m.group(1), m.group(2), m.group(3))
            words.append(
                {
                    "text": text,
                    "prior_ms": ms,
                    "norm": normalize_token(text),
                    "mms": mms_word(text),
                    "skippable": is_skippable_token(text),
                }
            )
        if not words:
            continue
        line_ms = (
            stamp_to_ms(bm.group(1), bm.group(2), bm.group(3))
            if bm
            else words[0]["prior_ms"]
        )
        lines.append({"prior_ms": line_ms, "words": words})
    if embedded:
        for ln in lines:
            ln["prior_ms"] = max(0, ln["prior_ms"] + embedded)
            for w in ln["words"]:
                w["prior_ms"] = max(0, w["prior_ms"] + embedded)
    return lines, embedded, aligned_ver


def load_wav_mono16k(path: Path) -> "torch.Tensor":
    import numpy as np
    import torch

    raw = subprocess.check_output(
        [
            "ffmpeg",
            "-v",
            "error",
            "-i",
            str(path),
            "-ac",
            "1",
            "-ar",
            "16000",
            "-f",
            "f32le",
            "-",
        ]
    )
    arr = np.frombuffer(raw, dtype=np.float32).copy()
    return torch.from_numpy(arr).unsqueeze(0)


def demucs_vocals(audio: Path, out_dir: Path, model: str = "htdemucs") -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    cached = out_dir / "vocals.wav"
    if cached.exists() and cached.stat().st_mtime >= audio.stat().st_mtime:
        return cached
    cmd = [
        sys.executable,
        "-m",
        "demucs",
        "--two-stems=vocals",
        "-n",
        model,
        "-o",
        str(out_dir),
        str(audio),
    ]
    t0 = time.time()
    subprocess.run(cmd, check=True, capture_output=True)
    found = list(out_dir.rglob("vocals.wav"))
    if not found:
        raise RuntimeError(f"demucs produced no vocals under {out_dir}")
    found.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    src = found[0]
    if src.resolve() != cached.resolve():
        shutil.copy2(src, cached)
    print(
        f"demucs {model}: {audio.name} -> vocals in {time.time() - t0:.1f}s",
        file=sys.stderr,
    )
    return cached


def prepare_vocals(audio: Path, work: Path, *, use_demucs: bool, demucs_model: str) -> Path:
    if use_demucs:
        return demucs_vocals(audio, work / "demucs", model=demucs_model)
    dst = work / "mix.wav"
    subprocess.run(
        ["ffmpeg", "-y", "-v", "error", "-i", str(audio), "-ac", "1", "-ar", "16000", str(dst)],
        check=True,
    )
    return dst


_mms_bundle: dict[str, Any] = {}


def get_mms(*, with_star: bool = True):
    """Load MMS_FA. Star token lets CTC skip frames for ad-libs not in the text."""
    import torch
    from torchaudio.pipelines import MMS_FA

    key = "star" if with_star else "nostar"
    if key not in _mms_bundle:
        device = torch.device("cpu")
        _mms_bundle[key] = {
            "model": MMS_FA.get_model(with_star=with_star).to(device).eval(),
            "tokenizer": MMS_FA.get_tokenizer(),
            "aligner": MMS_FA.get_aligner(),
            "device": device,
        }
    return _mms_bundle[key]


def vocal_activity_bounds(waveform: "torch.Tensor", *, frame_ms: int = 50, thresh_ratio: float = 0.08) -> tuple[int, int]:
    """First/last ms with significant energy — trim empty intro/outro for search."""
    import torch

    sr = 16_000
    x = waveform.squeeze(0)
    n = x.numel()
    dur_ms = max(1, int(n / sr * 1000))
    hop = max(1, int(sr * frame_ms / 1000))
    energies = []
    for i in range(0, n - hop + 1, hop):
        energies.append(float(torch.sqrt(torch.mean(x[i : i + hop] ** 2))))
    if not energies:
        return 0, dur_ms
    peak = max(energies) or 1.0
    thr = peak * thresh_ratio
    first = 0
    last = len(energies) - 1
    for i, e in enumerate(energies):
        if e >= thr:
            first = i
            break
    for i in range(len(energies) - 1, -1, -1):
        if energies[i] >= thr:
            last = i
            break
    return first * frame_ms, min(dur_ms, (last + 1) * frame_ms)


def _min_window_ms_for_tokens(tokens: list[str]) -> int:
    """CTC needs roughly ≥1 frame per letter (+ blanks); keep a floor."""
    chars = sum(max(1, len(t)) for t in tokens) + len(tokens)
    return max(1200, int(chars * FRAME_MS * 2.5) + 400)


def compute_emission(waveform: "torch.Tensor", *, with_star: bool = True) -> "torch.Tensor":
    """Full-clip MMS emission (T, C) on CPU — reuse for sliding line search."""
    import torch

    bundle = get_mms(with_star=with_star)
    with torch.inference_mode():
        emission, _ = bundle["model"](waveform.to(bundle["device"]))
        if emission.ndim == 3:
            emission = emission[0]
        return emission.cpu()


def ctc_align_emission(
    emission: "torch.Tensor",
    tokens: list[str],
    g0_ms: int,
    *,
    with_star: bool = True,
) -> list[dict[str, Any]]:
    """Align tokens against a precomputed emission slice starting at g0_ms."""
    if not tokens or emission.shape[0] < 3:
        return []
    bundle = get_mms(with_star=with_star)
    tokenizer = bundle["tokenizer"]
    aligner = bundle["aligner"]
    try:
        spans = aligner(emission, tokenizer(tokens))
    except Exception:
        return []
    out = []
    for tok, word_spans in zip(tokens, spans):
        if not word_spans:
            out.append({"mms": tok, "ctc_ms": None, "end_ms": None, "score": 0.0})
            continue
        start_frame = word_spans[0].start
        end_frame = word_spans[-1].end
        score = float(statistics.mean(s.score for s in word_spans))
        out.append(
            {
                "mms": tok,
                "ctc_ms": g0_ms + int(round(start_frame * FRAME_MS)),
                "end_ms": g0_ms + int(round(end_frame * FRAME_MS)),
                "score": score,
            }
        )
    return out


def ctc_align_in_window(
    waveform: "torch.Tensor",
    tokens: list[str],
    g0_ms: int,
    g1_ms: int,
    *,
    with_star: bool = True,
    emission: "torch.Tensor | None" = None,
) -> list[dict[str, Any]]:
    """Align `tokens` inside absolute window [g0_ms, g1_ms]."""
    if not tokens:
        return []
    sr = 16_000
    n = waveform.shape[-1]
    dur_ms = max(1, int(n / sr * 1000))
    need = _min_window_ms_for_tokens(tokens)
    if g1_ms - g0_ms < need:
        mid = (g0_ms + g1_ms) // 2
        g0_ms = mid - need // 2
        g1_ms = g0_ms + need
    g0 = max(0, g0_ms)
    g1 = min(dur_ms, max(g0 + need, g1_ms))
    if emission is not None:
        # emission frame i ≈ time i * FRAME_MS
        f0 = max(0, int(g0 / FRAME_MS))
        f1 = min(emission.shape[0], max(f0 + 3, int(g1 / FRAME_MS)))
        return ctc_align_emission(emission[f0:f1], tokens, int(f0 * FRAME_MS), with_star=with_star)

    import torch

    bundle = get_mms(with_star=with_star)
    model = bundle["model"]
    tokenizer = bundle["tokenizer"]
    aligner = bundle["aligner"]
    device = bundle["device"]
    a0 = int(g0 / 1000 * sr)
    a1 = int(g1 / 1000 * sr)
    clip = waveform[:, a0:a1].to(device)
    if clip.numel() < sr // 8:
        return []
    with torch.inference_mode():
        em, _ = model(clip)
        if em.ndim == 3:
            em = em[0]
        try:
            spans = aligner(em.cpu(), tokenizer(tokens))
        except Exception as exc:  # pragma: no cover
            print(f"align window failed: {exc}", file=sys.stderr)
            return []
    out = []
    for tok, word_spans in zip(tokens, spans):
        if not word_spans:
            out.append({"mms": tok, "ctc_ms": None, "end_ms": None, "score": 0.0})
            continue
        start_frame = word_spans[0].start
        end_frame = word_spans[-1].end
        score = float(statistics.mean(s.score for s in word_spans))
        out.append(
            {
                "mms": tok,
                "ctc_ms": g0 + int(round(start_frame * FRAME_MS)),
                "end_ms": g0 + int(round(end_frame * FRAME_MS)),
                "score": score,
            }
        )
    return out


def search_line_placement(
    emission: "torch.Tensor",
    tokens: list[str],
    prior_ms: int,
    *,
    search_ms: int,
    dur_ms: int,
    v0: int,
    v1: int,
    step_ms: int = 80,
    min_start: int = 0,
    max_ahead_ms: int = 10000,
) -> tuple[list[dict[str, Any]], float, int, int]:
    """Place a line by sliding forward from min_start.

    LRCLIB `prior_ms` is only a soft bias (never a hard snap). Forward search
    stops repeated hooks from yanking a later line back to an earlier chorus.
    """
    if not tokens:
        return [], 0.0, prior_ms, prior_ms + 500
    need = _min_window_ms_for_tokens(tokens)
    win = need + 1000
    lo = max(v0, min_start)
    hi = min(v1 if v1 > v0 else dur_ms, lo + max_ahead_ms, dur_ms) - win
    # Softly prefer the prior when it sits ahead of the cursor.
    if prior_ms - search_ms > lo:
        # Allow starting a bit before the prior, but never before min_start.
        lo = max(lo, prior_ms - search_ms)
    if hi <= lo:
        hi = min(dur_ms - win, lo + max(500, search_ms))
        if hi <= lo:
            lo = max(0, min_start)
            hi = max(lo + 1, min(dur_ms - win, lo + win))

    best_hits: list[dict[str, Any]] = []
    best_score = -1e9
    best_g0 = lo
    for g0 in range(int(lo), int(max(lo + 1, hi)) + 1, step_ms):
        f0 = max(0, int(g0 / FRAME_MS))
        f1 = min(emission.shape[0], int((g0 + win) / FRAME_MS))
        if f1 - f0 < 5:
            continue
        hits = ctc_align_emission(emission[f0:f1], tokens, int(f0 * FRAME_MS))
        scored = [h for h in hits if h.get("ctc_ms") is not None]
        if len(scored) < max(1, (len(tokens) + 1) // 2):
            continue
        mean_s = statistics.mean(h["score"] for h in scored)
        first = scored[0]["ctc_ms"] or g0
        # Soft prior pull + mild preference for not racing too far ahead of cursor.
        prior_pen = 0.00005 * abs(first - prior_ms)
        ahead_pen = 0.00002 * max(0, first - min_start - 4000)
        tie = mean_s - prior_pen - ahead_pen
        if tie > best_score:
            best_score = tie
            best_hits = hits
            best_g0 = g0

    if not best_hits:
        g0 = max(v0, min_start, prior_ms)
        f0 = max(0, int(g0 / FRAME_MS))
        f1 = min(emission.shape[0], int((g0 + win) / FRAME_MS))
        best_hits = ctc_align_emission(emission[f0:f1], tokens, int(f0 * FRAME_MS))
        scored = [h for h in best_hits if h.get("ctc_ms") is not None]
        best_score = statistics.mean(h["score"] for h in scored) if scored else 0.0

    scored = [h for h in best_hits if h.get("ctc_ms") is not None]
    if scored:
        seg0 = min(h["ctc_ms"] for h in scored)
        seg1 = max(h["end_ms"] or h["ctc_ms"] for h in scored)
        # Reject placements that still start before the cursor (should be rare).
        if seg0 < min_start - 50:
            seg0 = min_start
    else:
        seg0, seg1 = best_g0, best_g0 + need
    mean_out = statistics.mean(h["score"] for h in scored) if scored else 0.0
    return best_hits, float(mean_out), int(seg0), int(seg1)


def ctc_align_words(
    waveform: "torch.Tensor",
    words: list[dict[str, Any]],
    *,
    group_max_words: int = 12,
    pad_ms: int = 1500,
    prior_shift_ms: int = 0,
    prior_key: str = "start_ms",
) -> list[dict[str, Any]]:
    """Line-grouped CTC against priors (used by measure / validate)."""
    usable = [w for w in words if w.get("mms")]
    if not usable:
        return []
    sr = 16_000
    n = waveform.shape[-1]
    dur_ms = max(1, int(n / sr * 1000))
    groups: list[list[dict[str, Any]]] = []
    cur: list[dict[str, Any]] = []
    for w in usable:
        prior = w.get(prior_key, w.get("start_ms", 0))
        if cur and (
            len(cur) >= group_max_words
            or prior - cur[-1].get(prior_key, cur[-1].get("start_ms", 0)) > 700
        ):
            groups.append(cur)
            cur = []
        cur.append(w)
    if cur:
        groups.append(cur)

    ordered: list[dict[str, Any]] = []
    for group in groups:
        first = group[0].get(prior_key, group[0].get("start_ms", 0)) - prior_shift_ms
        last = group[-1].get(prior_key, group[-1].get("start_ms", 0)) - prior_shift_ms
        g0 = max(0, first - pad_ms)
        span = max(400, last - first)
        g1 = min(dur_ms, last + max(pad_ms, int(span * 0.35) + 500))
        hits = ctc_align_in_window(
            waveform, [w["mms"] for w in group], g0, g1, with_star=True
        )
        for w, h in zip(group, hits):
            if h.get("ctc_ms") is None:
                continue
            ordered.append(
                {
                    "text": w["text"],
                    "lrc_ms": w.get("start_ms", w.get("prior_ms", 0)),
                    "ctc_ms": h["ctc_ms"],
                    "end_ms": h["end_ms"],
                    "score": h["score"],
                    "norm": w.get("norm", normalize_token(w["text"])),
                    "mms": w["mms"],
                }
            )
    return ordered


def summarize_pairs(pairs: list[dict[str, Any]], err_key: str = "err_ms") -> dict[str, Any]:
    if len(pairs) < 5:
        return {"n": len(pairs), "pass": False, "reason": "too_few_pairs"}
    errs = [p[err_key] for p in pairs]
    abs_e = [abs(e) for e in errs]
    xs = [p.get("ctc_ms", p.get("truth_ms", 0)) for p in pairs]
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


def interpolate_low_confidence(
    words: list[dict[str, Any]],
    *,
    min_score: float,
    seg_start: int,
    seg_end: int,
) -> tuple[list[dict[str, Any]], int]:
    """Fill low-score / missing onsets by linear interp between confident neighbours."""
    n = len(words)
    if n == 0:
        return words, 0
    confident = [
        i
        for i, w in enumerate(words)
        if w.get("ctc_ms") is not None
        and w.get("score", 0) >= min_score
        and not (w.get("skippable") and w.get("score", 0) < min_score * 1.5)
    ]
    interpolated = 0
    out = []
    for i, w in enumerate(words):
        use_ctc = (
            w.get("ctc_ms") is not None
            and w.get("score", 0) >= min_score
            and not (w.get("skippable") and w.get("score", 0) < min_score * 1.5)
        )
        if use_ctc:
            out.append({**w, "start_ms": int(w["ctc_ms"]), "source": "ctc"})
            continue
        # Find neighbours
        prev_i = next((j for j in reversed(confident) if j < i), None)
        next_i = next((j for j in confident if j > i), None)
        if prev_i is not None and next_i is not None:
            t0 = words[prev_i]["ctc_ms"]
            t1 = words[next_i]["ctc_ms"]
            frac = (i - prev_i) / (next_i - prev_i)
            ms = int(round(t0 + (t1 - t0) * frac))
        elif prev_i is not None:
            # after last confident: step forward by mean gap or 120ms
            ms = int(words[prev_i]["ctc_ms"]) + 120 * (i - prev_i)
        elif next_i is not None:
            ms = int(words[next_i]["ctc_ms"]) - 120 * (next_i - i)
        else:
            # no confident hits — even spread across segment
            frac = (i + 0.5) / n
            ms = int(round(seg_start + (seg_end - seg_start) * frac))
        ms = max(seg_start, min(seg_end, ms))
        out.append({**w, "start_ms": ms, "source": "interp"})
        interpolated += 1
    # Enforce monotonic within the line
    for i in range(1, len(out)):
        if out[i]["start_ms"] < out[i - 1]["start_ms"]:
            out[i]["start_ms"] = out[i - 1]["start_ms"]
    return out, interpolated


def generate_word_timings(
    waveform: "torch.Tensor",
    lines: list[dict[str, Any]],
    *,
    line_search_ms: int = DEFAULT_LINE_SEARCH_MS,
    min_score: float = DEFAULT_MIN_SCORE,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Segment-constrained CTC: slide-search lines → in-segment words → interpolate."""
    sr = 16_000
    n = waveform.shape[-1]
    dur_ms = max(1, int(n / sr * 1000))
    v0, v1 = vocal_activity_bounds(waveform)
    stats = {
        "vocal_start_ms": v0,
        "vocal_end_ms": v1,
        "n_lines": len(lines),
        "n_words": sum(len(ln["words"]) for ln in lines),
        "n_ctc": 0,
        "n_interp": 0,
        "n_skippable": 0,
        "high_conf": 0,
        "mean_line_score": 0.0,
    }

    emission = compute_emission(waveform, with_star=True)

    # --- Pass 1: LRCLIB line prior ± search, forced forward cursor ---
    line_segs: list[dict[str, Any]] = []
    line_scores: list[float] = []
    cursor = v0
    n_lines_left = sum(1 for ln in lines if any(w.get("mms") for w in ln["words"]))
    for i, ln in enumerate(lines):
        priors = [w for w in ln["words"] if w.get("mms")]
        if not priors:
            continue
        n_lines_left -= 1
        # Budget remaining audio so late lines aren't crushed to zero.
        reserve = max(300, n_lines_left * 450)
        latest_start = max(cursor, dur_ms - reserve - 500)

        prior = max(cursor + 20, ln["prior_ms"])
        # Expected duration from coarse LRCLIB word span (anchor only).
        prior_span = max(
            600,
            priors[-1]["prior_ms"] - priors[0]["prior_ms"] + 500,
        )
        tokens = [w["mms"] for w in priors]
        # Chunk long lines
        chunks: list[list[str]] = []
        cur_tok: list[str] = []
        for t in tokens:
            if len(cur_tok) >= 10:
                chunks.append(cur_tok)
                cur_tok = []
            cur_tok.append(t)
        if cur_tok:
            chunks.append(cur_tok)

        chunk_hits: list[dict[str, Any]] = []
        scores: list[float] = []
        seg_start = None
        seg_end = None
        chunk_cursor = cursor
        for ci, chunk in enumerate(chunks):
            if ci == 0:
                chunk_prior = prior
            elif chunk_hits and chunk_hits[-1].get("end_ms") is not None:
                chunk_prior = int(chunk_hits[-1]["end_ms"])
            elif chunk_hits and chunk_hits[-1].get("ctc_ms") is not None:
                chunk_prior = int(chunk_hits[-1]["ctc_ms"]) + 150
            else:
                chunk_prior = prior + ci * 400
            # Window: ±line_search around prior, clamped to [chunk_cursor, latest]
            need = _min_window_ms_for_tokens(chunk)
            center = max(chunk_cursor, min(latest_start, chunk_prior))
            g0 = max(chunk_cursor, center - line_search_ms)
            g1 = min(dur_ms, max(g0 + need, center + prior_span + line_search_ms))
            # Prefer a scored slide inside that window when it's wide enough
            if g1 - g0 > need + 400:
                hits, score, s0, s1 = search_line_placement(
                    emission,
                    chunk,
                    chunk_prior,
                    search_ms=min(line_search_ms, g1 - g0 - need),
                    dur_ms=dur_ms,
                    v0=g0,
                    v1=g1,
                    step_ms=80,
                    min_start=chunk_cursor,
                    max_ahead_ms=g1 - chunk_cursor,
                )
            else:
                hits = ctc_align_in_window(
                    waveform, chunk, g0, g1, with_star=True, emission=emission
                )
                scored = [h for h in hits if h.get("ctc_ms") is not None]
                score = statistics.mean(h["score"] for h in scored) if scored else 0.0
                if scored:
                    s0 = min(h["ctc_ms"] for h in scored)
                    s1 = max(h["end_ms"] or h["ctc_ms"] for h in scored)
                else:
                    s0, s1 = center, center + need
            chunk_hits.extend(hits)
            scores.append(score)
            seg_start = s0 if seg_start is None else min(seg_start, s0)
            seg_end = s1 if seg_end is None else max(seg_end, s1)
            chunk_cursor = max(chunk_cursor, int(seg_end) if seg_end else chunk_cursor)

        mean_score = statistics.mean(scores) if scores else 0.0
        line_scores.append(mean_score)
        if seg_start is None:
            seg_start = prior
            seg_end = min(dur_ms, prior + prior_span)
        # Keep segments tight — long CTC tails steal audio from later lines.
        max_end = min(
            dur_ms,
            int(seg_start) + min(
                max(prior_span + 800, _min_window_ms_for_tokens(tokens)),
                max(900, len(priors) * 280),
            ),
        )
        seg_end = min(int(seg_end), max_end)
        seg_start = max(cursor, min(int(seg_start), dur_ms - 50))
        seg_end = max(seg_start + 200, seg_end)
        line_segs.append(
            {
                "index": i,
                "words": ln["words"],
                "start_ms": seg_start,
                "end_ms": seg_end,
                "mean_score": mean_score,
                "coarse_hits": chunk_hits,
            }
        )
        cursor = max(cursor, seg_end + 40)

    for i in range(1, len(line_segs)):
        if line_segs[i]["start_ms"] < line_segs[i - 1]["start_ms"] + 80:
            line_segs[i]["start_ms"] = line_segs[i - 1]["start_ms"] + 80
        if line_segs[i]["start_ms"] >= line_segs[i]["end_ms"]:
            line_segs[i]["end_ms"] = min(dur_ms, line_segs[i]["start_ms"] + 500)

    # Enforce non-overlapping segments before word pass.
    for i in range(1, len(line_segs)):
        prev = line_segs[i - 1]
        cur = line_segs[i]
        if cur["start_ms"] < prev["end_ms"]:
            cur["start_ms"] = prev["end_ms"]
        if cur["end_ms"] <= cur["start_ms"] + 150:
            cur["end_ms"] = min(dur_ms, cur["start_ms"] + max(400, len(cur["words"]) * 120))

    # --- Pass 2: word CTC strictly inside each line segment ---
    generated_lines: list[dict[str, Any]] = []
    for seg in line_segs:
        words = seg["words"]
        usable = [w for w in words if w.get("mms")]
        pad = 200
        g0 = max(0, seg["start_ms"] - pad)
        g1 = min(dur_ms, seg["end_ms"] + pad)
        hits = []
        # Align whole line when it fits; otherwise chunk sequentially inside the segment.
        if usable:
            if len(usable) <= 10:
                hits = ctc_align_in_window(
                    waveform,
                    [w["mms"] for w in usable],
                    g0,
                    g1,
                    with_star=True,
                    emission=emission,
                )
            else:
                cursor2 = g0
                for i0 in range(0, len(usable), 8):
                    chunk = usable[i0 : i0 + 8]
                    need = _min_window_ms_for_tokens([w["mms"] for w in chunk])
                    cg1 = min(g1, max(cursor2 + need, g1))
                    part = ctc_align_in_window(
                        waveform,
                        [w["mms"] for w in chunk],
                        cursor2,
                        cg1,
                        with_star=True,
                        emission=emission,
                    )
                    hits.extend(part)
                    if part and part[-1].get("end_ms") is not None:
                        cursor2 = max(cursor2, int(part[-1]["end_ms"]))

        hit_i = 0
        merged = []
        for w in words:
            if not w.get("mms"):
                merged.append({**w, "ctc_ms": None, "end_ms": None, "score": 0.0})
                continue
            h = hits[hit_i] if hit_i < len(hits) else {"ctc_ms": None, "end_ms": None, "score": 0.0}
            hit_i += 1
            merged.append({**w, **h})
            if w.get("skippable"):
                stats["n_skippable"] += 1
            if h.get("ctc_ms") is not None and h.get("score", 0) >= min_score:
                stats["high_conf"] += 1
                stats["n_ctc"] += 1

        filled, n_interp = interpolate_low_confidence(
            merged,
            min_score=min_score,
            seg_start=seg["start_ms"],
            seg_end=seg["end_ms"],
        )
        stats["n_interp"] += n_interp
        generated_lines.append(
            {
                "start_ms": filled[0]["start_ms"] if filled else seg["start_ms"],
                "words": filled,
            }
        )

    stats["coverage"] = (
        round(stats["high_conf"] / stats["n_words"], 4) if stats["n_words"] else 0.0
    )
    stats["mean_line_score"] = round(statistics.mean(line_scores), 4) if line_scores else 0.0
    return generated_lines, stats


def rewrite_lrc_generated(
    raw: str,
    generated_lines: list[dict[str, Any]],
    *,
    aligned_version: str,
) -> str:
    """Rewrite Enhanced LRC using generated word starts (drop old word stamps)."""
    lines_out: list[str] = [f"[drome-aligned:{aligned_version}]"]
    # Preserve non-timing tags
    for line in raw.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if OFFSET_RE.match(stripped) or ALIGNED_RE.match(stripped):
            continue
        if BRACKET_RE.search(line) or ANGLE_RE.search(line):
            continue
        if stripped.startswith("[") and stripped.endswith("]") and ":" in stripped:
            # [ti:] / [ar:] etc.
            lines_out.append(stripped)

    for gl in generated_lines:
        words = gl["words"]
        if not words:
            continue
        bits = " ".join(
            f"<{format_stamp(w['start_ms'])}>{w['text']}" for w in words
        )
        lines_out.append(f"[{format_stamp(gl['start_ms'])}] {bits}")
    return "\n".join(lines_out) + "\n"


def deps_available() -> dict[str, Any]:
    out: dict[str, Any] = {"ok": True, "missing": []}
    try:
        import torch  # noqa: F401
    except Exception:
        out["ok"] = False
        out["missing"].append("torch")
    try:
        import torchaudio  # noqa: F401
    except Exception:
        out["ok"] = False
        out["missing"].append("torchaudio")
    try:
        import demucs  # noqa: F401
    except Exception:
        out["ok"] = False
        out["missing"].append("demucs")
    if shutil.which("ffmpeg") is None:
        out["ok"] = False
        out["missing"].append("ffmpeg")
    return out


def _emit(payload: dict[str, Any], json_path: str | None) -> None:
    text = json.dumps(payload, indent=2)
    if json_path:
        Path(json_path).write_text(text + "\n", encoding="utf-8")
    print(text)


# ----- commands -----


def cmd_check_deps(args: argparse.Namespace) -> int:
    info = deps_available()
    _emit(info, args.json)
    return 0 if info["ok"] else 1


def cmd_synth_fixture(args: argparse.Namespace) -> int:
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    cues = [
        (820, "one"),
        (1510, "two"),
        (2235, "three"),
        (3100, "four"),
        (4055, "five"),
        (5200, "six"),
    ]
    sr = 16_000
    duration_s = 8.0
    samples = [0.0] * int(sr * duration_s)
    with tempfile.TemporaryDirectory() as td:
        td_path = Path(td)
        for ms, word in cues:
            wav_path = td_path / f"{word}.wav"
            subprocess.run(
                ["espeak", "-w", str(wav_path), "-s", "140", word],
                check=True,
                capture_output=True,
            )
            with wave.open(str(wav_path), "rb") as w:
                fr = w.getframerate()
                import array

                arr = array.array("h")
                arr.frombytes(w.readframes(w.getnframes()))
                if fr != sr:
                    ratio = sr / fr
                    new_len = int(len(arr) * ratio)
                    vals = []
                    for i in range(new_len):
                        src = i / ratio
                        j = int(src)
                        f = src - j
                        a = arr[j] if j < len(arr) else 0
                        b = arr[j + 1] if j + 1 < len(arr) else 0
                        vals.append(a * (1 - f) + b * f)
                else:
                    vals = list(arr)
            start = int(sr * ms / 1000)
            for i, v in enumerate(vals):
                idx = start + i
                if idx >= len(samples):
                    break
                samples[idx] += (v / 32768.0) * 0.9

    wav_path = out / "speech.wav"
    with wave.open(str(wav_path), "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        frames = b"".join(
            int(max(-1, min(1, s)) * 32767).to_bytes(2, "little", signed=True)
            for s in samples
        )
        w.writeframes(frames)

    bits = " ".join(f"<{format_stamp(ms)}>{text}" for ms, text in cues)
    lrc = "\n".join(
        [
            "[ti:speech-fixture]",
            f"[{format_stamp(cues[0][0])}] {bits}",
            f"[{format_stamp(7000)}] end",
            "",
        ]
    )
    (out / "speech.lrc").write_text(lrc, encoding="utf-8")
    truth = {"words": [{"text": t, "start_ms": ms} for ms, t in cues]}
    (out / "speech.truth.json").write_text(json.dumps(truth, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"wav": str(wav_path), "lrc": str(out / "speech.lrc"), "words": len(cues)}))
    return 0


def cmd_check_truth(args: argparse.Namespace) -> int:
    words, _, _ = parse_lrc_words(Path(args.lrc).read_text(encoding="utf-8", errors="replace"))
    truth = json.loads(Path(args.truth).read_text(encoding="utf-8"))
    tw = truth["words"]
    pairs = []
    for w, t in zip(words, tw):
        pairs.append(
            {
                "text": w["text"],
                "lrc_ms": w["start_ms"],
                "truth_ms": t["start_ms"],
                "err_ms": w["start_ms"] - t["start_ms"],
            }
        )
    stats = summarize_pairs(pairs) if len(pairs) >= 5 else {
        "n": len(pairs),
        "pass": all(p["err_ms"] == 0 for p in pairs) and len(pairs) > 0,
        "median_abs_ms": statistics.median([abs(p["err_ms"]) for p in pairs]) if pairs else None,
        "p90_abs_ms": sorted(abs(p["err_ms"]) for p in pairs)[-1] if pairs else None,
    }
    # Tiny fixtures (<5 words): exact match pass
    if len(pairs) < 5:
        stats["pass"] = all(p["err_ms"] == 0 for p in pairs) and len(pairs) > 0
    _emit({"stats": stats, "sample": pairs}, args.json)
    return 0 if stats.get("pass") else 1


def cmd_validate_aligner(args: argparse.Namespace) -> int:
    truth = json.loads(Path(args.truth).read_text(encoding="utf-8"))
    waveform = load_wav_mono16k(Path(args.audio))
    words = [
        {
            "text": w["text"],
            "start_ms": w["start_ms"],
            "norm": normalize_token(w["text"]),
            "mms": mms_word(w["text"]),
        }
        for w in truth["words"]
    ]
    aligned = ctc_align_words(waveform, words, pad_ms=800)
    pairs = []
    for a in aligned:
        truth_ms = next(w["start_ms"] for w in words if w["mms"] == a["mms"])
        pairs.append(
            {
                "text": a["text"],
                "truth_ms": truth_ms,
                "ctc_ms": a["ctc_ms"],
                "err_ms": truth_ms - a["ctc_ms"],
                "score": a["score"],
            }
        )
    # summarize_pairs uses err vs ctc; rename for truth comparison
    for p in pairs:
        p["ctc_ms_ref"] = p["ctc_ms"]
    stats = summarize_pairs(pairs) if len(pairs) >= 5 else {"n": len(pairs), "pass": False}
    # Soft pass for known ~1-frame CTC lag on TTS
    soft = dict(stats)
    if pairs:
        bias = statistics.median(p["err_ms"] for p in pairs)
        deb = [{**p, "err_ms": p["err_ms"] - bias} for p in pairs]
        soft["constant_bias_ms"] = bias
        soft["after_bias_median_abs_ms"] = summarize_pairs(deb)["median_abs_ms"]
        soft["after_bias_p90_abs_ms"] = summarize_pairs(deb)["p90_abs_ms"]
    _emit({"stats": stats, "soft": soft, "sample": pairs}, args.json)
    return 0 if stats.get("pass") else 1


def cmd_measure(args: argparse.Namespace) -> int:
    raw = Path(args.lrc).read_text(encoding="utf-8", errors="replace")
    words, _, ver = parse_lrc_words(raw)
    work = Path(args.work_dir) if args.work_dir else Path(tempfile.mkdtemp(prefix="lyrics-measure-"))
    work.mkdir(parents=True, exist_ok=True)
    vocals = prepare_vocals(
        Path(args.audio), work, use_demucs=not args.no_demucs, demucs_model=args.demucs_model
    )
    waveform = load_wav_mono16k(vocals)
    aligned = ctc_align_words(waveform, words, pad_ms=1500)
    pairs = [
        {
            "text": a["text"],
            "lrc_ms": a["lrc_ms"],
            "ctc_ms": a["ctc_ms"],
            "err_ms": a["lrc_ms"] - a["ctc_ms"],
            "score": a["score"],
        }
        for a in aligned
    ]
    hi = [p for p in pairs if p["score"] >= args.min_score]
    stats = summarize_pairs(hi if len(hi) >= 5 else pairs)
    payload = {
        "mode": "measure",
        "aligned_version_in_file": ver,
        "n": len(pairs),
        "n_high_conf": len(hi),
        "coverage": round(len(hi) / len(pairs), 4) if pairs else 0,
        "stats": stats,
        "sample": (hi or pairs)[:12],
    }
    _emit(payload, args.json)
    return 0 if stats.get("pass") else 1


def cmd_generate_words(args: argparse.Namespace) -> int:
    """Generate word stamps from text + coarse line anchors (no LRCLIB snap)."""
    deps = deps_available()
    if not deps["ok"] and not args.no_demucs:
        # Allow --no-demucs if only demucs missing but torch present
        missing = set(deps["missing"])
        if missing - {"demucs"}:
            payload = {
                "mode": "generate_words",
                "skipped": True,
                "reason": f"missing deps: {deps['missing']}",
                "fallback": "keep_lrclib",
            }
            _emit(payload, args.json)
            return 0
        # demucs missing → fall back to mix unless forced
        if "demucs" in missing and not args.allow_no_demucs:
            payload = {
                "mode": "generate_words",
                "skipped": True,
                "reason": "demucs not installed",
                "fallback": "keep_lrclib",
            }
            _emit(payload, args.json)
            return 0

    lrc_path = Path(args.lrc)
    raw = lrc_path.read_text(encoding="utf-8", errors="replace")
    lines, embedded, ver = parse_lrc_lines(raw)
    if ver == args.aligned_version and not args.force:
        payload = {
            "mode": "generate_words",
            "skipped": True,
            "reason": f"already aligned ({ver})",
            "lyrics": str(lrc_path),
        }
        _emit(payload, args.json)
        return 0
    if not lines:
        payload = {
            "mode": "generate_words",
            "skipped": True,
            "reason": "no word-synced lines",
            "fallback": "keep_lrclib",
        }
        _emit(payload, args.json)
        return 0

    work = Path(args.work_dir) if args.work_dir else Path(tempfile.mkdtemp(prefix="lyrics-gen-"))
    work.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    use_demucs = not args.no_demucs
    try:
        vocals = prepare_vocals(
            Path(args.audio), work, use_demucs=use_demucs, demucs_model=args.demucs_model
        )
    except Exception as exc:
        payload = {
            "mode": "generate_words",
            "skipped": True,
            "reason": f"demucs/prepare failed: {exc}",
            "fallback": "keep_lrclib",
        }
        _emit(payload, args.json)
        return 0
    sep_s = time.time() - t0
    waveform = load_wav_mono16k(vocals)
    t1 = time.time()
    generated, gen_stats = generate_word_timings(
        waveform,
        lines,
        line_search_ms=args.line_search_ms,
        min_score=args.min_score,
    )
    align_s = time.time() - t1

    # Self-check: re-CTC against generated stamps (tight pad) — should be near fixture error
    flat = []
    for gl in generated:
        for w in gl["words"]:
            if w.get("mms"):
                flat.append(
                    {
                        "text": w["text"],
                        "start_ms": w["start_ms"],
                        "norm": w.get("norm", normalize_token(w["text"])),
                        "mms": w["mms"],
                    }
                )
    aligned = ctc_align_words(waveform, flat, pad_ms=400)
    pairs = [
        {
            "text": a["text"],
            "lrc_ms": a["lrc_ms"],
            "ctc_ms": a["ctc_ms"],
            "err_ms": a["lrc_ms"] - a["ctc_ms"],
            "score": a["score"],
        }
        for a in aligned
    ]
    hi = [p for p in pairs if p["score"] >= args.min_score]
    after = summarize_pairs(hi if len(hi) >= 5 else pairs) if pairs else {"n": 0, "pass": False}

    # Before: original LRCLIB word stamps vs CTC (same vocals)
    before_words, _, _ = parse_lrc_words(raw)
    before_aligned = ctc_align_words(waveform, before_words, pad_ms=1500)
    before_pairs = [
        {
            "text": a["text"],
            "lrc_ms": a["lrc_ms"],
            "ctc_ms": a["ctc_ms"],
            "err_ms": a["lrc_ms"] - a["ctc_ms"],
            "score": a["score"],
        }
        for a in before_aligned
    ]
    before_hi = [p for p in before_pairs if p["score"] >= args.min_score]
    before = (
        summarize_pairs(before_hi if len(before_hi) >= 5 else before_pairs)
        if before_pairs
        else {"n": 0, "pass": False}
    )

    wrote = False
    if args.write and generated:
        new_raw = rewrite_lrc_generated(raw, generated, aligned_version=args.aligned_version)
        lrc_path.write_text(new_raw, encoding="utf-8")
        wrote = True

    peak_rss_mb = None
    try:
        # Linux VmHWM in kB
        with open("/proc/self/status") as f:
            for line in f:
                if line.startswith("VmHWM:"):
                    peak_rss_mb = round(int(line.split()[1]) / 1024, 1)
                    break
    except OSError:
        pass

    audio_dur_s = waveform.shape[-1] / 16_000
    payload = {
        "mode": "generate_words",
        "audio": str(args.audio),
        "lyrics": str(lrc_path),
        "aligned_version": args.aligned_version,
        "line_search_ms": args.line_search_ms,
        "min_score": args.min_score,
        "demucs": use_demucs,
        "seconds_separate": round(sep_s, 2),
        "seconds_align": round(align_s, 2),
        "seconds_total": round(time.time() - t0, 2),
        "audio_duration_s": round(audio_dur_s, 2),
        "realtime_factor": round((time.time() - t0) / audio_dur_s, 3) if audio_dur_s > 0 else None,
        "peak_rss_mb": peak_rss_mb,
        "gen": gen_stats,
        "coverage": gen_stats.get("coverage"),
        "before": before,
        "after": after,
        "n_snapped": 0,  # compatibility for Go logger
        "n_kept": 0,
        "n_generated": sum(len(g["words"]) for g in generated),
        "n_interp": gen_stats.get("n_interp", 0),
        "wrote": wrote,
        "skipped": False,
    }
    _emit(payload, args.json)
    return 0 if after.get("pass") else 1


def cmd_benchmark(args: argparse.Namespace) -> int:
    """Time Demucs + generate on one file; report cost per minute of audio."""
    audio = Path(args.audio)
    work = Path(args.work_dir) if args.work_dir else Path(tempfile.mkdtemp(prefix="lyrics-bench-"))
    work.mkdir(parents=True, exist_ok=True)
    # Probe duration
    dur = float(
        subprocess.check_output(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "csv=p=0",
                str(audio),
            ],
            text=True,
        ).strip()
    )
    t0 = time.time()
    vocals = prepare_vocals(audio, work, use_demucs=not args.no_demucs, demucs_model=args.demucs_model)
    sep_s = time.time() - t0
    waveform = load_wav_mono16k(vocals)
    # Minimal one-line align cost sample
    raw = Path(args.lrc).read_text(encoding="utf-8", errors="replace") if args.lrc else ""
    lines, _, _ = parse_lrc_lines(raw) if raw else ([], 0, None)
    t1 = time.time()
    if lines:
        generate_word_timings(waveform, lines, line_search_ms=args.line_search_ms)
    align_s = time.time() - t1
    total = time.time() - t0
    peak_rss_mb = None
    try:
        with open("/proc/self/status") as f:
            for line in f:
                if line.startswith("VmHWM:"):
                    peak_rss_mb = round(int(line.split()[1]) / 1024, 1)
                    break
    except OSError:
        pass
    per_min = (total / dur) * 60 if dur > 0 else None
    payload = {
        "mode": "benchmark",
        "audio_duration_s": round(dur, 2),
        "seconds_demucs": round(sep_s, 2),
        "seconds_align": round(align_s, 2),
        "seconds_total": round(total, 2),
        "seconds_per_audio_minute": round(per_min, 2) if per_min is not None else None,
        "realtime_factor": round(total / dur, 3) if dur > 0 else None,
        "peak_rss_mb": peak_rss_mb,
        "demucs": not args.no_demucs,
    }
    _emit(payload, args.json)
    return 0


def cmd_separate(args: argparse.Namespace) -> int:
    out = demucs_vocals(Path(args.audio), Path(args.out_dir), model=args.demucs_model)
    print(json.dumps({"vocals": str(out)}))
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    d = sub.add_parser("check-deps", help="Verify torch/torchaudio/demucs/ffmpeg")
    d.add_argument("--json")
    d.set_defaults(func=cmd_check_deps)

    s = sub.add_parser("synth-fixture", help="TTS words at known onsets")
    s.add_argument("--out-dir", required=True)
    s.add_argument("--also-beep", action="store_true")
    s.set_defaults(func=cmd_synth_fixture)

    c = sub.add_parser("check-truth", help="Compare LRC to truth JSON")
    c.add_argument("--lrc", required=True)
    c.add_argument("--truth", required=True)
    c.add_argument("--json")
    c.set_defaults(func=cmd_check_truth)

    v = sub.add_parser("validate-aligner", help="CTC error on speech fixture")
    v.add_argument("--audio", required=True)
    v.add_argument("--truth", required=True)
    v.add_argument("--json")
    v.set_defaults(func=cmd_validate_aligner)

    m = sub.add_parser("measure", help="LRC vs CTC on Demucs vocals")
    m.add_argument("--audio", required=True)
    m.add_argument("--lrc", required=True)
    m.add_argument("--work-dir")
    m.add_argument("--no-demucs", action="store_true")
    m.add_argument("--demucs-model", default="htdemucs")
    m.add_argument("--min-score", type=float, default=DEFAULT_MIN_SCORE)
    m.add_argument("--preview-anchor", action="store_true")
    m.add_argument("--json")
    m.set_defaults(func=cmd_measure)

    g = sub.add_parser(
        "generate-words",
        help="Generate word stamps via segment-constrained CTC (no LRCLIB snap)",
    )
    g.add_argument("--audio", required=True)
    g.add_argument("--lrc", required=True)
    g.add_argument("--work-dir")
    g.add_argument("--no-demucs", action="store_true")
    g.add_argument("--allow-no-demucs", action="store_true", help="Use mix if demucs missing")
    g.add_argument("--demucs-model", default="htdemucs")
    g.add_argument("--line-search-ms", type=int, default=DEFAULT_LINE_SEARCH_MS)
    g.add_argument("--min-score", type=float, default=DEFAULT_MIN_SCORE)
    g.add_argument("--aligned-version", default=ALIGNED_VERSION)
    g.add_argument("--force", action="store_true")
    g.add_argument("--write", action="store_true")
    g.add_argument("--json")
    g.set_defaults(func=cmd_generate_words)

    # Alias: old companion / docs called refine-words (snap). Now generates.
    r = sub.add_parser("refine-words", help="Alias for generate-words")
    r.add_argument("--audio", required=True)
    r.add_argument("--lrc", required=True)
    r.add_argument("--work-dir")
    r.add_argument("--no-demucs", action="store_true")
    r.add_argument("--allow-no-demucs", action="store_true")
    r.add_argument("--demucs-model", default="htdemucs")
    r.add_argument("--line-search-ms", type=int, default=DEFAULT_LINE_SEARCH_MS)
    r.add_argument("--window-ms", type=int, default=DEFAULT_LINE_SEARCH_MS, help="Ignored; use --line-search-ms")
    r.add_argument("--min-score", type=float, default=DEFAULT_MIN_SCORE)
    r.add_argument("--aligned-version", default=ALIGNED_VERSION)
    r.add_argument("--force", action="store_true")
    r.add_argument("--write", action="store_true")
    r.add_argument("--json")
    r.set_defaults(func=cmd_generate_words)

    b = sub.add_parser("benchmark", help="Demucs + align cost per audio minute")
    b.add_argument("--audio", required=True)
    b.add_argument("--lrc")
    b.add_argument("--work-dir")
    b.add_argument("--no-demucs", action="store_true")
    b.add_argument("--demucs-model", default="htdemucs")
    b.add_argument("--line-search-ms", type=int, default=DEFAULT_LINE_SEARCH_MS)
    b.add_argument("--json")
    b.set_defaults(func=cmd_benchmark)

    sep = sub.add_parser("separate", help="Demucs vocals only")
    sep.add_argument("--audio", required=True)
    sep.add_argument("--out-dir", required=True)
    sep.add_argument("--demucs-model", default="htdemucs")
    sep.set_defaults(func=cmd_separate)

    args = p.parse_args()
    # Map legacy window-ms onto line-search when generate alias used
    if getattr(args, "window_ms", None) and not hasattr(args, "line_search_ms"):
        args.line_search_ms = args.window_ms
    elif getattr(args, "window_ms", None) and args.cmd == "refine-words":
        # Prefer explicit line_search; window-ms from Go becomes line search floor
        if getattr(args, "line_search_ms", DEFAULT_LINE_SEARCH_MS) == DEFAULT_LINE_SEARCH_MS:
            args.line_search_ms = max(args.window_ms, DEFAULT_LINE_SEARCH_MS)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
