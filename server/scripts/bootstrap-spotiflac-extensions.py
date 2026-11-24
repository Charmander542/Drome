#!/usr/bin/env python3
"""Install Mornye provider extensions from configured registries.

Mornye (and SpotiFLAC 5+) ship with no download providers. Drome needs at
least one extension (typically tidal-web) plus the python utilities package
for the Chromium Turnstile solver.
"""
from __future__ import annotations

import os
import sys

DEFAULT_EXTS = ("utilities", "tidal-web", "qobuz-web", "amazon", "deezer")


def _extension_manager():
    try:
        from mornye.extensions.manager import ExtensionManager

        return ExtensionManager()
    except Exception as mornye_exc:  # pragma: no cover
        try:
            from SpotiFLAC.extensions.manager import ExtensionManager

            return ExtensionManager()
        except Exception as spoti_exc:  # pragma: no cover
            raise RuntimeError(
                f"Mornye ExtensionManager unavailable ({mornye_exc}); "
                f"SpotiFLAC fallback also failed ({spoti_exc})"
            ) from spoti_exc


def main() -> int:
    raw = (
        os.environ.get("MORNYE_REGISTRIES", "").strip()
        or os.environ.get("SPOTIFLAC_REGISTRIES", "").strip()
    )
    if not raw:
        print(
            "MORNYE_REGISTRIES / SPOTIFLAC_REGISTRIES unset — skipping extension bootstrap",
            file=sys.stderr,
        )
        return 0

    registries = [u.strip() for u in raw.split(",") if u.strip()]
    wanted = [
        e.strip()
        for e in os.environ.get(
            "DROME_SPOTIFLAC_EXTENSIONS", ",".join(DEFAULT_EXTS)
        ).split(",")
        if e.strip()
    ]

    try:
        em = _extension_manager()
    except Exception as exc:  # pragma: no cover
        print(f"extension manager unavailable: {exc}", file=sys.stderr)
        return 1

    ok = 0
    for ext_id in wanted:
        last_err: Exception | None = None
        for reg in registries:
            try:
                em.install(ext_id, registry_url=reg)
                print(f"installed/updated {ext_id} from {reg}")
                ok += 1
                last_err = None
                break
            except Exception as exc:  # noqa: BLE001 — try next registry
                last_err = exc
        if last_err is not None:
            print(f"failed {ext_id}: {last_err}", file=sys.stderr)

    installed = []
    try:
        installed = [
            getattr(x, "name", None) or getattr(x, "id", str(x))
            for x in em.list_installed()
        ]
    except Exception:
        pass
    print(f"bootstrap done ({ok}/{len(wanted)}); installed={installed}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
