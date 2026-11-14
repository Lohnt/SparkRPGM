#!/usr/bin/env python3
"""
SparkRPGM icon generator.

Produces fully-populated .appiconset bundles (iPhone + iPad + marketing sizes)
for the primary icon and the five alternate icons, plus 1024x1024 preview PNGs
used by the in-app App Icon picker.

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
    from PIL import Image, ImageDraw, ImageFilter
except ImportError:  # pragma: no cover - handled with a clear message
    sys.stderr.write("Pillow is required: python -m pip install pillow\n")
    raise

# ---------------------------------------------------------------------------
# Palettes: (top colour, bottom colour, spark colour, glow colour, style)
# ---------------------------------------------------------------------------
ICON_SETS = [
    ("AppIcon", "Default", (0x6D, 0x5B, 0xFF), (0x2A, 0x1A, 0x6B), (0xFF, 0xFF, 0xFF), (0xA9, 0x8B, 0xFF), "spark"),
    ("IconMidnight", "Midnight", (0x10, 0x2A, 0x43), (0x03, 0x08, 0x14), (0x6C, 0xE7, 0xFF), (0x2A, 0xC7, 0xE8), "spark"),
    ("IconRetro", "Retro", (0xFF, 0x8A, 0x3D), (0xB3, 0x23, 0x6B), (0xFF, 0xF3, 0xD6), (0xFF, 0xD1, 0x66), "pixel"),
    ("IconCrimson", "Crimson", (0x8E, 0x12, 0x2B), (0x33, 0x03, 0x0B), (0xFF, 0xD2, 0x6E), (0xFF, 0x6B, 0x4F), "spark"),
    ("IconNeon", "Neon", (0x14, 0x00, 0x2B), (0x00, 0x00, 0x00), (0x5B, 0xFF, 0xC4), (0x9B, 0x5B, 0xFF), "grid"),
    ("IconMinimal", "Minimal", (0xF7, 0xF7, 0xFA), (0xD9, 0xDB, 0xE3), (0x1C, 0x1D, 0x24), (0x9A, 0x9C, 0xAB), "minimal"),
]

# iPhone + iPad app icon sizes (base points, scale)
IPHONE_SIZES = [(20, 2), (20, 3), (29, 2), (29, 3), (40, 2), (40, 3), (60, 2), (60, 3)]
IPAD_SIZES = [(20, 1), (20, 2), (29, 1), (29, 2), (40, 1), (40, 2), (76, 1), (76, 2), (83.5, 2)]
MARKETING_SIZE = (1024, 1)

SUPERSAMPLE = 2


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def vertical_gradient(size: int, top: tuple, bottom: tuple) -> Image.Image:
    """Linear top->bottom gradient with a subtle diagonal light sweep.

    The vertical ramp is built as a 1xN strip and stretched, which keeps the
    generator fast enough to run inside CI. The diagonal sheen is a second
    low-resolution ramp that is upscaled and blended on top.
    """
    strip = Image.new("RGB", (1, size))
    px = strip.load()
    for y in range(size):
        t = y / max(1, size - 1)
        tt = t ** 0.85
        px[0, y] = (
            int(lerp(top[0], bottom[0], tt)),
            int(lerp(top[1], bottom[1], tt)),
            int(lerp(top[2], bottom[2], tt)),
        )
    img = strip.resize((size, size), Image.BILINEAR)

    # Diagonal sheen: bright top-left, transparent bottom-right.
    ramp_w = 256
    ramp = Image.new("L", (ramp_w, ramp_w))
    rpx = ramp.load()
    for y in range(ramp_w):
        for x in range(ramp_w):
            d = (x / ramp_w) * 0.55 + (1.0 - y / ramp_w) * 0.45
            rpx[x, y] = int(max(0.0, min(1.0, d)) * 26)
    sheen = Image.new("RGB", (size, size), (255, 255, 255))
    img = Image.composite(sheen, img, ramp.resize((size, size), Image.BICUBIC))
    return img


def radial_glow(size: int, colour: tuple, alpha: int, radius_factor: float) -> Image.Image:
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    cx = size * 0.5
    cy = size * 0.46
    max_r = size * radius_factor
    steps = 48
    for i in range(steps, 0, -1):
        t = i / steps
        r = max_r * t
        a = int(alpha * (1.0 - t) ** 1.6)
        draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=colour + (a,))
    return layer.filter(ImageFilter.GaussianBlur(size * 0.02))


def star_polygon(cx: float, cy: float, outer: float, inner: float, points: int = 4, rotation: float = 0.0):
    pts = []
    for i in range(points * 2):
        r = outer if i % 2 == 0 else inner
        angle = math.pi * 2 * i / (points * 2) - math.pi / 2 + rotation
        pts.append((cx + r * math.cos(angle), cy + r * math.sin(angle)))
    return pts


def draw_spark(draw: ImageDraw.ImageDraw, size: int, colour: tuple, shadow: tuple):
    cx, cy = size * 0.5, size * 0.5
    outer = size * 0.34
    inner = size * 0.105

    # soft shadow under the glyph
    shadow_offset = size * 0.012
    draw.polygon(
        star_polygon(cx + shadow_offset, cy + shadow_offset, outer * 1.01, inner * 1.01),
        fill=shadow + (110,),
    )
    draw.polygon(star_polygon(cx, cy, outer, inner), fill=colour + (255,))

    # secondary sparkle, upper-right
    sx, sy = size * 0.735, size * 0.255
    draw.polygon(star_polygon(sx, sy, size * 0.105, size * 0.032), fill=colour + (235,))
    # tiny dot sparkle, lower-left
    dx, dy = size * 0.265, size * 0.755
    draw.ellipse([dx - size * 0.022, dy - size * 0.022, dx + size * 0.022, dy + size * 0.022],
                 fill=colour + (200,))


def draw_pixel_spark(draw: ImageDraw.ImageDraw, size: int, colour: tuple, shadow: tuple):
    """Chunky 8-bit flavoured spark made of blocks."""
    unit = size / 16.0
    blocks = [
        (7, 1), (8, 1),
        (7, 2), (8, 2),
        (6, 3), (7, 3), (8, 3), (9, 3),
        (5, 4), (6, 4), (7, 4), (8, 4), (9, 4), (10, 4),
        (6, 5), (7, 5), (8, 5), (9, 5),
        (7, 6), (8, 6),
        (7, 7), (8, 7),
        (6, 8), (7, 8), (8, 8), (9, 8),
        (5, 9), (6, 9), (7, 9), (8, 9), (9, 9), (10, 9),
        (6, 10), (7, 10), (8, 10), (9, 10),
        (7, 11), (8, 11),
        (7, 12), (8, 12),
    ]
    ox, oy = unit * 0.2, unit * 0.2
    for (bx, by) in blocks:
        box = [bx * unit + ox, by * unit + oy, (bx + 1) * unit + ox, (by + 1) * unit + oy]
        draw.rectangle(box, fill=shadow + (90,))
    for (bx, by) in blocks:
        box = [bx * unit, by * unit, (bx + 1) * unit - unit * 0.06, (by + 1) * unit - unit * 0.06]
        draw.rectangle(box, fill=colour + (255,))
    # accent pixels
    draw.rectangle([unit * 12.1, unit * 3.1, unit * 13.1, unit * 4.1], fill=colour + (220,))
    draw.rectangle([unit * 2.1, unit * 11.1, unit * 3.1, unit * 12.1], fill=colour + (220,))


def draw_neon_grid(draw: ImageDraw.ImageDraw, size: int, accent: tuple, glow: tuple):
    step = size / 12.0
    for i in range(1, 12):
        a = int(70 * (1.0 - abs(i - 6) / 12.0))
        draw.line([(0, i * step), (size, i * step)], fill=glow + (a,), width=max(1, int(size * 0.004)))
        draw.line([(i * step, 0), (i * step, size)], fill=glow + (a,), width=max(1, int(size * 0.004)))
    draw_spark(draw, size, accent, glow)


def draw_minimal(draw: ImageDraw.ImageDraw, size: int, ink: tuple, muted: tuple):
    margin = size * 0.20
    radius = size * 0.10
    draw.rounded_rectangle(
        [margin, margin, size - margin, size - margin],
        radius=radius,
        outline=muted + (140,),
        width=max(2, int(size * 0.014)),
    )
    draw_spark(draw, size, ink, muted)


def render_icon(top, bottom, spark, glow, style: str) -> Image.Image:
    size = 1024 * SUPERSAMPLE
    base = vertical_gradient(size, top, bottom).convert("RGBA")

    glow_layer = radial_glow(size, spark, 96 if style != "minimal" else 40, 0.62)
    base = Image.alpha_composite(base, glow_layer)

    draw = ImageDraw.Draw(base, "RGBA")
    if style == "pixel":
        draw_pixel_spark(draw, size, spark, glow)
    elif style == "grid":
        draw_neon_grid(draw, size, spark, glow)
    elif style == "minimal":
        draw_minimal(draw, size, spark, glow)
    else:
        draw_spark(draw, size, spark, glow)

    # subtle inner vignette for depth (skip for the flat minimal design)
    if style != "minimal":
        vignette = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        vdraw = ImageDraw.Draw(vignette)
        for i in range(28):
            t = i / 28.0
            r = size * (0.72 + 0.30 * t)
            alpha = int(80 * t ** 2)
            vdraw.ellipse([size / 2 - r, size / 2 - r, size / 2 + r, size / 2 + r],
                          outline=(0, 0, 0, 0), width=max(1, int(size * 0.02)))
        base = Image.alpha_composite(base, vignette)

    return base.convert("RGB").resize((1024, 1024), Image.LANCZOS)


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


def build_appiconset(assets_root: str, set_name: str, base_img: Image.Image):
    folder = os.path.join(assets_root, f"{set_name}.appiconset")
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


# Flattened PNGs copied to the app bundle root.
#
# `UIApplication.setAlternateIconName` resolves `CFBundleAlternateIcons` through
# `CFBundleIconFiles` when `CFBundleIconName` is absent. Reading loose PNGs from
# the bundle is far more reliable on iOS 15 / TrollStore than relying on the
# asset catalog, where a missing compiled slot surfaces as OSStatus -54.
BUNDLE_ICON_VARIANTS = [
    (".png", 1024),          # fallback / marketing
    ("@2x.png", 120),        # iPhone
    ("@3x.png", 180),        # iPhone
    ("-76.png", 76),         # iPad
    ("-76@2x.png", 152),     # iPad
    ("-83.5.png", 167),      # iPad Pro
    ("-83.5@2x.png", 167),   # iPad Pro
    ("~ipad.png", 76),       # device-specific aliases
    ("~ipad@2x.png", 152),
    ("~ipad@3x.png", 167),
]


def build_bundle_icons(repo_root: str, set_name: str, base_img: Image.Image):
    folder = os.path.join(repo_root, "SparkRPGM", "Resources", "IconAssets")
    os.makedirs(folder, exist_ok=True)
    for suffix, pixels in BUNDLE_ICON_VARIANTS:
        write_image(base_img, os.path.join(folder, f"{set_name}{suffix}"), pixels)


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
    parser.add_argument("--skip-previews", action="store_true")
    args = parser.parse_args()

    repo_root = os.path.abspath(args.repo_root)
    assets_root = os.path.join(repo_root, "SparkRPGM", "Resources", "Assets.xcassets")
    preview_root = os.path.join(repo_root, "SparkRPGM", "Resources", "IconPreviews")

    ensure_catalog_skeleton(assets_root)
    os.makedirs(preview_root, exist_ok=True)

    for set_name, label, top, bottom, spark, glow, style in ICON_SETS:
        print(f"Rendering {set_name} ({label}) ...")
        img = render_icon(top, bottom, spark, glow, style)
        build_appiconset(assets_root, set_name, img)
        build_bundle_icons(repo_root, set_name, img)
        if not args.skip_previews:
            write_image(img, os.path.join(preview_root, f"Preview{label}.png"), 1024)

    print(f"Done. Assets: {assets_root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
