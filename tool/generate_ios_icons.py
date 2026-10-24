"""Generate opaque iOS icons from the rendered WakeGuard logo (requires Pillow)."""

import json
from pathlib import Path

from PIL import Image


def main():
    root = Path(__file__).resolve().parent.parent
    catalog = root / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    entries = json.loads((catalog / "Contents.json").read_text())["images"]
    with Image.open(root / "branding/wakeguard-logo.png") as source:
        rgba = source.convert("RGBA")
        # Remove pre-rounded transparent corners; iOS applies its own mask.
        artwork = Image.new("RGB", rgba.size, "#10141A")
        artwork.paste(rgba, mask=rgba.getchannel("A"))
        for entry in entries:
            size = round(float(entry["size"].split("x")[0]) * float(entry["scale"].removesuffix("x")))
            icon = artwork.resize((size, size), Image.Resampling.LANCZOS)
            destination = catalog / entry["filename"]
            icon.save(destination)
            with Image.open(destination) as generated:
                assert generated.size == (size, size)
                assert generated.mode == "RGB", "iOS icons must have no alpha channel"
        print(f"Generated and verified {len(entries)} iOS icon entries.")


if __name__ == "__main__":
    main()
