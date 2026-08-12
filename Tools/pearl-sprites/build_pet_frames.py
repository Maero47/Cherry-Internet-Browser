#!/usr/bin/env python3
"""Add Pearl's pet frames to the runner's sprite sheet.

The runner's sheet (`Features/PearlRunner/Sprites/pearl-sprites.png` + `.json`)
is the ONE place Pearl's pixels live. The desktop pet needed six poses the
runner never had — sit, blink, groom, sleep, eat, happy — so they were drawn
into the same sheet rather than into a second one.

Input
-----
`pearl-pet-poses-generated.png`: the poses as they came out of image
generation, drawn at 10 screen pixels per art pixel on white. Every pose sits
on the same 10px grid, which is what makes the downsample below exact rather
than a resample: one sample per block centre, no interpolation, no new colours.

What this script does
---------------------
1. samples the block centres, giving true 1x pixel art;
2. snaps every colour to the SEVEN colours the runner's own frames use, so the
   pet cannot drift away from the runner's palette;
3. keeps white eye glints, which a naive "white is background" rule eats — the
   background is found by flood fill from the border instead;
4. derives the second frame of each two-frame cycle as a one-pixel breath, and
   derives `pet_blink` from `pet_sit` so a blink cannot move anything but the
   eyes;
5. pads each pose into the fixed box its contract entry declares
   (`PearlSpriteContract`), bottom-aligned and centred, so the poses can
   replace each other in place without the cat jumping;
6. appends the frames to the existing sheet and manifest, leaving every
   existing frame's pixels and rectangle exactly where they were.

Re-running it is idempotent: it always rebuilds from the runner's original
region plus the generated poses.

    python3 Tools/pearl-sprites/build_pet_frames.py

One thing it does NOT know about: step 2 above snaps to the runner's AMBER
palette, so running this re-golds Pearl's eyes whatever colour they were
shipping in. `Tools/pearl-eyes/pearl_eyes.py` is what decides that, and it has
to be re-run afterwards — `PearlEyeColourTests` is what fails if it is not.
"""

import json
import os
from collections import deque

from PIL import Image
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
SPRITES = os.path.join(
    REPO, "Internet Browser", "Internet Browser",
    "Features", "PearlRunner", "Sprites",
)
SHEET = os.path.join(SPRITES, "pearl-sprites.png")
MANIFEST = os.path.join(SPRITES, "pearl-sprites.json")
GENERATED = os.path.join(HERE, "pearl-pet-poses-generated.png")

# The runner's palette, in the order the sheet uses it.
PALETTE = np.array([
    (32, 24, 19),      # body dark
    (58, 42, 31),      # body mid
    (242, 226, 196),   # cream rim light
    (184, 120, 24),    # gold rim
    (232, 160, 32),    # gold bright (eyes, the bow)
    (232, 144, 128),   # pink (inner ears, tongue)
    (255, 255, 255),   # white (eye glint)
])
DARK = (32, 24, 19, 255)
CREAM = (242, 226, 196, 255)
CLEAR = (0, 0, 0, 0)

BLOCK = 10                 # generated pixels per art pixel
STAND_BOX = (36, 40)       # every upright pet pose
SLEEP_BOX = (36, 24)       # lying down

# The rows/columns of `pet_sit` her eyes occupy, used to derive the blink.
EYE_ROWS = range(10, 17)
EYE_COLUMNS = (range(4, 11), range(14, 22))
EYE_LID_ROW = 13


def generated_poses():
    """The six generated poses as 1x RGBA images, tight to their own ink."""
    image = np.array(Image.open(GENERATED).convert("RGB")).astype(int)
    height, width, _ = image.shape
    grid_w, grid_h = width // BLOCK, height // BLOCK
    centres = image[BLOCK // 2::BLOCK, BLOCK // 2::BLOCK, :][:grid_h, :grid_w]

    whiteish = centres.sum(axis=2) > 700
    background = np.zeros((grid_h, grid_w), bool)
    queue = deque()
    for y in range(grid_h):
        for x in range(grid_w):
            if (y in (0, grid_h - 1) or x in (0, grid_w - 1)) and whiteish[y, x]:
                background[y, x] = True
                queue.append((y, x))
    while queue:
        y, x = queue.popleft()
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < grid_h and 0 <= nx < grid_w:
                if whiteish[ny, nx] and not background[ny, nx]:
                    background[ny, nx] = True
                    queue.append((ny, nx))

    distance = ((centres[:, :, None, :] - PALETTE[None, None, :, :]) ** 2).sum(axis=3)
    snapped = PALETTE[distance.argmin(axis=2)]
    alpha = np.where(background, 0, 255)
    quantized = Image.fromarray(np.dstack([snapped, alpha]).astype(np.uint8))

    ink = ~background
    columns = ink.any(axis=0)
    runs, start = [], None
    for x, filled in enumerate(columns):
        if filled and start is None:
            start = x
        elif not filled and start is not None:
            runs.append((start, x))
            start = None
    if start is not None:
        runs.append((start, len(columns)))
    runs = [run for run in runs if run[1] - run[0] > 2]

    names = ["sit", "blink", "groom", "sleep", "eat", "happy"]
    assert len(runs) == len(names), f"expected {len(names)} poses, found {len(runs)}"

    poses = {}
    for name, (x0, x1) in zip(names, runs):
        rows = np.where(ink[:, x0:x1].any(axis=1))[0]
        poses[name] = quantized.crop((x0, rows.min(), x1, rows.max() + 1))
    return poses


def blink(sit):
    """`pet_sit` with her eyes shut, so a blink moves nothing else."""
    image = sit.copy()
    pixels = image.load()
    for y in EYE_ROWS:
        for span in EYE_COLUMNS:
            for x in span:
                if x < image.width and y < image.height and pixels[x, y][3]:
                    pixels[x, y] = DARK
    for span in EYE_COLUMNS:
        for x in list(span)[1:-1]:
            if pixels[x, EYE_LID_ROW][3]:
                pixels[x, EYE_LID_ROW] = CREAM
    return image


def breathe(pose):
    """One pixel of breath: everything settles a row, the feet stay put."""
    image = Image.new("RGBA", pose.size, CLEAR)
    image.paste(pose.crop((0, 0, pose.width, pose.height - 1)), (0, 1))
    bottom = pose.crop((0, pose.height - 1, pose.width, pose.height))
    image.paste(bottom, (0, pose.height - 1), bottom)
    return image


def boxed(pose, box):
    """Bottom-aligned and centred inside a fixed frame box."""
    width, height = box
    assert pose.width <= width and pose.height <= height, f"{pose.size} exceeds {box}"
    canvas = Image.new("RGBA", box, CLEAR)
    canvas.paste(pose, ((width - pose.width) // 2, height - pose.height))
    return canvas


def main():
    poses = generated_poses()
    sit = poses["sit"]

    frames = {
        "pet_sit": [boxed(sit, STAND_BOX), boxed(breathe(sit), STAND_BOX)],
        "pet_blink": [boxed(blink(sit), STAND_BOX)],
        "pet_groom": [boxed(poses["groom"], STAND_BOX),
                      boxed(breathe(poses["groom"]), STAND_BOX)],
        "pet_happy": [boxed(poses["happy"], STAND_BOX)],
        "pet_eat": [boxed(poses["eat"], STAND_BOX),
                    boxed(breathe(poses["eat"]), STAND_BOX)],
        "pet_sleep": [boxed(poses["sleep"], SLEEP_BOX),
                      boxed(breathe(poses["sleep"]), SLEEP_BOX)],
    }

    manifest = json.load(open(MANIFEST))
    old = Image.open(SHEET).convert("RGBA")
    runner_height = 159          # the runner's own region; never touched
    runner = old.crop((0, 0, old.width, runner_height))

    # Lay the pet frames out in rows below the runner's region.
    margin, gap = 2, 2
    rows, row, x = [], [], margin
    for name in ["pet_sit", "pet_blink", "pet_groom", "pet_happy", "pet_eat", "pet_sleep"]:
        for index, frame in enumerate(frames[name]):
            if x + frame.width + margin > old.width:
                rows.append(row)
                row, x = [], margin
            row.append((name, index, frame, x))
            x += frame.width + gap
    rows.append(row)

    y = runner_height + gap
    placements = []
    for row in rows:
        tallest = max(frame.height for _, _, frame, _ in row)
        for name, index, frame, x in row:
            placements.append((name, index, frame, x, y + tallest - frame.height))
        y += tallest + gap
    sheet_height = y + margin - gap

    sheet = Image.new("RGBA", (old.width, sheet_height), CLEAR)
    sheet.paste(runner, (0, 0))
    packed = {}
    for name, index, frame, x, top in placements:
        sheet.paste(frame, (x, top))
        packed.setdefault(name, []).append(
            {"x": x, "y": top, "w": frame.width, "h": frame.height}
        )

    for name, boxes in packed.items():
        manifest["frames"][name] = boxes
    sheet.save(SHEET)
    with open(MANIFEST, "w") as handle:
        json.dump(manifest, handle, indent=2)
        handle.write("\n")

    print(f"sheet {old.width}x{sheet_height}")
    for name, boxes in packed.items():
        print(f"  {name}: {boxes}")


if __name__ == "__main__":
    main()
