#!/usr/bin/env python3
"""Adapt white-on-transparent glyph PNGs into the icon pipeline.

For each input glyph:
- trim to its alpha bounding box and center-fit at GLYPH_FRACTION of the tile
- composite onto the Icon Composer dark gradient (glyph stays white)
- composite onto the proposed light gradient (glyph tinted dark via its alpha)

Usage: make-icon-tiles.py <glyph-dir> <out-dir> [size]
Writes <name>-dark.png and <name>-light.png per glyph.
"""

import sys
from pathlib import Path

from PIL import Image

GLYPH_FRACTION = 0.68
DARK_TOP, DARK_BOTTOM = (10, 14, 20), (30, 42, 58)
LIGHT_TOP, LIGHT_BOTTOM = (255, 255, 255), (221, 229, 240)
LIGHT_GLYPH = (24, 34, 48)


def gradient(size, top, bottom):
    tile = Image.new('RGBA', (size, size))
    for y in range(size):
        t = y / max(size - 1, 1)
        row = tuple(round(a + (b - a) * t) for a, b in zip(top, bottom))
        for x in range(size):
            tile.putpixel((x, y), row + (255,))
    return tile


def fit_glyph(img, size):
    alpha = img.getchannel('A')
    bbox = alpha.getbbox()
    if not bbox:
        return None
    glyph = img.crop(bbox)
    target = int(size * GLYPH_FRACTION)
    scale = min(target / glyph.width, target / glyph.height)
    glyph = glyph.resize(
        (max(1, round(glyph.width * scale)), max(1, round(glyph.height * scale))),
        Image.LANCZOS,
    )
    return glyph


def tint(glyph, rgb):
    out = Image.new('RGBA', glyph.size, rgb + (0,))
    out.putalpha(glyph.getchannel('A'))
    return out


def main():
    src, out = Path(sys.argv[1]), Path(sys.argv[2])
    size = int(sys.argv[3]) if len(sys.argv) > 3 else 512
    out.mkdir(parents=True, exist_ok=True)

    dark = gradient(size, DARK_TOP, DARK_BOTTOM)
    light = gradient(size, LIGHT_TOP, LIGHT_BOTTOM)

    for path in sorted(src.glob('*.png')):
        img = Image.open(path).convert('RGBA')
        glyph = fit_glyph(img, size)
        if glyph is None:
            print(f'skip (empty): {path.name}')
            continue
        pos = ((size - glyph.width) // 2, (size - glyph.height) // 2)

        tile = dark.copy()
        tile.alpha_composite(glyph, pos)
        tile.save(out / f'{path.stem}-dark.png')

        tile = light.copy()
        tile.alpha_composite(tint(glyph, LIGHT_GLYPH), pos)
        tile.save(out / f'{path.stem}-light.png')
        print(f'ok: {path.stem}')


if __name__ == '__main__':
    main()
