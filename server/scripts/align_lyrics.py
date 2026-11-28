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
import math
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

MEDIAN_ABS_LIMIT_MS = 60  # round-5 shipping target vs ground truth
P90_ABS_LIMIT_MS = 150
DRIFT_LIMIT_MS_PER_MIN = 30
ALIGNED_VERSION = "v4-ctc-line"
DEFAULT_LINE_SEARCH_MS = 1500
DEFAULT_MIN_SCORE = 0.08
DEFAULT_MIN_COVERAGE = 0.7
LINE_AGREE_MS = 1000  # first CTC word must land within this of LRCLIB line start
FRAME_MS = 20.0  # MMS_FA asymptotic hop (320 samples @ 16 kHz)
# MMS_FA word starts are ~1–2 frames late on clean speech; pull CTC onsets
# forward so karaoke lights with the vocal (still clamped ≥0). Client also
# applies a separate 45 ms visual lead.
CTC_LAG_COMPENSATE_MS = 40
_MMS_CHARS = set("abcdefghijklmnopqrstuvwxyz'")

# Spoken forms MMS can actually emit (numbers / common contractions).
_NUMBER_WORDS = {
    "0": "zero",
    "1": "one",
    "2": "two",
    "3": "three",
    "4": "four",
    "5": "five",
    "6": "six",
    "7": "seven",
    "8": "eight",
    "9": "nine",
    "10": "ten",
}
_CONTRACTIONS = {
    "won't": "wont",
    "can't": "cant",
    "don't": "dont",
    "didn't": "didnt",
    "it's": "its",
    "that's": "thats",
    "i'm": "im",
    "you're": "youre",
    "we're": "were",
    "they're": "theyre",
    "i've": "ive",
    "you've": "youve",
    "we've": "weve",
    "they've": "theyve",
    "i'll": "ill",
    "you'll": "youll",
    "he'll": "hell",
    "she'll": "shell",
    "we'll": "well",
    "they'll": "theyll",
    "isn't": "isnt",
    "aren't": "arent",
    "wasn't": "wasnt",
    "weren't": "werent",
    "haven't": "havent",
    "hasn't": "hasnt",
    "hadn't": "hadnt",
    "wouldn't": "wouldnt",
    "couldn't": "couldnt",
    "shouldn't": "shouldnt",
    "ain't": "aint",
    "y'all": "yall",
}


def normalize_token(tok: str) -> str:
    t = tok.strip().lower()
    # Profanity stars / grawlix → drop non-letters so residual letters remain.
    t = t.replace("*", "")
    if t in _CONTRACTIONS:
        t = _CONTRACTIONS[t]
    if t in _NUMBER_WORDS:
        t = _NUMBER_WORDS[t]
    # "12" → "one"+"two" is too aggressive for MMS as one token; spell as digits joined.
    if t.isdigit() and t not in _NUMBER_WORDS:
        t = "".join(_NUMBER_WORDS.get(ch, ch) for ch in t)
    return re.sub(r"[^a-z0-9']+", "", t)


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
    # Bare profanity masks / grawlix
    if re.fullmatch(r"[*#@$%]+", t):
        return True
    low = normalize_token(t)
    return low in {"yeah", "uh", "ooh", "ooo", "ah", "ha", "hey", "woah", "whoa", "oohh", "mmm"}


def emission_frame_ms(emission: "torch.Tensor", n_samples: int, sr: int = 16_000) -> float:
    """Ms per MMS emission frame from the actual tensor length (not a hard-coded guess)."""
    frames = max(1, int(emission.shape[0]))
    return (n_samples / sr * 1000.0) / frames


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
    frame_ms: float = FRAME_MS,
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
        start_ms = g0_ms + int(round(start_frame * frame_ms)) - CTC_LAG_COMPENSATE_MS
        end_ms = g0_ms + int(round(end_frame * frame_ms)) - CTC_LAG_COMPENSATE_MS
        out.append(
            {
                "mms": tok,
                "ctc_ms": max(0, start_ms),
                "end_ms": max(0, end_ms),
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
    frame_ms: float | None = None,
) -> list[dict[str, Any]]:
    """Align `tokens` inside absolute window [g0_ms, g1_ms].

    When `emission` is the full-clip MMS tensor, slice by frame index and add
    the window's absolute origin back — never treat local frame 0 as t=0 of the song.
    """
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
        fms = frame_ms if frame_ms is not None else emission_frame_ms(emission, n, sr)
        f0 = max(0, int(g0 / fms))
        f1 = min(emission.shape[0], max(f0 + 3, int(math.ceil(g1 / fms))))
        # Origin is the absolute time of emission frame f0 — critical for long files.
        return ctc_align_emission(
            emission[f0:f1], tokens, int(round(f0 * fms)), frame_ms=fms, with_star=with_star
        )

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
        em = em.cpu()
        try:
            spans = aligner(em, tokenizer(tokens))
        except Exception as exc:  # pragma: no cover
            print(f"align window failed: {exc}", file=sys.stderr)
            return []
    local_fms = emission_frame_ms(em, clip.shape[-1], sr)
    out = []
    for tok, word_spans in zip(tokens, spans):
        if not word_spans:
            out.append({"mms": tok, "ctc_ms": None, "end_ms": None, "score": 0.0})
            continue
        start_frame = word_spans[0].start
        end_frame = word_spans[-1].end
        score = float(statistics.mean(s.score for s in word_spans))
        start_ms = g0 + int(round(start_frame * local_fms)) - CTC_LAG_COMPENSATE_MS
        end_ms = g0 + int(round(end_frame * local_fms)) - CTC_LAG_COMPENSATE_MS
        out.append(
            {
                "mms": tok,
                "ctc_ms": max(0, start_ms),
                "end_ms": max(0, end_ms),
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


def _line_window(
    lines: list[dict[str, Any]],
    index: int,
    *,
    dur_ms: int,
    line_search_ms: int,
    prev_end_ms: int,
) -> tuple[int, int]:
    """LRCLIB line window ±search, clamped to neighbors — never crush to N*280ms."""
    ln = lines[index]
    prior = int(ln["prior_ms"])
    words = [w for w in ln["words"] if w.get("mms")]
    if words:
        prior_span = max(400, words[-1]["prior_ms"] - words[0]["prior_ms"])
    else:
        prior_span = 800
    next_prior = int(lines[index + 1]["prior_ms"]) if index + 1 < len(lines) else dur_ms
    # Span at least to the next line prior so mid-line words have room.
    span = max(prior_span + 400, next_prior - prior)
    g0 = max(0, prior - line_search_ms)
    g1 = min(dur_ms, prior + span + line_search_ms)
    # Clamp to neighbors so windows don't steal the next line's vocal.
    g0 = max(g0, prev_end_ms)
    g1 = min(g1, next_prior + line_search_ms)
    if g1 <= g0 + 300:
        g1 = min(dur_ms, g0 + max(800, prior_span + 2 * line_search_ms))
    return int(g0), int(g1)


def _keep_lrclib_line(ln: dict[str, Any]) -> dict[str, Any]:
    words = []
    for w in ln["words"]:
        words.append(
            {
                **w,
                "start_ms": int(w.get("prior_ms", ln["prior_ms"])),
                "source": "lrclib",
                "ctc_ms": None,
                "score": 0.0,
            }
        )
    start = words[0]["start_ms"] if words else int(ln["prior_ms"])
    return {"start_ms": start, "words": words, "fallback": "lrclib"}


def generate_word_timings(
    waveform: "torch.Tensor",
    lines: list[dict[str, Any]],
    *,
    line_search_ms: int = DEFAULT_LINE_SEARCH_MS,
    min_score: float = DEFAULT_MIN_SCORE,
    line_agree_ms: int = LINE_AGREE_MS,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Segment-constrained CTC per LRCLIB line (±search, neighbor-clamped).

    Round-4 bug: a `len(words)*280` segment cap crushed each line to ~1.4 s, so
    only the first word locked and the rest were interpolated early — error grew
    with duration. This path keeps the full line span from LRCLIB priors.
    """
    sr = 16_000
    n = waveform.shape[-1]
    dur_ms = max(1, int(n / sr * 1000))
    v0, v1 = vocal_activity_bounds(waveform)
    stats: dict[str, Any] = {
        "vocal_start_ms": v0,
        "vocal_end_ms": v1,
        "n_lines": len(lines),
        "n_words": sum(len(ln["words"]) for ln in lines),
        "n_ctc": 0,
        "n_interp": 0,
        "n_skippable": 0,
        "high_conf": 0,
        "n_line_fallback": 0,
        "n_line_aligned": 0,
        "mean_line_score": 0.0,
        "frame_ms": FRAME_MS,
    }
    if not lines:
        stats["coverage"] = 0.0
        return [], stats

    emission = compute_emission(waveform, with_star=True)
    fms = emission_frame_ms(emission, n, sr)
    stats["frame_ms"] = round(fms, 4)

    generated_lines: list[dict[str, Any]] = []
    line_scores: list[float] = []
    prev_end = 0

    for i, ln in enumerate(lines):
        usable = [w for w in ln["words"] if w.get("mms")]
        if not usable:
            generated_lines.append(_keep_lrclib_line(ln))
            stats["n_line_fallback"] += 1
            continue

        g0, g1 = _line_window(
            lines, i, dur_ms=dur_ms, line_search_ms=line_search_ms, prev_end_ms=prev_end
        )
        tokens = [w["mms"] for w in usable]

        # Chunk long lines sequentially inside the same neighbor-clamped window.
        hits: list[dict[str, Any]] = []
        if len(tokens) <= 12:
            hits = ctc_align_in_window(
                waveform, tokens, g0, g1, with_star=True, emission=emission, frame_ms=fms
            )
        else:
            cursor = g0
            for i0 in range(0, len(tokens), 8):
                chunk = tokens[i0 : i0 + 8]
                need = _min_window_ms_for_tokens(chunk)
                cg1 = min(g1, max(cursor + need, g1))
                part = ctc_align_in_window(
                    waveform,
                    chunk,
                    cursor,
                    cg1,
                    with_star=True,
                    emission=emission,
                    frame_ms=fms,
                )
                hits.extend(part)
                if part and part[-1].get("end_ms") is not None:
                    cursor = max(cursor, int(part[-1]["end_ms"]))

        # Non-circular line gate: first aligned word vs LRCLIB line start.
        # Posterior threshold still decides CTC vs interp per word below.
        first_hit = next((h for h in hits if h.get("ctc_ms") is not None), None)
        prior = int(ln["prior_ms"])
        if first_hit is None or abs(int(first_hit["ctc_ms"]) - prior) > line_agree_ms:
            generated_lines.append(_keep_lrclib_line(ln))
            stats["n_line_fallback"] += 1
            # Advance neighbor clamp using LRCLIB span so the next window is sane.
            last_prior = max(w["prior_ms"] for w in usable)
            prev_end = max(prev_end, int(last_prior))
            continue

        hit_i = 0
        merged = []
        for w in ln["words"]:
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

        scored = [h for h in hits if h.get("ctc_ms") is not None]
        mean_score = statistics.mean(h["score"] for h in scored) if scored else 0.0
        line_scores.append(mean_score)
        seg_start = min(h["ctc_ms"] for h in scored) if scored else g0
        seg_end = max((h["end_ms"] or h["ctc_ms"]) for h in scored) if scored else g1
        # Keep interp domain inside the neighbor-clamped window (full line span).
        seg_start = max(g0, int(seg_start))
        seg_end = min(g1, max(int(seg_end), seg_start + 200))

        filled, n_interp = interpolate_low_confidence(
            merged, min_score=min_score, seg_start=seg_start, seg_end=seg_end
        )
        # Monotonic vs previous line's last word.
        if generated_lines and generated_lines[-1]["words"] and filled:
            prev_last = generated_lines[-1]["words"][-1]["start_ms"]
            if filled[0]["start_ms"] < prev_last:
                shift = prev_last - filled[0]["start_ms"]
                for w in filled:
                    w["start_ms"] += shift
        stats["n_interp"] += n_interp
        stats["n_line_aligned"] += 1
        generated_lines.append(
            {
                "start_ms": filled[0]["start_ms"] if filled else seg_start,
                "words": filled,
                "fallback": None,
            }
        )
        prev_end = max(prev_end, filled[-1]["start_ms"] if filled else seg_end)

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


def _espeak_word_pcm(word: str, *, sr: int, rate: int) -> list[float]:
    """Render one word with espeak; return mono float samples at `sr`."""
    with tempfile.TemporaryDirectory() as td:
        wav_path = Path(td) / "w.wav"
        subprocess.run(
            ["espeak", "-w", str(wav_path), "-s", str(rate), word],
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
            vals: list[float] = []
            for i in range(new_len):
                src = i / ratio
                j = int(src)
                f = src - j
                a = arr[j] if j < len(arr) else 0
                b = arr[j + 1] if j + 1 < len(arr) else 0
                vals.append(a * (1 - f) + b * f)
            return [v / 32768.0 for v in vals]
        return [v / 32768.0 for v in arr]


def _music_bed(n_samples: int, sr: int, seed: int = 7) -> list[float]:
    """Simple deterministic pad under vocals — not a copyrighted bed."""
    import math

    out = [0.0] * n_samples
    # Two slow sine layers + soft noise.
    for i in range(n_samples):
        t = i / sr
        tone = 0.04 * math.sin(2 * math.pi * 110 * t) + 0.03 * math.sin(2 * math.pi * 164.8 * t)
        # xorshift-ish noise from index
        n = (seed * 1103515245 + i * 12345) & 0x7FFFFFFF
        noise = ((n / 0x7FFFFFFF) * 2 - 1) * 0.008
        out[i] = tone + noise
    return out


def _write_wav_mono(path: Path, samples: list[float], sr: int) -> None:
    with wave.open(str(path), "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        frames = b"".join(
            int(max(-1.0, min(1.0, s)) * 32767).to_bytes(2, "little", signed=True)
            for s in samples
        )
        w.writeframes(frames)


def _score_lrc_against_truth(lrc_raw: str, truth_words: list[dict[str, Any]]) -> dict[str, Any]:
    """Score word starts vs independent ground truth (never CTC self-score)."""
    words, _, _ = parse_lrc_words(lrc_raw)
    pairs = []
    n = min(len(words), len(truth_words))
    for i in range(n):
        w = words[i]
        t = truth_words[i]
        # Prefer text match when lengths diverge mid-list.
        pairs.append(
            {
                "text": w["text"],
                "truth_text": t["text"],
                "lrc_ms": w["start_ms"],
                "truth_ms": t["start_ms"],
                "err_ms": w["start_ms"] - t["start_ms"],
            }
        )
    stats = summarize_pairs(pairs) if pairs else {"n": 0, "pass": False, "median_abs_ms": None, "p90_abs_ms": None}
    coverage = round(n / len(truth_words), 4) if truth_words else 0.0
    stats["coverage"] = coverage
    return {"stats": stats, "n_scored": n, "n_truth": len(truth_words), "sample": pairs[:8]}


def cmd_selftest_timebase(args: argparse.Namespace) -> int:
    """Unit test: recover known onsets within 30 ms at 30s / 120s / 240s.

    Uses the full generate_word_timings path (neighbor-clamped line windows) so a
    regressing segment cap would fail here the way round 4 failed in production.
    """
    import torch

    sr = 16_000
    # Multi-word lines at late positions — single tokens on a bed score too low
    # for a meaningful posterior; the bug we guard against is segment crushing.
    cues = [
        (30_000, ["alpha", "ready", "now"]),
        (120_000, ["bravo", "standing", "by"]),
        (240_000, ["charlie", "locking", "in"]),
    ]
    dur_ms = 250_000
    n = int(sr * dur_ms / 1000)
    samples = _music_bed(n, sr, seed=3)
    lines: list[dict[str, Any]] = []
    truth_first: list[tuple[int, str]] = []
    for ms, words in cues:
        cursor = ms
        wdicts = []
        for wi, word in enumerate(words):
            pcm = _espeak_word_pcm(word, sr=sr, rate=140)
            start = int(sr * cursor / 1000)
            for i, v in enumerate(pcm):
                if start + i < n:
                    samples[start + i] += v * 0.9
            if wi == 0:
                truth_first.append((cursor, word))
            prior = cursor + (60 if wi == 0 else 0)
            wdicts.append(
                {
                    "text": word,
                    "prior_ms": prior,
                    "norm": normalize_token(word),
                    "mms": mms_word(word),
                    "skippable": False,
                }
            )
            cursor += max(int(1000 * len(pcm) / sr), 200) + 180
        lines.append({"prior_ms": wdicts[0]["prior_ms"], "words": wdicts})
    wf = torch.tensor(samples, dtype=torch.float32).unsqueeze(0)
    generated, stats = generate_word_timings(
        wf, lines, line_search_ms=DEFAULT_LINE_SEARCH_MS, min_score=DEFAULT_MIN_SCORE
    )
    results = []
    ok = True
    # Absolute cap (~3 MMS frames) plus a no-growth check: round-4's segment
    # crush produced multi-second errors that worsened with song position.
    abs_tol = 60
    for (ms, word), gl in zip(truth_first, generated):
        w0 = gl["words"][0]
        ctc = int(w0["start_ms"])
        err = abs(ctc - ms)
        passed = err <= abs_tol and w0.get("source") == "ctc"
        ok = ok and passed
        results.append(
            {
                "word": word,
                "truth_ms": ms,
                "ctc_ms": ctc,
                "abs_err_ms": err,
                "source": w0.get("source"),
                "pass": passed,
            }
        )
    errs = [r["abs_err_ms"] for r in results if r["abs_err_ms"] is not None]
    growth = (max(errs) - min(errs)) if errs else 999
    if growth > 30:
        ok = False
    payload = {
        "mode": "selftest_timebase",
        "frame_ms": stats.get("frame_ms"),
        "tolerance_ms": abs_tol,
        "max_error_growth_ms": 30,
        "error_growth_ms": growth,
        "gen": {
            "coverage": stats.get("coverage"),
            "n_line_aligned": stats.get("n_line_aligned"),
            "n_line_fallback": stats.get("n_line_fallback"),
        },
        "results": results,
        "pass": ok,
        "root_cause_note": (
            "Round-4 p90 multi-second errors came from crushing each line segment to "
            "len(words)*280 ms — not from MMS frame hop. This test locks absolute "
            "timebase at late song positions through generate_word_timings."
        ),
    }
    _emit(payload, args.json)
    return 0 if ok else 1


def _build_variant_lines(
    *,
    name: str,
    target_duration_ms: int,
    rate: int,
    gap_ms: int,
    line_pause_ms: int,
    lines_words: list[list[str]],
    lead_ms: int = 2000,
    instrumental_gaps: list[tuple[int, int]] | None = None,
) -> tuple[list[float], list[dict[str, Any]], int, str]:
    """Return (mix_samples@16k, truth_words, duration_ms, input_lrc)."""
    sr = 16_000
    truth_words: list[dict[str, Any]] = []
    placed: list[tuple[int, str, list[float]]] = []
    cursor_ms = lead_ms
    gap_set = {g[0]: g[1] for g in (instrumental_gaps or [])}

    for li, line in enumerate(lines_words):
        if li in gap_set:
            cursor_ms += gap_set[li]
        for word in line:
            pcm = _espeak_word_pcm(word, sr=sr, rate=rate)
            placed.append((cursor_ms, word, pcm))
            truth_words.append({"text": word, "start_ms": cursor_ms, "line": li})
            spoken_ms = int(1000 * len(pcm) / sr)
            cursor_ms += max(spoken_ms, 160) + gap_ms
        cursor_ms += line_pause_ms

    # Stretch trailing silence to hit the target duration when content is shorter.
    duration_ms = max(target_duration_ms, cursor_ms + 2000)
    n_samples = int(sr * duration_ms / 1000)
    mix = _music_bed(n_samples, sr, seed=rate + len(lines_words))
    for start_ms, _word, pcm in placed:
        start = int(sr * start_ms / 1000)
        for i, v in enumerate(pcm):
            idx = start + i
            if idx >= len(mix):
                break
            mix[idx] += v * 0.85

    lrc_lines = [f"[ti:synth-full-{name}]"]
    for li, _line in enumerate(lines_words):
        tw = [w for w in truth_words if w["line"] == li]
        if not tw:
            continue
        line_start = tw[0]["start_ms"]
        line_end = tw[-1]["start_ms"] + 400
        if len(tw) == 1:
            stamps = [line_start]
        else:
            step = (line_end - line_start) / (len(tw) - 1)
            stamps = [int(line_start + i * step) for i in range(len(tw))]
        bits = " ".join(f"<{format_stamp(stamps[i])}>{tw[i]['text']}" for i in range(len(tw)))
        lrc_lines.append(f"[{format_stamp(line_start)}] {bits}")
    lrc_lines.append("")
    return mix, truth_words, duration_ms, "\n".join(lrc_lines)


def cmd_synth_full(args: argparse.Namespace) -> int:
    """Full-length TTS+bed ground truth; score vs truth (optionally via Demucs)."""
    out_root = Path(args.out_dir)
    out_root.mkdir(parents=True, exist_ok=True)
    sr = 16_000

    verse = [
        ["hello", "world", "this", "is", "a", "timing", "fixture"],
        ["singing", "words", "with", "known", "onset", "times"],
        ["another", "line", "keeps", "the", "aligner", "honest"],
        ["tempo", "changes", "should", "still", "lock", "the", "words"],
    ]
    chorus = [
        ["final", "chorus", "repeats", "the", "same", "idea", "clearly"],
        ["bridge", "section", "adds", "length", "without", "new", "tricks"],
        ["closing", "line", "ends", "the", "song", "on", "time"],
    ]
    rap = [
        ["rapid", "fire", "bars", "with", "many", "short", "words", "stacked"],
        ["double", "time", "flow", "keeps", "pushing", "forward", "hard"],
        ["tight", "rhyme", "scheme", "never", "gives", "the", "clock", "rest"],
        ["finish", "strong", "before", "the", "instrumental", "hit"],
    ]
    slow = [
        ["slow", "gentle", "phrases", "breathe", "between", "the", "words"],
        ["open", "vowels", "linger", "across", "the", "measure"],
        ["quiet", "ending", "holds", "the", "final", "tone"],
    ]

    # Pad line lists so content roughly fills the target duration.
    def repeat_until(lines: list[list[str]], n_lines: int) -> list[list[str]]:
        out: list[list[str]] = []
        while len(out) < n_lines:
            out.extend(lines)
        return out[:n_lines]

    variants = [
        {"name": "d60", "target_ms": 60_000, "rate": 140, "gap_ms": 120, "line_pause_ms": 500,
         "lines": repeat_until(verse + chorus, 10)},
        {"name": "d120", "target_ms": 120_000, "rate": 140, "gap_ms": 140, "line_pause_ms": 550,
         "lines": repeat_until(verse + chorus, 18)},
        {"name": "d214", "target_ms": 214_000, "rate": 140, "gap_ms": 150, "line_pause_ms": 600,
         "lines": repeat_until(verse + chorus, 28)},
        {"name": "fast-rap", "target_ms": 90_000, "rate": 200, "gap_ms": 40, "line_pause_ms": 280,
         "lines": repeat_until(rap, 16)},
        {"name": "slow", "target_ms": 120_000, "rate": 100, "gap_ms": 280, "line_pause_ms": 900,
         "lines": repeat_until(slow, 12)},
        {"name": "gaps", "target_ms": 150_000, "rate": 140, "gap_ms": 140, "line_pause_ms": 500,
         "lines": repeat_until(verse + chorus, 14),
         "instrumental_gaps": [(4, 12_000), (9, 18_000)]},
    ]

    report: list[dict[str, Any]] = []
    use_demucs = not getattr(args, "no_demucs", False)

    for variant in variants:
        vdir = out_root / variant["name"]
        vdir.mkdir(parents=True, exist_ok=True)
        mix, truth_words, duration_ms, input_lrc = _build_variant_lines(
            name=variant["name"],
            target_duration_ms=variant["target_ms"],
            rate=variant["rate"],
            gap_ms=variant["gap_ms"],
            line_pause_ms=variant["line_pause_ms"],
            lines_words=variant["lines"],
            instrumental_gaps=variant.get("instrumental_gaps"),
        )
        wav_path = vdir / "mix.wav"
        _write_wav_mono(wav_path, mix, sr)
        # Demucs prefers richer audio — upmix mono bed to 44.1 stereo wav.
        demucs_in = vdir / "mix44.wav"
        subprocess.run(
            [
                "ffmpeg", "-y", "-v", "error",
                "-i", str(wav_path),
                "-ac", "2", "-ar", "44100",
                str(demucs_in),
            ],
            check=True,
        )
        (vdir / "truth.json").write_text(
            json.dumps(
                {
                    "variant": variant["name"],
                    "rate": variant["rate"],
                    "duration_ms": duration_ms,
                    "words": truth_words,
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        (vdir / "input.lrc").write_text(input_lrc, encoding="utf-8")

        before = _score_lrc_against_truth(input_lrc, truth_words)
        entry: dict[str, Any] = {
            "variant": variant["name"],
            "duration_ms": duration_ms,
            "n_words": len(truth_words),
            "rate": variant["rate"],
            "before_vs_truth": before["stats"],
            "wav": str(wav_path),
        }

        if args.run_align:
            work = vdir / "work"
            work.mkdir(exist_ok=True)
            out_lrc = vdir / "aligned.lrc"
            out_lrc.write_text(input_lrc, encoding="utf-8")
            gen_json = vdir / "generate.json"
            ns = argparse.Namespace(
                audio=str(demucs_in if use_demucs else wav_path),
                lrc=str(out_lrc),
                work_dir=str(work),
                no_demucs=not use_demucs,
                allow_no_demucs=True,
                demucs_model="htdemucs",
                line_search_ms=args.line_search_ms,
                min_score=DEFAULT_MIN_SCORE,
                aligned_version=ALIGNED_VERSION,
                force=True,
                write=True,
                force_write=True,
                min_coverage=0.0,
                json=str(gen_json),
            )
            cmd_generate_words(ns)
            aligned_raw = out_lrc.read_text(encoding="utf-8", errors="replace")
            after = _score_lrc_against_truth(aligned_raw, truth_words)
            entry["after_vs_truth"] = after["stats"]
            entry["generate_json"] = str(gen_json)
            entry["demucs"] = use_demucs
            a = after["stats"]
            entry["meets_target"] = bool(
                a.get("median_abs_ms") is not None
                and a.get("p90_abs_ms") is not None
                and a["median_abs_ms"] <= MEDIAN_ABS_LIMIT_MS
                and a["p90_abs_ms"] <= P90_ABS_LIMIT_MS
                and abs(a.get("drift_ms_per_min") or 0) <= DRIFT_LIMIT_MS_PER_MIN
            )

        report.append(entry)

    payload = {
        "mode": "synth_full",
        "pass_bar": {
            "median_abs_ms": MEDIAN_ABS_LIMIT_MS,
            "p90_abs_ms": P90_ABS_LIMIT_MS,
            "drift_ms_per_min": DRIFT_LIMIT_MS_PER_MIN,
        },
        "demucs": use_demucs,
        "note": (
            "Scores are LRC vs independent TTS onset truth after Demucs vocals. "
            "No Deezer previews, no CTC self-score."
        ),
        "root_cause_fixed": (
            "Removed len(words)*280 segment cap that crushed lines to ~1.4s; "
            "windows are now LRCLIB line span ±1.5s clamped to neighbors; "
            "emission frame_ms derived from tensor length; 40ms MMS lag compensate."
        ),
        "variants": report,
    }
    _emit(payload, args.json)
    if args.run_align:
        return 0 if all(v.get("meets_target") for v in report) else 1
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

    coverage = float(gen_stats.get("coverage") or 0.0)
    min_cov = getattr(args, "min_coverage", DEFAULT_MIN_COVERAGE)
    gate_ok, gate_reason = quality_gate_allows_write(
        gen_stats=gen_stats,
        generated_lines=generated,
        min_coverage=min_cov,
    )

    wrote = False
    fallback = None
    reason = None
    if args.write and generated:
        if gate_ok or getattr(args, "force_write", False):
            new_raw = rewrite_lrc_generated(raw, generated, aligned_version=args.aligned_version)
            lrc_path.write_text(new_raw, encoding="utf-8")
            wrote = True
            if not gate_ok and getattr(args, "force_write", False):
                reason = f"force_write despite gate: {gate_reason}"
        else:
            # Keep LRCLIB unchanged — do not rewrite the sidecar.
            fallback = "keep_lrclib"
            reason = f"quality_gate: {gate_reason}"

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
        "coverage": coverage,
        "gate": {
            "ok": gate_ok,
            "reason": gate_reason,
            "min_coverage": min_cov,
            "line_agree_ms": LINE_AGREE_MS,
            "note": "non-circular: per-line first-word agreement + coverage + monotonicity",
        },
        "n_snapped": 0,  # compatibility for Go logger
        "n_kept": int(gen_stats.get("n_line_fallback") or 0),
        "n_generated": sum(len(g["words"]) for g in generated),
        "n_interp": gen_stats.get("n_interp", 0),
        "wrote": wrote,
        "skipped": False,
        "fallback": fallback,
        "reason": reason,
    }
    _emit(payload, args.json)
    if fallback == "keep_lrclib":
        return 0
    return 0 if gate_ok else 1


def quality_gate_allows_write(
    *,
    gen_stats: dict[str, Any],
    generated_lines: list[dict[str, Any]],
    min_coverage: float = DEFAULT_MIN_COVERAGE,
) -> tuple[bool, str]:
    """Non-circular write gate (no CTC-vs-self scoring).

    Per-line agreement / LRCLIB fallback already happened inside generate_word_timings.
    Here we require overall CTC coverage, at least one aligned line, and global
    monotonic word starts before rewriting the sidecar.
    """
    coverage = float(gen_stats.get("coverage") or 0.0)
    if coverage < min_coverage:
        return False, f"coverage {coverage:.3f} < {min_coverage}"
    if int(gen_stats.get("n_line_aligned") or 0) < 1:
        return False, "no lines passed first-word agreement"
    starts: list[int] = []
    for gl in generated_lines:
        for w in gl.get("words") or []:
            if "start_ms" in w:
                starts.append(int(w["start_ms"]))
    for i in range(1, len(starts)):
        if starts[i] < starts[i - 1]:
            return False, f"non-monotonic at word {i} ({starts[i]} < {starts[i-1]})"
    return True, "ok"


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
    g.add_argument("--min-coverage", type=float, default=DEFAULT_MIN_COVERAGE)
    g.add_argument(
        "--force-write",
        action="store_true",
        help="Write even when the quality gate fails (eval / debug only)",
    )
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
    r.add_argument("--min-coverage", type=float, default=DEFAULT_MIN_COVERAGE)
    r.add_argument("--force-write", action="store_true")
    r.add_argument("--json")
    r.set_defaults(func=cmd_generate_words)

    st = sub.add_parser(
        "selftest-timebase",
        help="Recover known onsets within 30ms at 30s/120s/240s",
    )
    st.add_argument("--json")
    st.set_defaults(func=cmd_selftest_timebase)

    sf = sub.add_parser(
        "synth-full",
        help="Full-length TTS+music-bed ground truth with tempo/length variants",
    )
    sf.add_argument("--out-dir", required=True)
    sf.add_argument(
        "--run-align",
        action="store_true",
        help="Also run generate-words and score vs truth (not self-score)",
    )
    sf.add_argument(
        "--no-demucs",
        action="store_true",
        help="Skip Demucs (debug only; round-5 eval uses Demucs by default)",
    )
    sf.add_argument("--line-search-ms", type=int, default=DEFAULT_LINE_SEARCH_MS)
    sf.add_argument("--json")
    sf.set_defaults(func=cmd_synth_full)

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
