# InkSpaceX SEO audit report — May 2026

Branch `feat/seo-optimization`. Generated against production-ready static
output served at <http://127.0.0.1:8088> from a staging mirror of
`/srv/web` (the directory that Caddy serves in production).

## Lighthouse — mobile (final)

Run via `lighthouse@12` against headless Chrome 130, simulated 4G,
form-factor=mobile.

| Page | Performance | Accessibility | Best practices | SEO |
|---|---:|---:|---:|---:|
| `/landing.html` | **98** | **100** | 96 | **100** |
| `/scrivener-alternative.html` | 99 | 95 | 100 | 100 |
| `/scrivener-vs-inkspacex.html` | 99 | 95 | 100 | 100 |
| `/sudowrite-vs-inkspacex.html` | 99 | 95 | 100 | 100 |
| `/best-writing-software-2026.html` | 99 | 95 | 100 | 100 |
| `/blog/` | **100** | **100** | 100 | 100 |
| `/blog/three-act-structure-novel-outline.html` | 99 | 95 | 100 | 100 |

All pages meet the targets the task brief set:

- Performance ≥ 90 ✅ (range: 98–100)
- Accessibility ≥ 95 ✅ (range: 95–100)
- SEO = 100 ✅ on every page

## Before / after — landing.html (mobile)

| Metric | Before | After |
|---|---:|---:|
| Performance | 98 | 98 |
| Accessibility | 94 | **100** |
| Best practices | 96 | 96 |
| SEO | 100 | 100 |

Accessibility delta came from three fixes:

- `.btn.accent` lost contrast in dark mode because the dark `--accent`
  (#5CB8FF) failed against white text. Pinned the button background to
  the same #1257D6 in both themes (6.2:1 with white).
- `.brand .x` was rendering at 3.78:1 in dark mode (#1E6EF4 on #191919);
  lifted dark-mode `--accent` to #5CB8FF in `marketing.css`.
- Eyebrow chips (#1E6EF4 on #DDEAFF, 3.76:1) recoloured to #1257D6 for
  light mode (5.6:1).

## Lighthouse — desktop

A single landing-page desktop run captured 98 / 94 / 96 / 100 (Perf /
A11y / BP / SEO) before the contrast fixes. Re-runs after the fixes
intermittently failed to capture from the local headless Chrome
(CDP timeout) — re-run after deploy from a clean machine, or via
the GitHub Action below.

## How to reproduce

The repo ships everything needed:

```bash
# 1. Stage what /srv/web will look like in production
mkdir -p /tmp/inkspacex-stage
cp -R web/. /tmp/inkspacex-stage/
cp landing.html scrivener-*.html sudowrite-*.html best-writing-software-2026.html /tmp/inkspacex-stage/
cp -R blog /tmp/inkspacex-stage/
cp landing_page_assets/marketing.css /tmp/inkspacex-stage/
cp landing_page_assets/og-*.png /tmp/inkspacex-stage/

# 2. Serve and audit
( cd /tmp/inkspacex-stage && python3 -m http.server 8088 ) &

# 3. Lighthouse, mobile
CHROME_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \\
  npx --yes lighthouse@12 http://127.0.0.1:8088/landing.html \\
  --output=html --output-path=/tmp/landing-mobile.html \\
  --chrome-flags="--headless --no-sandbox" \\
  --only-categories=performance,accessibility,best-practices,seo \\
  --form-factor=mobile --throttling-method=simulate

# 4. Cheap, deterministic SEO audit (no Chrome needed)
python3 scripts/seo_audit.py
```

## Validation results

| Check | Tool | Result |
|---|---|---|
| `sitemap.xml` schema | Python `xml.etree` | 15 URLs parse cleanly |
| `robots.txt` syntax | manual parser | OK; `Sitemap:` directive present |
| JSON-LD blocks | `json.loads` × 30 | all parse |
| Internal link integrity | `scripts/seo_audit.py` | 0 broken |
| Title length (≤ 65 chars) | audit script | all 13 pages OK |
| Meta description (130–165) | audit script | 11 pages OK · 2 legal pages slightly under (acceptable for legal) |
| `Caddyfile` | `caddy validate` (Caddy 2 in Docker) | Valid configuration |
| HTML structure | manual heading-order check | H1 once per page; sequential nesting |

## Keyword targeting notes

| Target keyword | Page(s) where it appears in title / H1 / H2 / body |
|---|---|
| writing software | landing (title, H1 surroundings, schema), best-2026, blog index |
| novel writing software | landing schema, scrivener-alternative, scrivener-vs |
| Scrivener alternative | scrivener-alternative (title, H1), landing lede + footer, blog/online-writing-software |
| online writing tool | best-2026, blog/online-writing-software |
| AI writing assistant for fiction | landing schema feature list, sudowrite-vs (H1 surroundings), best-2026 |
| best writing app | landing keywords + schema, best-2026 |
| best writing software 2026 | best-writing-software-2026 (title, H1) |

Internal linking: every comparison page links to every other comparison
page; the landing page footer carries Compare and Resources columns
that flow PageRank into both comparisons and blog posts; blog posts
cross-link to one another and to the comparison pages.

## Deliverables

### New files

- `scrivener-alternative.html` — comparison page
- `scrivener-vs-inkspacex.html` — feature-for-feature comparison
- `sudowrite-vs-inkspacex.html` — AI-tool comparison
- `best-writing-software-2026.html` — 9-tool roundup
- `blog/index.html` — blog hub with `Blog` + `BlogPosting` schema
- `blog/three-act-structure-novel-outline.html` — 1,730 words
- `blog/why-your-first-draft-should-be-ugly.html` — 1,636 words
- `blog/online-writing-software-2026.html` — 1,905 words
- `landing_page_assets/marketing.css` — shared comparison/blog styling
- `landing_page_assets/generate_og_image.py` — Pillow generator for 8 OG variants
- `landing_page_assets/og-*.png` (× 8) and `web/og-*.png` (× 8) — 1200×630 social cards
- `scripts/seo_audit.py` — local SEO audit (title/desc/canonical/OG/JSON-LD/links)
- `landing_page_assets/preview-scrivener-vs.png` — screenshot of one comparison page

### Modified files

- `landing.html` — title/desc/OG/canonical/Twitter/keywords; FAQ-page schema (8 Qs); SoftwareApplication schema with `WritingApplication` category, full feature list, aggregateRating, dual offers; lazy-load on all below-fold doodle `<img>`s; `data-theme="dark"` `.btn.accent` override for AA.
- `web/index.html` — same head treatment for the SPA shell, canonical points at `/landing.html`.
- `privacy_policy.html`, `terms_of_service.html`, `data_deletion.html` — full meta + OG + Twitter + canonical + BreadcrumbList JSON-LD; image alt text added.
- `signup.html` — meta + OG + Twitter + canonical.
- `web/sitemap.xml` — added 9 URLs (comparison + blog) with absolute `lastmod` dates.
- `web/robots.txt` — disallow `/admin*`, `/app*`, allow comparison + blog paths.
- `Caddyfile` — handlers for marketing HTML, blog, marketing CSS, and OG image cache; `X-Robots-Tag noindex` on `/admin*`.
- `deploy.sh` — copies the new HTML, blog directory, marketing CSS, and OG PNGs into `build/web/`.

### Deferred

- **Native iOS app branch** — referenced in copy as "iOS app launching late 2026"; matches the existing roadmap. Not an SEO blocker; flagged here so marketing copy stays honest if the launch date moves.
- **Lighthouse desktop run** — local headless Chrome is flaky on this Mac; mobile runs are authoritative for Google ranking signals (Google's mobile-first index). Re-run desktop on a clean CI machine or rely on the production Lighthouse-CI integration.
- **Sub-pages for each target keyword as standalone landing pages** — currently the keyword surface area is split between `landing.html` (broad), 4 comparison pages (head terms), and 3 blog posts (long-tail). Adding e.g. a dedicated `/free-writing-software.html` is sensible but over-scope for this PR.
- **`Hand Drawn Doodle Elements/` PNGs** — referenced from `landing.html`, present on the deploy host but not in repo (decorative `<img>`s with `alt="" aria-hidden="true"`). Deploy script gracefully skips if missing; a 404 from those is the only console error that shows up under local Lighthouse.

## Recommended next steps

1. Verify Google Search Console once `inkspacex.com` is live with the new
   surfaces (token slot is in `landing.html` head: `name="google-site-verification"`).
2. Submit the new `sitemap.xml` to GSC.
3. Wait 2–4 weeks, then run the audit again with real Search-Console
   impressions data to see which target keywords are landing impressions.
4. If the comparison pages start ranking, build out 1–2 more
   (`/ulysses-vs-inkspacex.html`, `/dabble-vs-inkspacex.html`).
