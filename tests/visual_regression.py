"""Layer-4 visual-regression harness for the SDL2 UI (see the sdl2-ui-debug-qa skill).

The repo's primary oracle is semantic state (screendump/soundstate/…), NOT pixels —
see the note in driver.d's ``screendump``.  This harness is deliberately the
*tolerance-based* counterpart the skill prescribes, never an exact-match golden diff:

- Baselines live in ``tests/baselines/<name>.png`` and are compared with a
  perceptual tolerance (a small fraction of pixels may differ by a small amount),
  so font hinting / rounding drift does not cause flakes.
- Run with ``CCUTTER_UPDATE_BASELINES=1`` to (re)generate baselines instead of asserting.
- On mismatch the actual + a diff mask are written under ``tests/_artifacts/`` for
  CI upload, so a failure is diagnosable rather than a bare red X.

Because pixels come from the app's own integer software framebuffer under
``SDL_VIDEODRIVER=dummy`` (not the platform GL stack), baselines are reproducible
across machines; generate and check them on the same OS the CI job runs on.
"""

from __future__ import annotations

import os
import struct
import subprocess
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / "ccdriver"
BASELINE_DIR = Path(__file__).resolve().parent / "baselines"
ARTIFACT_DIR = Path(__file__).resolve().parent / "_artifacts"

# Tolerance knobs (generous by design — see module docstring / skill anti-patterns).
# A pixel "differs" when any channel is off by more than CHANNEL_DELTA; the frames
# mismatch when more than DIFF_FRACTION of pixels differ.
CHANNEL_DELTA = int(os.environ.get("CCUTTER_VR_CHANNEL_DELTA", "16"))
DIFF_FRACTION = float(os.environ.get("CCUTTER_VR_DIFF_FRACTION", "0.005"))
UPDATE = os.environ.get("CCUTTER_UPDATE_BASELINES") == "1"
# Instrumented (ASan) runs are slower; the sanitizer job scales the capture
# timeout via CCDRIVER_TIMEOUT_SCALE (default 1.0).
TIMEOUT_SCALE = float(os.environ.get("CCDRIVER_TIMEOUT_SCALE", "1"))


def read_png_rgb(path: Path) -> tuple[int, int, list[bytearray]]:
    """Minimal stdlib PNG reader for ccdriver's non-interlaced 8-bit RGB screenshots."""
    data = Path(path).read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise AssertionError(f"not a PNG: {path}")
    pos, packed = 8, bytearray()
    width = height = 0
    while pos < len(data):
        size = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        payload = data[pos + 8:pos + 8 + size]
        pos += size + 12
        if kind == b"IHDR":
            width, height, depth, color_type, _, _, interlace = struct.unpack(
                ">IIBBBBB", payload
            )
            if depth != 8 or color_type != 2 or interlace != 0:
                raise AssertionError("ccdriver screenshot must be 8-bit RGB/non-interlaced")
        elif kind == b"IDAT":
            packed.extend(payload)
        elif kind == b"IEND":
            break
    raw = zlib.decompress(packed)
    stride, bpp = width * 3, 3
    rows: list[bytearray] = []
    previous = bytearray(stride)
    offset = 0
    for _ in range(height):
        filter_type = raw[offset]
        offset += 1
        current = bytearray(raw[offset:offset + stride])
        offset += stride
        for index in range(stride):
            left = current[index - bpp] if index >= bpp else 0
            above = previous[index]
            upper_left = previous[index - bpp] if index >= bpp else 0
            if filter_type == 1:
                current[index] = (current[index] + left) & 0xFF
            elif filter_type == 2:
                current[index] = (current[index] + above) & 0xFF
            elif filter_type == 3:
                current[index] = (current[index] + (left + above) // 2) & 0xFF
            elif filter_type == 4:
                estimate = left + above - upper_left
                distances = (
                    abs(estimate - left), abs(estimate - above), abs(estimate - upper_left)
                )
                predictor = (left, above, upper_left)[distances.index(min(distances))]
                current[index] = (current[index] + predictor) & 0xFF
            elif filter_type != 0:
                raise AssertionError(f"unsupported PNG filter {filter_type}")
        rows.append(current)
        previous = current
    return width, height, rows


def _write_png_rgb(path: Path, width: int, height: int, rows: list[bytearray]) -> None:
    """Write 8-bit RGB rows back to a PNG (filter 0), for baselines/diff artifacts."""
    raw = bytearray()
    for row in rows:
        raw.append(0)
        raw.extend(row)

    def chunk(kind: bytes, payload: bytes) -> bytes:
        body = kind + payload
        return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body))

    path.parent.mkdir(parents=True, exist_ok=True)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )


def capture_screenshot(out_path: Path, *commands: str, timeout: int = 30) -> Path:
    """Drive ccdriver through ``commands`` and write a screenshot to ``out_path``."""
    out_path.parent.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update(SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
    proc = subprocess.run(
        [str(DRIVER), *commands, f"shot:{out_path}"],
        cwd=ROOT, env=env, text=True, capture_output=True, timeout=timeout * TIMEOUT_SCALE,
    )
    if proc.returncode != 0 or not out_path.exists():
        raise RuntimeError(
            f"ccdriver failed to capture {out_path.name} (exit {proc.returncode})\n{proc.stderr}"
        )
    return out_path


def compare_to_baseline(name: str, actual_png: Path) -> tuple[bool, str]:
    """Compare ``actual_png`` to baseline ``name``.

    Returns ``(ok, message)``.  In UPDATE mode (or when the baseline is missing)
    the baseline is (re)written and the call passes.  On a real mismatch the diff
    mask + actual are dropped in ARTIFACT_DIR and ``ok`` is False.
    """
    baseline = BASELINE_DIR / f"{name}.png"
    if UPDATE or not baseline.exists():
        width, height, rows = read_png_rgb(actual_png)
        _write_png_rgb(baseline, width, height, rows)
        verb = "refreshed" if UPDATE else "created (was missing)"
        return True, f"baseline {name!r} {verb}"

    bw, bh, brows = read_png_rgb(baseline)
    aw, ah, arows = read_png_rgb(actual_png)
    if (bw, bh) != (aw, ah):
        return False, f"{name}: size {aw}x{ah} != baseline {bw}x{bh}"

    stride = bw * 3
    differing = 0
    diff_rows = [bytearray(stride) for _ in range(bh)]
    for y in range(bh):
        arow, brow = arows[y], brows[y]
        drow = diff_rows[y]
        for x in range(bw):
            i = x * 3
            dr = abs(arow[i] - brow[i])
            dg = abs(arow[i + 1] - brow[i + 1])
            db = abs(arow[i + 2] - brow[i + 2])
            if max(dr, dg, db) > CHANNEL_DELTA:
                differing += 1
                drow[i] = 255  # mark changed pixels red in the diff mask
    total = bw * bh
    fraction = differing / total if total else 0.0
    if fraction > DIFF_FRACTION:
        ARTIFACT_DIR.mkdir(parents=True, exist_ok=True)
        _write_png_rgb(ARTIFACT_DIR / f"{name}.actual.png", aw, ah, arows)
        _write_png_rgb(ARTIFACT_DIR / f"{name}.diff.png", bw, bh, diff_rows)
        return False, (
            f"{name}: {fraction:.3%} of pixels differ by >{CHANNEL_DELTA} "
            f"(limit {DIFF_FRACTION:.3%}); artifacts in {ARTIFACT_DIR}"
        )
    return True, f"{name}: {fraction:.3%} differing (<= {DIFF_FRACTION:.3%})"
