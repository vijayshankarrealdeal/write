"""Mirror of the Flutter app's WritingType + format taxonomy.

The reader app stores user preferences (onboarding + Feed Preferences page)
as exact strings drawn from these lists. Anything the ingest pipeline
emits as `writing_types` on a FeedItem must match — otherwise a published
book never matches the user's preference filter.

Source of truth in the app:
  - lib/models/writing_model.dart      (the enum + per-type subtype enums)
  - lib/models/preference_options.dart (the goal/mood/role/etc lists)

Keep this file in sync when the app's enum changes.
"""

from __future__ import annotations

# WritingType enum names from lib/models/writing_model.dart.
# Order matches the enum so the same string survives a round-trip.
WRITING_TYPES: list[str] = [
    "creative",
    "digitalContent",
    "personal",
    "journalistic",
    "marketing",
]

# displayName for each subtype, per WritingType. The Flutter UI persists
# the displayName (not the enum name) when the user picks a format chip,
# so the agent must emit the displayName form too.
WRITING_TYPE_FORMATS: dict[str, list[str]] = {
    "creative": ["Short Story", "Poetry", "Script", "Flash Fiction"],
    "digitalContent": [
        "Blog Post",
        "Newsletter",
        "Social Media Post",
        "Caption",
        "Thread",
        "Reels Script",
    ],
    "personal": [
        "Storytime",
        "Rant",
        "Open Letter",
        "Life Update",
        "Affirmation",
        "Deep Talk",
        "Relationship Tea",
        "Mental Health Log",
    ],
    "journalistic": ["News Article", "Editorial", "Opinion Piece", "Interview"],
    "marketing": ["Ad Copy", "Product Description", "Email Campaign", "Slogan"],
}

# Synonyms the LLM commonly emits → canonical WritingType. Lowercased keys.
# Keep this conservative: when in doubt, fall through to the default
# rather than picking the wrong bucket.
_WRITING_TYPE_SYNONYMS: dict[str, str] = {
    # creative
    "creative": "creative",
    "fiction": "creative",
    "literary": "creative",
    "literature": "creative",
    "novel": "creative",
    "story": "creative",
    "stories": "creative",
    "poetry": "creative",
    "poem": "creative",
    "epic": "creative",
    "myth": "creative",
    "mythology": "creative",
    "mythic": "creative",
    "sacred": "creative",
    "sacred-text": "creative",
    "scripture": "creative",
    "religious": "creative",
    "translation": "creative",
    "retelling": "creative",
    "mythic-retelling": "creative",
    "drama": "creative",
    "screenplay": "creative",
    "play": "creative",
    "book": "creative",
    # digital content
    "digitalcontent": "digitalContent",
    "digital-content": "digitalContent",
    "blog": "digitalContent",
    "newsletter": "digitalContent",
    "social": "digitalContent",
    "social-media": "digitalContent",
    "thread": "digitalContent",
    "post": "digitalContent",
    "caption": "digitalContent",
    # personal
    "personal": "personal",
    "memoir": "personal",
    "diary": "personal",
    "journal": "personal",
    "essay": "personal",
    "reflection": "personal",
    "letter": "personal",
    # journalistic
    "journalism": "journalistic",
    "journalistic": "journalistic",
    "news": "journalistic",
    "report": "journalistic",
    "editorial": "journalistic",
    "opinion": "journalistic",
    "interview": "journalistic",
    "non-fiction": "journalistic",
    "nonfiction": "journalistic",
    # marketing
    "marketing": "marketing",
    "ad": "marketing",
    "advertising": "marketing",
    "copy": "marketing",
    "ad-copy": "marketing",
    "slogan": "marketing",
}

# Default when nothing maps cleanly. Most ingested long-form books are
# retellings/translations/myth — those land in 'creative'.
DEFAULT_WRITING_TYPE = "creative"


def coerce_writing_type(value: str | None) -> str:
    """Snap a free-form string to a canonical WritingType enum name."""
    if not value or not isinstance(value, str):
        return DEFAULT_WRITING_TYPE
    key = value.strip().lower().replace("_", "-")
    if key in _WRITING_TYPE_SYNONYMS:
        return _WRITING_TYPE_SYNONYMS[key]
    # Already canonical (case-insensitive)?
    for canonical in WRITING_TYPES:
        if canonical.lower() == key:
            return canonical
    return DEFAULT_WRITING_TYPE


def coerce_writing_type_format(writing_type: str, value: str | None) -> str:
    """Snap a free-form format/subtype string to a valid displayName for
    the given writing_type. Falls back to the first format in the list."""
    formats = WRITING_TYPE_FORMATS.get(writing_type, [])
    if not formats:
        return ""
    if not value or not isinstance(value, str):
        return formats[0]
    needle = value.strip().lower()
    if not needle:
        return formats[0]
    # Exact case-insensitive match
    for f in formats:
        if f.lower() == needle:
            return f
    # Loose match: ignore separators/spacing
    def _norm(s: str) -> str:
        return s.lower().replace(" ", "").replace("-", "").replace("_", "")
    needle_n = _norm(needle)
    for f in formats:
        if _norm(f) == needle_n:
            return f
    # Substring match (e.g. "short" → "Short Story")
    for f in formats:
        if needle_n in _norm(f) or _norm(f) in needle_n:
            return f
    return formats[0]
