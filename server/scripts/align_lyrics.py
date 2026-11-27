#!/usr/bin/env python3
"""Karaoke stamp evaluation + per-word forced-alignment refine.

Ground truth is CTC forced alignment (torchaudio MMS_FA) of the known lyric
text onto Demucs-separated vocals — not Whisper ASR timestamps.

Commands:
  synth-fixture   TTS words at known onsets (validates CTC itself)
  check-truth     Compare LRC to a truth JSON (no ML)
  measure         Per-word error of LRC vs CTC (optional Deezer-preview anchor)
  refine-words    Snap each LRCLIB stamp to CTC onset within ±window; rewrite .lrc
  separate        Demucs vocals only (debug)

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

MEDIAN_ABS_LIMIT_MS = 40
P90_ABS_LIMIT_MS = 100
DRIFT_LIMIT_MS_PER_MIN = 30
ALIGNED_VERSION = "v2-ctc-demucs"
DEFAULT_SNAP_WINDOW_MS = 300
DEFAULT_MIN_SCORE = 0.15
FRAME_MS = 20.0  # MMS_FA hop at 16 kHz

# MMS_FA dictionary letters (plus apostrophe). Others are dropped.
_MMS_CHARS = set("abcdefghijklmnopqrstuvwxyz'")


def normalize_token(tok: str) -> str:
    return re.sub(r"[^a-z0-9']+", "", tok.lower())


def mms_word(tok: str) -> str:
    """Lowercase roman letters + apostrophe only for MMS_FA tokenizer."""
    raw = normalize_token(tok)
    return "".join(c for c in raw if c in _MMS_CHARS)


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
                }
            )
    if embedded:
        for w in words:
            w["start_ms"] = max(0, w["start_ms"] + embedded)
    return words, embedded, aligned_ver


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
                words.append(
                    {
                        "text": text,
                        "start_ms": w["start_ms"],
                        "norm": normalize_token(text),
                        "mms": mms_word(text),
                    }
                )
    return words


def load_lyric_words(path: Path) -> tuple[list[dict[str, Any]], str, str | None]:
    raw = path.read_text(encoding="utf-8", errors="replace")
    if path.suffix.lower() in {".yml", ".yaml"} or "start_ms:" in raw[:800]:
        return parse_lyricsfile_words(raw), "lyricsfile", None
    words, _, ver = parse_lrc_words(raw)
    return words, "lrc", ver


def load_wav_mono16k(path: Path) -> "torch.Tensor":
    """Load mono 16 kHz float tensor. Avoids torchaudio.load (needs torchcodec)."""
    import numpy as np
    import torch

    # Prefer ffmpeg → f32le so mp3/flac/wav all work the same way.
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
    """Separate vocals with Demucs; return path to vocals.wav."""
    out_dir.mkdir(parents=True, exist_ok=True)
    cached = out_dir / "vocals.wav"
    if cached.exists() and cached.stat().st_mtime >= audio.stat().st_mtime:
        return cached
    # demucs writes out_dir/<model>/<track>/vocals.wav
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
    # find vocals
    found = list(out_dir.rglob("vocals.wav"))
    if not found:
        raise RuntimeError(f"demucs produced no vocals under {out_dir}")
    # Prefer the newest match for this run
    found.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    src = found[0]
    if src.resolve() != cached.resolve():
        shutil.copy2(src, cached)
    print(
        f"demucs {model}: {audio.name} -> vocals in {time.time() - t0:.1f}s",
        file=sys.stderr,
    )
    return cached


_mms_bundle: dict[str, Any] = {}


def get_mms():
    import torch
    from torchaudio.pipelines import MMS_FA

    if not _mms_bundle:
        device = torch.device("cpu")
        _mms_bundle["model"] = MMS_FA.get_model(with_star=False).to(device).eval()
        _mms_bundle["tokenizer"] = MMS_FA.get_tokenizer()
        _mms_bundle["aligner"] = MMS_FA.get_aligner()
        _mms_bundle["device"] = device
    return _mms_bundle


def ctc_align_words(
    waveform: "torch.Tensor",
    words: list[dict[str, Any]],
    *,
    group_max_words: int = 10,
    pad_ms: int = 1200,
    prior_shift_ms: int = 0,
) -> list[dict[str, Any]]:
    """Forced-align `words` onto mono 16 kHz `waveform`.

    Aligns small groups (≈one lyric line) against a window around their LRCLIB
    priors. Dumping a whole verse into one CTC pass drifts on dense rap.

    `pad_ms` defaults wide (±1.2 s) so late/early LRCLIB stamps still put the
    true onset inside the clip — a tight 400 ms pad centered on a 500–700 ms
    late prior misses the vocal and invents non-monotonic hits.

    `prior_shift_ms` recenters windows after a coarse constant offset is known
    (positive => priors are late vs vocals, so windows move earlier).
    """
    import torch

    bundle = get_mms()
    model = bundle["model"]
    tokenizer = bundle["tokenizer"]
    aligner = bundle["aligner"]
    device = bundle["device"]

    usable = [w for w in words if w.get("mms")]
    if not usable:
        return []

    sr = 16_000
    n = waveform.shape[-1]
    dur_ms = max(1, int(n / sr * 1000))

    # Group by lyric-line gaps (>700ms) or max words — keeps CTC paths short.
    groups: list[list[dict[str, Any]]] = []
    cur: list[dict[str, Any]] = []
    for w in usable:
        if cur and (
            len(cur) >= group_max_words
            or w["start_ms"] - cur[-1]["start_ms"] > 700
        ):
            groups.append(cur)
            cur = []
        cur.append(w)
    if cur:
        groups.append(cur)

    ordered: list[dict[str, Any]] = []
    with torch.inference_mode():
        for group in groups:
            # Window around shifted priors (coarse master/intro correction).
            first = group[0]["start_ms"] - prior_shift_ms
            last = group[-1]["start_ms"] - prior_shift_ms
            g0 = max(0, first - pad_ms)
            span = max(400, last - first)
            g1 = min(dur_ms, last + max(pad_ms, int(span * 0.35) + 500))
            if g1 - g0 < 300:
                g1 = min(dur_ms, g0 + 800)
            a0 = int(g0 / 1000 * sr)
            a1 = int(g1 / 1000 * sr)
            clip = waveform[:, a0:a1].to(device)
            if clip.numel() < sr // 4:
                continue
            emission, _ = model(clip)
            if emission.ndim == 3:
                emission = emission[0]
            tokens = tokenizer([w["mms"] for w in group])
            try:
                spans = aligner(emission.cpu(), tokens)
            except Exception as exc:  # pragma: no cover
                print(f"align group failed: {exc}", file=sys.stderr)
                continue
            for w, word_spans in zip(group, spans):
                if not word_spans:
                    continue
                start_frame = word_spans[0].start
                end_frame = word_spans[-1].end
                score = float(statistics.mean(s.score for s in word_spans))
                onset_ms = g0 + int(round(start_frame * FRAME_MS))
                end_ms = g0 + int(round(end_frame * FRAME_MS))
                ordered.append(
                    {
                        "text": w["text"],
                        "lrc_ms": w["start_ms"],
                        "ctc_ms": onset_ms,
                        "end_ms": end_ms,
                        "score": score,
                        "norm": w["norm"],
                        "mms": w["mms"],
                    }
                )
    return ordered


def summarize_pairs(pairs: list[dict[str, Any]], err_key: str = "err_ms") -> dict[str, Any]:
    if len(pairs) < 5:
        return {"n": len(pairs), "pass": False, "reason": "too_few_pairs"}
    errs = [p[err_key] for p in pairs]
    abs_e = [abs(e) for e in errs]
    xs = [p.get("ctc_ms", p.get("asr_ms", p.get("truth_ms", 0))) for p in pairs]
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


def anchor_preview_by_text(
    lrc_words: list[dict[str, Any]], preview_words_mms: list[str], min_run: int = 5
) -> tuple[int, int, int] | None:
    """Find (lrc_index, preview_index, score) for the best shared word run."""
    lrc_mms = [w["mms"] for w in lrc_words]
    best = None
    best_score = -1
    for i in range(len(lrc_mms) - min_run + 1):
        for j in range(len(preview_words_mms) - min_run + 1):
            score = 0
            for k in range(min(40, len(lrc_mms) - i, len(preview_words_mms) - j)):
                if not lrc_mms[i + k] or not preview_words_mms[j + k]:
                    break
                if lrc_mms[i + k] == preview_words_mms[j + k]:
                    score += 1
                else:
                    break
            if score > best_score:
                best_score = score
                best = (i, j, score)
    if not best or best[2] < min_run:
        return None
    return best


def rewrite_lrc_word_stamps(
    raw: str,
    snaps: dict[int, int],
    *,
    aligned_version: str,
) -> str:
    """Rewrite angle stamps by sequential word index using `snaps` map."""
    words, embedded, _ = parse_lrc_words(raw)
    # Build new absolute stamp list (already includes embedded offset undo)
    new_abs = []
    for i, w in enumerate(words):
        base = w["start_ms"] - embedded  # strip prior offset from stored stamp
        if i in snaps:
            # snaps are absolute desired times (playhead / file time)
            base = snaps[i]
        new_abs.append(max(0, base))

    lines_out: list[str] = [f"[drome-aligned:{aligned_version}]"]
    # Drop old offset / aligned tags; stamps are absolute to the audio file.
    word_i = 0

    def repl_angle(m: re.Match[str]) -> str:
        nonlocal word_i
        text = m.group(4)
        if word_i < len(new_abs):
            ms = new_abs[word_i]
            word_i += 1
        else:
            ms = stamp_to_ms(m.group(1), m.group(2), m.group(3))
        return f"<{format_stamp(ms)}>{text}"

    def repl_bracket(m: re.Match[str]) -> str:
        # Line stamp: use first upcoming word stamp if present
        if word_i < len(new_abs):
            # peek — line stamp should be <= first word on the line
            return f"[{format_stamp(new_abs[word_i])}]"
        ms = stamp_to_ms(m.group(1), m.group(2), m.group(3))
        return f"[{format_stamp(ms)}]"

    for line in raw.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if OFFSET_RE.match(stripped) or ALIGNED_RE.match(stripped):
            continue
        if not BRACKET_RE.search(line) and not ANGLE_RE.search(line):
            if stripped.startswith("[") and stripped.endswith("]") and ":" in stripped:
                lines_out.append(stripped)
            continue
        # Replace brackets first (line start), then angles (advances word_i)
        # Actually bracket uses peek of word_i before angles advance — good order:
        rewritten = BRACKET_RE.sub(repl_bracket, line, count=1)
        rewritten = ANGLE_RE.sub(repl_angle, rewritten)
        lines_out.append(rewritten.rstrip())
    return "\n".join(lines_out) + "\n"


def prepare_vocals(audio: Path, work: Path, *, use_demucs: bool, demucs_model: str) -> Path:
    if use_demucs:
        return demucs_vocals(audio, work / "demucs", model=demucs_model)
    # Copy / resample to work for consistency
    dst = work / "mix.wav"
    subprocess.run(
        ["ffmpeg", "-y", "-v", "error", "-i", str(audio), "-ac", "1", "-ar", "16000", str(dst)],
        check=True,
    )
    return dst


def cmd_synth_fixture(args: argparse.Namespace) -> int:
    """Build TTS words at known onsets — validates CTC, not beep tones."""
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
            # load
            with wave.open(str(wav_path), "rb") as w:
                assert w.getnchannels() == 1
                fr = w.getframerate()
                raw = w.readframes(w.getnframes())
                import array

                arr = array.array("h")
                arr.frombytes(raw)
                # resample naive if needed
                if fr != sr:
                    # linear
                    ratio = sr / fr
                    new_len = int(len(arr) * ratio)
                    rs = []
                    for i in range(new_len):
                        src = i / ratio
                        j = int(src)
                        f = src - j
                        a = arr[j] if j < len(arr) else 0
                        b = arr[j + 1] if j + 1 < len(arr) else 0
                        rs.append(a * (1 - f) + b * f)
                    vals = rs
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
            int(max(-1, min(1, s)) * 32767).to_bytes(2, "little", signed=True) for s in samples
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
    lrc_path = out / "speech.lrc"
    lrc_path.write_text(lrc, encoding="utf-8")
    truth = {"words": [{"text": t, "start_ms": ms} for ms, t in cues]}
    (out / "speech.truth.json").write_text(json.dumps(truth, indent=2) + "\n", encoding="utf-8")

    # Also keep beep fixture for check-truth-only path
    beep_dir = out.parent / "perfect"
    if args.also_beep:
        cmd_synth_beep(beep_dir)

    print(json.dumps({"wav": str(wav_path), "lrc": str(lrc_path), "words": len(cues)}))
    return 0


def cmd_synth_beep(out: Path) -> None:
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
    samples = [0.0] * int(sr * 8)
    for ms, _ in cues:
        start = int(sr * ms / 1000)
        for i in range(start, min(len(samples), start + int(0.08 * sr))):
            t = (i - start) / sr
            samples[i] = 0.35 * math.sin(2 * math.pi * 880 * t)
    with wave.open(str(out / "perfect.wav"), "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(
            b"".join(
                int(max(-1, min(1, s)) * 32767).to_bytes(2, "little", signed=True) for s in samples
            )
        )
    bits = " ".join(f"<{format_stamp(ms)}>{t}" for ms, t in cues)
    (out / "perfect.lrc").write_text(
        f"[ti:perfect-fixture]\n[{format_stamp(cues[0][0])}] {bits}\n", encoding="utf-8"
    )
    (out / "perfect.truth.json").write_text(
        json.dumps({"words": [{"text": t, "start_ms": ms} for ms, t in cues]}, indent=2) + "\n",
        encoding="utf-8",
    )


def cmd_check_truth(args: argparse.Namespace) -> int:
    words, _, _ = load_lyric_words(Path(args.lrc))
    truth = json.loads(Path(args.truth).read_text(encoding="utf-8"))
    tw = truth["words"]
    pairs = []
    for a, b in zip(words, tw):
        pairs.append(
            {
                "text": a["text"],
                "lrc_ms": a["start_ms"],
                "truth_ms": b["start_ms"],
                "err_ms": a["start_ms"] - b["start_ms"],
            }
        )
    stats = summarize_pairs(pairs)
    _emit({"mode": "check_truth", "stats": stats, "sample": pairs}, args.json)
    return 0 if stats.get("pass") else 1


def cmd_validate_aligner(args: argparse.Namespace) -> int:
    """Run CTC on the speech fixture and report aligner error vs known onsets."""
    wav = Path(args.audio)
    truth = json.loads(Path(args.truth).read_text(encoding="utf-8"))
    words = [
        {
            "text": w["text"],
            "start_ms": w["start_ms"],
            "norm": normalize_token(w["text"]),
            "mms": mms_word(w["text"]),
        }
        for w in truth["words"]
    ]
    waveform = load_wav_mono16k(wav)
    # No demucs for clean TTS
    aligned = ctc_align_words(waveform, words)
    pairs = []
    for a in aligned:
        pairs.append(
            {
                "text": a["text"],
                "truth_ms": a["lrc_ms"],
                "ctc_ms": a["ctc_ms"],
                "err_ms": a["ctc_ms"] - a["lrc_ms"],
                "score": a["score"],
            }
        )
    stats = summarize_pairs(pairs)
    payload = {
        "mode": "validate_aligner",
        "aligner": "torchaudio MMS_FA",
        "demucs": False,
        "note": "CTC onset minus known TTS onset; this is the aligner's own error",
        "stats": stats,
        "sample": pairs,
        "frame_ms": FRAME_MS,
    }
    _emit(payload, args.json)
    # Soft pass for aligner self-test: median abs ≤ 80ms (TTS + 20ms frames)
    soft_pass = stats.get("n", 0) >= 5 and stats.get("median_abs_ms", 999) <= 80
    return 0 if soft_pass else 1


def cmd_measure(args: argparse.Namespace) -> int:
    audio = Path(args.audio)
    lrc_path = Path(args.lrc)
    lrc_words, kind, ver = load_lyric_words(lrc_path)
    work = Path(args.work_dir) if args.work_dir else Path(tempfile.mkdtemp(prefix="lyrics-eval-"))
    work.mkdir(parents=True, exist_ok=True)

    t0 = time.time()
    vocals = prepare_vocals(
        audio, work, use_demucs=not args.no_demucs, demucs_model=args.demucs_model
    )
    waveform = load_wav_mono16k(vocals)
    sep_s = time.time() - t0

    # Preview mode: only align the lyric window that matches the preview text.
    measure_words = lrc_words
    preview_origin_ms = 0
    anchor_info = None
    if args.preview_anchor:
        # CTC-align using ALL lrc words that could fit in the preview duration,
        # but first find which LRC subsequence the preview contains via a quick
        # CTC pass on a coarse word list from the LRC file spanning possible times.
        # Simpler approach: use --preview-start-ms if known; else text-anchor with
        # words whose priors fall in a sliding window after guessing origin from
        # densest match of CTC on full lrc truncated to preview length.
        preview_dur_ms = int(waveform.shape[-1] / 16)  # samples/16 = ms at 16k
        # Take successive LRC windows of ~preview duration and pick best CTC scores
        best = None
        step = 2_000
        window = preview_dur_ms + 2_000
        for origin in range(0, max(1, (lrc_words[-1]["start_ms"] if lrc_words else 0) - 5_000), step):
            candidates = [
                w
                for w in lrc_words
                if origin - 500 <= w["start_ms"] <= origin + window and w.get("mms")
            ]
            if len(candidates) < 6:
                continue
            # Remap priors into preview-local times for chunk assignment
            local = []
            for w in candidates:
                c = dict(w)
                c["start_ms"] = w["start_ms"] - origin
                local.append(c)
            aligned = ctc_align_words(waveform, local)
            if len(aligned) < 5:
                continue
            mean_score = statistics.mean(a["score"] for a in aligned)
            # Also prefer low residual after fitting origin
            resid = []
            for a in aligned:
                # a['lrc_ms'] is local prior; a['ctc_ms'] is local onset
                resid.append(abs((a["lrc_ms"] + origin) - (a["ctc_ms"] + origin)))
            med = statistics.median(resid) if resid else 9999
            score = mean_score - 0.0001 * med
            if best is None or score > best[0]:
                best = (score, origin, candidates, aligned, mean_score)
        if best is None:
            _emit(
                {
                    "mode": "measure",
                    "error": "preview_anchor_failed",
                    "n_lrc": len(lrc_words),
                },
                args.json,
            )
            return 2
        _, preview_origin_ms, measure_words, aligned_local, mean_score = best
        anchor_info = {
            "preview_origin_ms": preview_origin_ms,
            "mean_ctc_score": mean_score,
            "n_window_words": len(measure_words),
        }
        pairs = []
        for a in aligned_local:
            lrc_abs = a["lrc_ms"] + preview_origin_ms
            ctc_abs = a["ctc_ms"] + preview_origin_ms
            # Offset-free per-word: after removing constant median(lrc-ctc)
            pairs.append(
                {
                    "text": a["text"],
                    "lrc_ms": lrc_abs,
                    "ctc_ms": ctc_abs,
                    "err_ms": lrc_abs - ctc_abs,
                    "score": a["score"],
                }
            )
        # Report both raw and after constant-offset removal
        raw_stats = summarize_pairs(pairs)
        off = raw_stats.get("median_ms", 0)
        debiased = []
        for p in pairs:
            debiased.append({**p, "err_ms": p["err_ms"] - off})
        stats = summarize_pairs(debiased)
        stats["constant_offset_removed_ms"] = off
        stats["raw_before_debias"] = {
            k: raw_stats[k]
            for k in ("median_ms", "median_abs_ms", "p90_abs_ms", "drift_ms_per_min")
            if k in raw_stats
        }
    else:
        t1 = time.time()
        aligned = ctc_align_words(waveform, measure_words)
        align_s = time.time() - t1
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
        stats = summarize_pairs(pairs)
        sep_s = sep_s  # noqa
        align_s = align_s

    payload = {
        "mode": "measure",
        "audio": str(audio),
        "lyrics": str(lrc_path),
        "lyrics_kind": kind,
        "aligned_version_in_lrc": ver,
        "ground_truth": "torchaudio MMS_FA CTC on Demucs vocals"
        if not args.no_demucs
        else "torchaudio MMS_FA CTC on mix",
        "demucs": not args.no_demucs,
        "demucs_model": args.demucs_model if not args.no_demucs else None,
        "seconds_separate": round(sep_s, 2),
        "n_lrc": len(lrc_words),
        "n_pairs": len(pairs),
        "preview_anchor": anchor_info,
        "stats": stats,
        "sample": pairs[:10],
        "note": (
            "err_ms = lrc - ctc (positive => stamp late vs vocal onset). "
            "Preview mode reports stats after removing constant origin offset "
            "so numbers are per-word accuracy, not master mismatch."
            if args.preview_anchor
            else "Full-file measure; ensure audio duration matches the LRCLIB master (±0.5s)."
        ),
    }
    _emit(payload, args.json)
    return 0 if stats.get("pass") else 1


def cmd_refine_words(args: argparse.Namespace) -> int:
    audio = Path(args.audio)
    lrc_path = Path(args.lrc)
    raw = lrc_path.read_text(encoding="utf-8", errors="replace")
    words, embedded, ver = parse_lrc_words(raw)
    if ver == args.aligned_version and not args.force:
        payload = {
            "mode": "refine_words",
            "skipped": True,
            "reason": f"already aligned ({ver})",
            "lyrics": str(lrc_path),
        }
        _emit(payload, args.json)
        return 0

    work = Path(args.work_dir) if args.work_dir else Path(tempfile.mkdtemp(prefix="lyrics-refine-"))
    work.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    vocals = prepare_vocals(
        audio, work, use_demucs=not args.no_demucs, demucs_model=args.demucs_model
    )
    sep_s = time.time() - t0
    waveform = load_wav_mono16k(vocals)
    t1 = time.time()

    def pair_aligned(
        aligned_rows: list[dict[str, Any]],
    ) -> list[tuple[int, dict[str, Any]]]:
        usable_iter = [i for i, w in enumerate(words) if w.get("mms")]
        out: list[tuple[int, dict[str, Any]]] = []
        ai = 0
        for idx in usable_iter:
            if ai >= len(aligned_rows):
                break
            a = aligned_rows[ai]
            if a["mms"] != words[idx]["mms"] and a["norm"] != words[idx]["norm"]:
                found = None
                for j in range(ai, min(ai + 5, len(aligned_rows))):
                    if (
                        aligned_rows[j]["mms"] == words[idx]["mms"]
                        or aligned_rows[j]["norm"] == words[idx]["norm"]
                    ):
                        found = j
                        break
                if found is None:
                    continue
                ai = found
                a = aligned_rows[ai]
            ai += 1
            out.append((idx, a))
        return out

    # Pass 1: wide pad around raw LRCLIB priors → coarse constant offset.
    aligned_coarse = ctc_align_words(waveform, words, pad_ms=max(1200, args.window_ms * 4))
    pairs_coarse = pair_aligned(aligned_coarse)
    before_pairs = [
        {
            "text": words[idx]["text"],
            "lrc_ms": words[idx]["start_ms"],
            "ctc_ms": a["ctc_ms"],
            "err_ms": words[idx]["start_ms"] - a["ctc_ms"],
            "score": a["score"],
        }
        for idx, a in pairs_coarse
    ]
    before = summarize_pairs(before_pairs) if before_pairs else {"n": 0, "pass": False}

    hi_errs = [
        words[idx]["start_ms"] - a["ctc_ms"]
        for idx, a in pairs_coarse
        if a["score"] >= args.min_score
    ]
    base_offset = int(round(statistics.median(hi_errs))) if len(hi_errs) >= 5 else 0

    # Pass 2: recenter windows by base_offset, tighter pad, then per-word snap.
    aligned = ctc_align_words(
        waveform,
        words,
        pad_ms=max(500, args.window_ms + 200),
        prior_shift_ms=base_offset,
    )
    pairs_idx = pair_aligned(aligned)
    align_s = time.time() - t1

    snaps: dict[int, int] = {}
    after_pairs = []
    snapped = 0
    shifted_only = 0
    kept = 0
    for idx, a in pairs_idx:
        lrc0 = words[idx]["start_ms"]
        shifted = lrc0 - base_offset  # apply constant correction
        residual = shifted - a["ctc_ms"]
        if a["score"] >= args.min_score and abs(residual) <= args.window_ms:
            snaps[idx] = a["ctc_ms"]
            snapped += 1
            final = a["ctc_ms"]
        elif base_offset != 0:
            snaps[idx] = max(0, shifted)
            shifted_only += 1
            final = max(0, shifted)
        else:
            kept += 1
            final = lrc0
        after_pairs.append(
            {
                "text": words[idx]["text"],
                "lrc_ms": final,
                "ctc_ms": a["ctc_ms"],
                "err_ms": final - a["ctc_ms"],
                "score": a["score"],
            }
        )

    # Words never aligned still get the constant shift when we rewrite.
    if base_offset != 0:
        aligned_idxs = {idx for idx, _ in pairs_idx}
        for idx, w in enumerate(words):
            if idx not in aligned_idxs and idx not in snaps:
                snaps[idx] = max(0, w["start_ms"] - base_offset)
                shifted_only += 1

    after = summarize_pairs(after_pairs) if after_pairs else {"n": 0, "pass": False}

    wrote = False
    if args.write and snaps:
        new_raw = rewrite_lrc_word_stamps(raw, snaps, aligned_version=args.aligned_version)
        lrc_path.write_text(new_raw, encoding="utf-8")
        wrote = True

    payload = {
        "mode": "refine_words",
        "audio": str(audio),
        "lyrics": str(lrc_path),
        "aligned_version": args.aligned_version,
        "window_ms": args.window_ms,
        "min_score": args.min_score,
        "base_offset_ms": base_offset,
        "demucs": not args.no_demucs,
        "seconds_separate": round(sep_s, 2),
        "seconds_align": round(align_s, 2),
        "seconds_total": round(time.time() - t0, 2),
        "n_lrc": len(words),
        "n_snapped": snapped,
        "n_shifted_only": shifted_only,
        "n_kept": kept,
        "before": before,
        "after": after,
        "wrote": wrote,
    }
    _emit(payload, args.json)
    return 0 if after.get("pass") else 1


def _emit(payload: dict[str, Any], json_path: str | None) -> None:
    text = json.dumps(payload, indent=2)
    if json_path:
        Path(json_path).write_text(text + "\n", encoding="utf-8")
    print(text)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

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
    m.add_argument(
        "--preview-anchor",
        action="store_true",
        help="Treat audio as a mid-song preview; debias constant origin before scoring",
    )
    m.add_argument("--json")
    m.set_defaults(func=cmd_measure)

    r = sub.add_parser("refine-words", help="Per-word snap LRC stamps to CTC")
    r.add_argument("--audio", required=True)
    r.add_argument("--lrc", required=True)
    r.add_argument("--work-dir")
    r.add_argument("--no-demucs", action="store_true")
    r.add_argument("--demucs-model", default="htdemucs")
    r.add_argument("--window-ms", type=int, default=DEFAULT_SNAP_WINDOW_MS)
    r.add_argument("--min-score", type=float, default=DEFAULT_MIN_SCORE)
    r.add_argument("--aligned-version", default=ALIGNED_VERSION)
    r.add_argument("--force", action="store_true")
    r.add_argument("--write", action="store_true")
    r.add_argument("--json")
    r.set_defaults(func=cmd_refine_words)

    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
