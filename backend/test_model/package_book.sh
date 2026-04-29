#!/usr/bin/env bash
# Package a locally-ingested book into a tarball ready for production publish.
#
# Usage:
#   ./package_book.sh <slug>
#
# Produces:
#   <slug>-bundle.tgz   in the current directory
#
# The tarball contains:
#   bundle/
#     book_ingest/                        # the ingest package (slim, JSON-only)
#     storage/books/<slug>/manifest.json
#     storage/books/<slug>/chunks/*.json
#     storage/books/<slug>/images/*.{png,json}
#     storage/books/<slug>/plan.json
#
# Briefs/deeps/embeddings/pages are intentionally excluded — the production
# publisher only needs the composite chunk JSONs (which already have the
# brief + deep embedded) plus the images and plan.

set -euo pipefail

SLUG="${1:-}"
if [[ -z "$SLUG" ]]; then
  echo "usage: $0 <slug>" >&2
  exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOK_DIR="$HERE/storage/books/$SLUG"
if [[ ! -d "$BOOK_DIR" ]]; then
  echo "no book at $BOOK_DIR" >&2
  exit 2
fi

STAGE="$(mktemp -d -t inkx-bundle-XXXX)"
trap "rm -rf '$STAGE'" EXIT

echo "→ Staging at $STAGE"
mkdir -p "$STAGE/bundle/book_ingest"
mkdir -p "$STAGE/bundle/storage/books/$SLUG/chunks"
mkdir -p "$STAGE/bundle/storage/books/$SLUG/images"

# Ingest package (so the production script can `import book_ingest.*`).
cp -r "$HERE/book_ingest/." "$STAGE/bundle/book_ingest/"
# Drop __pycache__ if present.
find "$STAGE/bundle/book_ingest" -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true

# Ship the publisher itself in the bundle so we don't need to rebuild the
# fastapi image — just `python /tmp/bundle/publish_book.py ...` works.
cp "$HERE/../scripts/publish_book.py" "$STAGE/bundle/publish_book.py"

# Book artifacts — minimum needed to reconstruct sections + upload images.
cp "$BOOK_DIR/manifest.json" "$STAGE/bundle/storage/books/$SLUG/manifest.json"
cp -r "$BOOK_DIR/chunks/." "$STAGE/bundle/storage/books/$SLUG/chunks/" 2>/dev/null || true
cp -r "$BOOK_DIR/images/." "$STAGE/bundle/storage/books/$SLUG/images/" 2>/dev/null || true
# Cleaner phase output (one .md per chunk_id) — needed so prod publish
# uses the same paragraph-formatted text the local studio shows.
if [[ -d "$BOOK_DIR/cleaned" ]]; then
  mkdir -p "$STAGE/bundle/storage/books/$SLUG/cleaned"
  cp -r "$BOOK_DIR/cleaned/." "$STAGE/bundle/storage/books/$SLUG/cleaned/" 2>/dev/null || true
fi
[[ -f "$BOOK_DIR/plan.json" ]]       && cp "$BOOK_DIR/plan.json"       "$STAGE/bundle/storage/books/$SLUG/"
[[ -f "$BOOK_DIR/highlights.json" ]] && cp "$BOOK_DIR/highlights.json" "$STAGE/bundle/storage/books/$SLUG/"

# InkSpaceX logo for the publishing-account avatar.
LOGO_SRC="$HERE/../../assets/icon/icon.png"
if [[ -f "$LOGO_SRC" ]]; then
  cp "$LOGO_SRC" "$STAGE/bundle/avatar.png"
fi

OUT="$HERE/$SLUG-bundle.tgz"
( cd "$STAGE" && tar czf "$OUT" bundle )

SIZE="$(du -h "$OUT" | cut -f1)"
N_IMG="$(find "$STAGE/bundle/storage/books/$SLUG/images" -name '*.png' | wc -l | tr -d ' ')"
N_CHUNK="$(find "$STAGE/bundle/storage/books/$SLUG/chunks" -name '*.json' | wc -l | tr -d ' ')"

cat <<EOF

✓ Bundle ready: $OUT  ($SIZE)
   chunks: $N_CHUNK
   images: $N_IMG

Next steps (from this machine):

  # 1. Copy to the VM
  scp "$OUT" \$SSH_HOST:/tmp/

  # 2. Inside the container, untar + run publish
  ssh \$SSH_HOST 'cd \$HOME/inkspacex && \\
    docker compose cp /tmp/$SLUG-bundle.tgz fastapi:/tmp/bundle.tgz && \\
    docker compose exec -T fastapi bash -c "
      rm -rf /tmp/bundle && mkdir -p /tmp/bundle &&
      tar xzf /tmp/bundle.tgz -C /tmp/bundle --strip-components=1 &&
      python /app/scripts/publish_book.py $SLUG \\
        --bundle-root /tmp/bundle \\
        --account-email inkspacex@inkspacex.com \\
        --account-name InkSpaceX
    "'

EOF
