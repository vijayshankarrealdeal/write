# InkSpaceX — Platform Features As Seen By A User

*Written from the perspective of a writer/reader landing on the platform, not from the engineering side.*
*Source: the actual shipped code in this repo, plus the live landing copy. Anything I couldn't find a feature for is called out in the "Gaps" section so we don't claim things we don't ship.*

---

## How the platform pitches itself

> **"A calm place to write, read & share your stories."**

The landing page leans on three feature pillars:

1. **An editor that listens** — distraction-free typing, slash menu, floating toolbar.
2. **Truly cross-device** — web, Android, macOS, Windows. Drafts and bookmarks sync.
3. **Your work, your rules** — end-to-end encrypted drafts, plain-text export.

This is the promise. The next sections are what's actually behind that promise in the code.

---

## What a writer gets

### A real writing app, not a notes app

This is closer to Scrivener than to Notion / Obsidian / Milanote. The Discord user who said "I used to be a Scrivener person, so InkSpaceX seems a good fit" is reading the product correctly — the core editor is built to handle a *manuscript*, not a knowledge base.

- **Three ways to see the same manuscript** — Scrivenings (continuous scroll across sections), Cards (one section per card), Outline (hierarchical tree). [scrivenings_view.dart](lib/ui/pages/editor_page_entry/writing_page/views/scrivenings_view.dart), [cards_view.dart](lib/ui/pages/editor_page_entry/writing_page/views/cards_view.dart), [outline_view.dart](lib/ui/pages/editor_page_entry/writing_page/views/outline_view.dart)
- **Binder pane** — the Scrivener-style left sidebar with Manuscript / Research / Trash folders, drag-to-reorder. [binder_pane.dart](lib/ui/pages/editor_page_entry/writing_page/binder_pane.dart)
- **Section labels with colors** — define your own labels (POV, Draft-1, Needs research) and color-code sections.
- **Per-project word-count targets and deadlines** — set in Project Settings. [project_settings_dialog.dart](lib/ui/pages/editor_page_entry/writing_page/project_settings_dialog.dart)
- **Find & Replace across the whole project**, not just the current section. [find_replace_bar.dart](lib/ui/pages/editor_page_entry/writing_page/find_replace_bar.dart)
- **Footnotes**, **annotations** (margin notes on a passage), and **comments** on your own writing. [footnotes_panel.dart](lib/ui/pages/editor_page_entry/writing_page/footnotes_panel.dart), [annotations_panel.dart](lib/ui/pages/editor_page_entry/writing_page/annotations_panel.dart)
- **Version history per section** — see and restore prior edits. [version_history_widgets.dart](lib/ui/pages/editor_page_entry/writing_page/version_history_widgets.dart)
- **Canvas / freeform drawing surface** — sketch ideas next to text. [canvas_editor.dart](lib/ui/pages/editor_page_entry/canvas_page/canvas_editor.dart)

### Self-editing tools you don't get in Word

- **Spell-check with a per-project ignore list.** [spell_check_sheet.dart](lib/ui/pages/editor_page_entry/writing_page/spell_check_sheet.dart)
- **Linguistic Focus** — highlight every adverb, adjective, verb, noun, or piece of dialogue in your draft so you can do an editing pass on one thing at a time. Backed by real NLP (spaCy) on the server. [linguistic_focus_service.dart](lib/services/linguistic_focus_service.dart)
- **Typography settings for writing** — page width, margins, font, line spacing. The page itself can feel like a printed novel, not like Notion. [page_layout_settings_dialog.dart](lib/ui/pages/editor_page_entry/writing_page/page_layout_settings_dialog.dart)

### AI that helps, doesn't take over

Lives in a bottom sheet inside the editor — not a chat side panel. [ai_bottom_sheet.dart](lib/ui/pages/editor_page_entry/writing_page/ai_bottom_sheet.dart)

Actions a writer can run on a selection or section:
- **Tighten**, **Sharpen Opening**, **Lift Thesis**, **Cut Throat-Clearing**
- **Continue Writing** (drafts the next paragraph)
- **Reframe for Audience** — beginner vs expert, add examples, steel-man the argument
- **Feedback Mode** — read-only critique, "what's missing", alternative openings

Distinction worth keeping: AI here is invoked deliberately on what you select. It does not autocomplete as you type.

### Writing goals & habits

- **Daily word-count goal** with streak tracking. [daily_goal_service.dart](lib/services/daily_goal_service.dart)
- **Scheduled OS reminders** at the time you choose ("write at 9 AM"). [local_notification_service.dart](lib/services/local_notification_service.dart)
- **Home-screen widgets on mobile** showing today's progress. [home_widget_service.dart](lib/services/home_widget_service.dart)
- **Desktop tray icon** with quick actions on Windows / macOS / Linux. [desktop_tray_service.dart](lib/services/desktop_tray_service.dart)

---

## What a *solo and short-story writer* gets — the Discord question

The Discord user's exact framing: "I'm a solo and short story writer, so on the platform get review by people." This is what they were asking about, so calling it out separately.

### Yes, you can publish and get reviews

- **Publish a Space** — turn a private draft into a public work readable by other users. You choose which chapters are free, which need purchase, cover image, genres, tags, type (Short Story, Essay, Novel, Poetry, Screenplay…). [publish_page.dart](lib/ui/pages/publish_page.dart)
- **Readers leave comments with a 1-5 star rating.** [comments.py](backend/app/routers/comments.py)
- **Likes & follower counts on your profile.** Tier badges go from Novice → Master based on engagement you've earned. [users.py](backend/app/routers/users.py)
- **Public author profile** with bio, social links, your published works grid, follower count. [author_profile_page.dart](lib/ui/pages/author_profile_page.dart)
- **Private mode** — keep your published work behind follow-approval if you want a smaller, curated audience. [follow_requests_page.dart](lib/ui/pages/follow_requests_page.dart)

### How that compares to "collaboration"

The Discord user said the platform looks "good for collaboration." This is worth being honest about: **what's shipped is publish-then-react, not live co-writing.**

- ✅ Readers commenting on your published work — shipped.
- ✅ DMs with other writers/readers — shipped. [chat_conversation_page.dart](lib/ui/pages/chat_conversation_page.dart)
- ✅ Following other writers, getting feedback through comments/DMs — shipped.
- ❌ Multiple writers editing the same draft live (Google-Docs style) — **not shipped**. One author per Space.
- ❌ Track-changes / suggested edits from another writer on your draft — not shipped.

If "collaboration" to you means *getting reader feedback after publishing*, the platform delivers. If it means *co-writing a draft with another author*, Ellipsus is closer.

---

## What a reader gets

The product runs both sides of the marketplace — same account, switch hats.

- **A home feed with curated rails** — Featured, Continue Reading, New Releases, For You, Trending Now, Top 10, Hidden Gems, Editor's Picks. [feed.py](backend/app/routers/feed.py)
- **Search across titles, descriptions, authors, content.** [search_page.dart](lib/ui/app/search_page.dart)
- **Browse by genre or tag.** [tag_feed_page.dart](lib/ui/pages/tag_feed_page.dart)
- **Reader view with proper typography** — 8 serif/sans choices including Atkinson Hyperlegible for low-vision readers; light/dark themes; resume where you left off. [post_detail_page.dart](lib/ui/pages/post_detail_page.dart)
- **Highlights** in custom colors, with private notes per highlight. [highlights.py](backend/app/routers/highlights.py)
- **Bookmarks** that survive reflow when you change font size. [bookmarks.py](backend/app/routers/bookmarks.py)
- **Save to Favorites / Saved** + create your own **named bookshelves.** [view_bookshelf_page.dart](lib/ui/pages/view_bookshelf_page.dart)
- **Offline reading** — download to read on a plane, encrypted on device. [offline_provider.dart](lib/services/offline/offline_provider.dart)
- **Reading stats** — books read, completion %, time spent, reader-tier badge (Curious → Sage). [reading_statistics_page.dart](lib/ui/pages/reading_statistics_page.dart)

---

## Money / publishing model

- **Pay-per-story via Razorpay** (INR pricing). Authors set a price; readers pay; platform takes a fee; author balance pays out through the Razorpay dashboard. [payments.py](backend/app/routers/payments.py)
- **Free preview chapters** — you can mark some chapters free and gate the rest behind purchase.
- **You can also publish 100% free** — many works on the platform are.

Worth noting for marketing: pricing is INR-only today. International readers can still pay, but the price feels native to India first.

---

## Cross-device story

| Surface | What you get |
|---|---|
| Web | Read on any browser, log in, sync drafts. Landing page redirects to app for signed-in users. |
| Android | Full editor + reader, home-screen widgets, offline. |
| iOS | Same Flutter app. |
| macOS | Full editor + reader, system tray. |
| Windows | Full editor + reader, system tray. |
| Linux | Full editor + reader, system tray. |

Drafts, bookmarks, reading progress, follows, notifications — all live server-side and sync. Offline edits queue and drain when you reconnect. [outbox_drainer.dart](lib/services/sync/outbox_drainer.dart)

---

## Communication & community

- **In-app notifications center** with real-time delivery — likes, comments, new followers, follow requests, replies. [notifications_page.dart](lib/ui/pages/notifications_page.dart)
- **OS push notifications** for the same events.
- **1-on-1 chat** with any user, real-time streaming. [chat_conversation_page.dart](lib/ui/pages/chat_conversation_page.dart)
- **Block, report, and follow-request approval** for safety. [reports.py](backend/app/routers/reports.py)

No group chats / no servers / no public posting feed (à la Twitter). The social shape is "writers and their readers", not "everyone talks to everyone."

---

## Account essentials

- Email + password, Google OAuth, password reset, session restore.
- Profile: name, bio, photo, social links (Twitter, Instagram, personal site, etc.).
- Onboarding flow captures preferences that seed the home feed.
- Feed preferences page — genre/type interests, muted tags. [feed_preferences_page.dart](lib/ui/pages/feed_preferences_page.dart)
- App settings: theme, language, notification toggles, reading defaults.

---

## Honest gaps — things a user might *expect* and *not* find

Calling these out because the Discord conversation showed the user comparing us against Scrivener, Ellipsus, Notion, Milanote, Obsidian — and those each have features we don't yet match.

| User might expect (because competitor X has it) | Do we have it? |
|---|---|
| Real-time co-editing one draft, like Google Docs / Ellipsus | **No** — single-author Spaces only |
| Track changes / suggested edits from another writer | **No** |
| Export to .docx, .epub, .pdf, Markdown | **Not found in code** — landing page says "plain text export" |
| Knowledge-base / backlinks / wiki style (Obsidian) | **No** — this is a manuscript app, not a notes graph |
| Visual moodboard like Milanote | **Partial** — Canvas editor exists, but it's per-Space sketching, not a separate moodboard surface |
| Twitter-style public feed of all writers | **No** — feed is curated rails + follow-based |
| Group chats / writing circles | **No** — 1-on-1 DMs only |
| AI image generation for covers | **No** |
| International payment in USD/EUR | **No** — Razorpay INR only |
| End-to-end encrypted drafts | Landing page claims this. Worth a separate audit before saying it on the FAQ; the sync layer touches the server, so the claim needs to be precise about *what* is encrypted *where*. |

These aren't bugs — they're product-shape decisions. But they're the gaps a user might run into in their first week, so they belong on this list.

---

## Where the platform stands vs the Discord conversation

The user who started the thread asked "anyone has used this?" and another user replied with **Ellipsus**, **Notion**, **Milanote**, **Obsidian** as alternatives. Quick read on each:

- **vs Scrivener** — InkSpaceX has the same project model (Spaces, Binder, sections, labels) and *also* gives you publishing + reader feedback, which Scrivener never has. Scrivener wins on compile/export depth.
- **vs Ellipsus** — Ellipsus is built around live co-writing, version branching, and writer-to-writer collaboration. We don't compete on that. We compete on "publish to readers and get reactions."
- **vs Notion / Obsidian** — they're knowledge-base tools. InkSpaceX is a *manuscript* tool. Don't try to win the same fight.
- **vs Milanote** — visual planning for creatives. We have a Canvas surface but not a moodboard product. Adjacent, not overlapping.
- **vs Sudowrite** — AI-first writing tool. Our AI is opt-in inside a traditional editor; theirs is the whole product.

**The clearest positioning that matches what's actually built:**
*"Scrivener-style writing app with a reader audience built in. Publish your draft, get comments and ratings, write the next one."*

That's the sentence a solo short-story writer would understand in one read. It's also what the code actually delivers.
