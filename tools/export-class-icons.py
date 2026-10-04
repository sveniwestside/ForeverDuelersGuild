#!/usr/bin/env python3
"""Fetch authentic class icons from Blizzard's image CDN and save PNG copies.

Uses existing Pillow for lossless JPEG-decoded-pixel-to-PNG conversion. No
resizing, recoloring, or generated art. Network access is required only when
refreshing these committed assets, never when running the local website.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
from urllib.request import Request, urlopen

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
CLASSES = ("warrior", "paladin", "hunter", "rogue", "priest", "shaman", "mage", "warlock", "druid")
BASE_URL = "https://render.worldofwarcraft.com/icons/56/"
MAX_IMAGE_BYTES = 1024 * 1024


def fetch_icons(output):
    icons = []
    for name in CLASSES:
        url = f"{BASE_URL}classicon_{name}.jpg"
        request = Request(url, headers={"User-Agent": "ForeverDuelGuild-AssetImporter/1.0"})
        with urlopen(request, timeout=20) as response:
            if response.status != 200 or response.headers.get_content_type() != "image/jpeg":
                raise ValueError(f"Unexpected image response for {name}")
            original = response.read(MAX_IMAGE_BYTES + 1)
        if len(original) > MAX_IMAGE_BYTES:
            raise ValueError(f"Image limit exceeded for {name}")
        with Image.open(io.BytesIO(original)) as image:
            if image.format != "JPEG" or image.size != (56, 56):
                raise ValueError(f"Unexpected Blizzard icon format or size for {name}")
            pixels = image.convert("RGB")
            encoded = io.BytesIO()
            pixels.save(encoded, format="PNG")
            png = encoded.getvalue()
            with Image.open(io.BytesIO(png)) as decoded:
                if decoded.convert("RGB").tobytes() != pixels.tobytes():
                    raise ValueError(f"Conversion changed icon pixels for {name}")
        icons.append((name, png, {
            "file": f"{name}.png", "source_url": url,
            "source_sha256": hashlib.sha256(original).hexdigest(),
            "png_sha256": hashlib.sha256(png).hexdigest(),
            "width": 56, "height": 56,
        }))
    output.mkdir(parents=True, exist_ok=True)
    for name, png, metadata in icons:
        (output / metadata["file"]).write_bytes(png)
        print(f"{name}: verified 56x56 Blizzard JPEG -> PNG ({len(png)} bytes)")
    manifest = {
        "copyright": "World of Warcraft artwork © Blizzard Entertainment, Inc.",
        "license_note": "Blizzard-owned game artwork; not covered by this project's code license. No endorsement or additional license is claimed.",
        "transformation": "JPEG decoded as RGB and encoded as PNG; dimensions and decoded RGB pixels are unchanged.",
        "retrieved_at_utc": datetime.now(timezone.utc).isoformat(),
        "icons": [metadata for name, png, metadata in icons],
    }
    (output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "web" / "public" / "assets" / "classes")
    arguments = parser.parse_args()
    fetch_icons(arguments.output.resolve())


if __name__ == "__main__":
    main()
