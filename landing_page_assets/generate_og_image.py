"""
One-shot generator for the social-card image used by every page in
the InkSpaceX marketing site (Open Graph + Twitter Card). Produces
1200×630 PNG with the brand colours + wordmark.

Run from repo root:

    python landing_page_assets/generate_og_image.py

Writes to `landing_page_assets/og-image.png` and a per-page variant
under `landing_page_assets/og-<page>.png` for the four comparison
pages and three blog posts. Each variant just swaps the eyebrow line.
"""

from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

OUT_DIR = Path(__file__).parent
W, H = 1200, 630

# Brand palette (mirrors landing.html CSS variables).
CREAM = (250, 250, 247)
INK = (17, 17, 17)
ACCENT = (30, 110, 244)         # blue
ACCENT_3 = (255, 210, 94)       # yellow
ACCENT_2 = (107, 91, 255)       # purple
MUTED = (91, 100, 112)


def _font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    """Pick the best available system font; bold variant when asked."""
    candidates = [
        # Inter / Helvetica family — available on macOS by default.
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/HelveticaNeue.ttc",
        "/Library/Fonts/Arial.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
    ]
    for path in candidates:
        if Path(path).exists():
            try:
                return ImageFont.truetype(path, size, index=1 if bold else 0)
            except Exception:
                try:
                    return ImageFont.truetype(path, size)
                except Exception:
                    continue
    return ImageFont.load_default()


def _measure(draw: ImageDraw.ImageDraw, text: str, font) -> tuple[int, int]:
    bbox = draw.textbbox((0, 0), text, font=font)
    return bbox[2] - bbox[0], bbox[3] - bbox[1]


def render(out_path: Path, eyebrow: str, headline: str, subhead: str) -> None:
    img = Image.new("RGB", (W, H), CREAM)
    draw = ImageDraw.Draw(img)

    # Decorative band at the top — same yellow accent the landing uses.
    draw.rectangle((0, 0, W, 16), fill=ACCENT_3)

    # Brand wordmark, top-left.
    brand_font = _font(40, bold=True)
    draw.text((64, 56), "InkSpaceX", fill=INK, font=brand_font)
    # Underline accent under the X.
    bw, _ = _measure(draw, "InkSpaceX", brand_font)
    underline_x = 64 + bw - 22
    draw.rectangle((underline_x, 100, underline_x + 22, 108), fill=ACCENT)

    # Eyebrow chip — small uppercase pill that varies per page.
    eb_font = _font(20, bold=True)
    eb_w, eb_h = _measure(draw, eyebrow, eb_font)
    pad_x, pad_y = 16, 10
    eb_y = 200
    draw.rounded_rectangle(
        (64, eb_y, 64 + eb_w + pad_x * 2, eb_y + eb_h + pad_y * 2),
        radius=999,
        fill=ACCENT_3,
    )
    draw.text((64 + pad_x, eb_y + pad_y), eyebrow, fill=INK, font=eb_font)

    # Headline — wraps automatically across two lines if needed.
    hl_font = _font(72, bold=True)
    headline_y = eb_y + eb_h + pad_y * 2 + 32
    # Naive word-wrap to fit in 1080px wide.
    max_width = W - 128
    words = headline.split()
    lines: list[str] = []
    current = ""
    for word in words:
        candidate = (current + " " + word).strip()
        cw, _ = _measure(draw, candidate, hl_font)
        if cw <= max_width:
            current = candidate
        else:
            if current:
                lines.append(current)
            current = word
    if current:
        lines.append(current)
    line_h = _measure(draw, "Ag", hl_font)[1] + 12
    for i, line in enumerate(lines[:2]):
        draw.text((64, headline_y + i * line_h), line, fill=INK, font=hl_font)

    # Subhead — single line, muted.
    sub_font = _font(28)
    sub_y = headline_y + len(lines[:2]) * line_h + 24
    draw.text((64, sub_y), subhead, fill=MUTED, font=sub_font)

    # Domain stamp, bottom-right.
    domain_font = _font(22, bold=True)
    dom_w, dom_h = _measure(draw, "inkspacex.com", domain_font)
    draw.text(
        (W - dom_w - 64, H - dom_h - 48),
        "inkspacex.com",
        fill=ACCENT,
        font=domain_font,
    )

    img.save(out_path, "PNG", optimize=True)
    print(f"wrote {out_path} ({out_path.stat().st_size // 1024} KB)")


VARIANTS = {
    "og-image.png": (
        "WRITING SOFTWARE",
        "A calm place to write your novel.",
        "Distraction-free editor • offline • free",
    ),
    "og-scrivener-alternative.png": (
        "SCRIVENER ALTERNATIVE",
        "Switch from Scrivener without losing your work.",
        "Web, mobile, desktop — Scrivener has none of those",
    ),
    "og-scrivener-vs.png": (
        "COMPARISON",
        "Scrivener vs InkSpaceX — feature for feature.",
        "Honest, current, no marketing fluff",
    ),
    "og-sudowrite-vs.png": (
        "COMPARISON",
        "Sudowrite vs InkSpaceX — what each does best.",
        "AI assist, distraction-free editor, free tier",
    ),
    "og-best-2026.png": (
        "GUIDE • 2026",
        "Best writing software of 2026.",
        "Picked for fiction writers and long-form drafters",
    ),
    "og-blog-three-act.png": (
        "BLOG • CRAFT",
        "Outline a novel with the Three-Act Structure.",
        "A free template + step-by-step walkthrough",
    ),
    "og-blog-ugly-draft.png": (
        "BLOG • CRAFT",
        "Why your first draft should be ugly.",
        "A working writer's guide to fast drafting",
    ),
    "og-blog-switching.png": (
        "BLOG • TOOLS",
        "Online writing software in 2026.",
        "What to look for if you're leaving Scrivener",
    ),
}

if __name__ == "__main__":
    for name, (eb, hl, sub) in VARIANTS.items():
        render(OUT_DIR / name, eb, hl, sub)
