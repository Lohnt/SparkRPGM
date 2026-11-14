#!/usr/bin/env python3
"""
SparkRPGM icon generator.

Renders ten flat, graphic 2D icons built around the Spark emblem (a four-point
star, a secondary star and a dot), then writes:

* fully-populated `.appiconset` bundles (iPhone + iPad + marketing sizes),
* loose PNGs at the app bundle root (`Resources/IconAssets`) used by
  `UIApplication.setAlternateIconName`,
* 1024x1024 previews for the in-app icon picker.

The loose-PNG export is what keeps alternate-icon switching working on
iOS 15 / TrollStore: `CFBundleAlternateIcons` entries point at plain bundle
files and never at an asset-catalog slot, which is what surfaced
`OSStatus error -54`.

Usage:
    python scripts/generate_icons.py [--repo-root .]

Requires Pillow. The GitHub Actions workflow installs it in a venv.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import random
import sys

try:
    from PIL import Image, ImageChops, ImageDraw
except ImportError:  # pragma: no cover - handled with a clear message
    sys.stderr.write("Pillow is required: python -m pip install pillow\n")
    raise

# ---------------------------------------------------------------------------
# Icon catalogue: (asset set name, picker title, preview file stem, renderer)
# ---------------------------------------------------------------------------

ICON_SETS = [
    ("AppIcon", "Default", "PreviewDefault", "default"),
    ("IconEditor", "Editor", "PreviewEditor", "editor"),
    ("IconOrbit", "Orbit", "PreviewOrbit", "orbit"),
    ("IconVinyl", "Vinyl", "PreviewVinyl", "vinyl"),
    ("IconCosmos", "Cosmos", "PreviewCosmos", "cosmos"),
    ("IconAmethyst", "Amethyst", "PreviewAmethyst", "amethyst"),
    ("IconY2KDisc", "Y2K Disc", "PreviewY2KDisc", "y2k"),
    ("IconCassette", "Cassette", "PreviewCassette", "cassette"),
    ("IconInvincible", "Invincible", "PreviewInvincible", "invincible"),
    ("IconBlueprint", "Blueprint", "PreviewBlueprint", "blueprint"),
]

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


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def flat_canvas(size: int, colour: tuple) -> Image.Image:
    return Image.new("RGBA", (size, size), colour + (255,))


def gradient_canvas(size: int, top: tuple, bottom: tuple) -> Image.Image:
    strip = Image.new("RGB", (1, size))
    px = strip.load()
    for y in range(size):
        t = y / max(1, size - 1)
        px[0, y] = (
            int(lerp(top[0], bottom[0], t)),
            int(lerp(top[1], bottom[1], t)),
            int(lerp(top[2], bottom[2], t)),
        )
    return strip.resize((size, size), Image.BILINEAR).convert("RGBA")


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
    outline: tuple | None = None,
    outline_width: float = 0.0,
):
    if outline is not None and outline_width > 0:
        draw.polygon(
            star_polygon(cx, cy, outer + outline_width, inner + outline_width * 0.55),
            fill=outline + (255,),
        )
    draw.polygon(star_polygon(cx, cy, outer, inner), fill=fill + (255,))


def draw_emblem(
    draw: ImageDraw.ImageDraw,
    size: int,
    fill: tuple,
    outline: tuple | None = None,
    cx: float | None = None,
    cy: float | None = None,
    scale: float = 1.0,
    secondary: bool = True,
    outline_weight: float = 0.012,
):
    """Four-point Spark star plus the secondary star and dot."""
    cx = size * 0.5 if cx is None else cx
    cy = size * 0.5 if cy is None else cy

    outer = size * 0.335 * scale
    inner = size * 0.104 * scale
    outline_width = size * outline_weight * scale

    draw_star(draw, cx, cy, outer, inner, fill, outline, outline_width)

    if not secondary:
        return

    if outline is not None and outline_width > 0:
        draw_star(
            draw,
            size * 0.735,
            size * 0.255,
            size * 0.103 * scale,
            size * 0.031 * scale,
            fill,
            outline,
            outline_width * 0.7,
        )
    else:
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
    if outline is not None and outline_width > 0:
        draw.ellipse(
            [dx - dot_r - outline_width * 0.6, dy - dot_r - outline_width * 0.6,
             dx + dot_r + outline_width * 0.6, dy + dot_r + outline_width * 0.6],
            fill=outline + (255,),
        )
    draw.ellipse([dx - dot_r, dy - dot_r, dx + dot_r, dy + dot_r], fill=fill + (255,))


# ---------------------------------------------------------------------------
# Renderers (all flat: no bevels, no drop shadows, no radial glows)
# ---------------------------------------------------------------------------


def render_default(size: int) -> Image.Image:
    base = flat_canvas(size, rgb("#0B0B0D"))
    draw = ImageDraw.Draw(base, "RGBA")
    draw_emblem(draw, size, rgb("#FFFFFF"))
    return base


def render_editor(size: int) -> Image.Image:
    base = flat_canvas(size, rgb("#141417"))
    draw = ImageDraw.Draw(base, "RGBA")

    # Editorial colour block on the right third.
    split = int(size * 0.63)
    draw.rectangle([split, 0, size, size], fill=rgb("#D9383A") + (255,))
    # Crisp rule separating the two columns.
    rule = max(2, int(size * 0.006))
    draw.rectangle([split - rule, 0, split, size], fill=rgb("#F2F2F4") + (235,))

    # Small masthead marks: two rules above the emblem.
    line_w = max(2, int(size * 0.010))
    draw.rectangle([size * 0.10, size * 0.155, size * 0.36, size * 0.155 + line_w],
                   fill=rgb("#F2F2F4") + (200,))
    draw.rectangle([size * 0.10, size * 0.20, size * 0.26, size * 0.20 + line_w],
                   fill=rgb("#F2F2F4") + (110,))

    draw_emblem(draw, size, rgb("#FFFFFF"))
    return base


def render_orbit(size: int) -> Image.Image:
    base = flat_canvas(size, rgb("#E84228"))
    draw = ImageDraw.Draw(base, "RGBA")

    ring = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    rdraw = ImageDraw.Draw(ring)
    cx = cy = size * 0.5
    rx = size * 0.44
    ry = size * 0.155
    width = max(3, int(size * 0.016))
    rdraw.ellipse(
        [cx - rx, cy - ry, cx + rx, cy + ry],
        outline=rgb("#FFFFFF") + (235,),
        width=width,
    )
    ring = ring.rotate(-18, resample=Image.BICUBIC, center=(cx, cy))
    base = Image.alpha_composite(base, ring)

    draw = ImageDraw.Draw(base, "RGBA")
    draw_emblem(draw, size, rgb("#FFFFFF"))
    return base


def render_vinyl(size: int) -> Image.Image:
    base = flat_canvas(size, rgb("#0A0A0B"))
    draw = ImageDraw.Draw(base, "RGBA")

    cx = cy = size * 0.5
    disc_r = size * 0.465
    draw.ellipse([cx - disc_r, cy - disc_r, cx + disc_r, cy + disc_r], fill=rgb("#0D0D0F") + (255,))
    draw.ellipse(
        [cx - disc_r, cy - disc_r, cx + disc_r, cy + disc_r],
        outline=rgb("#232328") + (255,),
        width=max(2, int(size * 0.004)),
    )

    # Concentric grooves.
    radius = size * 0.30
    step = size * 0.021
    index = 0
    while radius < disc_r - size * 0.012:
        shade = rgb("#1B1B1F") if index % 2 == 0 else rgb("#26262C")
        draw.ellipse(
            [cx - radius, cy - radius, cx + radius, cy + radius],
            outline=shade + (255,),
            width=max(1, int(size * 0.0035)),
        )
        radius += step
        index += 1

    # Centre label: dark disc, gold rim, gold Spark.
    label_r = size * 0.195
    draw.ellipse([cx - label_r, cy - label_r, cx + label_r, cy + label_r], fill=rgb("#141416") + (255,))
    draw.ellipse(
        [cx - label_r, cy - label_r, cx + label_r, cy + label_r],
        outline=rgb("#F4C44E") + (235,),
        width=max(2, int(size * 0.006)),
    )

    draw_star(draw, cx, cy, size * 0.150, size * 0.046, rgb("#F4C44E"))
    return base


def render_cosmos(size: int) -> Image.Image:
    base = gradient_canvas(size, rgb("#141836"), rgb("#252B5C"))
    draw = ImageDraw.Draw(base, "RGBA")

    rng = random.Random(20261114)
    for _ in range(110):
        x = rng.uniform(0, size)
        y = rng.uniform(0, size)
        r = rng.uniform(size * 0.0016, size * 0.0042)
        alpha = rng.randint(90, 225)
        draw.ellipse([x - r, y - r, x + r, y + r], fill=(255, 255, 255, alpha))

    # A few brighter four-point specks.
    for (fx, fy, s) in [(0.19, 0.28, 0.020), (0.83, 0.66, 0.017), (0.70, 0.18, 0.014)]:
        draw_star(draw, size * fx, size * fy, size * s, size * s * 0.30, (255, 255, 255))

    draw_emblem(draw, size, rgb("#DCE0FF"))
    return base


def render_amethyst(size: int) -> Image.Image:
    base = flat_canvas(size, rgb("#2A1746"))
    draw = ImageDraw.Draw(base, "RGBA")

    s = size
    facets = [
        ([(0, 0.14), (0.46, 0), (0.30, 0.56)], "#6D3EC4"),
        ([(0.46, 0), (0.94, 0.09), (0.62, 0.49)], "#9B6EF3"),
        ([(0, 0.14), (0.30, 0.56), (0, 0.78)], "#5A2FA8"),
        ([(0.94, 0.09), (1, 0.56), (0.62, 0.49)], "#7B4FD0"),
        ([(0.30, 0.56), (0.62, 0.49), (0.90, 1), (0.14, 1)], "#4A2488"),
        ([(0, 0.78), (0.30, 0.56), (0.14, 1), (0, 1)], "#3B1B70"),
    ]
    for points, colour in facets:
        draw.polygon([(x * s, y * s) for (x, y) in points], fill=rgb(colour) + (255,))

    # Facet edges.
    edge = max(1, int(size * 0.0035))
    for points, _ in facets:
        draw.line([(x * s, y * s) for (x, y) in points] + [(points[0][0] * s, points[0][1] * s)],
                  fill=(255, 255, 255, 40), width=edge, joint="curve")

    draw_emblem(draw, size, rgb("#FFFFFF"))
    return base


def render_y2k(size: int) -> Image.Image:
    base = flat_canvas(size, rgb("#E6E9F0"))
    draw = ImageDraw.Draw(base, "RGBA")

    cx = cy = size * 0.5
    disc_r = size * 0.465
    bbox = [cx - disc_r, cy - disc_r, cx + disc_r, cy + disc_r]
    draw.ellipse(bbox, fill=rgb("#DFE4EF") + (255,))
    draw.ellipse(bbox, outline=rgb("#B4BCCC") + (255,), width=max(2, int(size * 0.005)))

    # Pastel diagonal sheen bands, clipped to the disc.
    bands = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    bdraw = ImageDraw.Draw(bands)
    colours = [rgb("#6FD8EA"), rgb("#F0A6CE"), rgb("#B8A6F5"), rgb("#7FE3C4")]
    band_w = size * 0.085
    gap = size * 0.058
    start = -size * 0.55
    index = 0
    diagonal = size * 1.75
    while start < size * 1.05:
        colour = colours[index % len(colours)] + (150,)
        bdraw.polygon(
            [
                (start, 0),
                (start + band_w, 0),
                (start + band_w - diagonal, size),
                (start - diagonal, size),
            ],
            fill=colour,
        )
        start += band_w + gap
        index += 1

    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).ellipse(bbox, fill=255)
    bands.putalpha(ImageChops.multiply(bands.getchannel("A"), mask))
    base = Image.alpha_composite(base, bands)

    draw = ImageDraw.Draw(base, "RGBA")
    # Centre hole.
    hole = size * 0.042
    draw.ellipse([cx - hole, cy - hole, cx + hole, cy + hole], fill=rgb("#E6E9F0") + (255,))
    draw.ellipse([cx - hole, cy - hole, cx + hole, cy + hole],
                 outline=rgb("#B4BCCC") + (255,), width=max(1, int(size * 0.003)))

    draw_emblem(draw, size, rgb("#FFFFFF"), outline=rgb("#141416"), outline_weight=0.018)
    return base


def render_cassette(size: int) -> Image.Image:
    base = flat_canvas(size, rgb("#E8DEC8"))
    draw = ImageDraw.Draw(base, "RGBA")

    inset = size * 0.10
    shell = [inset, inset, size - inset, size - inset]
    stroke = max(2, int(size * 0.012))
    draw.rounded_rectangle(shell, radius=size * 0.055, outline=rgb("#2A2118") + (215,), width=stroke)

    # Spools.
    spool_r = size * 0.070
    for fx in (0.355, 0.645):
        sx, sy = size * fx, size * 0.315
        draw.ellipse([sx - spool_r, sy - spool_r, sx + spool_r, sy + spool_r],
                     outline=rgb("#2A2118") + (205,), width=max(2, int(size * 0.007)))
        hub = spool_r * 0.34
        draw.ellipse([sx - hub, sy - hub, sx + hub, sy + hub], fill=rgb("#2A2118") + (215,))

    # Retro stripe band.
    band_left = inset + stroke
    band_right = size - inset - stroke
    stripes = [
        (0.455, 0.545, "#E0703A"),
        (0.545, 0.625, "#8A5A2B"),
        (0.625, 0.695, "#E8B23A"),
    ]
    for top_f, bottom_f, colour in stripes:
        draw.rectangle(
            [band_left, size * top_f, band_right, size * bottom_f],
            fill=rgb(colour) + (255,),
        )

    draw_emblem(draw, size, rgb("#FFF9EE"), outline=rgb("#2A2118"))
    return base


def render_invincible(size: int) -> Image.Image:
    base = flat_canvas(size, rgb("#1D8FE1"))
    draw = ImageDraw.Draw(base, "RGBA")

    ink = rgb("#0E1A2A")

    # Halftone field in the top-right corner.
    step = size * 0.040
    y = size * 0.055
    while y < size * 0.40:
        x = size * 0.60
        while x < size * 0.95:
            distance = math.hypot(x - size * 0.93, y - size * 0.07)
            t = max(0.0, 1.0 - distance / (size * 0.46))
            radius = size * 0.004 + size * 0.009 * t
            if radius > 0.5:
                draw.ellipse([x - radius, y - radius, x + radius, y + radius], fill=ink + (110,))
            x += step
        y += step

    # Ink speed lines along the lower-left edge.
    for offset, length, alpha in [(0.66, 0.24, 90), (0.76, 0.30, 75), (0.87, 0.18, 60)]:
        x0 = size * 0.075
        y0 = size * offset
        draw.line(
            [(x0, y0), (x0 + size * length, y0 + size * length * 0.26)],
            fill=ink + (alpha,),
            width=max(2, int(size * 0.013)),
        )

    draw_emblem(draw, size, rgb("#FFD43B"), outline=rgb("#10131A"))
    return base


def render_blueprint(size: int) -> Image.Image:
    base = flat_canvas(size, rgb("#102338"))
    draw = ImageDraw.Draw(base, "RGBA")

    line = max(1, int(size * 0.0018))
    step = size / 16.0
    for i in range(1, 16):
        draw.line([(i * step, 0), (i * step, size)], fill=(255, 255, 255, 32), width=line)
        draw.line([(0, i * step), (size, i * step)], fill=(255, 255, 255, 32), width=line)

    # Drawing frame.
    inset = size * 0.055
    draw.rectangle([inset, inset, size - inset, size - inset],
                   outline=(255, 255, 255, 78), width=max(1, int(size * 0.003)))

    # Construction circles.
    cx = cy = size * 0.5
    guide = max(1, int(size * 0.0026))
    for r in (size * 0.300, size * 0.395):
        draw.ellipse([cx - r, cy - r, cx + r, cy + r], outline=(255, 255, 255, 58), width=guide)

    # Corner crosshairs.
    arm = size * 0.045
    for (ax, ay) in [(inset, inset), (size - inset, inset), (inset, size - inset), (size - inset, size - inset)]:
        draw.line([(ax - arm, ay), (ax + arm, ay)], fill=(255, 255, 255, 88), width=guide)
        draw.line([(ax, ay - arm), (ax, ay + arm)], fill=(255, 255, 255, 88), width=guide)

    draw_emblem(draw, size, rgb("#FFFFFF"))
    return base


RENDERERS = {
    "default": render_default,
    "editor": render_editor,
    "orbit": render_orbit,
    "vinyl": render_vinyl,
    "cosmos": render_cosmos,
    "amethyst": render_amethyst,
    "y2k": render_y2k,
    "cassette": render_cassette,
    "invincible": render_invincible,
    "blueprint": render_blueprint,
}


def render_icon(key: str) -> Image.Image:
    size = 1024 * SUPERSAMPLE
    img = RENDERERS[key](size)
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


def prune_stale(assets_root: str, icon_root: str, preview_root: str):
    """Removes icons and previews that are no longer in the catalogue."""
    keep_sets = {f"{name}.appiconset" for name, _, _, _ in ICON_SETS}
    keep_sets.add("AccentColor.colorset")
    for entry in os.listdir(assets_root):
        if entry.endswith(".appiconset") and entry not in keep_sets:
            folder = os.path.join(assets_root, entry)
            for name in os.listdir(folder):
                os.remove(os.path.join(folder, name))
            os.rmdir(folder)

    keep_previews = {preview for _, _, preview, _ in ICON_SETS}
    for entry in os.listdir(preview_root):
        if entry.endswith(".png") and entry[:-4] not in keep_previews:
            os.remove(os.path.join(preview_root, entry))

    keep_bundle = {
        f"{name}{suffix}"
        for name, _, _, _ in ICON_SETS
        for suffix, _ in BUNDLE_ICON_VARIANTS
    }
    for entry in os.listdir(icon_root):
        if entry.endswith(".png") and entry not in keep_bundle:
            os.remove(os.path.join(icon_root, entry))


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
    icon_root = os.path.join(repo_root, "SparkRPGM", "Resources", "IconAssets")

    ensure_catalog_skeleton(assets_root)
    os.makedirs(preview_root, exist_ok=True)
    os.makedirs(icon_root, exist_ok=True)

    prune_stale(assets_root, icon_root, preview_root)

    for set_name, title, preview, key in ICON_SETS:
        print(f"Rendering {set_name} ({title}) ...")
        img = render_icon(key)
        build_appiconset(assets_root, set_name, img)
        build_bundle_icons(repo_root, set_name, img)
        if not args.skip_previews:
            write_image(img, os.path.join(preview_root, f"{preview}.png"), 1024)

    print(f"Done. Assets: {assets_root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
