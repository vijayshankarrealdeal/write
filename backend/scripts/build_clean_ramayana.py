"""Build a clean, chapter-organized PDF from the OCR'd Hari Prasad Shastri Ramayana.

Extracts each chapter via the embedded TOC, applies basic OCR cleanup, then
emits a fresh PDF with a title page, hand-cleaned introduction, navigable
table of contents, and per-chapter sections with bookmarks.
"""

from __future__ import annotations

import re
from pathlib import Path

import fitz
from reportlab.lib.pagesizes import A5
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import cm
from reportlab.lib.enums import TA_JUSTIFY, TA_CENTER, TA_LEFT
from reportlab.platypus import (
    BaseDocTemplate,
    Frame,
    PageTemplate,
    Paragraph,
    Spacer,
    PageBreak,
    NextPageTemplate,
    Flowable,
)
from reportlab.platypus.tableofcontents import TableOfContents
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont


SRC = Path("/home/verti/write/backend/test_model/data/Ramayana.of.Valmiki.by.Hari.Prasad.Shastri.pdf")
DST = Path("/home/verti/write/backend/test_model/data/Ramayana_clean.pdf")


# Hand-cleaned introduction (OCR artifacts in source were too rough to leave raw).
CLEAN_INTRO_PARAGRAPHS = [
    "Western culture is only just beginning to look beyond the Roman and Greek "
    "civilizations for new inspiration. Even so, it is a little surprising that, "
    "although the mighty epics of the Iliad and the Odyssey are widely known and "
    "loved, only a few scholars have studied their Hindu counterparts known as the "
    "Ramayana and the Mahabharata. In fact no good complete modern English "
    "translation of the Ramayana exists, and the best of those made in the last "
    "half of the 19th century are unobtainable outside the larger libraries.",

    "The Ramayana is a work of great antiquity attributed to the illustrious Sage "
    "Valmiki. Its date of composition cannot be fixed with any certainty, "
    "particularly as, in common with other Sanskrit classics, it was not at first "
    "committed to writing, but was passed on from singer to singer. This process "
    "also accounts for the fact that the various versions (Sakhas) of the poem "
    "that have come down to us differ slightly in context. The interesting fact "
    "is that the scholars are agreed that the Ramayana is the grandly conceived "
    "and executed masterpiece of one poet, and not a collection of stories from "
    "many sources, loosely gathered together.",

    "Unfortunately we know very little about the Rishi Valmiki, whose title "
    "&lsquo;Adikavi&rsquo; (First Poet) and pre-eminence in Sanskrit verse has "
    "never been seriously challenged to this day. He was a robber chief in a "
    "forest in Northern India and on one occasion waylaid two ascetics for the "
    "purpose of plundering them. The travellers, however, spoke to him with "
    "kindness, and offered him the spiritual truth in lieu of the gold and silver "
    "which they did not possess. Convinced of their sincerity and on their advice, "
    "Valmiki changed his mode of life and became a devotee of Shri Ramachandra, "
    "the Seventh Incarnation of God (Vishnu) on earth. After a long period of "
    "meditation on the form and virtues of Shri Rama, it is said that he was "
    "granted a vision of Rama&rsquo;s life from beginning to end.",

    "He gave expression to this unique experience, in Sanskrit verse, in the "
    "24,000 slokas (48,000 lines) known as the Ramayana. The sloka is a specific "
    "metre which the poet himself discovered, as is told in a beautiful passage "
    "in the first book.",

    "The poem is divided into seven books (Kandas) of unequal length, which may "
    "be very briefly summarised as follows:",

    "<b>Book I (Bala-Kanda).</b> King Dasaratha of Ayodhya (Oudh) performs a "
    "sacrifice in the hope of obtaining a son. At this time the Gods (Devas) are "
    "alarmed at the power acquired by the mighty Titan named Ravana, who, by the "
    "practice of black magic, had conquered almost all of the known world. King "
    "Dasaratha&rsquo;s prayer is answered and his three wives bear four sons, "
    "Rama, Bharata and the twins Lakshmana and Shatrughna, who are all partial "
    "incarnations of Shri Vishnu. Vishnu, however, manifests himself more fully "
    "in Shri Rama than in the other brothers. The boys grow up and Shri Rama "
    "wins as his bride, Sita, the daughter of King Janaka of the neighbouring "
    "kingdom of Videha.",

    "<b>Book II (Ayodhya-Kanda).</b> King Dasaratha intends to proclaim Shri "
    "Rama heir-apparent, but the jealousy of his second queen, Kaikeyi, is "
    "aroused and she holds the king to a promise made formerly, that he would "
    "grant her two boons. The boons she now secures are the banishment of Shri "
    "Rama to the forest for fourteen years, and the installation of her own son "
    "Bharata as Yuvaraja. According to the law of righteousness (dharma) a vow "
    "must be honoured, and Shri Rama calmly accepts the sentence of exile. He "
    "travels south to Chitrakuta in the Dandaka Forest with his wife Sita and "
    "his brother Lakshmana. King Dasaratha dies of grief and Bharata implores "
    "Shri Rama to return to the throne, but the latter adheres firmly to the "
    "vindication of his father&rsquo;s honour and the fulfilment of his vow.",

    "<b>Book III (Aranya-Kanda).</b> After about ten years in the forest with "
    "her husband, Princess Sita is kidnapped by the Titan Ravana, and taken by "
    "him to his capital, Lanka (the modern Ceylon).",

    "<b>Book IV (Kishkindha-Kanda).</b> Rama and Lakshmana in pursuit of Ravana "
    "and to rescue Sita, enlist the aid of King Sugriva, leader of the monkey "
    "tribe, whose chief minister Hanuman becomes the foremost devotee and "
    "servant of Shri Rama. Help also comes from Vibhishana, brother of Ravana, "
    "who has openly disapproved of the Titan king&rsquo;s conduct, and warned "
    "him of the retribution he may expect for his unrighteous actions.",

    "<b>Book V (Sundara-Kanda).</b> The monkey armies reach the south coast of "
    "India, and, bridging the straits, gain entry into Lanka.",

    "<b>Book VI (Yuddha-Kanda).</b> After a series of pitched battles, Lanka is "
    "captured and Ravana is slain by Shri Rama. Sita demonstrates her purity and "
    "faithfulness to her husband, by successfully undergoing the ordeal by fire. "
    "The period of fourteen years&rsquo; exile is by now completed, and Shri "
    "Rama returns with his consort, his brothers and allies, to the capital "
    "Ayodhya, where he begins a long and glorious reign.",

    "<b>Book VII (Uttara-Kanda).</b> This &lsquo;later section&rsquo; or "
    "epilogue describes the doubts raised in the minds of the citizens "
    "concerning the purity of Sita, and how they compel Shri Rama to send her "
    "to Valmiki&rsquo;s hermitage in the forest where she gives birth to twin "
    "sons, Kusha and Lava. When these boys grow up, they return to Ayodhya and "
    "are recognized by Shri Rama, who subsequently brings Sita back to share "
    "the ruling of the kingdom with him.",

    "This in outline is the story of the Ramayana, which, in the poetic grandeur "
    "of the original, as well as in the later Hindi work on the same theme by "
    "Goswami Tulsidas, has exerted a tremendous influence on the men and women "
    "of India. It is not only poetry of unsurpassed dramatic power and "
    "brilliance, it is a treasure-house of information on rhetoric, medicine, "
    "geology, botany, geography and every facet of the ancient civilization, "
    "with which learned scholars may interest themselves. For every Hindu, Shri "
    "Rama and Sita are the ideal man and woman, the model husband and wife. "
    "Shri Rama is an incarnation of God, the One all-pervading Principle of "
    "Truth and Intelligence, and what higher pattern for one&rsquo;s life could "
    "be chosen than this man of perfect virtue, a lover of truth, compassionate, "
    "just, benevolent, valorous and chivalrous?",

    "The story may also be taken as an allegory. Symbolically Rama and Ravana "
    "represent the forces of light and darkness operating in the human heart, as "
    "well as in the world. Truth, benevolence, mercy and righteousness are the "
    "forces of Light which are opposed by greed, lust, love of pleasure and "
    "power, anger and egoity. The real triumph of man means conquest of the "
    "forces of darkness. In India a festival is celebrated each year on the day "
    "traditionally held to be that on which Ravana fell and the rule of tyranny, "
    "injustice, savagery and unrighteousness ended.",

    "Mention has already been made of Tulsidas&rsquo; later Hindi epic on the "
    "life of Shri Rama, which is probably the most widely read of all in the "
    "present day. One version of the story also forms an episode in the "
    "Mahabharata and another comparatively modern treatment of it is the "
    "Adhyatma Ramayana ascribed to the Sage Vyasa.",

    "The Sage Valmiki himself wrote a long metaphysical classic known as the "
    "Maharamayana or Yoga Vasishtha, which deals with the inner development of "
    "Shri Rama as opposed to his outer deeds and which remains one of the most "
    "authoritative and respected philosophical treatises of Vedanta.",

    "The life of Shri Rama has entered into the consciousness of the Indian "
    "people, and much art and literature, such as Bhavabhuti&rsquo;s dramas, "
    "draw their inspiration from it. The words of Brahma in the Ramayana have "
    "proved so far to be no idle boast: &ldquo;So long as mountains and rivers "
    "have place on the earth, the story of the Ramayana will be told in the "
    "world.&rdquo;",

    "The aim of the translator is to make the story known to English readers in "
    "a complete form. Although it is not possible to reproduce the beauty of "
    "the original poetic form, the true spirit of Valmiki&rsquo;s masterpiece "
    "is here preserved and for those who have vision, the whole significance of "
    "its spiritual purpose will be apparent.",
]


# Generic OCR cleanup: collapse whitespace, fix hyphenated wraps, drop running heads.
HEADER_PATTERNS = [
    re.compile(r"^\s*THE RAMAYANA OF VALMIKI\s*$", re.IGNORECASE),
    re.compile(r"^\s*RAMAYANA OF VALMIKI\s*$", re.IGNORECASE),
    re.compile(r"^\s*BALA[- ]?KANDA\s*$", re.IGNORECASE),
    re.compile(r"^\s*AYODHYA[- ]?KANDA\s*$", re.IGNORECASE),
    re.compile(r"^\s*ARANYA[- ]?KANDA\s*$", re.IGNORECASE),
    re.compile(r"^\s*KISHKINDHA[- ]?KANDA\s*$", re.IGNORECASE),
    re.compile(r"^\s*SUNDARA[- ]?KANDA\s*$", re.IGNORECASE),
    re.compile(r"^\s*YUDDHA[- ]?KANDA\s*$", re.IGNORECASE),
    re.compile(r"^\s*UTTARA[- ]?KANDA\s*$", re.IGNORECASE),
    re.compile(r"^\s*BOOK\s+(I|II|III|IV|V|VI|VII)\b.*$", re.IGNORECASE),
    re.compile(r"^\s*\d{1,4}\s*$"),  # bare page numbers
    re.compile(r"^\s*[ivxlcIVXLC]{1,6}\s*$"),  # roman numeral page numbers
    re.compile(r"^\s*CHAPTER\s+\d+\s*$", re.IGNORECASE),
]


def is_header_line(line: str) -> bool:
    return any(p.match(line) for p in HEADER_PATTERNS)


def extract_body_text(page) -> str:
    """Extract the page's body text, dropping the footnote block.

    Pages use Times-Roman ~6.5pt for body and HiddenHorzOCR / sub-5.6pt
    spans for footnote glosses. Footnote refs (small `1`, `2` markers)
    also appear *inline* in the upper body, so we only treat small spans
    as a footnote-zone signal when they sit in the lower portion of the
    page. Cutoff = topmost such span minus a small buffer to catch
    body-sized words that fell inside the footnote area.
    """
    body_size_threshold = 5.6
    page_h = page.rect.height
    bottom_zone_start = 0.65 * page_h  # only count signals below this y

    d = page.get_text("dict")

    # First pass: find the y of the topmost footnote-zone indicator.
    footnote_y = float("inf")
    for block in d.get("blocks", []):
        if block.get("type") != 0:
            continue
        for line in block.get("lines", []):
            for span in line.get("spans", []):
                y = span["bbox"][1]
                font = span.get("font", "")
                size = span.get("size", 0)
                # HiddenHorzOCR is footnote regardless of position
                if "Hidden" in font and y < footnote_y:
                    footnote_y = y
                # Small spans only count if in lower zone
                elif size < body_size_threshold and y >= bottom_zone_start and y < footnote_y:
                    footnote_y = y

    # Buffer up so adjacent body-fonted words inside the footnote drop too.
    if footnote_y != float("inf"):
        footnote_y -= 3.5

    # Second pass: keep only lines whose top is above the footnote zone,
    # and within those, drop the inline small-font footnote refs.
    out_lines: list[str] = []
    for block in d.get("blocks", []):
        if block.get("type") != 0:
            continue
        for line in block.get("lines", []):
            line_y = line.get("bbox", [0, 0, 0, 0])[1]
            if line_y >= footnote_y:
                continue
            spans = line.get("spans", [])
            kept_texts: list[str] = []
            for span in spans:
                font = span.get("font", "")
                size = span.get("size", 0)
                if "Hidden" in font or size < body_size_threshold:
                    continue
                kept_texts.append(span["text"])
            joined = "".join(kept_texts).rstrip()
            if joined.strip():
                out_lines.append(joined)
    return "\n".join(out_lines)


def to_roman(n: int) -> str:
    rules = [
        (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
        (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
        (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
    ]
    out = ""
    for v, s in rules:
        while n >= v:
            out += s
            n -= v
    return out


_BODY_OPENER_RE = re.compile(
    r'(?:'
    r'\b[A-Z]{3,}[A-Z]?[A-Za-z]*\s+'
    r'(?:said|saith|spoke|asked|cried|replied|answered|continued|added|'
    r'inquired|enquired|exclaimed|protested|whispered|murmured|sighed|'
    r'declared|observed|spake|having)\b'
    r'|\b(?:THE|WHEN|NOW|AS|IN|AT|UPON|HAVING|WHILE|HEARING|AFTER|BEFORE|'
    r'THEN|THUS|ON|MEANWHILE|TAKING|TURNING|RISING|HEARING|SEEING)\s+[A-Za-z]'
    r'|\bO\s+[A-Z]'
    r'|"[A-Z]'
    r')'
)


def locate_chapter_start(text: str, ch_num: int) -> str:
    """Trim everything up through the OCR-rendered chapter heading
    AND drop the tail that has bled in from the next chapter.

    Strategy: locate 'CHAPTER N' (arabic or roman), then skip up to two
    short lines (the OCR'd title), then keep everything up to the next
    'CHAPTER N+1' marker.
    """
    roman = to_roman(ch_num)
    pattern = rf"\bCHAPTER\s+(?:{ch_num}\b|{roman}\b)"
    m = re.search(pattern, text)
    if m:
        after = text[m.end():]
        lines = after.split("\n")
        # Skip lines until we find a body opener:
        #   - line starts with " or 'O ' / '0 ' (dialogue)
        #   - line starts with an ALL-CAPS lead word (THE, WHEN, ALL, HAVING, etc.)
        #   - safety cap: give up after 4 non-blank lines
        skip = 0
        nonblank_seen = 0
        body_lead_re = re.compile(
            r'^["\']?\s*'
            r'(?:'
            r'[A-Z]{2,}[A-Za-z]*\s'              # small-caps lead word
            r'|[\"“”‘’]'      # any quote
            r'|[0OoQ]\s'                          # OCR for "O" address
            r')'
        )
        for i, line in enumerate(lines):
            s = line.strip()
            if not s:
                continue
            if is_header_line(s):
                continue
            nonblank_seen += 1
            if body_lead_re.match(s):
                skip = i
                break
            if nonblank_seen >= 4:
                skip = i
                break
        after = "\n".join(lines[skip:])
    else:
        after = text

    # Stop before the next chapter heading bleeds in.
    nxt = ch_num + 1
    nxt_roman = to_roman(nxt)
    nxt_pattern = rf"\bCHAPTER\s+(?:{nxt}\b|{nxt_roman}\b)"
    nm = re.search(nxt_pattern, after)
    if nm:
        after = after[: nm.start()]
    return after


_RUNNING_HEAD_INLINE = re.compile(
    r"\s*"
    r"(?:[A-Z']{2,4}\s+RAMA[Y7]?ANA\s+OF\s+VALMIKI"  # 'THE/THR/THB/IHE/'IHE etc
    r"|RAMA[Y7]?ANA\s+OF\s+VALMIKI"
    r"|BALA[-\s]?KANDA"
    r"|AYODHYA[-\s]?KANDA"
    r"|ARANYA[-\s]?KANDA"
    r"|KISHKINDHA[-\s]?KANDA"
    r"|SUNDARA[-\s]?KANDA"
    r"|YUDDHA[-\s]?KANDA"
    r"|UTTARA[-\s]?KANDA)"
    r"\s*",
    re.IGNORECASE,
)


def clean_chapter_text(raw: str, chapter_title: str, chapter_num: int) -> str:
    """Extract paragraphs from raw OCR text — strip headers, fix hyphen wraps."""
    # Locate and trim through the OCR'd chapter heading first.
    raw = locate_chapter_start(raw, chapter_num)

    # Strip running heads anywhere they appear mid-text (they get joined into
    # paragraphs at page boundaries).
    raw = _RUNNING_HEAD_INLINE.sub(" ", raw)

    # Split into lines, drop running heads / page numbers / chapter num lines.
    raw_lines = raw.splitlines()
    kept: list[str] = []
    for line in raw_lines:
        s = line.strip()
        if not s:
            kept.append("")
            continue
        if is_header_line(s):
            continue
        kept.append(s)

    # Re-join into paragraphs: blank line breaks, hyphen at line-end joins.
    paragraphs: list[str] = []
    buf: list[str] = []

    def flush():
        if buf:
            joined = " ".join(buf)
            joined = re.sub(r"-\s+", "", joined.replace("- ", "-_TMP_"))
            joined = joined.replace("-_TMP_", "-")
            joined = re.sub(r"\s+", " ", joined).strip()
            if joined:
                paragraphs.append(joined)
            buf.clear()

    for line in kept:
        if not line:
            flush()
            continue
        if line.endswith("-") and len(line) > 1:
            buf.append(line[:-1])  # join across hyphenated wrap
        else:
            buf.append(line)
    flush()

    # Drop very short residual paragraphs (likely artifacts: e.g., "xvii").
    paragraphs = [p for p in paragraphs if len(p) > 3]
    return "\n\n".join(paragraphs)


def escape_xml(text: str) -> str:
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )


# ----------------------------------------------------------------------
# Typography enhancements applied to each cleaned paragraph.
# ----------------------------------------------------------------------

# Principal characters — rendered in bold small-caps wherever they appear.
PRINCIPAL_NAMES = [
    "Rama", "Ramachandra", "Shri Rama", "Sita", "Lakshmana", "Bharata",
    "Shatrughna", "Hanuman", "Ravana", "Vibhishana", "Kumbhakarna",
    "Indrajit", "Sugriva", "Vali", "Angada", "Jambavan", "Jatayu",
    "Vasishtha", "Vishwamitra", "Janaka", "Dasaratha", "Kaikeyi",
    "Kaushalya", "Sumitra", "Manthara", "Valmiki", "Brahma", "Vishnu",
    "Shiva", "Indra", "Agni", "Surya", "Yama", "Kubera", "Varuna",
    "Garuda", "Mandodari", "Trijata", "Surpanakha",
]

# Common Sanskrit terms — italicized whenever they appear (case-insensitive).
SANSKRIT_TERMS = [
    "dharma", "karma", "yoga", "moksha", "brahman", "atman", "deva",
    "devas", "asura", "asuras", "rishi", "rishis", "sloka", "slokas",
    "kanda", "kandas", "yuga", "yugas", "ashrama", "ashram", "tapas",
    "yajna", "yajnas", "soma", "homa", "japa", "puja", "mantra",
    "yuvaraja", "raja", "rakshasa", "rakshasas", "rakshasi",
    "vanara", "vanaras", "kapi", "kapis", "rishi", "muni", "munis",
    "brahmin", "brahmins", "kshatriya", "kshatriyas",
    "Adikavi", "Sakhas",
]


def fix_ocr_junk(text: str) -> str:
    """Strip the most-visible OCR artifacts that survive into body text.

    These are conservative: they only remove glyphs the scanner sprays
    where letters belong. They don't try to *correct* misread words —
    that would need a real OCR pass or an LLM.
    """
    # Standalone digit 0 used as the vocative letter "O" — "0 Rama" → "O Rama".
    text = re.sub(r"(?<=[\s\"“‘'(])0(?=\s+[A-Za-z])", "O", text)
    text = re.sub(r"^0(?=\s+[A-Za-z])", "O", text, flags=re.MULTILINE)
    # Trailing/standalone vocative 0 at line-end or before punctuation.
    text = re.sub(r"(?<=\s)0(?=\s*$)", "O", text, flags=re.MULTILINE)
    text = re.sub(r"(?<=\s)0(?=[!?,.;:])", "O", text)
    text = re.sub(r"(?<=\s)0(?=\s+[!?,.;:])", "O", text)
    # 0 glued to a lowercase letter — "0f", "0oe", "0t" → "Of", "Ooe", "Ot".
    text = re.sub(r"(?<=\s)0(?=[a-z])", "O", text)
    text = re.sub(r"^0(?=[a-z])", "O", text, flags=re.MULTILINE)
    # Stray ampersand inside a word — almost always OCR garbage.
    text = re.sub(r"(\w)&(\w)", r"\1\2", text)
    # '&s...' at word start → 'as...' (most common OCR'd 'a')
    text = re.sub(r"(?:^|(?<=[\s(\[]))&(?=[a-z])", "a", text)
    text = re.sub(r"(\w)&(?=[\s.,;:!?\)\]])", r"\1", text)
    # Any remaining stray ampersands are OCR junk — drop them.
    text = text.replace("&", "")
    # Stray <, >, <:, >: in word positions.
    text = re.sub(r"<:|>:|<>", "", text)
    text = re.sub(r"(\w)[<>](\w)", r"\1\2", text)
    # Colon spuriously in middle of word: 'c:bief' / 'c:bild' / 'a&s<:etics' tail.
    text = re.sub(r"(?<=[a-z]):(?=[a-z])", "", text)
    # Common b/h swap in 'cbild'/'cbief' once colons are gone.
    text = re.sub(r"\bcbild\b", "child", text)
    text = re.sub(r"\bcbief\b", "chief", text)
    text = re.sub(r"\bcbarmed\b", "charmed", text)
    text = re.sub(r"\bcbosen\b", "chosen", text)
    return text


def normalize_typography(text: str) -> str:
    """Light typographic cleanup: smart quotes, dashes."""
    text = fix_ocr_junk(text)
    # Strip inline bullet (•) used as footnote reference marker.
    text = text.replace("•", "")
    # Double quotes — context-bound so unbalanced OCR quotes don't cascade.
    text = re.sub(r'(^|[\s—\-(])"(\w)', r"\1“\2", text)              # opening
    text = re.sub(r'(\w|[.,;:!?\)])"(?=\s|$|[—\-])', r"\1”", text)   # closing
    # Apostrophes between letters → curly
    text = re.sub(r"(\w)'(\w)", r"\1’\2", text)
    # Possessive-s style word' at end-of-word
    text = re.sub(r"(\w)'(?=\s|$|[.,;:!?])", r"\1’", text)
    # Double-hyphen → em dash
    text = re.sub(r"--", "—", text)
    return text


SPEAKER_RE = re.compile(
    r"\b("
    r"[A-Z][A-Za-z]+(?:\s+[A-Z][A-Za-z]+){0,3}"
    r")\s+"
    r"(said|spoke|exclaimed|cried|replied|answered|continued|added|"
    r"asked|inquired|murmured|sighed|declared|protested|whispered|"
    r"questioned|enquired|observed|spake|saith)\s*:",
)

PRINCIPAL_RE = re.compile(
    r"\b(" + "|".join(re.escape(n) for n in sorted(PRINCIPAL_NAMES, key=len, reverse=True)) + r")\b"
)

SANSKRIT_RE = re.compile(
    r"\b(" + "|".join(re.escape(t) for t in sorted(SANSKRIT_TERMS, key=len, reverse=True)) + r")\b",
    re.IGNORECASE,
)

PAREN_TERM_RE = re.compile(r"\(([A-Za-z][A-Za-z\s\-]{0,30})\)")


def stylize_paragraph(text: str) -> str:
    """Return reportlab-XML markup for a body paragraph with inline highlights.

    Applied (in order so they don't collide):
      * speaker tags: BOLD SMALL-CAPS
      * parenthetical Sanskrit gloss: italicized (e.g. "(dharma)")
      * stand-alone Sanskrit terms: italicized
      * principal names: small-caps
    """
    # First, escape XML on the raw text.
    s = escape_xml(text)

    # 1) Speaker tags at sentence start: "RAMA said:" → bold smallcaps + colon kept
    def speaker_sub(m):
        name = m.group(1)
        verb = m.group(2)
        return f'<b><font size="9">{name.upper()}</font></b> <i>{verb}</i>:'

    s = SPEAKER_RE.sub(speaker_sub, s)

    # 2) Parenthesized short term → italicize the term
    def paren_sub(m):
        inner = m.group(1).strip()
        # don't double-italicize if it's already going to be picked up
        return f"(<i>{inner}</i>)"

    s = PAREN_TERM_RE.sub(paren_sub, s)

    # 3) Sanskrit terms → italicize (skip if inside an existing tag)
    def sanskrit_sub(m):
        return f"<i>{m.group(1)}</i>"

    # to avoid double-wrapping, do a quick token-level pass on text outside tags
    def apply_outside_tags(s: str, regex: re.Pattern, repl) -> str:
        parts = re.split(r"(<[^>]+>)", s)
        for i, part in enumerate(parts):
            if part.startswith("<"):
                continue
            parts[i] = regex.sub(repl, part)
        return "".join(parts)

    s = apply_outside_tags(s, SANSKRIT_RE, sanskrit_sub)

    # 4) Principal names → bold small-caps
    def princ_sub(m):
        name = m.group(1)
        return f'<b><font size="9">{name.upper()}</font></b>'

    s = apply_outside_tags(s, PRINCIPAL_RE, princ_sub)

    return s


def add_drop_cap(html_paragraph: str) -> str:
    """Inflate the first letter modestly so it doesn't blow out line leading."""
    in_tag = False
    for i, ch in enumerate(html_paragraph):
        if ch == "<":
            in_tag = True
            continue
        if ch == ">":
            in_tag = False
            continue
        if in_tag:
            continue
        if ch.isalpha():
            return (
                html_paragraph[:i]
                + f'<font size="16" color="#7a2e1f"><b>{ch}</b></font>'
                + html_paragraph[i + 1:]
            )
    return html_paragraph


# Per-book summary blurbs (extracted/adapted from the introduction).
BOOK_SUMMARIES: dict[str, str] = {
    "Book 1 - Bala Kanda": (
        "King Dasaratha of Ayodhya performs a sacrifice in the hope of a son. "
        "The Devas, alarmed at the power of the Titan Ravana, prevail upon "
        "Vishnu to incarnate. Four sons are born — Rama, Bharata, Lakshmana, "
        "Shatrughna — and the boys grow to manhood. Rama, accompanying the "
        "sage Vishwamitra, slays the demons of the forest, breaks the bow of "
        "Shiva at the court of Janaka, and wins Sita as his bride."
    ),
    "Book 2 - Ayodhya Kanda": (
        "Dasaratha intends to crown Rama heir-apparent, but Queen Kaikeyi, "
        "moved by the maid Manthara, holds the king to two old boons: Rama&rsquo;s "
        "fourteen-year exile and Bharata&rsquo;s coronation. Faithful to dharma, "
        "Rama goes calmly into the forest with Sita and Lakshmana. Dasaratha "
        "dies of grief; Bharata pleads with Rama to return, but Rama remains "
        "true to his father&rsquo;s vow."
    ),
    "Book 3 - Aranya Kanda": (
        "After ten years of forest life, the demoness Surpanakha is humiliated "
        "and her brothers slain. In revenge, Ravana abducts Sita to Lanka. "
        "The aged eagle Jatayu fights the Titan and falls, dying in Rama&rsquo;s arms. "
        "The grief-stricken brothers begin their search."
    ),
    "Book 4 - Kishkindha Kanda": (
        "Rama allies with Sugriva, exiled king of the monkey tribe, slaying "
        "his usurping brother Vali. Hanuman emerges as Rama&rsquo;s foremost "
        "devotee. The vanara hosts are dispatched in every direction to find "
        "Sita; the southern host, with Hanuman, learns from Sampati that she "
        "is held in Lanka."
    ),
    "Book 5 - Sundara Kanda": (
        "Hanuman leaps the ocean to Lanka, finds Sita in the Ashoka grove, "
        "delivers Rama&rsquo;s ring, sets fire to the city and returns to "
        "Rama with news. The book is considered the most beautiful of the "
        "seven, and is recited as a devotional whole."
    ),
    "Book 6 - Yuddha Kanda": (
        "The vanara army bridges the ocean. After a long sequence of pitched "
        "battles, Kumbhakarna and Indrajit fall, and Ravana is slain by Rama. "
        "Sita proves her purity by the ordeal of fire. The fourteen years of "
        "exile complete, Rama returns to Ayodhya for a long and glorious reign."
    ),
    "Book 7 - Uttara Kanda": (
        "The &lsquo;later section&rsquo; — doubts of the citizens drive Rama "
        "to send Sita to Valmiki&rsquo;s hermitage, where she bears the twins "
        "Kusha and Lava. The boys grow up reciting the Ramayana itself; in time "
        "they return to Ayodhya. Sita is recalled, and at last departs into "
        "the earth from which she came."
    ),
}


def build():
    print(f"Opening source: {SRC}")
    src = fitz.open(str(SRC))
    toc = src.get_toc()

    # Group TOC: Books (level 2 starting with "Book") + their chapters (level 3).
    books: list[dict] = []
    current = None
    for entry in toc:
        level, title, page = entry
        if level == 2 and title.startswith("Book"):
            current = {"title": title.strip(), "page": page, "chapters": []}
            books.append(current)
        elif level == 3 and current is not None:
            current["chapters"].append({"title": title.strip(), "page": page})

    # Compute end pages — INCLUDE next chapter's first page so we capture the
    # tail of this chapter that often shares a page with the next chapter's
    # heading. The locate/trim routines remove the next chapter's content.
    flat: list[tuple[dict, dict]] = []
    for book in books:
        for ch in book["chapters"]:
            flat.append((book, ch))
    for i, (_, ch) in enumerate(flat):
        if i + 1 < len(flat):
            ch["end_page"] = flat[i + 1][1]["page"]
        else:
            ch["end_page"] = len(src)
        if ch["end_page"] < ch["page"]:
            ch["end_page"] = ch["page"]

    print(f"Books: {len(books)}, chapters: {len(flat)}")

    # ------------------------------------------------------------------
    # Build the destination PDF with reportlab.
    # ------------------------------------------------------------------
    styles = getSampleStyleSheet()

    title_style = ParagraphStyle(
        "TitleBig",
        parent=styles["Title"],
        fontName="Times-Bold",
        fontSize=26,
        leading=32,
        alignment=TA_CENTER,
        spaceAfter=18,
    )
    subtitle_style = ParagraphStyle(
        "SubTitle",
        parent=styles["Title"],
        fontName="Times-Italic",
        fontSize=14,
        leading=18,
        alignment=TA_CENTER,
        spaceAfter=12,
    )
    h1_style = ParagraphStyle(
        "BookHeading",
        parent=styles["Heading1"],
        fontName="Times-Bold",
        fontSize=20,
        leading=26,
        alignment=TA_CENTER,
        spaceBefore=24,
        spaceAfter=24,
    )
    h2_style = ParagraphStyle(
        "ChapterHeading",
        parent=styles["Heading2"],
        fontName="Times-Bold",
        fontSize=14,
        leading=18,
        alignment=TA_LEFT,
        spaceBefore=22,
        spaceAfter=12,
        textColor="#3a1c0f",
        keepWithNext=True,
    )
    chapter_kicker_style = ParagraphStyle(
        "ChapterKicker",
        parent=styles["BodyText"],
        fontName="Times-Italic",
        fontSize=8.5,
        leading=11,
        alignment=TA_LEFT,
        spaceBefore=0,
        spaceAfter=0,
        textColor="#7a2e1f",
        keepWithNext=True,
    )
    book_summary_style = ParagraphStyle(
        "BookSummary",
        parent=styles["BodyText"],
        fontName="Times-Italic",
        fontSize=11,
        leading=16,
        alignment=TA_JUSTIFY,
        firstLineIndent=0,
        leftIndent=20,
        rightIndent=20,
        spaceBefore=18,
        spaceAfter=18,
        textColor="#3a1c0f",
    )
    book_kicker_style = ParagraphStyle(
        "BookKicker",
        parent=styles["BodyText"],
        fontName="Times-Italic",
        fontSize=10,
        alignment=TA_CENTER,
        textColor="#7a2e1f",
        spaceBefore=0,
        spaceAfter=8,
    )
    ornament_style = ParagraphStyle(
        "Ornament",
        parent=styles["BodyText"],
        fontName="Times-Roman",
        fontSize=12,
        leading=18,
        alignment=TA_CENTER,
        spaceBefore=10,
        spaceAfter=10,
        textColor="#7a2e1f",
    )
    intro_h_style = ParagraphStyle(
        "IntroHeading",
        parent=h1_style,
        spaceBefore=0,
    )
    body_style = ParagraphStyle(
        "Body",
        parent=styles["BodyText"],
        fontName="Times-Roman",
        fontSize=10.5,
        leading=14.5,
        alignment=TA_JUSTIFY,
        firstLineIndent=14,
        spaceAfter=4,
    )
    lead_style = ParagraphStyle(
        "Lead",
        parent=body_style,
        firstLineIndent=0,
        spaceAfter=6,
        leading=16,
    )
    toc_h_style = ParagraphStyle(
        "TOCHeading",
        parent=h1_style,
        spaceBefore=0,
    )

    outline_records: list[tuple[int, str, int]] = []  # populated only on final draw pass

    class OutlineMark(Flowable):
        """Zero-height flowable that records its page when drawn (final pass only)."""

        def __init__(self, level: int, title: str):
            super().__init__()
            self.level = level
            self.title = title
            self.width = 0
            self.height = 0

        def draw(self):  # called once, on the final layout pass
            outline_records.append((self.level, self.title, self.canv.getPageNumber()))

        def wrap(self, aw, ah):
            return (0, 0)

    class TocDoc(BaseDocTemplate):
        def afterFlowable(self, flowable):
            if isinstance(flowable, Paragraph):
                style_name = flowable.style.name
                text = flowable.getPlainText()
                if style_name == "BookHeading":
                    self.notify("TOCEntry", (0, text, self.page, getattr(flowable, "_bookmark", None)))
                elif style_name == "ChapterHeading":
                    self.notify("TOCEntry", (1, text, self.page, getattr(flowable, "_bookmark", None)))

    doc = TocDoc(
        str(DST),
        pagesize=A5,
        leftMargin=1.8 * cm,
        rightMargin=1.8 * cm,
        topMargin=2.0 * cm,
        bottomMargin=2.0 * cm,
        title="The Ramayana of Valmiki",
        author="Hari Prasad Shastri (translator)",
    )
    frame = Frame(
        doc.leftMargin,
        doc.bottomMargin,
        doc.width,
        doc.height,
        id="main",
        showBoundary=0,
    )
    doc.addPageTemplates([PageTemplate(id="main", frames=[frame])])

    story: list = []

    # --- Title page ---
    story.append(Spacer(1, 6 * cm))
    story.append(Paragraph("The Ramayana of Valmiki", title_style))
    story.append(PageBreak())

    # --- Introduction ---
    intro_bm = "intro"
    story.append(OutlineMark(1, "Introduction"))
    p = Paragraph(f'<a name="{intro_bm}"/>Introduction', intro_h_style)
    p._bookmark = intro_bm
    story.append(p)
    for para in CLEAN_INTRO_PARAGRAPHS:
        story.append(Paragraph(para, body_style))
    story.append(PageBreak())


    # --- Books and chapters ---
    book_pad = len(books)
    for bi, book in enumerate(books, 1):
        # Frontispiece page for the book.
        bm_book = f"book_{bi}"
        story.append(OutlineMark(1, book["title"]))
        story.append(Spacer(1, 4 * cm))
        roman = ["I", "II", "III", "IV", "V", "VI", "VII"][bi - 1]
        story.append(Paragraph(f"BOOK&nbsp;{roman}", book_kicker_style))
        # Title without the leading "Book N - "
        bare_title = re.sub(r"^Book\s+\d+\s*-\s*", "", book["title"]).strip()
        bp = Paragraph(f'<a name="{bm_book}"/>{escape_xml(bare_title)}', h1_style)
        bp._bookmark = bm_book
        story.append(bp)
        summary = BOOK_SUMMARIES.get(book["title"])
        if summary:
            story.append(Paragraph(summary, book_summary_style))
        story.append(Paragraph("&#10086;", ornament_style))  # ornamental flourish
        story.append(PageBreak())

        for ci, ch in enumerate(book["chapters"], 1):
            start = ch["page"] - 1  # to 0-indexed
            end = ch["end_page"] - 1
            raw = []
            for pi in range(start, min(end + 1, len(src))):
                raw.append(extract_body_text(src[pi]))
            raw_text = "\n".join(raw)
            cleaned = clean_chapter_text(raw_text, ch["title"], ci)
            cleaned = normalize_typography(cleaned)

            # Split chapter title: "12. The sacrifice is commenced" → ("12", "The sacrifice is commenced")
            mnum = re.match(r"^(\d+)\.\s*(.*)$", ch["title"].strip())
            if mnum:
                ch_num, ch_name = mnum.group(1), mnum.group(2)
            else:
                ch_num, ch_name = "", ch["title"].strip()

            bm_ch = f"b{bi}_c{ci}"
            if ch_num:
                story.append(Paragraph(f"CHAPTER&nbsp;{ch_num}", chapter_kicker_style))
            cp = Paragraph(
                f'<a name="{bm_ch}"/>{escape_xml(ch_name)}',
                h2_style,
            )
            cp._bookmark = bm_ch
            story.append(cp)
            # OutlineMark AFTER the heading: keepWithNext on h2 binds these
            # together, so the recorded page matches the heading's page.
            story.append(OutlineMark(2, ch["title"]))

            paragraphs = [p.strip() for p in cleaned.split("\n\n") if p.strip()]
            for pi_, para in enumerate(paragraphs):
                styled = stylize_paragraph(para)
                if pi_ == 0:
                    styled = add_drop_cap(styled)
                    story.append(Paragraph(styled, lead_style))
                else:
                    story.append(Paragraph(styled, body_style))
                # ornamental break every ~6 paragraphs for breathing room
                if pi_ > 0 and pi_ % 6 == 0 and pi_ < len(paragraphs) - 1:
                    story.append(Paragraph("&#8258;", ornament_style))
            # progress
            if ci % 25 == 0:
                print(f"  {book['title']}: chapter {ci}/{len(book['chapters'])}")
        story.append(PageBreak())
        print(f"Book {bi}/{book_pad} done: {book['title']}")

    # multiBuild does TOC two-pass; OutlineMark.draw fires only on the final pass.
    print("Rendering PDF (two passes for TOC)...")
    doc.multiBuild(story)

    # multiBuild may run 3+ passes; keep only the records from the final pass
    # by detecting where the sequence restarts ("Introduction" appears again).
    final_pass_records = outline_records
    intro_indices = [i for i, (lvl, title, _) in enumerate(outline_records) if title == "Introduction"]
    if intro_indices:
        final_pass_records = outline_records[intro_indices[-1]:]

    # Write a real outline tree with pymupdf.
    out = fitz.open(str(DST))
    fitz_toc: list[list] = [[level, title, page] for level, title, page in final_pass_records]
    # set_toc requires the first item to be at level 1.
    if fitz_toc and fitz_toc[0][0] != 1:
        fitz_toc[0][0] = 1
    if fitz_toc:
        out.set_toc(fitz_toc)
        out.saveIncr()
    out.close()
    print(f"Wrote: {DST}  ({DST.stat().st_size/1024/1024:.1f} MB)  with {len(fitz_toc)} bookmarks")
    src.close()


if __name__ == "__main__":
    build()
