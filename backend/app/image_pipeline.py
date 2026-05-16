"""Image processing pipeline.

Takes an uploaded image, decodes it, fixes EXIF orientation, strips metadata,
and emits a set of WebP size variants. Also computes a blurhash for instant
placeholders and a dominant color hex for chrome (cards, splash backgrounds,
etc.) before the image arrives.

Variants are sized for: avatars/thumbnails (160), feed cards (400), full-width
list items (800), hero/cover at retina (1600). Originals are kept (re-encoded
to WebP) for editor/zoom use.

The processing runs in a thread pool (Pillow is sync) so it doesn't block the
event loop.

Decoder hardening:
    * `pillow-heif` is registered so iPhone HEIC/HEIF uploads decode.
    * `Image.MAX_IMAGE_PIXELS` is capped — Pillow raises `DecompressionBombError`
      above the limit so a small malicious file can't OOM the worker.
"""
from __future__ import annotations

import asyncio
import io
from dataclasses import asdict, dataclass
from typing import Iterable

import blurhash
from PIL import Image, ImageOps

# HEIC/HEIF support for iPhone uploads. Side-effect import.
try:
    from pillow_heif import register_heif_opener

    register_heif_opener()
except ImportError:  # pragma: no cover - keeps the module importable in dev
    pass

# Decompression-bomb cap. 50 MP comfortably covers a 50MP phone sensor while
# rejecting the 100KB-PNG-that-decompresses-to-gigabytes attack class. Pillow
# raises `Image.DecompressionBombError` above this limit; callers must catch.
Image.MAX_IMAGE_PIXELS = 50_000_000


# (variant key, max edge in CSS pixels). Width OR height, whichever is larger,
# is bounded by max_edge — aspect ratio is preserved.
DEFAULT_VARIANTS: tuple[tuple[str, int], ...] = (
    ("thumb", 160),
    ("small", 400),
    ("medium", 800),
    ("large", 1600),
)

# Avatars are square and never need a 1600px variant — overrides per scope.
AVATAR_VARIANTS: tuple[tuple[str, int], ...] = (
    ("thumb", 96),
    ("small", 256),
    ("medium", 512),
)

# Editor inline images: original is the "full" the user pasted. We emit
# narrower variants for small renders inside the article body.
EDITOR_VARIANTS: tuple[tuple[str, int], ...] = (
    ("small", 480),
    ("medium", 960),
    ("large", 1600),
)

# Quality knobs. WebP at q=82 is visually indistinguishable from source for
# most photographic content while ~30% smaller than equivalent JPEG.
WEBP_QUALITY = 82
# Max edge for the "original" re-encode. Anything larger than this is downscaled
# — protects against 12MP phone uploads bloating storage.
MAX_ORIGINAL_EDGE = 2400


@dataclass(slots=True)
class ProcessedVariant:
    key: str            # "thumb" | "small" | "medium" | "large" | "original"
    fmt: str            # "webp"
    data: bytes
    width: int
    height: int


@dataclass(slots=True)
class ImageMeta:
    """Wire-format metadata attached to every processed image.

    Stored as JSONB on the row that owns the image, returned alongside the
    primary URL on every upload response. The frontend uses `variants` to pick
    the right size for the rendered area (`base + '/' + key + '.' + fmt`).
    """
    base_url: str           # public base, no extension (e.g. ".../avatar")
    width: int              # original width, post-orientation fix
    height: int             # original height, post-orientation fix
    blurhash: str           # 4x3 component blurhash for placeholder
    color: str              # dominant color hex like "#a37c4f"
    variants: dict[str, dict[str, int]]  # key -> {w, h}, present formats live next to each variant
    formats: list[str]      # ["webp"] — what the server emitted

    def to_dict(self) -> dict:
        return asdict(self)


def _load_oriented(data: bytes) -> Image.Image:
    """Decode bytes, apply EXIF orientation, drop metadata, normalize mode."""
    img = Image.open(io.BytesIO(data))
    # Apply EXIF rotation so width/height match the displayed image.
    img = ImageOps.exif_transpose(img)
    # Pillow lazy-loads — force decode now so we can close the underlying stream.
    img.load()
    # Strip all metadata by recreating the image without `info`.
    if img.mode in ("P", "LA"):
        img = img.convert("RGBA")
    elif img.mode not in ("RGB", "RGBA", "L"):
        img = img.convert("RGB")
    return img


def _resize(img: Image.Image, max_edge: int) -> Image.Image:
    w, h = img.size
    longest = max(w, h)
    if longest <= max_edge:
        return img.copy()
    scale = max_edge / longest
    new_size = (max(1, round(w * scale)), max(1, round(h * scale)))
    return img.resize(new_size, Image.Resampling.LANCZOS)


def _square_crop(img: Image.Image) -> Image.Image:
    """Center-crop to a square. For portrait shots, bias the crop upward by
    ~15% of the excess height so faces (usually in the top third) stay in
    frame instead of being cropped off — what BoxFit.cover would otherwise
    show inside a circular avatar.
    """
    w, h = img.size
    if w == h:
        return img.copy()
    side = min(w, h)
    if h > w:
        # Portrait: subjects usually sit in the upper portion. A pure center
        # crop would slice their heads off; biasing the window upward keeps
        # the face.
        excess = h - side
        top = max(0, round(excess * 0.35))
        return img.crop((0, top, side, top + side))
    # Landscape: center horizontally.
    excess = w - side
    left = excess // 2
    return img.crop((left, 0, left + side, side))


def _encode(img: Image.Image, fmt: str) -> bytes:
    if fmt != "webp":
        raise ValueError(f"unknown fmt: {fmt}")
    buf = io.BytesIO()
    img.save(buf, format="WEBP", quality=WEBP_QUALITY, method=4)
    return buf.getvalue()


def _dominant_color(img: Image.Image) -> str:
    """Return the most-common color via palette quantization.

    A 1×1 average flattens "red apple on white background" into pinkish-grey;
    quantizing to a small palette and taking the most-populated bucket gives
    the actual eye-catching color. Median-cut (Pillow's default) handles
    photographic content well.
    """
    # 64×64 is enough resolution to keep small accent regions in the palette
    # without quantizing for thousands of pixels.
    sample = img.convert("RGB").resize((64, 64), Image.Resampling.LANCZOS)
    pal = sample.quantize(colors=8, method=Image.Quantize.MEDIANCUT)
    palette = pal.getpalette() or []
    counts = sorted(pal.getcolors() or [], key=lambda c: c[0], reverse=True)
    if not counts or len(palette) < 3:
        return "#cccccc"
    idx = counts[0][1]
    r, g, b = palette[idx * 3 : idx * 3 + 3]
    return f"#{r:02x}{g:02x}{b:02x}"


def _blurhash(img: Image.Image) -> str:
    # blurhash-python wants a small RGB image; 100px max edge keeps encoding fast.
    small = _resize(img, 100).convert("RGB")
    return blurhash.encode(small, x_components=4, y_components=3)


def _process_sync(
    data: bytes,
    sizes: Iterable[tuple[str, int]],
    formats: tuple[str, ...],
    include_original: bool,
    square_crop: bool = False,
) -> tuple[list[ProcessedVariant], int, int, str, str]:
    img = _load_oriented(data)
    if square_crop:
        img = _square_crop(img)
    width, height = img.size
    color = _dominant_color(img)
    bhash = _blurhash(img)

    variants: list[ProcessedVariant] = []
    targets = list(sizes)
    if include_original:
        targets.append(("original", MAX_ORIGINAL_EDGE))

    for key, max_edge in targets:
        resized = _resize(img, max_edge)
        rw, rh = resized.size
        for fmt in formats:
            variants.append(
                ProcessedVariant(
                    key=key,
                    fmt=fmt,
                    data=_encode(resized, fmt),
                    width=rw,
                    height=rh,
                )
            )
    return variants, width, height, color, bhash


async def process_image(
    data: bytes,
    *,
    scope: str = "default",
    formats: tuple[str, ...] = ("webp",),
    include_original: bool = True,
) -> tuple[list[ProcessedVariant], dict]:
    """Process raw upload bytes into variants + a JSON-ready meta dict.

    The returned meta dict has `base_url=""` — callers fill it in once they
    know the storage path.
    """
    if scope == "avatar":
        sizes = AVATAR_VARIANTS
    elif scope == "editor":
        sizes = EDITOR_VARIANTS
    else:
        sizes = DEFAULT_VARIANTS

    loop = asyncio.get_running_loop()
    variants, width, height, color, bhash = await loop.run_in_executor(
        None,
        _process_sync,
        data,
        sizes,
        formats,
        include_original,
        scope == "avatar",
    )

    # Group variant dimensions by key so the frontend can pick a size.
    variant_sizes: dict[str, dict[str, int]] = {}
    for v in variants:
        if v.key not in variant_sizes:
            variant_sizes[v.key] = {"w": v.width, "h": v.height}

    meta = ImageMeta(
        base_url="",  # caller fills this
        width=width,
        height=height,
        blurhash=bhash,
        color=color,
        variants=variant_sizes,
        formats=list(formats),
    ).to_dict()
    return variants, meta
