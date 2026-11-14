#!/usr/bin/env python3
"""Build iPhone/iPad AppIcon sizes from a square master (generation requires Pillow)."""
import argparse
import json
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "BL616Camera/Resources/Assets.xcassets"
ICON_SET = CATALOG / "AppIcon.appiconset"
MASTER = ICON_SET / "AppIcon-1024.png"


def slots():
    images = []
    for idiom, sizes in (
        ("iphone", ((20, (2, 3)), (29, (2, 3)), (40, (2, 3)), (60, (2, 3)))),
        ("ipad", ((20, (1, 2)), (29, (1, 2)), (40, (1, 2)), (76, (1, 2)), (83.5, (2,)))),
        ("ios-marketing", ((1024, (1,)),)),
    ):
        for points, scales in sizes:
            for scale in scales:
                pixels = int(points * scale)
                images.append(dict(idiom=idiom, size=f"{points:g}x{points:g}", scale=f"{scale}x",
                                   filename=f"AppIcon-{pixels}.png"))
    return images


def generate(source):
    from PIL import Image

    with Image.open(source) as image:
        if image.width != image.height:
            raise SystemExit("AppIcon master must be square")
        rgba = image.convert("RGBA")
        background = Image.new("RGBA", rgba.size, "white")
        image = Image.alpha_composite(background, rgba).convert("RGB")
        master = image.resize((1024, 1024), Image.Resampling.LANCZOS)
    ICON_SET.mkdir(parents=True, exist_ok=True)
    for pixels in sorted({int(float(i["size"].split("x")[0]) * int(i["scale"][0])) for i in slots()}):
        master.resize((pixels, pixels), Image.Resampling.LANCZOS).save(
            ICON_SET / f"AppIcon-{pixels}.png", optimize=True)
    (CATALOG / "Contents.json").write_text(json.dumps(dict(info=dict(author="xcode", version=1)), indent=2) + "\n")
    (ICON_SET / "Contents.json").write_text(json.dumps(
        dict(images=slots(), info=dict(author="xcode", version=1)), indent=2) + "\n")


def check():
    contents = json.loads((ICON_SET / "Contents.json").read_text())
    if contents["images"] != slots():
        raise SystemExit("AppIcon Contents.json is out of date")
    for image in slots():
        pixels = int(float(image["size"].split("x")[0]) * int(image["scale"][0]))
        data = (ICON_SET / image["filename"]).read_bytes()
        if (data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR" or
                struct.unpack(">II", data[16:24]) != (pixels, pixels) or data[24:26] != b"\x08\x02"):
            raise SystemExit(f"AppIcon must be an opaque 8-bit RGB PNG at {pixels}px: {image['filename']}")
    print(f"AppIcon checks passed: {len(slots())} iPhone/iPad/App Store slots, opaque RGB PNGs")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", nargs="?", type=Path, default=MASTER)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if not args.check:
        generate(args.source)
    check()
