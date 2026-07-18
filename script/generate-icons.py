#!/usr/bin/env python3
"""Generate the Understudy desktop icon set from the brand mark.

Brand source: the-understudy-co/BRAND.md — one filled ink triangle (the
understudy, ready) on the ochre stage line, on the warm stage background.
Geometry lifted from assets/mark.svg (viewBox 512):
  triangle (256,96)-(452,392)-(60,392)  ink   #141210
  stage line x60 y428 w392 h24          ochre #D98E32
  background (stage)                    cream #F7F3EC

Channel accents (distinguish installs, all brand palette):
  prod  -> ochre  #D98E32
  beta  -> clay   #A6452C
  dev   -> indigo #232A4D

Usage: python3 script/generate-icons.py
Walks packages/desktop/icons/{prod,beta,dev} for every .png, renders the
mark at the SAME pixel dimensions under assets/icons/<channel>/ (mirroring
relative paths), plus icon.ico (multi-size) and icon.icns (via iconutil,
macOS). Outputs are committed; the transform script copies them over
packages/desktop/icons/ at build time.
"""

import os
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "packages", "desktop", "icons")
OUT = os.path.join(ROOT, "assets", "icons")

INK = (0x14, 0x12, 0x10, 255)
STAGE = (0xF7, 0xF3, 0xEC, 255)
ACCENT = {
    "prod": (0xD9, 0x8E, 0x32, 255),  # ochre
    "beta": (0xA6, 0x45, 0x2C, 255),  # clay
    "dev": (0x23, 0x2A, 0x4D, 255),   # indigo
}

# Windows tile assets are square-edged; everything else gets the modern
# rounded-square app-icon treatment.
SQUARE_EDGED = ("Square", "StoreLogo")


def render(size: int, accent, rounded: bool) -> Image.Image:
    # Draw at 4x and downsample for clean edges.
    s = size * 4
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    radius = int(s * 0.225) if rounded else 0
    d.rounded_rectangle([0, 0, s - 1, s - 1], radius=radius, fill=STAGE)

    # mark.svg geometry, scaled from the 512 viewBox.
    k = s / 512
    d.polygon(
        [(256 * k, 96 * k), (452 * k, 392 * k), (60 * k, 392 * k)],
        fill=INK,
    )
    d.rectangle([60 * k, 428 * k, (60 + 392) * k, (428 + 24) * k], fill=accent)

    return img.resize((size, size), Image.LANCZOS)


def main() -> int:
    if not os.path.isdir(SRC):
        print(f"missing {SRC}", file=sys.stderr)
        return 1
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)

    for channel, accent in ACCENT.items():
        src_dir = os.path.join(SRC, channel)
        out_dir = os.path.join(OUT, channel)
        count = 0

        for dirpath, _dirs, files in os.walk(src_dir):
            for name in files:
                if not name.endswith(".png"):
                    continue
                rel = os.path.relpath(os.path.join(dirpath, name), src_dir)
                with Image.open(os.path.join(dirpath, name)) as ref:
                    w, h = ref.size
                rounded = not os.path.basename(rel).startswith(SQUARE_EDGED)
                icon = render(max(w, h), accent, rounded)
                if (w, h) != icon.size:  # non-square ref: letterbox on transparent
                    canvas = Image.new("RGBA", (w, h), (0, 0, 0, 0))
                    canvas.paste(icon.resize((min(w, h),) * 2, Image.LANCZOS),
                                 ((w - min(w, h)) // 2, (h - min(w, h)) // 2))
                    icon = canvas
                dest = os.path.join(out_dir, rel)
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                icon.save(dest)
                count += 1

        # icon.ico — multi-size, PIL assembles it.
        ico_sizes = [16, 24, 32, 48, 64, 128, 256]
        render(256, accent, True).save(
            os.path.join(out_dir, "icon.ico"),
            sizes=[(x, x) for x in ico_sizes],
        )

        # icon.icns — via iconutil (macOS).
        with tempfile.TemporaryDirectory() as tmp:
            iconset = os.path.join(tmp, "icon.iconset")
            os.makedirs(iconset)
            for pt in (16, 32, 128, 256, 512):
                render(pt, accent, True).save(f"{iconset}/icon_{pt}x{pt}.png")
                render(pt * 2, accent, True).save(f"{iconset}/icon_{pt}x{pt}@2x.png")
            subprocess.run(
                ["iconutil", "-c", "icns", iconset, "-o",
                 os.path.join(out_dir, "icon.icns")],
                check=True,
            )

        print(f"{channel}: {count} png + icon.ico + icon.icns")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
