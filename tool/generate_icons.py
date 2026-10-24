"""Render branding and Android launcher icons from the logo mark (requires Pillow).

Source: branding/wakeguard-mark.png, the transparent coral/cyan alarm-shield mark.
Then run generate_ios_icons.py to refresh the opaque iOS icon catalog.
"""

from pathlib import Path

from PIL import Image, ImageDraw

BACKGROUND = "#10141A"


def mark(root: Path) -> Image.Image:
    with Image.open(root / "branding/wakeguard-mark.png") as source:
        art = source.convert("RGBA")
    art = art.crop(art.getchannel("A").point(lambda a: 255 if a > 8 else 0).getbbox())
    side = max(art.size)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(art, ((side - art.width) // 2, (side - art.height) // 2))
    return square


def placed(art: Image.Image, canvas: int, scale: float) -> Image.Image:
    """The mark centred on a transparent square canvas at [scale] of its width."""
    size = round(canvas * scale)
    layer = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    resized = art.resize((size, size), Image.Resampling.LANCZOS)
    layer.paste(resized, ((canvas - size) // 2, (canvas - size) // 2), resized)
    return layer


def rounded_tile(art: Image.Image, size: int) -> Image.Image:
    tile = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size - 1, size - 1), radius=round(size * 0.22), fill=255)
    tile.paste(Image.new("RGBA", (size, size), BACKGROUND), mask=mask)
    return Image.alpha_composite(tile, placed(art, size, 0.70))


def main():
    root = Path(__file__).resolve().parent.parent
    res = root / "android/app/src/main/res"
    art = mark(root)

    branding = rounded_tile(art, 1024)
    branding.save(root / "branding/wakeguard-logo.png", optimize=True)

    densities = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
    for density, factor in densities.items():
        folder = res / f"mipmap-{density}"
        legacy = round(48 * factor)
        branding.resize((legacy, legacy), Image.Resampling.LANCZOS).save(folder / "ic_launcher.png", optimize=True)
        # Adaptive layers are 108dp; keep the mark inside the 66dp safe zone.
        adaptive = round(108 * factor)
        foreground = placed(art, adaptive, 0.56)
        foreground.save(folder / "ic_launcher_foreground.png", optimize=True)
        monochrome = Image.new("RGBA", foreground.size, (255, 255, 255, 0))
        monochrome.putalpha(foreground.getchannel("A"))
        monochrome.save(folder / "ic_launcher_monochrome.png", optimize=True)
        for name in ("ic_launcher.png", "ic_launcher_foreground.png", "ic_launcher_monochrome.png"):
            with Image.open(folder / name) as icon:
                assert icon.size[0] in (legacy, adaptive)
    print("Generated branding PNG and Android legacy, adaptive and monochrome icons.")


if __name__ == "__main__":
    main()
