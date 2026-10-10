"""Render branding and legacy Android icons (requires resvg-py and Pillow).

Then run generate_ios_icons.py to refresh the opaque iOS icon catalog.
Android adaptive and monochrome vector geometry must match the source SVG.
"""

from io import BytesIO
from pathlib import Path

from PIL import Image
import resvg_py


def main():
    root = Path(__file__).resolve().parent.parent
    source = (root / "branding/wakeguard-logo.svg").read_text()
    png = resvg_py.svg_to_bytes(svg_string=source)
    with Image.open(BytesIO(png)) as rendered:
        artwork = rendered.convert("RGBA")
        artwork.save(root / "branding/wakeguard-logo.png", optimize=True)
        densities = {"mdpi": 48, "hdpi": 72, "xhdpi": 96,
                     "xxhdpi": 144, "xxxhdpi": 192}
        for density, size in densities.items():
            destination = root / f"android/app/src/main/res/mipmap-{density}/ic_launcher.png"
            artwork.resize((size, size), Image.Resampling.LANCZOS).save(
                destination, optimize=True
            )
            with Image.open(destination) as icon:
                assert icon.size == (size, size)
        assert artwork.size == (1024, 1024)
    print("Generated branding PNG and verified all 5 Android legacy icons.")


if __name__ == "__main__":
    main()
