#!/usr/bin/env python3
"""Generate Trans2.app's icon from code.

Minimal mark: a sound wave that settles into a subtitle line, with a second
translated line underneath and a coral full stop.

Run from the repo root: python3 tools/gen_icon.py
Writes Sources/Trans2/Resources/AppIcon.icns and docs/icon.png.
"""
from __future__ import annotations

import math
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
ICNS = ROOT / "Sources" / "Trans2" / "Resources" / "AppIcon.icns"
PREVIEW = ROOT / "docs" / "icon.png"

S = 2048
RADIUS = 458

INK = (247, 248, 255, 255)
MUTED = (168, 174, 194, 255)
CORAL = (255, 122, 89, 255)
NAVY_TOP = (17, 22, 42)
NAVY_BOTTOM = (26, 33, 64)


def rounded_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return mask


def background(size: int) -> Image.Image:
    return Image.new("RGB", (size, size), NAVY_TOP)


def smoothstep(edge0: float, edge1: float, x: float) -> float:
    t = min(max((x - edge0) / (edge1 - edge0), 0.0), 1.0)
    return t * t * (3 - 2 * t)


def main() -> None:
    # Full-bleed on purpose: macOS 26+ puts icons that keep a transparent
    # margin on a white system plate, which reads as a white border in the
    # Dock. Filling the canvas lets the system mask the squircle itself.
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    squircle = background(S)
    squircle.putalpha(rounded_mask(S, RADIUS))
    canvas.alpha_composite(squircle)

    draw = ImageDraw.Draw(canvas)

    def dot(x: float, y: float, r: float, fill) -> None:
        draw.ellipse((x - r, y - r, x + r, y + r), fill=fill)

    stroke = 105
    # Main line: waveform on the left, settling into a straight subtitle line.
    x0, x1 = 349, 1458
    yc = 971
    amp = 195
    points: list[tuple[float, float]] = []
    for i in range(181):
        t = i / 180
        x = x0 + (x1 - x0) * t
        envelope = 1.0 - smoothstep(0.42, 0.78, t)
        y = yc + amp * math.sin(t * 3.1 * 2 * math.pi) * envelope
        points.append((x, y))
    draw.line(points, fill=INK, width=stroke, joint="curve")
    # Round every joint: Pillow's joint="curve" still leaves hairline gaps on
    # tight turns, which look like scratches at icon sizes.
    for x, y in points:
        dot(x, y, stroke / 2, INK)

    # Second line: the translated subtitle.
    line2_y = 1273
    lx0, lx1 = 580, 1458
    draw.line((lx0, line2_y, lx1, line2_y), fill=MUTED, width=stroke)
    dot(lx0, line2_y, stroke / 2, MUTED)
    dot(lx1, line2_y, stroke / 2, MUTED)

    # Coral full stop, the one accent.
    dot(1628, 971, 71, CORAL)

    master = canvas.resize((1024, 1024), Image.LANCZOS)
    master.save(PREVIEW)

    iconset = ROOT / "build" / "AppIcon.iconset"
    if iconset.exists():
        for child in iconset.iterdir():
            child.unlink()
    iconset.mkdir(parents=True, exist_ok=True)
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = size * scale
            name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
            master.resize((pixels, pixels), Image.LANCZOS).save(iconset / name)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(ICNS)], check=True)
    print(f"wrote {ICNS.relative_to(ROOT)} and {PREVIEW.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
