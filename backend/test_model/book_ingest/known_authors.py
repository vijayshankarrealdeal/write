"""Curated title→author fallback for Gutenberg files where the loader
can't extract `<meta name="dc.creator">` and the `<title>` tag doesn't
carry "by AUTHOR".

Kept in its own module (no bs4 / heavy deps) so the repair script can
import it inside the production fastapi container without dragging in
the full HTML loader chain.
"""

from __future__ import annotations

import re

_KNOWN_AUTHORS_BY_TITLE: dict[str, str] = {
    "sense and sensibility": "Jane Austen",
    "pride and prejudice": "Jane Austen",
    "life on the mississippi": "Mark Twain",
    "romeo and juliet": "William Shakespeare",
    "a dolls house": "Henrik Ibsen",
    "a doll's house": "Henrik Ibsen",
    "a room with a view": "E. M. Forster",
    "grimms fairy tales": "Jacob and Wilhelm Grimm",
    "grimms' fairy tales": "Jacob and Wilhelm Grimm",
    "beowulf": "Anonymous",
    "beowulf an anglo-saxon epic poem": "Anonymous",
    "the federalist papers":
        "Alexander Hamilton, James Madison, and John Jay",
    "spoon river anthology": "Edgar Lee Masters",
    "the best short stories of 1920 american short story":
        "Edward J. O'Brien",
    "the junior classics volume 1 fairy and wonder tales": "William Patten",
    "little women": "Louisa May Alcott",
    # Defensive net: common Gutenberg classics where dc.creator is the
    # primary source but a future re-download might drop the meta tag.
    "alice's adventures in wonderland": "Lewis Carroll",
    "frankenstein": "Mary Wollstonecraft Shelley",
    "frankenstein or the modern prometheus": "Mary Wollstonecraft Shelley",
    "the adventures of sherlock holmes": "Arthur Conan Doyle",
    "the adventures of tom sawyer": "Mark Twain",
    "adventures of huckleberry finn": "Mark Twain",
    "the picture of dorian gray": "Oscar Wilde",
    "dracula": "Bram Stoker",
    "the great gatsby": "F. Scott Fitzgerald",
    "moby dick or the whale": "Herman Melville",
    "moby dick": "Herman Melville",
    "wuthering heights": "Emily Brontë",
    "jane eyre an autobiography": "Charlotte Brontë",
    "jane eyre": "Charlotte Brontë",
    "great expectations": "Charles Dickens",
    "a tale of two cities": "Charles Dickens",
    "the count of monte cristo": "Alexandre Dumas",
    "treasure island": "Robert Louis Stevenson",
    "the strange case of dr jekyll and mr hyde":
        "Robert Louis Stevenson",
    "middlemarch": "George Eliot",
    "crime and punishment": "Fyodor Dostoevsky",
    "the brothers karamazov": "Fyodor Dostoevsky",
    "the hound of the baskervilles": "Arthur Conan Doyle",
    "a study in scarlet": "Arthur Conan Doyle",
    "the canterbury tales": "Geoffrey Chaucer",
    "meditations": "Marcus Aurelius",
    "leviathan": "Thomas Hobbes",
    "the importance of being earnest": "Oscar Wilde",
    "a modest proposal": "Jonathan Swift",
    "twenty years after": "Alexandre Dumas",
    "the turn of the screw": "Henry James",
    "carmen": "Prosper Mérimée",
    "narrative of the life of frederick douglass":
        "Frederick Douglass",
    "the complete works of william shakespeare": "William Shakespeare",
    "the mysteries of udolpho": "Ann Radcliffe",
    "the confessions of st augustine": "Augustine of Hippo",
    "the city of god volume i": "Augustine of Hippo",
    "the kama sutra of vatsyayana": "Vātsyāyana",
    "the man who was thursday": "G. K. Chesterton",
    "the lady of the lake": "Sir Walter Scott",
    "the green mummy": "Fergus Hume",
    "the monk a romance": "Matthew Gregory Lewis",
    "cranford": "Elizabeth Gaskell",
    "penrod": "Booth Tarkington",
    "the king in yellow": "Robert W. Chambers",
    "the enchanted april": "Elizabeth von Arnim",
    "the blue castle": "L. M. Montgomery",
    "miss mapp": "E. F. Benson",
    "the secret of chimneys": "Agatha Christie",
    "le fantôme de l'opéra": "Gaston Leroux",
    "le fantome de lopera": "Gaston Leroux",
    "die traumdeutung": "Sigmund Freud",
    "buddenbrooks": "Thomas Mann",
    "der zauberberg": "Thomas Mann",
    "henrietta temple": "Benjamin Disraeli",
    "robert elsmere": "Mrs. Humphry Ward",
    "the string of pearls": "Anonymous",
    "the extraordinary adventures of arsène lupin": "Maurice Leblanc",
    "the extraordinary adventures of arsene lupin": "Maurice Leblanc",
}


def _normalize_title_key(t: str) -> str:
    """Lowercase + strip punctuation/extra spaces for fuzzy title lookup."""
    cleaned = re.sub(r"[^a-z0-9\s]", "", t.lower())
    return re.sub(r"\s+", " ", cleaned).strip()


def lookup_known_author(title: str | None) -> str | None:
    """Return a known author for [title] from the curated map, or None.

    Used both by the HTML loader (`book_ingest.html_loader`) when a
    Gutenberg file is missing dc.creator, and by the DB repair script
    that backfills FeedItem.author for already-ingested books.
    """
    if not title:
        return None
    key = _normalize_title_key(title)
    if not key:
        return None
    if key in _KNOWN_AUTHORS_BY_TITLE:
        return _KNOWN_AUTHORS_BY_TITLE[key]
    # Try with the leading article stripped — Gutenberg titles sometimes
    # carry "The …" / "A …" that the user-facing display drops.
    for prefix in ("the ", "a ", "an "):
        if key.startswith(prefix):
            trimmed = key[len(prefix):]
            if trimmed in _KNOWN_AUTHORS_BY_TITLE:
                return _KNOWN_AUTHORS_BY_TITLE[trimmed]
    return None
