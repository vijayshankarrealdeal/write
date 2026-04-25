#!/usr/bin/env python3
"""
Generate InkSpaceX app icon variants from the master icon.

Reads assets/icon/icon.png and produces:
  - assets/icon/icon_foreground.png  (Android adaptive, 18% padding)
  - web/favicon.png                  (32x32)
  - web/icons/Icon-192.png           (192x192)
  - web/icons/Icon-512.png           (512x512)
  - web/icons/Icon-maskable-192.png  (192x192, 10% padding, black bg)
  - web/icons/Icon-maskable-512.png  (512x512, 10% padding, black bg)

After running this script, run:
    dart run flutter_launcher_icons
to regenerate iOS, Android, and macOS icons.
"""

import os
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MASTER = os.path.join(ROOT, "assets", "icon", "icon.png")


def make_square(img, bg_color=(0, 0, 0, 255)):
    """Pad a non-square image to square, centered."""
    w, h = img.size
    if w == h:
        return img
    size = max(w, h)
    square = Image.new("RGBA", (size, size), bg_color)
    square.paste(img, ((size - w) // 2, (size - h) // 2), img)
    return square


def main():
    icon = Image.open(MASTER).convert("RGBA")
    print(f"Source icon: {icon.size[0]}x{icon.size[1]}")

    square = make_square(icon)
    master = square.resize((1024, 1024), Image.LANCZOS)

    # Adaptive foreground (18% padding, transparent bg)
    pad = int(1024 * 0.18)
    inner = 1024 - 2 * pad
    fg = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    resized = master.resize((inner, inner), Image.LANCZOS)
    fg.paste(resized, (pad, pad), resized)
    fg_path = os.path.join(ROOT, "assets", "icon", "icon_foreground.png")
    fg.save(fg_path, "PNG")
    print(f"Adaptive foreground: {fg_path}")

    # Web favicon
    fav = master.resize((32, 32), Image.LANCZOS)
    fav.save(os.path.join(ROOT, "web", "favicon.png"), "PNG")
    print("Created web/favicon.png")

    # Web icons
    for sz, name in [(192, "Icon-192.png"), (512, "Icon-512.png")]:
        out = master.resize((sz, sz), Image.LANCZOS)
        out.save(os.path.join(ROOT, "web", "icons", name), "PNG")
        print(f"Created web/icons/{name}")

    # Maskable web icons (10% padding, black bg)
    for sz, name in [(192, "Icon-maskable-192.png"), (512, "Icon-maskable-512.png")]:
        mask = Image.new("RGBA", (sz, sz), (0, 0, 0, 255))
        p = int(sz * 0.1)
        inner_s = sz - 2 * p
        r = master.resize((inner_s, inner_s), Image.LANCZOS)
        mask.paste(r, (p, p), r)
        mask.save(os.path.join(ROOT, "web", "icons", name), "PNG")
        print(f"Created web/icons/{name}")

    print("\nDone. Now run: dart run flutter_launcher_icons")


if __name__ == "__main__":
    main()
