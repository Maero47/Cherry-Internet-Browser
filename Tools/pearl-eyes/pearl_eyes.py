#!/usr/bin/env python3
"""Pearl's eye colour — the one place it is decided, and the one way it is changed.

Pearl's eyes are amber. This asks what she looks like with purple ones, and it
is built so that the answer can be thrown away: the amber artwork is kept whole
in `amber/`, every shipped file is REGENERATED from it, and nothing here is a
hand-edit anybody would have to undo.

    python3 Tools/pearl-eyes/pearl_eyes.py paint amber      # ship the amber eyes
    python3 Tools/pearl-eyes/pearl_eyes.py paint purple     # ship the purple eyes
    python3 Tools/pearl-eyes/pearl_eyes.py compare          # rebuild comparison/

`paint amber` is a byte-for-byte restore, because amber is a straight copy of
the originals rather than a round trip through the maths below.

The other half of the switch is `PearlEyes.shipping` in the app, and
`PearlEyeColourTests` fails if the two disagree — so the constant cannot claim
one colour while the artwork is the other.

## Why the eyes are recoloured rather than repainted

The obvious way to make a purple-eyed Pearl is to generate a new painting of
her. That gives you a different cat: different fur strokes, a different rim
light, a different silhouette to cut. You then cannot answer the question this
round is actually asking, because you are comparing two paintings and not two
eye colours. So the painting is left alone and the irises are rotated in place.
Everything outside her irises — every fur pixel, the cream rim light, the
alpha cut-out, the image dimensions — is bit-identical to the amber art, which
is what makes the side-by-sides in `comparison/` an honest A/B.

## How a pixel is decided to be an iris

Two different problems, because the two kinds of artwork are different.

**The painterly poses** are continuous-tone, so the irises are found inside
hand-picked boxes (`EYE_BOXES`, one per eye, measured at @2x and halved for
1x) and weighted smoothly by how amber a pixel is: hue in the orange band,
saturated, and BRIGHT. The brightness ramp is what separates the iris from her
fur, which is the same hue and nearly as saturated but half as light. The
weight is a fraction rather than a yes/no so the anti-aliased edges between
iris, pupil and sclera come through as gradients rather than as a cut-out.

**The sprite sheet** is seven flat colours, so no threshold can tell an iris
from the gold rim light on her ears or from a gull's beak — they are the same
two values. It is decided geometrically instead: an eye is a connected blob of
{gold, gold-shade, cream, white} that (a) never touches transparent pixels,
(b) lies inside one of Pearl's own frames, and (c) contains both a gold pixel
and a pale one — an iris and a sclera. Her rim light, the gulls, the moon, the
cherry trees and the fish she eats all touch the cut-out edge or have no
sclera, so none of them are eyes. Frames where her eyes are shut — `pet_blink`,
`pet_happy`, `pet_sleep` — come out with zero iris pixels, which is correct
and is what `PearlEyeColourTests` pins.

## The colour

One rotation, applied to every iris pixel in both kinds of artwork, in OKLCh:

    hue  -> PURPLE_HUE  (amber's own hue is the pivot, so the iris keeps all
                         of its internal hue variation)
    L    -> L * PURPLE_LIGHTNESS
    C    -> unchanged, then shrunk until it fits sRGB

Lightness is the whole argument. Keeping OKLab's L exactly gives a purple that
is perceptually as light as the amber was — it measures 7.7:1 against her fur
where amber measures 7.9:1 — but at that lightness sRGB has no room for a
saturated violet and she ends up with pale periwinkle eyes. Taking L down to
0.92 buys a purple that actually reads as purple and costs a fifth of her eye's
separation from her fur: 6.1:1 instead of 7.9:1. That is the trade, and 0.92 is
where this round put it.

## If the pet frames are ever rebuilt

`build_pet_frames.py` snaps the pet's poses to the runner's seven-colour AMBER
palette, so running it re-golds her eyes. Run this script after it, always.
"""

import shutil
import sys
from collections import deque
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
APP = REPO / "Internet Browser" / "Internet Browser"
CATALOG = APP / "Assets.xcassets"
SPRITES = APP / "Features" / "PearlRunner" / "Sprites"
AMBER = HERE / "amber"
COMPARISON = HERE / "comparison"

# MARK: - The colour

PURPLE_HUE = 312.0
PURPLE_LIGHTNESS = 0.92
AMBER_HUE = 74.8646          # OKLCh hue of (232, 160, 32), the sheet's iris gold

# MARK: - The painterly poses

#: Every pose that ships as an imageset, and where its irises are at @2x.
#: `PearlCurled` is asleep — her eyes are two dark arcs and there is no iris in
#: the drawing at all — so she is copied through untouched. That is not an
#: oversight; it is the answer for that pose.
EYE_BOXES = {
    "PearlHero": [(66, 84, 96, 118), (116, 113, 152, 150)],
    # The yellow hero is the same painting composited at (90, 90) on its field.
    "PearlHeroYellow": [(156, 174, 186, 208), (206, 203, 242, 240)],
    "PearlWave": [(84, 96, 119, 132), (147, 108, 182, 144)],
    "PearlSitting": [(37, 53, 61, 78), (77, 53, 101, 78)],
    "PearlDelighted": [(83, 89, 114, 124), (135, 116, 174, 157)],
    "PearlCurled": [],
}

# MARK: - The sprite sheet

GOLD = (232, 160, 32)
GOLD_SHADE = (184, 120, 24)
CREAM = (242, 226, 196)
WHITE = (255, 255, 255)
#: Pearl's own frames. Everything else in the sheet is scenery or a gull.
PEARL_FRAMES = ("run", "jump", "hit", "duck", "pet_sit", "pet_blink",
                "pet_groom", "pet_happy", "pet_eat", "pet_sleep")


# MARK: - OKLab

_M1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929],
                [0.2119034982, 0.6806995451, 0.1073969566],
                [0.0883024619, 0.2817188376, 0.6299787005]])
_M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
                [1.9779984951, -2.4285922050, 0.4505937099],
                [0.0259040371, 0.7827717662, -0.8086757660]])
_M1_INV = np.linalg.inv(_M1)
_M2_INV = np.linalg.inv(_M2)


def _to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def _to_srgb(c):
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.clip(c, 0, None) ** (1 / 2.4) - 0.055)


def rotate_to_purple(rgb):
    """sRGB in 0…1 -> the same colours with amber's hue turned to purple."""
    lms = np.cbrt(np.clip(_to_linear(rgb) @ _M1.T, 0, None))
    lab = lms @ _M2.T
    lightness = lab[..., 0] * PURPLE_LIGHTNESS
    chroma = np.hypot(lab[..., 1], lab[..., 2])
    hue = np.degrees(np.arctan2(lab[..., 2], lab[..., 1])) + (PURPLE_HUE - AMBER_HUE)

    # Shrink chroma until the colour is inside sRGB, keeping lightness and hue.
    low = np.zeros_like(chroma)
    high = chroma.copy()
    for _ in range(40):
        mid = (low + high) / 2
        trial = _from_oklab(lightness, mid, hue)
        inside = (trial >= -0.001).all(-1) & (trial <= 1.001).all(-1)
        low = np.where(inside, mid, low)
        high = np.where(inside, high, mid)
    return np.clip(_from_oklab(lightness, low, hue), 0, 1)


def _from_oklab(lightness, chroma, hue):
    radians = np.radians(hue)
    lab = np.stack([lightness, chroma * np.cos(radians), chroma * np.sin(radians)], -1)
    return _to_srgb((lab @ _M2_INV.T) ** 3 @ _M1_INV.T)


# MARK: - Painterly irises

def _hue_saturation_value(rgb):
    red, green, blue = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    high = rgb.max(-1)
    span = high - rgb.min(-1)
    saturation = np.where(high > 0, span / np.maximum(high, 1e-6), 0)
    safe = np.maximum(span, 1e-9)
    hue = np.zeros_like(high)
    at = high == red
    hue[at] = ((green - blue)[at] / safe[at]) % 6
    at = (high == green) & ~(high == red)
    hue[at] = ((blue - red)[at] / safe[at]) + 2
    at = (high == blue) & ~(high == red) & ~(high == green)
    hue[at] = ((red - green)[at] / safe[at]) + 4
    return hue * 60, saturation, high


def _ramp(value, low, high):
    return np.clip((value - low) / (high - low), 0, 1)


def iris_weight(rgb):
    """How much of a pixel is iris, from 0 to 1.

    Hue in the orange band, saturated, and — the discriminator that matters —
    light. Her fur is the same hue at half the value.
    """
    hue, saturation, value = _hue_saturation_value(rgb)
    in_band = _ramp(hue, 5, 15) * (1 - _ramp(hue, 60, 75))
    return in_band * _ramp(saturation, 0.25, 0.45) * _ramp(value, 0.42, 0.58)


def painterly_purple(image, boxes):
    """One imageset representation, with its irises turned purple."""
    mode = image.mode
    rgba = np.asarray(image.convert("RGBA")).astype(float) / 255
    weight = np.zeros(rgba.shape[:2])
    for (x0, y0, x1, y1) in boxes:
        weight[y0:y1, x0:x1] = iris_weight(rgba[y0:y1, x0:x1, :3])

    rotated = rotate_to_purple(rgba[..., :3])
    out = rgba.copy()
    out[..., :3] = rgba[..., :3] * (1 - weight[..., None]) + rotated * weight[..., None]
    painted = Image.fromarray((out * 255).round().astype(np.uint8))
    return painted.convert(mode), int((weight > 0.004).sum())


# MARK: - Sprite-sheet irises

def sheet_iris_mask(sheet):
    """The sheet's iris pixels — see the module docstring for the rule."""
    import json

    pixels = np.asarray(sheet.convert("RGBA"))
    height, width = pixels.shape[:2]
    opaque = pixels[..., 3] > 0

    def exactly(colour):
        return ((pixels[..., 0] == colour[0]) & (pixels[..., 1] == colour[1])
                & (pixels[..., 2] == colour[2]) & opaque)

    gold = exactly(GOLD) | exactly(GOLD_SHADE)
    pale = exactly(CREAM) | exactly(WHITE)
    eye_coloured = gold | pale

    manifest = json.loads((SPRITES / "pearl-sprites.json").read_text())
    in_pearl = np.zeros((height, width), bool)
    for name in PEARL_FRAMES:
        boxes = manifest["frames"][name]
        for box in ([boxes] if isinstance(boxes, dict) else boxes):
            in_pearl[box["y"]:box["y"] + box["h"], box["x"]:box["x"] + box["w"]] = True

    seen = np.zeros((height, width), bool)
    iris = np.zeros((height, width), bool)
    for y in range(height):
        for x in range(width):
            if not eye_coloured[y, x] or seen[y, x]:
                continue
            queue = deque([(y, x)])
            seen[y, x] = True
            blob = []
            touches_cutout = False
            while queue:
                cy, cx = queue.popleft()
                blob.append((cy, cx))
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    ny, nx = cy + dy, cx + dx
                    if not (0 <= ny < height and 0 <= nx < width) or not opaque[ny, nx]:
                        touches_cutout = True
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1),
                               (1, 1), (1, -1), (-1, 1), (-1, -1)):
                    ny, nx = cy + dy, cx + dx
                    if (0 <= ny < height and 0 <= nx < width
                            and eye_coloured[ny, nx] and not seen[ny, nx]):
                        seen[ny, nx] = True
                        queue.append((ny, nx))
            if touches_cutout:
                continue
            if not all(in_pearl[point] for point in blob):
                continue
            if not any(gold[point] for point in blob):
                continue
            if not any(pale[point] for point in blob):
                continue
            for point in blob:
                if gold[point]:
                    iris[point] = True
    return iris


def sheet_purple(sheet):
    mask = sheet_iris_mask(sheet)
    pixels = np.asarray(sheet.convert("RGBA")).copy()
    rotated = rotate_to_purple(pixels[..., :3].astype(float) / 255)
    pixels[..., :3][mask] = (rotated * 255).round().astype(np.uint8)[mask]
    return Image.fromarray(pixels), int(mask.sum())


# MARK: - Painting

def shipped_paths(name):
    return [(AMBER / f"{name}.png", CATALOG / f"{name}.imageset" / f"{name}.png"),
            (AMBER / f"{name}@2x.png", CATALOG / f"{name}.imageset" / f"{name}@2x.png")]


def paint(colour):
    if colour not in ("amber", "purple"):
        raise SystemExit("colour must be amber or purple")

    for name, boxes in EYE_BOXES.items():
        # `EYE_BOXES` is measured at @2x, so the 1x representation halves them.
        for divisor, (source, destination) in zip((2, 1), shipped_paths(name)):
            # Amber is a restore, and a pose with no iris to turn is one too —
            # re-encoding a file whose pixels do not change is a diff that says
            # something happened when nothing did.
            if colour == "amber" or not boxes:
                shutil.copyfile(source, destination)
                print(f"{destination.name}: amber"
                      + (" (no iris in this pose)" if boxes == [] else " (restored)"))
                continue
            scaled = [tuple(edge // divisor for edge in box) for box in boxes]
            painted, touched = painterly_purple(Image.open(source), scaled)
            painted.save(destination)
            print(f"{destination.name}: purple, {touched} iris pixels")

    source = AMBER / "pearl-sprites.png"
    destination = SPRITES / "pearl-sprites.png"
    if colour == "amber":
        shutil.copyfile(source, destination)
        print("pearl-sprites.png: amber (restored)")
    else:
        painted, touched = sheet_purple(Image.open(source))
        painted.save(destination)
        print(f"pearl-sprites.png: purple, {touched} iris pixels")


# MARK: - The comparison sheets

LIGHT = (236, 236, 236)      # windowBackgroundColor, light
DARK = (50, 50, 50)          # windowBackgroundColor, dark


def _flatten(image, background, box=None):
    if box:
        image = image.crop(box)
    plate = Image.new("RGB", image.size, background)
    rgba = image.convert("RGBA")
    plate.paste(rgba, (0, 0), rgba)
    return plate


def _caption(draw, xy, text, background):
    ink = (30, 30, 30) if sum(background) > 380 else (225, 225, 225)
    draw.text(xy, text, fill=ink)


def _both(name):
    """(amber, purple) for one pose's @2x representation."""
    amber = Image.open(AMBER / f"{name}@2x.png")
    purple, _ = painterly_purple(amber, EYE_BOXES[name])
    return amber, purple


def compare():
    COMPARISON.mkdir(exist_ok=True)
    _compare_hero()
    _compare_pet()
    _compare_runner()
    _compare_closeup()
    _compare_poses()
    _compare_avatar()


def _compare_hero():
    """The wizard's welcome, at the 196pt she is actually drawn at."""
    amber, purple = _both("PearlWave")
    height = 196 * 2                                   # 196pt on a retina screen
    width = round(amber.width * height / amber.height)
    pair = [image.resize((width, height), Image.LANCZOS) for image in (amber, purple)]

    gap, pad, label = 60, 40, 26
    tile_w, tile_h = width * 2 + gap, height + label
    canvas = Image.new("RGB", (tile_w + pad * 2, tile_h * 2 + pad * 3), LIGHT)
    draw = ImageDraw.Draw(canvas)
    for row, background in enumerate((LIGHT, DARK)):
        top = pad + row * (tile_h + pad)
        canvas.paste(Image.new("RGB", (tile_w, tile_h), background), (pad, top))
        for column, image in enumerate(pair):
            left = pad + column * (width + gap)
            canvas.paste(_flatten(image, background), (left, top))
            _caption(draw, (left + 2, top + height + 8),
                     ("amber", "purple")[column] + "  ·  196pt, the welcome step", background)
    canvas.save(COMPARISON / "01-wizard-hero.png")
    print("comparison/01-wizard-hero.png")


def _compare_pet():
    """The desktop pet at the three sizes she is actually offered at."""
    import json

    manifest = json.loads((SPRITES / "pearl-sprites.json").read_text())
    box = manifest["frames"]["pet_sit"][0]
    amber_sheet = Image.open(AMBER / "pearl-sprites.png")
    purple_sheet, _ = sheet_purple(amber_sheet)
    crop = (box["x"], box["y"], box["x"] + box["w"], box["y"] + box["h"])
    sprites = [sheet.crop(crop) for sheet in (amber_sheet, purple_sheet)]

    # Amber and purple stand next to each other at each size, because the
    # question is which of two colours this is, not what one of them looks
    # like. Drawn at 2x device pixels so the file opens at her true on-screen
    # size on a retina display; the sprite itself is still magnified by whole
    # numbers, exactly as `PearlPetSize` insists.
    pad, gap, span, label = 40, 26, 70, 26
    row_w = sum(36 * m * 2 * 2 + gap for m in (1, 2, 3)) + span * 2
    row_h = 40 * 3 * 2 + label
    canvas = Image.new("RGB", (row_w + pad * 2, row_h * 2 + pad * 3), LIGHT)
    draw = ImageDraw.Draw(canvas)
    for row, background in enumerate((LIGHT, DARK)):
        top = pad + row * (row_h + pad)
        canvas.paste(Image.new("RGB", (row_w, row_h), background), (pad, top))
        left = pad
        for multiple in (1, 2, 3):
            pair_left = left
            for which, sprite in enumerate(sprites):
                drawn = sprite.resize((36 * multiple * 2, 40 * multiple * 2), Image.NEAREST)
                canvas.paste(_flatten(drawn, background),
                             (left, top + row_h - label - drawn.height))
                _caption(draw, (left + 2, top + row_h - label + 6),
                         ("amber", "purple")[which], background)
                left += drawn.width + (gap if which == 0 else span)
            _caption(draw, (pair_left + 2, top + 8),
                     f"{('Small', 'Medium', 'Large')[multiple - 1]} ({multiple}x)", background)
    canvas.save(COMPARISON / "02-pet-at-real-size.png")
    print("comparison/02-pet-at-real-size.png")


def _compare_runner():
    """One running frame, magnified until a person can see the eye."""
    import json

    manifest = json.loads((SPRITES / "pearl-sprites.json").read_text())
    amber_sheet = Image.open(AMBER / "pearl-sprites.png")
    purple_sheet, _ = sheet_purple(amber_sheet)

    frames = [("run", 0), ("run", 1), ("jump", 0), ("hit", 0), ("duck", 0)]
    zoom = 6
    pad, gap = 40, 24
    crops = []
    for name, index in frames:
        box = manifest["frames"][name][index]
        crops.append((box["x"], box["y"], box["x"] + box["w"], box["y"] + box["h"]))

    row_w = sum((c[2] - c[0]) * zoom for c in crops) + gap * (len(crops) - 1)
    row_h = max((c[3] - c[1]) * zoom for c in crops) + 26
    canvas = Image.new("RGB", (row_w + pad * 2, row_h * 2 + pad * 3), (244, 240, 230))
    draw = ImageDraw.Draw(canvas)
    for row, (sheet, name) in enumerate(((amber_sheet, "amber"), (purple_sheet, "purple"))):
        top = pad + row * (row_h + pad)
        # The runner's own surface: the offline page's parchment.
        canvas.paste(Image.new("RGB", (row_w, row_h), (250, 247, 240)), (pad, top))
        left = pad
        for crop in crops:
            piece = sheet.crop(crop)
            piece = piece.resize((piece.width * zoom, piece.height * zoom), Image.NEAREST)
            canvas.paste(_flatten(piece, (250, 247, 240)), (left, top))
            left += piece.width + gap
        _caption(draw, (pad + 4, top + row_h - 20), f"{name}  ·  magnified {zoom}x",
                 (250, 247, 240))
    canvas.save(COMPARISON / "03-runner-frames.png")
    print("comparison/03-runner-frames.png")


def _compare_closeup():
    """Exactly what changed, and nothing else: her eyes, very large."""
    amber, purple = _both("PearlWave")
    boxes = EYE_BOXES["PearlWave"]
    x0 = min(b[0] for b in boxes) - 10
    y0 = min(b[1] for b in boxes) - 10
    x1 = max(b[2] for b in boxes) + 10
    y1 = max(b[3] for b in boxes) + 10
    zoom = 5
    pieces = [_flatten(image, LIGHT, (x0, y0, x1, y1)).resize(
        ((x1 - x0) * zoom, (y1 - y0) * zoom), Image.LANCZOS) for image in (amber, purple)]

    pad, gap = 30, 30
    canvas = Image.new("RGB",
                       (pieces[0].width + pad * 2, pieces[0].height * 2 + pad * 2 + gap + 40),
                       LIGHT)
    draw = ImageDraw.Draw(canvas)
    for row, piece in enumerate(pieces):
        top = pad + row * (piece.height + gap)
        canvas.paste(piece, (pad, top))
        _caption(draw, (pad, top + piece.height + 6), ("amber", "purple")[row], LIGHT)
    canvas.save(COMPARISON / "04-eyes-close-up.png")
    print("comparison/04-eyes-close-up.png")


def _compare_poses():
    """Every painterly pose she has, both ways."""
    names = ["PearlWave", "PearlSitting", "PearlDelighted", "PearlHero", "PearlCurled"]
    height, pad, gap = 260, 40, 30
    tiles = []
    for name in names:
        amber, purple = _both(name)
        pair = []
        for image in (amber, purple):
            width = round(image.width * height / image.height)
            pair.append(image.resize((width, height), Image.LANCZOS))
        tiles.append((name, pair))

    row_w = sum(pair[0].width for _, pair in tiles) + gap * (len(tiles) - 1)
    rows = [(LIGHT, 0), (LIGHT, 1), (DARK, 0), (DARK, 1)]
    canvas = Image.new("RGB", (row_w + pad * 2, (height + 26) * len(rows) + pad * 5), LIGHT)
    draw = ImageDraw.Draw(canvas)
    for row, (background, which) in enumerate(rows):
        top = pad + row * (height + 26 + pad)
        canvas.paste(Image.new("RGB", (row_w, height + 26), background), (pad, top))
        left = pad
        for name, pair in tiles:
            canvas.paste(_flatten(pair[which], background), (left, top))
            _caption(draw, (left + 2, top + height + 6),
                     f"{name} · {('amber', 'purple')[which]}", background)
            left += pair[which].width + gap
    canvas.save(COMPARISON / "05-every-pose.png")
    print("comparison/05-every-pose.png  (amber row above purple row, light then dark)")


def _compare_avatar():
    """The smallest she is ever drawn: the chat panel's 24pt header face.

    Smaller than the pet at 1x, and the place where an eye colour has the
    least room to be one — three or four device pixels of iris. If purple
    survives anywhere it has to survive here, and if it does not, this is the
    file that says so.
    """
    amber, purple = _both("PearlSitting")
    pad, gap, span = 40, 24, 60
    rows = []
    for points in (24, 48):
        height = points * 2
        width = round(amber.width * height / amber.height)
        rows.append((points, [image.resize((width, height), Image.LANCZOS)
                              for image in (amber, purple)]))

    row_h = max(pair[0].height for _, pair in rows) + 26
    row_w = max(pair[0].width * 2 + gap for _, pair in rows) + span + 240
    canvas = Image.new("RGB", (row_w + pad * 2, row_h * len(rows) * 2 + pad * 5), LIGHT)
    draw = ImageDraw.Draw(canvas)
    row = 0
    for background in (LIGHT, DARK):
        for points, pair in rows:
            top = pad + row * (row_h + pad // 2)
            canvas.paste(Image.new("RGB", (row_w, row_h), background), (pad, top))
            left = pad + 10
            for which, image in enumerate(pair):
                canvas.paste(_flatten(image, background), (left, top))
                _caption(draw, (left, top + image.height + 6),
                         ("amber", "purple")[which], background)
                left += image.width + gap
            _caption(draw, (left + 10, top + 4),
                     f"{points}pt" + ("  ·  the chat header, her smallest" if points == 24
                                      else "  ·  twice that, for reference"), background)
            row += 1
    canvas.save(COMPARISON / "06-chat-avatar.png")
    print("comparison/06-chat-avatar.png")


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "compare":
        compare()
    elif len(sys.argv) == 3 and sys.argv[1] == "paint":
        paint(sys.argv[2])
    else:
        raise SystemExit(__doc__.strip().splitlines()[0]
                         + "\n\n  pearl_eyes.py paint amber|purple\n  pearl_eyes.py compare")


if __name__ == "__main__":
    main()
