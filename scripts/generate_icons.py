#!/usr/bin/env python3
"""
SparkRPGM icon generator.

Renders the single matte-black Spark app icon and writes a complete
`AppIcon.appiconset` (iPhone + iPad + marketing sizes) into
`SparkRPGM/Resources/Assets.xcassets`.

Alternate icons are gone on purpose: TrollStore on iPadOS 15 answers
`UIApplication.setAlternateIconName` with OSStatus -54, so the build ships one
icon and `Info.plist` no longer carries `CFBundleAlternateIcons`.

Usage:
    python scripts/generate_icons.py [--repo-root .]

Requires Pillow. The GitHub Actions workflow installs it in a venv.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys

try:
    from PIL import Image, ImageDraw
except ImportError:  # pragma: no cover - handled with a clear message
    sys.stderr.write("Pillow is required: python -m pip install pillow\n")
    raise

# iPhone + iPad app icon sizes (base points, scale)
IPHONE_SIZES = [(20, 2), (20, 3), (29, 2), (29, 3), (40, 2), (40, 3), (60, 2), (60, 3)]
IPAD_SIZES = [(20, 1), (20, 2), (29, 1), (29, 2), (40, 1), (40, 2), (76, 1), (76, 2), (83.5, 2)]
MARKETING_SIZE = (1024, 1)

SUPERSAMPLE = 2

# ---------------------------------------------------------------------------
# Palette helpers
# ---------------------------------------------------------------------------


def rgb(hex_value: str) -> tuple:
    value = hex_value.lstrip("#")
    return (int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16))


def flat_canvas(size: int, colour: tuple) -> Image.Image:
    return Image.new("RGBA", (size, size), colour + (255,))


# ---------------------------------------------------------------------------
# Emblem
# ---------------------------------------------------------------------------


def star_polygon(cx: float, cy: float, outer: float, inner: float, points: int = 4):
    pts = []
    for i in range(points * 2):
        r = outer if i % 2 == 0 else inner
        angle = math.pi * 2 * i / (points * 2) - math.pi / 2
        pts.append((cx + r * math.cos(angle), cy + r * math.sin(angle)))
    return pts


def draw_star(
    draw: ImageDraw.ImageDraw,
    cx: float,
    cy: float,
    outer: float,
    inner: float,
    fill: tuple,
):
    draw.polygon(star_polygon(cx, cy, outer, inner), fill=fill + (255,))


def draw_emblem(draw: ImageDraw.ImageDraw, size: int, fill: tuple, scale: float = 1.0):
    """Four-point Spark star plus the secondary star and dot."""
    cx = cy = size * 0.5

    draw_star(draw, cx, cy, size * 0.335 * scale, size * 0.104 * scale, fill)
    draw_star(
        draw,
        size * 0.735,
        size * 0.255,
        size * 0.103 * scale,
        size * 0.031 * scale,
        fill,
    )

    dot_r = size * 0.021 * scale
    dx, dy = size * 0.262, size * 0.752
    draw.ellipse([dx - dot_r, dy - dot_r, dx + dot_r, dy + dot_r], fill=fill + (255,))


# ---------------------------------------------------------------------------
# Renderer: one flat matte-black icon with the white Spark
# ---------------------------------------------------------------------------


def render_appicon(size: int) -> Image.Image:
    base = flat_canvas(size, rgb("#0B0B0D"))
    draw = ImageDraw.Draw(base, "RGBA")
    draw_emblem(draw, size, rgb("#FFFFFF"))
    return base


def render_icon() -> Image.Image:
    size = 1024 * SUPERSAMPLE
    img = render_appicon(size)
    return img.convert("RGB").resize((1024, 1024), Image.LANCZOS)


# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------


def write_image(img: Image.Image, path: str, pixel_size: int):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if pixel_size == img.width:
        out = img
    else:
        out = img.resize((pixel_size, pixel_size), Image.LANCZOS)
    out.save(path, format="PNG", optimize=True)


def contents_json(images: list) -> dict:
    return {
        "images": images,
        "info": {"author": "sparkrpgm", "version": 1},
    }


def build_appiconset(assets_root: str, base_img: Image.Image):
    set_name = "AppIcon"
    folder = os.path.join(assets_root, f"{set_name}.appiconset")

    if os.path.isdir(folder):
        for name in os.listdir(folder):
            path = os.path.join(folder, name)
            if os.path.isfile(path):
                os.remove(path)
    else:
        os.makedirs(folder, exist_ok=True)

    images = []

    def add(idiom: str, points: float, scale: int):
        if float(points).is_integer():
            size_str = f"{int(points)}x{int(points)}"
        else:
            size_str = f"{points}x{points}"
        filename = f"{set_name}-{idiom}-{size_str}@{scale}x.png"
        pixels = int(round(points * scale))
        write_image(base_img, os.path.join(folder, filename), pixels)
        images.append({
            "size": size_str,
            "idiom": idiom,
            "filename": filename,
            "scale": f"{scale}x",
        })

    for points, scale in IPHONE_SIZES:
        add("iphone", points, scale)
    for points, scale in IPAD_SIZES:
        add("ipad", points, scale)
    add("ios-marketing", MARKETING_SIZE[0], MARKETING_SIZE[1])

    with open(os.path.join(folder, "Contents.json"), "w", encoding="utf-8") as fh:
        json.dump(contents_json(images), fh, indent=2, sort_keys=False)
        fh.write("\n")


def prune_legacy_assets(assets_root: str, preview_root: str, icon_root: str):
    """Removes alternate icon sets, picker previews and loose bundle PNGs."""
    keep_sets = {"AppIcon.appiconset", "AccentColor.colorset"}

    for entry in os.listdir(assets_root):
        if not entry.endswith(".appiconset") or entry in keep_sets:
            continue
        folder = os.path.join(assets_root, entry)
        for name in os.listdir(folder):
            os.remove(os.path.join(folder, name))
        os.rmdir(folder)

    for legacy in (preview_root, icon_root):
        if not os.path.isdir(legacy):
            continue
        for name in os.listdir(legacy):
            path = os.path.join(legacy, name)
            if os.path.isfile(path):
                os.remove(path)
        try:
            os.rmdir(legacy)
        except OSError:
            pass


def ensure_catalog_skeleton(assets_root: str):
    os.makedirs(assets_root, exist_ok=True)
    catalog_contents = os.path.join(assets_root, "Contents.json")
    if not os.path.exists(catalog_contents):
        with open(catalog_contents, "w", encoding="utf-8") as fh:
            json.dump({"info": {"author": "xcode", "version": 1}}, fh, indent=2)
            fh.write("\n")

    accent_dir = os.path.join(assets_root, "AccentColor.colorset")
    os.makedirs(accent_dir, exist_ok=True)
    accent = {
        "colors": [
            {
                "idiom": "universal",
                "color": {
                    "color-space": "srgb",
                    "components": {
                        "red": "0.427",
                        "green": "0.357",
                        "blue": "1.000",
                        "alpha": "1.000",
                    },
                },
            }
        ],
        "info": {"author": "xcode", "version": 1},
    }
    with open(os.path.join(accent_dir, "Contents.json"), "w", encoding="utf-8") as fh:
        json.dump(accent, fh, indent=2)
        fh.write("\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", default=".")
    args = parser.parse_args()

    repo_root = os.path.abspath(args.repo_root)
    assets_root = os.path.join(repo_root, "SparkRPGM", "Resources", "Assets.xcassets")
    preview_root = os.path.join(repo_root, "SparkRPGM", "Resources", "IconPreviews")
    icon_root = os.path.join(repo_root, "SparkRPGM", "Resources", "IconAssets")

    ensure_catalog_skeleton(assets_root)
    prune_legacy_assets(assets_root, preview_root, icon_root)

    print("Rendering AppIcon ...")
    build_appiconset(assets_root, render_icon())

    print(f"Done. Assets: {assets_root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
