#!/usr/bin/env python3
"""Draws jellymc's icon: mostly black, a deep navy at the top as the Music app's has its
dark red, and the play mark in the blue accent (purple into sky blue), with a faint glow.

    python3 tools/icon/make-icon.py

Writes the iPhone's 1024 px icon (full square: iOS rounds it) and the Linux sizes,
rounded as the Music app's are: a 32 px margin at 512 px and corners about a fifth of
the width. Needs Pillow and NumPy.
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
S = 4096  # drawn large and scaled down, for clean edges
PURPLE = np.array([106, 43, 217], np.float32)
BLUE = np.array([14, 165, 233], np.float32)


def art() -> Image.Image:
    y, x = np.mgrid[0:S, 0:S].astype(np.float32) / S
    # Navy at the top into black, lit a little behind the mark.
    top, bottom = np.array([25, 39, 80], np.float32), np.array([8, 10, 16], np.float32)
    fade = np.clip(y * 1.15, 0, 1)[..., None] ** 0.9
    background = top * (1 - fade) + bottom * fade
    centre = np.sqrt((x - 0.5) ** 2 + (y - 0.48) ** 2)[..., None]
    background += np.clip(0.35 - centre, 0, None) * np.array([13, 23, 43], np.float32)

    k = S / 1024
    triangle = [(338 * k, 298 * k), (765 * k, 512 * k), (338 * k, 726 * k)]
    # Corner to corner across the mark: purple at its top left, sky blue at its point.
    t = np.clip(((x - 338 / 1024) + (y - 298 / 1024)) / ((765 - 338 + 726 - 298) / 1024), 0, 1)[..., None]
    fill = PURPLE * (1 - t) ** 1.2 + BLUE * (1 - (1 - t) ** 1.2)

    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).polygon(triangle, fill=255)
    glow = np.asarray(mask.filter(ImageFilter.GaussianBlur(S * 0.06)), np.float32)[..., None] / 255 * 0.38
    inside = np.asarray(mask, np.float32)[..., None] / 255
    out = background * (1 - glow) + BLUE * glow
    out = out * (1 - inside) + fill * inside
    return Image.fromarray(np.clip(out, 0, 255).astype(np.uint8), "RGB")


def rounded(square: Image.Image) -> Image.Image:
    """The Music app's shape: inset 1/16 on each side, corners a fifth of the width."""
    margin = S // 16
    side = S - 2 * margin
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shape = Image.new("L", (S, S), 0)
    ImageDraw.Draw(shape).rounded_rectangle((margin, margin, margin + side - 1, margin + side - 1), radius=int(side * 0.208), fill=255)
    canvas.paste(square.resize((side, side), Image.LANCZOS), (margin, margin))
    canvas.putalpha(shape)
    return canvas


def main() -> None:
    square = art()
    square.resize((1024, 1024), Image.LANCZOS).save(ROOT / "App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png", optimize=True)
    linux = rounded(square)
    for size in (64, 128, 256, 512):
        path = ROOT / f"Linux/Resources/icons/hicolor/{size}x{size}/apps/com.milescoviello.jellymc.png"
        linux.resize((size, size), Image.LANCZOS).save(path, optimize=True)
    print("written")


if __name__ == "__main__":
    main()
