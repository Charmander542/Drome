#!/usr/bin/env python3
"""Patch installed SpotiFLAC Amazon provider: ASIN promote/dedup + hard finalize.

Mirrors SpotiFLAC Go backend/download_finalize.go behavior used by Drome.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path


HELPERS = '''
# --- drome ASIN finalize (patched in) ---
_AMAZON_ASIN_BASE_RE = re.compile(r"(?i)^B[0-9A-Z]{9}$")


def _is_amazon_asin_base_name(base: str) -> bool:
    base = (base or "").strip()
    if not base:
        return False
    if "_" in base:
        base = base.split("_", 1)[0]
    return bool(_AMAZON_ASIN_BASE_RE.match(base))


def _require_spotify_identity(title: str, artist: str) -> None:
    if not (title or "").strip():
        raise SpotiflacError(
            ErrorKind.UNAVAILABLE,
            "spotify title is required before Amazon finalize",
            "amazon",
        )
    if not (artist or "").strip():
        raise SpotiflacError(
            ErrorKind.UNAVAILABLE,
            "spotify artist is required before Amazon finalize",
            "amazon",
        )


def _promote_or_dedup_asin(asin_path: str, dest_path: str) -> str:
    asin_path = os.path.abspath(asin_path)
    dest_path = os.path.abspath(dest_path)
    if asin_path == dest_path:
        return dest_path
    if os.path.exists(dest_path) and os.path.getsize(dest_path) > 0:
        with contextlib.suppress(FileNotFoundError):
            os.remove(asin_path)
        return dest_path
    os.makedirs(os.path.dirname(dest_path) or ".", exist_ok=True)
    if os.path.exists(dest_path):
        os.remove(dest_path)
    os.replace(asin_path, dest_path)
    return dest_path


def _finalize_tagged_download(path: str, title: str, artist: str) -> None:
    _require_spotify_identity(title, artist)
    base = os.path.splitext(os.path.basename(path))[0]
    if _is_amazon_asin_base_name(base):
        raise SpotiflacError(
            ErrorKind.UNAVAILABLE,
            f"download still ASIN-named after finalize: {os.path.basename(path)}",
            "amazon",
        )
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        raise SpotiflacError(
            ErrorKind.UNAVAILABLE,
            f"finalize missing/empty file: {path}",
            "amazon",
        )
# --- end drome ASIN finalize ---
'''

IDENTITY_INSERT = '''            if await asyncio.to_thread(self._file_exists, dest):
                return DownloadResult.skipped_result(self.name, str(dest))

            _require_spotify_identity(
                getattr(metadata, "title", "") or "",
                getattr(metadata, "artists", "") or "",
            )
'''

OLD_REPLACE = '''            if os.path.abspath(downloaded) != os.path.abspath(dest_ext):
                if os.path.exists(dest_ext):
                    os.remove(dest_ext)
                os.replace(downloaded, dest_ext)
'''

NEW_REPLACE = '''            if os.path.abspath(downloaded) != os.path.abspath(dest_ext):
                dest_ext = _promote_or_dedup_asin(downloaded, dest_ext)
            else:
                dest_ext = downloaded
'''

OLD_RETURN = '''            fmt = ext.replace(".", "")
            return DownloadResult.ok(self.name, dest_ext, fmt=fmt)
'''

NEW_RETURN = '''            _finalize_tagged_download(
                dest_ext,
                getattr(metadata, "title", "") or "",
                getattr(metadata, "artists", "") or "",
            )

            fmt = ext.replace(".", "")
            return DownloadResult.ok(self.name, dest_ext, fmt=fmt)
'''


def patch(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if "_promote_or_dedup_asin" in text:
        print(f"already patched: {path}")
        return

    # Insert helpers after imports / before AmazonProvider class.
    marker = "\nclass AmazonProvider(BaseProvider):"
    if marker not in text:
        raise SystemExit(f"AmazonProvider class not found in {path}")
    text = text.replace(marker, "\n" + HELPERS + marker, 1)

    old_ident = '''            if await asyncio.to_thread(self._file_exists, dest):
                return DownloadResult.skipped_result(self.name, str(dest))
'''
    if old_ident not in text:
        raise SystemExit("skip-exists block not found")
    text = text.replace(old_ident, IDENTITY_INSERT, 1)

    if OLD_REPLACE not in text:
        raise SystemExit("os.replace block not found")
    text = text.replace(OLD_REPLACE, NEW_REPLACE, 1)

    if OLD_RETURN not in text:
        raise SystemExit("ok return block not found")
    text = text.replace(OLD_RETURN, NEW_RETURN, 1)

    path.write_text(text, encoding="utf-8")
    print(f"patched: {path}")


def main() -> int:
    roots = [
        Path(sys.prefix) / "lib",
        Path("/usr/local/lib"),
    ]
    matches: list[Path] = []
    seen: set[Path] = set()
    for root in roots:
        for m in root.glob("python*/site-packages/SpotiFLAC/providers/amazon.py"):
            resolved = m.resolve()
            if resolved in seen:
                continue
            seen.add(resolved)
            matches.append(m)
    if not matches:
        print("SpotiFLAC amazon.py not found", file=sys.stderr)
        return 1
    for m in matches:
        patch(m)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
