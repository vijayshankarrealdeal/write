import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:inkspacex/ui/editor/image_embed_builder.dart';
import 'package:inkspacex/ui/widgets/app_network_image.dart';
import 'package:inkspacex/ui/widgets/app_spinner.dart';
import 'package:inkspacex/ui/widgets/author_link.dart';
import 'package:inkspacex/ui/widgets/cast_strip.dart';
import 'package:inkspacex/ui/widgets/more_like_this_carousel.dart';
import 'package:inkspacex/ui/widgets/report_dialog.dart';

import 'package:inkspacex/models/canvas_element_model.dart';
import 'package:inkspacex/models/comment_model.dart';
import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/models/image_meta.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/provider/bookmark_provider.dart';
import 'package:inkspacex/provider/feed_provider.dart';
import 'package:inkspacex/provider/offline_provider.dart';
import 'package:inkspacex/services/analytics_service.dart';
import 'package:inkspacex/services/api/api_data_service.dart';
import 'package:inkspacex/services/api/api_payments_service.dart';
import 'package:url_launcher/url_launcher.dart';

// ---------------------------------------------------------------------------
// Custom style builder (matches editor font rendering)
// ---------------------------------------------------------------------------
TextStyle _customStyleBuilder(quill.Attribute attr) {
  if (attr.key == 'font') {
    final name = attr.value as String?;
    if (name != null && name.isNotEmpty && name != 'Clear') {
      try {
        return GoogleFonts.getFont(name);
      } catch (_) {
        return TextStyle(fontFamily: name);
      }
    }
  }
  if (attr.key == 'size') {
    final raw = attr.value;
    final size =
        raw is num ? raw.toDouble() : double.tryParse(raw?.toString() ?? '');
    if (size != null && size > 0) return TextStyle(fontSize: size);
  }
  return const TextStyle();
}

// ---------------------------------------------------------------------------
// Reading time estimator
// ---------------------------------------------------------------------------
int _estimateReadingMinutes(List<FeedItemSection> sections) {
  int totalWords = 0;
  for (final section in sections) {
    if (section.content.isEmpty) continue;
    try {
      final decoded = jsonDecode(section.content);
      if (decoded is List) {
        for (final op in decoded) {
          if (op is Map && op['insert'] is String) {
            totalWords +=
                (op['insert'] as String).split(RegExp(r'\s+')).length;
          }
        }
      }
    } catch (_) {}
  }
  return max(1, (totalWords / 238).ceil());
}

// ---------------------------------------------------------------------------
// Date formatter
// ---------------------------------------------------------------------------
String _formatDate(DateTime dt) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
}

// ============================================================================
// PostDetailPage — two-level: overview → section detail
// ============================================================================
class PostDetailPage extends StatefulWidget {
  final FeedItemModel item;
  const PostDetailPage({super.key, required this.item});

  @override
  State<PostDetailPage> createState() => _PostDetailPageState();
}

class _PostDetailPageState extends State<PostDetailPage>
    with SingleTickerProviderStateMixin {
  // -- Quill controllers (keyed by section index) --
  final Map<int, quill.QuillController> _quillControllers = {};

  // -- Editor + outer scroll keys per section, used to jump to a highlight's
  //    pixel position when the user taps a row in the Quotes drawer.
  final Map<int, GlobalKey<quill.EditorState>> _editorKeys = {};
  final Map<int, ScrollController> _sectionScrollControllers = {};

  // -- Lazy-loaded section bodies for big books. The server returns the
  // chapter list as title-only stubs; we fetch each body on demand from
  // /api/feed/{id}/sections/by-id/{section_id} (UUID-stable so reordering
  // / inserting / deleting sections doesn't move bodies under the
  // reader's cursor). Keyed by section index for the local UI;
  // value is the raw Quill-Delta JSON string.
  final Map<int, String> _lazyContent = {};
  // Sections whose lazy fetch is currently in flight, to dedupe.
  final Set<int> _lazyLoading = {};

  // -- "Updated" badge cache.
  // Maps section_id → the `updated_at` we showed the user the last time
  // they entered that chapter. Persisted across launches via
  // SharedPreferences (one key per (feedItemId, sectionId) pair).
  // Render rule: if `_item.sections[i].updatedAt > _lastSeenAt[id]`,
  // paint an "Updated" pill on the chapter row. Cache miss = brand new
  // chapter, no badge (the chapter list itself is the new-chapter
  // signal). Marked seen when the reader enters a section.
  final Map<String, DateTime> _lastSeenAt = {};

  // -- Reading progress persistence --
  late final ApiDataService _dataService;
  Timer? _debounce;
  String? _userId;

  // Local mirror of the displayed feed item. Seeded from `widget.item` (the
  // listing-shape model passed via GoRouter extra — sections empty because
  // list endpoints strip them) and replaced with the detail-shape response
  // from `_refreshCountsFromServer`. Reads go through this field, never
  // `widget.item`, so the chapter list paints once the detail fetch lands.
  late FeedItemModel _item;

  // -- Razorpay Payment Link state. `_checkoutBusy` guards the buy
  // CTA against double-tap. After returning from the hosted payment
  // page we poll the purchases endpoint until the webhook lands, then
  // refresh the item so the reader UI flips from "Buy" to fully
  // unlocked without the user having to back out and re-enter the page.
  bool _checkoutBusy = false;

  // -- Two-level navigation: null = overview, int = section detail --
  int? _selectedSectionIndex;

  // -- Last read section (for "continue reading" prompt) --
  int? _lastReadSection;

  // -- Chapter-list virtualization. Long books (Mahābhārata: 1422 chapters)
  // freeze the page if every row is laid out in a single shrinkWrap pass.
  // We render `_chaptersShown` rows up front and auto-bump that count by
  // `_kChaptersBatch` whenever the scroll viewport is within 800px of the
  // bottom — feels like infinite scroll without the all-at-once layout cost.
  static const int _kChaptersInitial = 50;
  static const int _kChaptersBatch = 8;
  static const double _kChaptersScrollTrigger = 800;
  int _chaptersShown = _kChaptersInitial;
  bool _chaptersBatchInFlight = false;

  // -- Scaffold key for endDrawer --
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  // -- PageView controller for section carousel --
  PageController? _pageController;

  // -- Reader hover state: drives chevron visibility on desktop (mouse only) --
  final ValueNotifier<bool> _readerHover = ValueNotifier(false);

  // -- Reader font scale (for Aa text size button in reading mode) --
  double _readerFontScale = 1.0;

  // -- Reader theme: 'white' | 'sepia' | 'black' | 'grey' --
  String _readerTheme = 'sepia';

  // -- Reader font family --
  // Default = Merriweather, bundled as a pubspec asset. Worldwide it's the
  // most-used reading-grade serif on the web (Medium-style sites, news
  // platforms, blogs), and shipping it as an asset means no Google Fonts
  // CDN fetch on first chapter open and identical rendering on every
  // platform (Android/iOS/web/desktop).
  String _readerFont = 'Merriweather';

  // -- Reader brightness multiplier (0.4–1.0, applied as overlay) --
  double _readerBrightness = 1.0;

  // -- Immersive (full) reading mode: hides app bar + bottom bar so the
  // reading column owns the whole viewport. Toggled by single-tap on the
  // section body OR auto-driven by scroll direction (see _scrollAccum
  // below). Resets when leaving the reader.
  bool _immersiveReader = false;

  // -- Scroll-direction immersive tracking --
  // Cumulative pixels scrolled in the current direction. Resets when
  // direction flips. Once it crosses ±threshold we toggle immersive and
  // reset to 0. Asymmetric thresholds (down 80 / up 40) bias toward giving
  // the reader controls back: harder to lose chrome, easier to recall it.
  // Top-of-page (pixels < 30) always forces chrome visible so the back
  // button is reachable when a reader reaches the start of a chapter.
  double _scrollAccum = 0;
  double _lastScrollPos = 0;

  // -- Per-section text highlights: section index -> list of (start, length, colorHex) --
  final Map<int, List<_Highlight>> _highlights = {};

  // -- Double-tap like heart animation --
  late final AnimationController _likeAnimController;

  // -- Accent color (used across reader UI) --
  static const Color _paperAccent = Color(0xFF2F62E0);

  // -- Chapter-row indicator dots. Blue = the section embeds an image.
  // Purple = the reader has personal marks here (highlights/notes or a
  // section bookmark). Fixed values so the dots render the same color
  // regardless of theme or which accent the surrounding card uses.
  static const Color _kChapterImageDot = Color(0xFF2563EB);
  static const Color _kChapterMarkDot = Color(0xFF8B5CF6);

  // --------------------------------------------------------------------------
  // Resolve reader palette (bg/text/subtle) from current theme
  // --------------------------------------------------------------------------
  ({Color bg, Color text, Color subtle}) _readerPalette() {
    switch (_readerTheme) {
      case 'white':
        return (
          bg: const Color(0xFFFFFFFF),
          text: const Color(0xFF1A1A1A),
          subtle: Colors.black.withValues(alpha: 0.5),
        );
      case 'black':
        return (
          bg: const Color(0xFF000000),
          text: const Color(0xFFE8E8E8),
          subtle: Colors.white.withValues(alpha: 0.55),
        );
      case 'grey':
        return (
          bg: const Color(0xFF2A2A2A),
          text: const Color(0xFFE8E8E8),
          subtle: Colors.white.withValues(alpha: 0.55),
        );
      case 'sepia':
      default:
        return (
          bg: const Color(0xFFEADCC1),
          text: const Color(0xFF2B2419),
          subtle: const Color(0xFF2B2419).withValues(alpha: 0.55),
        );
    }
  }

  // Faces we resolve via a plain TextStyle(fontFamily: …) — no GoogleFonts
  // CDN fetch. Two groups:
  //
  //  1. Bundled assets declared in pubspec.yaml (the eight reading fonts
  //     downloaded into `assets/fonts/`). These are the worldwide most-used
  //     serif/sans faces for long-form articles.
  //  2. OS-provided system serifs we keep as a fallback for the legacy
  //     `Georgia` default that older user prefs may still hold.
  static const Set<String> _bundledFontFamilies = {
    'Merriweather',
    'Lora',
    'PT Serif',
    'Source Serif 4',
    'Playfair Display',
    'Inter',
    'Open Sans',
    'Atkinson Hyperlegible',
  };
  static const Set<String> _systemFontFamilies = {
    'Georgia', 'Times New Roman', 'Times', 'Iowan Old Style', 'Charter',
    'Palatino', 'Garamond', 'Baskerville', 'serif',
  };

  // --------------------------------------------------------------------------
  // Resolve a TextStyle using the current reader font family
  // --------------------------------------------------------------------------
  TextStyle _readerTextStyle({
    double? fontSize,
    FontWeight? fontWeight,
    FontStyle? fontStyle,
    Color? color,
    double? height,
    double? letterSpacing,
  }) {
    // Bundled or system fonts get a plain TextStyle — no google_fonts
    // fetch on first chapter open, no network round-trip on web, identical
    // rendering across platforms because the .ttf travels with the app.
    if (_bundledFontFamilies.contains(_readerFont) ||
        _systemFontFamilies.contains(_readerFont)) {
      return TextStyle(
        fontFamily: _readerFont,
        fontFamilyFallback: const ['Merriweather', 'Georgia', 'serif'],
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontStyle: fontStyle,
        color: color,
        height: height,
        letterSpacing: letterSpacing,
      );
    }
    try {
      return GoogleFonts.getFont(
        _readerFont,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontStyle: fontStyle,
        color: color,
        height: height,
        letterSpacing: letterSpacing,
      );
    } catch (_) {
      return TextStyle(
        fontFamily: _readerFont,
        fontFamilyFallback: const ['Georgia', 'Times New Roman', 'serif'],
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontStyle: fontStyle,
        color: color,
        height: height,
        letterSpacing: letterSpacing,
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _item = widget.item;
    AnalyticsService.instance.track(
      'post_viewed',
      screen: '/post/:id',
      action: 'view',
      entityType: 'post',
      entityId: _item.id,
    );
    _likeAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    // Default theme: black for dark mode, white for light mode (overridden by saved pref)
    final platformBrightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    _readerTheme = platformBrightness == Brightness.dark ? 'black' : 'white';
    // Defer Quill parsing off the first frame — for the Mahābhārata's
    // first chapter (an 11K-char Translator's Preface) parsing the delta
    // costs ~80ms which would otherwise stall the page transition.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _dataService = context.read<AuthProvider>().dataService;
      _initQuillControllers();
      if (mounted) setState(() {}); // surface controllers as they land
      _loadProgress();
      _loadReaderPrefs();
      _hydrateSectionSeenCache();
      _subscribeToFeedItemEvents();
      _refreshCountsFromServer();
    });
  }

  // --------------------------------------------------------------------------
  // "Updated" badge persistence
  // --------------------------------------------------------------------------
  //
  // Per-(feedItem, section) "last seen this chapter's `updated_at`"
  // timestamp, used to decide whether to render the "Updated" pill on
  // the chapter row.
  //
  // Storage shape: one SharedPreferences key per chapter, namespaced to
  // the feed item so changing books doesn't pollute the cache:
  //
  //     section_seen_at:<feed_item_id>:<section_id> = ISO-8601 timestamp
  //
  // Hydrated once when the reader opens; mutated lazily as the reader
  // enters chapters. The full cache for a given book is at most
  // `n_sections` keys — fine even for the Mahābhārata (1422 keys = a few
  // hundred KB on disk, all string-typed, no JSON parse cost).
  static const _kSeenAtPrefix = 'section_seen_at:';

  String _seenAtKey(String sectionId) =>
      '$_kSeenAtPrefix${_item.id}:$sectionId';

  Future<void> _hydrateSectionSeenCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final prefix = '$_kSeenAtPrefix${_item.id}:';
      bool changed = false;
      for (final key in prefs.getKeys()) {
        if (!key.startsWith(prefix)) continue;
        final iso = prefs.getString(key);
        if (iso == null || iso.isEmpty) continue;
        final ts = DateTime.tryParse(iso);
        if (ts == null) continue;
        _lastSeenAt[key.substring(prefix.length)] = ts;
        changed = true;
      }
      if (changed && mounted) setState(() {});
    } catch (_) {
      // SharedPreferences failure shouldn't break the reader. Worst
      // case: every chapter shows "Updated" (cache miss → no badge),
      // or no chapter does — graceful degradation either way.
    }
  }

  /// True when the chapter has been edited since the user last opened it.
  /// Cache miss (brand new chapter) returns false on purpose — the new
  /// chapter is its own signal, "Updated" would be misleading.
  bool _isSectionUpdated(FeedItemSection section) {
    final updatedAt = section.updatedAt;
    if (updatedAt == null) return false;
    if (section.id.isEmpty) return false;
    final seen = _lastSeenAt[section.id];
    if (seen == null) return false;
    return updatedAt.isAfter(seen);
  }

  /// Persist the chapter's current `updated_at` so the "Updated" pill
  /// stops rendering on subsequent visits — until the author edits it
  /// again. No-op when the section has no id or no timestamp (older
  /// payloads without the new sectioning shape).
  Future<void> _markSectionSeen(FeedItemSection section) async {
    final updatedAt = section.updatedAt;
    if (updatedAt == null) return;
    if (section.id.isEmpty) return;
    _lastSeenAt[section.id] = updatedAt;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_seenAtKey(section.id), updatedAt.toIso8601String());
    } catch (_) {
      // Lost a write → user sees the badge again next launch. Acceptable.
    }
  }

  // The feed list cache may be older than the post itself — another
  // user might have liked or commented since this client last fetched
  // the list. Pull the authoritative counts on open so the action row
  // matches the DB before the SSE stream even has a chance to fire.
  // Also refresh the signed-in user so the heart's filled state matches
  // likes the user gave on a different device.
  // --------------------------------------------------------------------------
  // Razorpay Payment Link flow.
  //
  // Backend mints a hosted Payment Link URL (an Order with metadata
  // notes that the webhook handler uses to fan out a Route transfer
  // to the author on capture), we open it via `url_launcher`, then
  // poll the purchases endpoint until the webhook lands. A poll-based
  // gate beats listening for app-foreground events because the user
  // might complete the payment in a browser tab and never return to
  // the app — once they do, the next render hits a freshly-
  // `purchased=true` item and the gate dissolves.
  // --------------------------------------------------------------------------
  Future<void> _startCheckout() async {
    if (_checkoutBusy) return;
    if (_item.priceCents <= 0 || _item.purchased) return;
    setState(() => _checkoutBusy = true);
    final auth = context.read<AuthProvider>();
    final payments = ApiPaymentsService(auth.apiClient);
    try {
      final url = await payments.startCheckout(_item.id);
      final ok = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!ok) throw Exception("Couldn't open the payment page.");
      // Optimistic poll loop. Real-world latency is "webhook within a
      // second or two", so 10 attempts at 1.5s = 15s ceiling is plenty
      // without burning battery. We stop early as soon as the row
      // appears.
      for (var attempt = 0; attempt < 10; attempt++) {
        await Future.delayed(const Duration(milliseconds: 1500));
        if (!mounted) return;
        try {
          final status = await payments.getPurchase(_item.id);
          if (status.purchased) {
            await _refreshAfterPurchase();
            return;
          }
        } catch (_) {
          // Transient — keep polling.
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(e.toString().replaceFirst('Exception: ', ''))),
        );
      }
    } finally {
      if (mounted) setState(() => _checkoutBusy = false);
    }
  }

  Future<void> _refreshAfterPurchase() async {
    try {
      final fresh = await _dataService.getFeedItem(_item.id);
      if (fresh != null && mounted) {
        setState(() => _item = fresh);
      }
    } catch (_) {}
  }

  Future<void> _refreshCountsFromServer() async {
    final auth = context.read<AuthProvider>();
    final feed = context.read<FeedProvider>();
    final freshFuture = _dataService.getFeedItem(_item.id);
    final userFuture = auth.refreshCurrentUser();
    try {
      final fresh = await freshFuture;
      if (mounted && fresh != null) {
        feed.applyRemoteCounts(
          _item.id,
          likesCount: fresh.likesCount,
          commentsCount: fresh.commentsCount,
        );
        // Listing endpoints don't ship `sections` — only the detail
        // endpoint does, via `list_section_stubs`. Swap in the fresh
        // payload so the chapter list and reader paint, then build
        // controllers for any bodies that arrived inline.
        if (fresh.sections.isNotEmpty && _item.sections.isEmpty) {
          setState(() => _item = fresh);
          _initQuillControllers();
        }
      }
      await userFuture;
    } on FeedItemMissing {
      // Source writing was deleted (FK cascaded the feed_item). Drop it
      // from the in-memory list + disk cache so the next cold start
      // doesn't hand the user a tombstone, and pop this detail page.
      if (!mounted) return;
      feed.dropMissingItem(_item.id);
      Navigator.of(context).maybePop();
    } catch (_) {
      // Stale counts will get corrected by the next SSE event anyway.
    }
  }

  // --------------------------------------------------------------------------
  // Live counts: subscribe to the per-feed-item SSE channel and apply
  // count deltas broadcast by the backend so two clients viewing the
  // same post stay in sync. Comment list and tile-level updates are
  // owned by the comments sheet's own subscription; this listener only
  // touches `likesCount` / `commentsCount` on the FeedProvider's item.
  // --------------------------------------------------------------------------
  StreamSubscription<Map<String, dynamic>>? _feedItemEventsSub;

  void _subscribeToFeedItemEvents() {
    final feed = context.read<FeedProvider>();
    final stream = _dataService.feedItemEvents(_item.id);
    if (stream == null) return;
    _feedItemEventsSub = stream.listen((event) {
      if (!mounted) return;
      final type = event['type'];
      switch (type) {
        case 'comment.created':
        case 'comment.deleted':
          final c = event['comments_count'];
          if (c is num) {
            feed.applyRemoteCounts(
              _item.id,
              commentsCount: c.toInt(),
            );
          }
          break;
        case 'like.added':
        case 'like.removed':
          final l = event['likes_count'];
          if (l is num) {
            feed.applyRemoteCounts(
              _item.id,
              likesCount: l.toInt(),
            );
          }
          break;
      }
    });
  }

  // --------------------------------------------------------------------------
  // Persisted reader preferences (theme / font / size / brightness)
  // --------------------------------------------------------------------------
  static const _kPrefTheme = 'reader_theme';
  static const _kPrefFont = 'reader_font';
  static const _kPrefScale = 'reader_font_scale';
  static const _kPrefBrightness = 'reader_brightness';

  Future<void> _loadReaderPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      var savedFont = prefs.getString(_kPrefFont) ?? _readerFont;
      // Migration: pre-bundled-fonts builds defaulted to system serifs
      // ('Georgia', 'Iowan Old Style', 'Charter') which are no longer
      // listed in the picker. Map them onto the closest bundled face so
      // returning users see a font they can actually re-select.
      if (!_bundledFontFamilies.contains(savedFont)) {
        savedFont = 'Merriweather';
      }
      setState(() {
        _readerTheme = prefs.getString(_kPrefTheme) ?? _readerTheme;
        _readerFont = savedFont;
        _readerFontScale =
            prefs.getDouble(_kPrefScale) ?? _readerFontScale;
        _readerBrightness =
            prefs.getDouble(_kPrefBrightness) ?? _readerBrightness;
      });
    } catch (_) {}
  }

  Future<void> _saveReaderPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPrefTheme, _readerTheme);
      await prefs.setString(_kPrefFont, _readerFont);
      await prefs.setDouble(_kPrefScale, _readerFontScale);
      await prefs.setDouble(_kPrefBrightness, _readerBrightness);
    } catch (_) {}
  }

  // --------------------------------------------------------------------------
  // Quill controller setup
  //
  // For long books (e.g. the Mahābhārata's 1422 sections) the server inlines
  // only the first ~10 section bodies in the feed-item response; the rest
  // arrive as title-only stubs. We mirror that here: build controllers only
  // for sections whose content actually arrived, and lazy-fetch the others
  // on demand via `_ensureSectionLoaded` when the reader navigates to one.
  // --------------------------------------------------------------------------
  void _initQuillControllers() {
    for (int i = 0; i < _item.sections.length; i++) {
      final section = _item.sections[i];
      if (section.content.isEmpty) continue;
      _buildController(i, section.content);
    }
  }

  void _buildController(int index, String contentJson) {
    try {
      final delta = quill.Document.fromJson(jsonDecode(contentJson));
      _quillControllers[index] = quill.QuillController(
        document: delta,
        selection: const TextSelection.collapsed(offset: 0),
      );
    } catch (_) {
      // Malformed content — skip; the reader will show the empty placeholder.
    }
  }

  /// Fetch a section's body from the server if we don't already have it.
  /// Idempotent — returns immediately when the controller already exists
  /// or a fetch for this index is already in flight.
  Future<void> _ensureSectionLoaded(int index) async {
    if (_quillControllers.containsKey(index)) return;
    if (_lazyLoading.contains(index)) return;
    if (index < 0 || index >= _item.sections.length) return;

    final cached = _lazyContent[index];
    if (cached != null && cached.isNotEmpty) {
      _buildController(index, cached);
      if (mounted) setState(() {});
      return;
    }

    _lazyLoading.add(index);
    try {
      final section = _item.sections[index];
      // Prefer the UUID-keyed endpoint — stable across author edits
      // (insert / delete / reorder), so a reader on chapter X stays on
      // X even if the author shuffles the chapter list mid-session.
      // Fall back to the legacy index endpoint for older payloads
      // whose sections came down without ids (server now translates
      // index → published section UUID server-side).
      final Map<String, dynamic>? body;
      if (section.id.isNotEmpty) {
        body = await _dataService.getFeedItemSectionById(
          _item.id,
          section.id,
        );
      } else {
        body = await _dataService.getFeedItemSection(_item.id, index);
      }
      if (body == null) return;
      final raw = body['content'];
      // Server returns content as a Quill-Delta list; encode back to a JSON
      // string so it lines up with how FeedItemSection stores it locally.
      final asJson = raw is String ? raw : jsonEncode(raw ?? const []);
      if (asJson.isEmpty || asJson == '[]') return;
      _lazyContent[index] = asJson;
      _buildController(index, asJson);
      if (mounted) setState(() {});
    } finally {
      _lazyLoading.remove(index);
    }
  }

  // --------------------------------------------------------------------------
  // Load reading progress (for "continue reading" prompt, always start on overview)
  // --------------------------------------------------------------------------
  Future<void> _loadProgress() async {
    final auth = context.read<AuthProvider>();
    _userId = auth.currentUser?.id;
    if (_userId == null) return;
    try {
      final progress = await _dataService.getReadingProgress(
        _userId!,
        _item.id,
      );
      if (progress != null && mounted) {
        final saved = progress.scrollPosition.round();
        if (saved >= 0 && saved < _item.sections.length) {
          setState(() => _lastReadSection = saved);
        }
      }
    } catch (_) {}
    await _loadHighlights();
  }

  // --------------------------------------------------------------------------
  // Load saved highlights from Firestore and re-apply them to Quill docs
  // --------------------------------------------------------------------------
  Future<void> _loadHighlights() async {
    if (_userId == null) return;
    try {
      final rows = await _dataService.getHighlightsForFeedItem(
        userId: _userId!,
        feedItemId: _item.id,
      );
      if (!mounted) return;
      for (final h in rows) {
        final sectionIndex = (h['sectionIndex'] as num?)?.toInt();
        final start = (h['start'] as num?)?.toInt();
        final length = (h['length'] as num?)?.toInt();
        final colorHex = (h['colorHex'] as String?) ?? '';
        final id = (h['id'] as String?) ?? '';
        final note = (h['note'] as String?) ?? '';
        if (sectionIndex == null ||
            start == null ||
            length == null ||
            id.isEmpty ||
            colorHex.isEmpty) {
          continue;
        }
        _highlights.putIfAbsent(sectionIndex, () => []).add(
              _Highlight(
                id: id,
                start: start,
                length: length,
                colorHex: colorHex,
                note: note,
              ),
            );
        final controller = _quillControllers[sectionIndex];
        if (controller != null) {
          try {
            controller.formatText(
              start,
              length,
              quill.BackgroundAttribute(_themedHex(colorHex)),
            );
          } catch (_) {}
        }
      }
      if (mounted) setState(() {});
    } catch (_) {}
  }

  // --------------------------------------------------------------------------
  // Remove local + remote highlights overlapping the given range
  // --------------------------------------------------------------------------
  void _removeHighlightsInRange(int sectionIndex, int start, int length) {
    final list = _highlights[sectionIndex];
    if (list == null || list.isEmpty) return;
    final end = start + length;
    final toRemove = list
        .where((h) => h.start < end && (h.start + h.length) > start)
        .toList();
    for (final h in toRemove) {
      list.remove(h);
      if (_userId != null && h.id.isNotEmpty) {
        _dataService.deleteHighlight(
          userId: _userId!,
          highlightId: h.id,
        );
      }
    }
  }

  // --------------------------------------------------------------------------
  // Find the first highlight overlapping the given range (used by note flow)
  // --------------------------------------------------------------------------
  _Highlight? _findOverlappingHighlight(
      int sectionIndex, int start, int length) {
    final list = _highlights[sectionIndex];
    if (list == null || list.isEmpty) return null;
    final end = start + length;
    for (final h in list) {
      if (h.start < end && (h.start + h.length) > start) return h;
    }
    return null;
  }

  // --------------------------------------------------------------------------
  // Persist a note edit on an existing highlight
  // --------------------------------------------------------------------------
  void _setHighlightNote(int sectionIndex, _Highlight h, String note) {
    final list = _highlights[sectionIndex];
    if (list == null) return;
    final idx = list.indexWhere((x) => x.id == h.id);
    if (idx == -1) return;
    list[idx] = list[idx].copyWith(note: note);
    if (_userId != null) {
      _dataService.updateHighlightNote(
        userId: _userId!,
        highlightId: h.id,
        note: note,
      );
    }
    if (mounted) setState(() {});
  }

  // --------------------------------------------------------------------------
  // Scroll the section's outer ScrollView so the given highlight's first
  // line is centered in the viewport. Best-effort: if the editor hasn't
  // laid out yet (e.g. just navigated to the page), we retry on the next
  // frame. Used by the Quotes drawer to jump to the exact passage.
  // --------------------------------------------------------------------------
  void _scrollToHighlight(int sectionIndex, _Highlight h) {
    if (!mounted) return;

    final scroll = _sectionScrollControllers[sectionIndex];
    final editorKey = _editorKeys[sectionIndex];
    if (scroll == null || editorKey == null) {
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => _scrollToHighlight(sectionIndex, h));
      return;
    }

    final editorState = editorKey.currentState;
    final editorBox = editorKey.currentContext?.findRenderObject() as RenderBox?;
    if (editorState == null ||
        editorBox == null ||
        !editorBox.hasSize ||
        !scroll.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => _scrollToHighlight(sectionIndex, h));
      return;
    }

    Rect localRect;
    try {
      localRect = editorState.renderEditor
          .getLocalRectForCaret(TextPosition(offset: h.start));
    } catch (_) {
      return;
    }

    // Editor-local → global → outer-viewport-local, then add the current
    // scroll offset to land in the ScrollView's content coordinate space.
    final viewportBox = scroll.position.context.notificationContext
        ?.findRenderObject() as RenderBox?;
    if (viewportBox == null || !viewportBox.hasSize) return;
    final globalTopLeft = editorBox.localToGlobal(localRect.topLeft);
    final localInViewport = viewportBox.globalToLocal(globalTopLeft).dy;
    final contentY = localInViewport + scroll.offset;

    final viewportHeight = scroll.position.viewportDimension;
    final target = (contentY - viewportHeight / 3)
        .clamp(0.0, scroll.position.maxScrollExtent);

    scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeInOutCubic,
    );
  }

  // --------------------------------------------------------------------------
  // Change the canonical color of an existing highlight (re-paints Quill in
  // the current theme variant, persists canonical hex to backend).
  // --------------------------------------------------------------------------
  void _changeHighlightColor(
      int sectionIndex, _Highlight h, String canonicalHex) {
    final list = _highlights[sectionIndex];
    if (list == null) return;
    final idx = list.indexWhere((x) => x.id == h.id);
    if (idx == -1) return;
    list[idx] = list[idx].copyWith(colorHex: canonicalHex);
    final controller = _quillControllers[sectionIndex];
    if (controller != null) {
      try {
        controller.formatText(
          h.start,
          h.length,
          quill.BackgroundAttribute(_themedHex(canonicalHex)),
        );
      } catch (_) {}
    }
    if (_userId != null) {
      _dataService.updateHighlightColor(
        userId: _userId!,
        highlightId: h.id,
        colorHex: canonicalHex,
      );
    }
    if (mounted) setState(() {});
  }

  // --------------------------------------------------------------------------
  // Remove a single highlight (clears Quill background + local + remote)
  // --------------------------------------------------------------------------
  void _removeSingleHighlight(int sectionIndex, _Highlight h) {
    final controller = _quillControllers[sectionIndex];
    if (controller != null) {
      try {
        controller.formatText(h.start, h.length, quill.BackgroundAttribute(null));
      } catch (_) {}
    }
    _highlights[sectionIndex]?.removeWhere((x) => x.id == h.id);
    if (_userId != null && h.id.isNotEmpty) {
      _dataService.deleteHighlight(userId: _userId!, highlightId: h.id);
    }
    if (mounted) setState(() {});
  }

  // --------------------------------------------------------------------------
  // Open the animated note sheet for a highlight. Handles save + delete.
  // --------------------------------------------------------------------------
  Future<void> _openNoteSheet({
    required int sectionIndex,
    required _Highlight highlight,
  }) async {
    final palette = _readerPalette();
    final excerpt = _highlightExcerpt(sectionIndex, highlight);
    final result = await showGeneralDialog<_NoteSheetResult>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close note',
      barrierColor: Colors.black.withValues(alpha: 0.55),
      transitionDuration: const Duration(milliseconds: 320),
      pageBuilder: (ctx, anim, secondary) => _NoteSheet(
        excerpt: excerpt,
        bg: palette.bg,
        textColor: palette.text,
        subtleColor: palette.subtle,
        initial: highlight.note,
        initialCanonicalHex: highlight.colorHex,
        swatches: [
          for (final s in _swatchSlots)
            (
              display:
                  _hexToColor(_isReaderDark() ? s.dark : s.light),
              canonical: s.light,
            ),
        ],
      ),
      transitionBuilder: (ctx, anim, _, child) {
        final eased = CurvedAnimation(
          parent: anim,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: eased,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.06),
              end: Offset.zero,
            ).animate(eased),
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.97, end: 1.0).animate(eased),
              child: child,
            ),
          ),
        );
      },
    );
    if (result == null || !mounted) return;
    if (result.delete) {
      _removeSingleHighlight(sectionIndex, highlight);
      return;
    }
    final newNote = result.note ?? '';
    final newColor = result.canonicalHex ?? highlight.colorHex;
    if (newColor != highlight.colorHex) {
      _changeHighlightColor(sectionIndex, highlight, newColor);
    }
    if (newNote != highlight.note) {
      _setHighlightNote(sectionIndex, highlight, newNote);
    }
  }

  // --------------------------------------------------------------------------
  // Note button entry from selection toolbar — creates a default highlight
  // first if the selection isn't already inside one, then opens the sheet.
  // --------------------------------------------------------------------------
  void _openNoteFromSelection(int sectionIndex) {
    final controller = _quillControllers[sectionIndex];
    if (controller == null) return;
    final sel = controller.selection;
    if (!sel.isValid || sel.isCollapsed) return;
    final start = sel.start;
    final length = sel.end - sel.start;

    final overlap = _findOverlappingHighlight(sectionIndex, start, length);
    if (overlap != null) {
      _openNoteSheet(sectionIndex: sectionIndex, highlight: overlap);
      return;
    }

    const defaultHex = '#FFE066';
    try {
      controller.formatText(
          start, length, quill.BackgroundAttribute(_themedHex(defaultHex)));
    } catch (_) {}
    final id = const Uuid().v4();
    final h = _Highlight(
      id: id,
      start: start,
      length: length,
      colorHex: defaultHex,
    );
    _highlights.putIfAbsent(sectionIndex, () => []).add(h);
    if (_userId != null) {
      _dataService.addHighlight(
        userId: _userId!,
        feedItemId: _item.id,
        highlightId: id,
        sectionIndex: sectionIndex,
        start: start,
        length: length,
        colorHex: defaultHex,
      );
    }
    if (mounted) setState(() {});
    _openNoteSheet(sectionIndex: sectionIndex, highlight: h);
  }

  // --------------------------------------------------------------------------
  // Enter section detail mode (from overview or continue reading)
  // --------------------------------------------------------------------------
  void _enterSectionDetail(int index) {
    _pageController?.dispose();
    _pageController = PageController(initialPage: index);
    setState(() => _selectedSectionIndex = index);
    _resetImmersiveScrollTracking();
    _saveProgress(index);
    // Pre-warm the body for the section we're opening + the next two so
    // forward swipes feel instant. Fire-and-forget; UI shows a spinner
    // until each one resolves.
    _ensureSectionLoaded(index);
    _ensureSectionLoaded(index + 1);
    _ensureSectionLoaded(index + 2);
    // Entering a chapter clears its "Updated" pill — author edits
    // reach the reader live (no republish), so once they've actually
    // opened the chapter, the badge has done its job.
    if (index >= 0 && index < _item.sections.length) {
      _markSectionSeen(_item.sections[index]);
    }
  }

  // --------------------------------------------------------------------------
  // Scroll-direction immersive control.
  //
  // Attached to each section's ScrollController. Tracks cumulative scroll
  // distance in the current direction; flips immersive mode once distance
  // crosses a threshold. Direction reversal resets the accumulator.
  //
  //   • Down >80px      → hide chrome (enter immersive)
  //   • Up >40px        → show chrome (leave immersive)
  //   • Top-of-page     → always show chrome
  //   • |delta| > 200   → ignored (page swap / jump-to / oversized fling)
  //
  // Asymmetric thresholds intentionally bias toward giving the reader
  // controls back (lower up-threshold), so the app errs on the side of
  // discoverability rather than ruthless minimalism.
  // --------------------------------------------------------------------------
  void _onSectionScrollForImmersive(ScrollController c) {
    if (!c.hasClients) return;
    if (_selectedSectionIndex == null) return;
    // Only the active section's scroll should drive immersive — ignore
    // background controllers that may still emit while paged offscreen.
    if (_sectionScrollControllers[_selectedSectionIndex] != c) return;

    final pos = c.position.pixels;
    final delta = pos - _lastScrollPos;
    _lastScrollPos = pos;

    if (pos < 30) {
      if (_immersiveReader) setState(() => _immersiveReader = false);
      _scrollAccum = 0;
      return;
    }

    if (delta == 0 || delta.abs() > 200) return;

    if (_scrollAccum != 0 && delta.sign != _scrollAccum.sign) {
      _scrollAccum = 0;
    }
    _scrollAccum += delta;

    if (_scrollAccum > 80 && !_immersiveReader) {
      setState(() => _immersiveReader = true);
      _scrollAccum = 0;
    } else if (_scrollAccum < -40 && _immersiveReader) {
      setState(() => _immersiveReader = false);
      _scrollAccum = 0;
    }
  }

  void _resetImmersiveScrollTracking() {
    _scrollAccum = 0;
    final ctrl = _sectionScrollControllers[_selectedSectionIndex];
    _lastScrollPos =
        ctrl != null && ctrl.hasClients ? ctrl.position.pixels : 0;
  }

  // --------------------------------------------------------------------------
  // Navigate to a section within the carousel (from drawer or dots)
  // --------------------------------------------------------------------------
  void _navigateToSection(int index) {
    setState(() => _selectedSectionIndex = index);
    _resetImmersiveScrollTracking();
    _saveProgress(index);
    _ensureSectionLoaded(index);
    _ensureSectionLoaded(index + 1);
    // Same "seen" semantics as _enterSectionDetail — clear the badge
    // when the reader actually arrives on this chapter.
    if (index >= 0 && index < _item.sections.length) {
      _markSectionSeen(_item.sections[index]);
    }
    if (_pageController?.hasClients == true) {
      _pageController!.animateToPage(
        index,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  // --------------------------------------------------------------------------
  // Persist current section as reading progress
  // --------------------------------------------------------------------------
  void _saveProgress(int sectionIndex) {
    if (_userId == null) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _dataService.updateReadingProgress(
        _userId!,
        _item.id,
        sectionIndex.toDouble(),
      );
    });
  }

  // --------------------------------------------------------------------------
  // Double-tap like with heart animation
  // --------------------------------------------------------------------------
  void _onDoubleTapLike() {
    final auth = context.read<AuthProvider>();
    final feed = context.read<FeedProvider>();
    final alreadyLiked =
        auth.currentUser?.likes.contains(_item.id) ?? false;
    if (!alreadyLiked) {
      auth.toggleLike(_item.id, feedProvider: feed);
    }
    _likeAnimController.forward(from: 0.0);
  }

  // --------------------------------------------------------------------------
  // Reader settings bottom sheet (brightness · theme · font)
  // --------------------------------------------------------------------------
  void _openReaderTextSizeSheet(bool isDark) {
    const themes = [
      ('white', 'White', Color(0xFFFFFFFF), Color(0xFF1A1A1A)),
      ('sepia', 'Sepia', Color(0xFFEADCC1), Color(0xFF2B2419)),
      ('black', 'Black', Color(0xFF000000), Color(0xFFE8E8E8)),
      ('grey', 'Grey', Color(0xFF2A2A2A), Color(0xFFE8E8E8)),
    ];
    // Bundled-asset reading fonts (declared in pubspec.yaml under
    // `flutter > fonts`). Order matches the worldwide popularity of each
    // face for long-form reading: Merriweather first as the default.
    // Group 1 = serif (article body), Group 2 = sans (modern reads),
    // Group 3 = accessibility.
    const fonts = [
      'Merriweather',         // most-used reading serif on the web
      'Lora',                 // popular blog serif
      'PT Serif',             // news-grade serif
      'Source Serif 4',       // Adobe / Medium-style
      'Playfair Display',     // magazine display serif
      'Inter',                // modern sans, top web body face
      'Open Sans',            // long-running #1 Google body sans
      'Atkinson Hyperlegible',// accessibility / dyslexia-friendly
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (sheetCtx, setSheet) {
            // Re-resolve palette on every rebuild so theme changes apply live.
            final palette = _readerPalette();
            final paperBg = palette.bg;
            final paperText = palette.text;
            final paperSubtle = palette.subtle;
            final pillBg = paperText.withValues(alpha: 0.06);
            final pillBorder = paperText.withValues(alpha: 0.12);

            void apply(VoidCallback fn) {
              setSheet(fn);
              setState(fn);
              _saveReaderPrefs();
            }

            return AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              decoration: BoxDecoration(
                color: paperBg,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(24)),
              ),
              padding: EdgeInsets.fromLTRB(
                20, 12, 20, 16 + MediaQuery.of(sheetCtx).padding.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Drag handle
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: paperText.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),

                  // Brightness slider
                  Row(
                    children: [
                      Icon(CupertinoIcons.sun_min,
                          size: 18, color: paperSubtle),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(sheetCtx).copyWith(
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 8,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 14,
                            ),
                          ),
                          child: Slider(
                            value: _readerBrightness,
                            min: 0.4,
                            max: 1.0,
                            activeColor: _paperAccent,
                            inactiveColor: paperText.withValues(alpha: 0.2),
                            onChanged: (v) =>
                                apply(() => _readerBrightness = v),
                          ),
                        ),
                      ),
                      Icon(CupertinoIcons.sun_max_fill,
                          size: 20, color: paperSubtle),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Theme pills
                  Row(
                    children: [
                      for (final t in themes) ...[
                        Expanded(
                          child: GestureDetector(
                            onTap: () => apply(() => _readerTheme = t.$1),
                            child: Container(
                              height: 40,
                              decoration: BoxDecoration(
                                color: t.$3,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: _readerTheme == t.$1
                                      ? _paperAccent
                                      : pillBorder,
                                  width: _readerTheme == t.$1 ? 2 : 1,
                                ),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                t.$2,
                                style: GoogleFonts.inter(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: t.$4,
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (t != themes.last) const SizedBox(width: 8),
                      ],
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Font row: dropdown + size - / +
                  Row(
                    children: [
                      // Font dropdown
                      Expanded(
                        child: GestureDetector(
                          onTap: () => _showFontPickerMenu(
                            sheetCtx, fonts, paperBg, paperText, apply,
                          ),
                          child: Container(
                            height: 44,
                            padding:
                                const EdgeInsets.symmetric(horizontal: 14),
                            decoration: BoxDecoration(
                              color: pillBg,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: pillBorder),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _readerFont,
                                    style: TextStyle(
                                      fontFamily: _readerFont,
                                      fontSize: 15,
                                      color: paperText,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                                Icon(CupertinoIcons.chevron_down,
                                    size: 14, color: paperSubtle),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Decrease font
                      _SizeButton(
                        icon: CupertinoIcons.minus,
                        bg: pillBg,
                        border: pillBorder,
                        color: paperText,
                        onTap: () => apply(() {
                          _readerFontScale =
                              (_readerFontScale - 0.05).clamp(0.85, 1.5);
                        }),
                      ),
                      const SizedBox(width: 8),
                      // Increase font
                      _SizeButton(
                        icon: CupertinoIcons.plus,
                        bg: pillBg,
                        border: pillBorder,
                        color: paperText,
                        onTap: () => apply(() {
                          _readerFontScale =
                              (_readerFontScale + 0.05).clamp(0.85, 1.5);
                        }),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Advanced settings link
                  Center(
                    child: GestureDetector(
                      onTap: () => Navigator.pop(sheetCtx),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          'Advanced settings',
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            color: paperSubtle,
                            decoration: TextDecoration.underline,
                            decorationColor: paperSubtle,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // --------------------------------------------------------------------------
  // Font picker popup (used inside the reader settings sheet)
  // --------------------------------------------------------------------------
  void _showFontPickerMenu(
    BuildContext sheetCtx,
    List<String> fonts,
    Color paperBg,
    Color paperText,
    void Function(VoidCallback) apply,
  ) {
    showModalBottomSheet(
      context: sheetCtx,
      backgroundColor: paperBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final f in fonts)
              ListTile(
                title: Text(
                  f,
                  style: TextStyle(
                    fontFamily: f,
                    fontSize: 16,
                    color: paperText,
                    fontWeight: _readerFont == f
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
                trailing: _readerFont == f
                    ? Icon(CupertinoIcons.check_mark,
                        color: _paperAccent, size: 20)
                    : null,
                onTap: () {
                  apply(() => _readerFont = f);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // Open comments bottom sheet — inline composer with optimistic UI.
  // --------------------------------------------------------------------------
  void _openCommentsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _CommentsSheet(item: _item),
    );
  }

  // --------------------------------------------------------------------------
  // Build quill editor styles
  // --------------------------------------------------------------------------
  quill.DefaultStyles _quillStyles(
    Color textColor,
    bool isDark, {
    bool paperMode = false,
    double scale = 1.0,
  }) {
    final paragraphStyle = paperMode
        ? _readerTextStyle(
            fontSize: 17 * scale,
            color: textColor,
            height: 1.7,
            letterSpacing: 0.1,
          )
        : GoogleFonts.inter(
            fontSize: 17,
            color: textColor,
            height: 1.8,
            letterSpacing: 0.1,
          );
    return quill.DefaultStyles(
      paragraph: quill.DefaultTextBlockStyle(
        paragraphStyle,
        quill.HorizontalSpacing.zero,
        const quill.VerticalSpacing(10, 0),
        quill.VerticalSpacing.zero,
        null,
      ),
      h1: quill.DefaultTextBlockStyle(
        GoogleFonts.playfairDisplay(
          fontSize: 28 * (paperMode ? scale : 1.0),
          fontWeight: FontWeight.w700,
          color: textColor,
          height: 1.3,
        ),
        quill.HorizontalSpacing.zero,
        const quill.VerticalSpacing(20, 8),
        quill.VerticalSpacing.zero,
        null,
      ),
      h2: quill.DefaultTextBlockStyle(
        GoogleFonts.playfairDisplay(
          fontSize: 24,
          fontWeight: FontWeight.w600,
          color: textColor,
          height: 1.35,
        ),
        quill.HorizontalSpacing.zero,
        const quill.VerticalSpacing(16, 6),
        quill.VerticalSpacing.zero,
        null,
      ),
      h3: quill.DefaultTextBlockStyle(
        GoogleFonts.inter(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: textColor,
          height: 1.4,
        ),
        quill.HorizontalSpacing.zero,
        const quill.VerticalSpacing(14, 4),
        quill.VerticalSpacing.zero,
        null,
      ),
      quote: quill.DefaultTextBlockStyle(
        GoogleFonts.inter(
          fontSize: 17,
          fontStyle: FontStyle.italic,
          color: textColor.withValues(alpha: 0.7),
          height: 1.7,
        ),
        quill.HorizontalSpacing.zero,
        const quill.VerticalSpacing(12, 12),
        quill.VerticalSpacing.zero,
        BoxDecoration(
          border: Border(
            left: BorderSide(
              color: isDark ? Colors.white24 : Colors.black26,
              width: 3,
            ),
          ),
        ),
      ),
      code: quill.DefaultTextBlockStyle(
        GoogleFonts.jetBrainsMono(
          fontSize: 14,
          color: textColor.withValues(alpha: 0.85),
          height: 1.5,
        ),
        quill.HorizontalSpacing.zero,
        const quill.VerticalSpacing(8, 8),
        quill.VerticalSpacing.zero,
        BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.05)
              : Colors.black.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      bold: const TextStyle(fontWeight: FontWeight.w700),
      italic: const TextStyle(fontStyle: FontStyle.italic),
      link: TextStyle(
        color:
            isDark ? const Color(0xFF93C5FD) : const Color(0xFF2563EB),
        decoration: TextDecoration.underline,
        decorationColor: isDark
            ? const Color(0xFF93C5FD).withValues(alpha: 0.4)
            : const Color(0xFF2563EB).withValues(alpha: 0.4),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // Get snippet text from a section (for card previews)
  // --------------------------------------------------------------------------
  String _sectionSnippet(FeedItemSection section) {
    final hasCanvas = section.canvasData.isNotEmpty;
    final hasText = section.content.isNotEmpty;

    if (!hasText && hasCanvas) return 'Tap to view artwork & layout';
    if (!hasText && !hasCanvas) return 'Tap to explore this section';

    try {
      final decoded = jsonDecode(section.content);
      if (decoded is List) {
        final buf = StringBuffer();
        for (final op in decoded) {
          if (op is Map && op['insert'] is String) {
            buf.write(op['insert']);
            if (buf.length > 120) break;
          }
        }
        return buf.toString().trim();
      }
    } catch (_) {}
    return '';
  }

  // --------------------------------------------------------------------------
  // Chapter list (with image-dot marker + capped initial render).
  // Renders only the first `_kChaptersInitial` rows up front; an "Show all"
  // tile reveals the rest. The dot marker tells readers which sections
  // contain illustrations without parsing any Quill content.
  // --------------------------------------------------------------------------
  Widget _buildChaptersList({
    required FeedItemModel item,
    required double contentPadding,
    required Color cardColor,
    required Color accentColor,
    required Color textColor,
    required Color subtleColor,
    required bool isDark,
  }) {
    final total = item.sections.length;
    final visible = _chaptersShown.clamp(0, total);
    final remaining = total - visible;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.05);

    // Watch for bookmark toggles so the purple "you've marked this" dot
    // updates immediately when the user bookmarks a section from the reader.
    final sectionBookmarks =
        context.watch<AuthProvider>().currentUser?.sectionBookmarks ??
            const <String>[];

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: contentPadding),
      child: Column(
        children: [
          for (int index = 0; index < visible; index++) ...[
            _buildChapterRow(
              item.sections[index],
              index: index,
              cardColor: cardColor,
              accentColor: accentColor,
              textColor: textColor,
              subtleColor: subtleColor,
              borderColor: borderColor,
              hasReaderMark: (_highlights[index]?.isNotEmpty ?? false) ||
                  sectionBookmarks.contains('${item.id}_$index'),
            ),
            const SizedBox(height: 10),
          ],
          if (remaining > 0)
            // Auto-fetched as the user scrolls into the trigger zone — see
            // the NotificationListener wrapping the overview SingleChildScrollView.
            // Tappable as a manual fallback for accessibility / desktop.
            GestureDetector(
              onTap: _chaptersBatchInFlight ? null : _bumpChaptersShown,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  color: cardColor,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: borderColor),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    AppSpinner(size: 16, color: accentColor),
                    const SizedBox(width: 10),
                    Text(
                      'Loading more · $remaining remaining',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: subtleColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Append `_kChaptersBatch` more rows on the next frame. Idempotent for
  /// the duration of the bump so a rapid scroll doesn't queue up multiple
  /// setState calls. Frame-throttled (~60fps) so the layout cost of each
  /// new batch can settle before the next one is requested.
  void _bumpChaptersShown() {
    if (_chaptersBatchInFlight) return;
    final total = _item.sections.length;
    if (_chaptersShown >= total) return;
    _chaptersBatchInFlight = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _chaptersShown = (_chaptersShown + _kChaptersBatch).clamp(0, total);
      });
      // Release the latch after a couple of frames so layout settles
      // before we accept another bump request from a still-scrolling user.
      Future.delayed(const Duration(milliseconds: 80), () {
        _chaptersBatchInFlight = false;
      });
    });
  }

  /// Listens to the overview ScrollView and triggers `_bumpChaptersShown`
  /// when the user is within the trigger zone of the current bottom.
  bool _onOverviewScroll(ScrollNotification n) {
    if (n is ScrollUpdateNotification || n is ScrollEndNotification) {
      final m = n.metrics;
      if (m.pixels >= m.maxScrollExtent - _kChaptersScrollTrigger) {
        if (_chaptersShown < _item.sections.length) {
          _bumpChaptersShown();
        }
      }
    }
    return false;
  }

  Widget _buildChapterRow(
    FeedItemSection section, {
    required int index,
    required Color cardColor,
    required Color accentColor,
    required Color textColor,
    required Color subtleColor,
    required Color borderColor,
    required bool hasReaderMark,
  }) {
    final snippet = _sectionSnippet(section);
    return GestureDetector(
      onTap: () => _enterSectionDetail(index),
      child: Container(
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: borderColor),
        ),
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            Container(
              width: 48,
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text(
                  '${index + 1}',
                  style: GoogleFonts.playfairDisplay(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: accentColor,
                  ),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 14, 16, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            section.title,
                            style: GoogleFonts.inter(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: textColor,
                              height: 1.3,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // "Updated" pill — author edited this chapter
                        // since the user last opened it. Clears when
                        // the user enters the chapter (`_markSectionSeen`).
                        if (_isSectionUpdated(section)) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: accentColor.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              'Updated',
                              style: GoogleFonts.inter(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: accentColor,
                                letterSpacing: 0.3,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (snippet.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        snippet,
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          color: subtleColor,
                          height: 1.4,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // Section indicator dots paired with the forward chevron, both
            // 7×7 circles so they read as a set: blue = the section embeds an
            // image, purple = the reader has personal marks (highlights/notes
            // or a section bookmark) here.
            if (section.hasImage)
              Container(
                width: 7,
                height: 7,
                margin: const EdgeInsets.only(right: 8),
                decoration: const BoxDecoration(
                  color: _kChapterImageDot,
                  shape: BoxShape.circle,
                ),
              ),
            if (hasReaderMark)
              Container(
                width: 7,
                height: 7,
                margin: const EdgeInsets.only(right: 8),
                decoration: const BoxDecoration(
                  color: _kChapterMarkDot,
                  shape: BoxShape.circle,
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Icon(
                CupertinoIcons.chevron_right,
                size: 16,
                color: subtleColor.withValues(alpha: 0.4),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // Dispose
  // --------------------------------------------------------------------------
  @override
  void dispose() {
    _debounce?.cancel();
    if (_feedItemEventsSub != null) {
      _feedItemEventsSub!.cancel();
      _dataService.closeFeedItemEvents(_item.id);
    }
    if (_userId != null && _selectedSectionIndex != null) {
      _dataService.updateReadingProgress(
        _userId!,
        _item.id,
        (_selectedSectionIndex ?? 0).toDouble(),
      );
    }
    _pageController?.dispose();
    _readerHover.dispose();
    _likeAnimController.dispose();
    for (final c in _quillControllers.values) {
      c.dispose();
    }
    for (final s in _sectionScrollControllers.values) {
      s.dispose();
    }
    super.dispose();
  }

  // ==========================================================================
  // BUILD
  // ==========================================================================
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inReader = _selectedSectionIndex != null;
    final palette = _readerPalette();
    final bgColor = inReader
        ? palette.bg
        : (isDark ? const Color(0xFF000000) : const Color(0xFFFAFAFA));
    final textColor = inReader
        ? palette.text
        : (isDark ? Colors.white : const Color(0xFF0F172A));
    final subtleColor = inReader
        ? palette.subtle
        : (isDark ? Colors.white54 : Colors.black45);
    final item = _item;

    // Heart animation curves
    final heartScale = TweenSequence<double>([
      TweenSequenceItem(
          tween: Tween(begin: 0.0, end: 1.0)
              .chain(CurveTween(curve: Curves.easeOut)),
          weight: 33),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 34),
      TweenSequenceItem(
          tween: Tween(begin: 1.0, end: 0.0)
              .chain(CurveTween(curve: Curves.easeIn)),
          weight: 33),
    ]).animate(_likeAnimController);

    final heartOpacity = TweenSequence<double>([
      TweenSequenceItem(
          tween: Tween(begin: 0.0, end: 1.0), weight: 33),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 34),
      TweenSequenceItem(
          tween: Tween(begin: 1.0, end: 0.0), weight: 33),
    ]).animate(_likeAnimController);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // Browser/system back: only go from section detail → overview.
        // Never pop the page — the app-bar back button handles leaving.
        if (_selectedSectionIndex != null) {
          _pageController?.dispose();
          _pageController = null;
          setState(() {
            _selectedSectionIndex = null;
            _immersiveReader = false;
          });
        }
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
      value: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Stack(
        children: [
          Scaffold(
        key: _scaffoldKey,
        backgroundColor: bgColor,
        extendBodyBehindAppBar: true,
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(kToolbarHeight),
          child: AnimatedSlide(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            offset: (inReader && _immersiveReader)
                ? const Offset(0, -1)
                : Offset.zero,
            child: AppBar(
          backgroundColor: bgColor,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          leading: CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: () {
              if (_selectedSectionIndex != null) {
                _pageController?.dispose();
                _pageController = null;
                setState(() {
                  _selectedSectionIndex = null;
                  _immersiveReader = false;
                });
              } else {
                Navigator.pop(context);
              }
            },
            child: Icon(CupertinoIcons.back, color: textColor, size: 22),
          ),
          title: inReader
              ? null
              : (MediaQuery.of(context).size.width >= 1024
                  ? null
                  : Text(
                  item.title,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: subtleColor,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                )),
          centerTitle: true,
          actions: [
            if (inReader) ...[
              // Aa: text size adjustment
              CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                onPressed: () => _openReaderTextSizeSheet(isDark),
                child: Text(
                  'Aa',
                  style: GoogleFonts.lora(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                  ),
                ),
              ),
              if (item.sections.length > 1)
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
                  child: Icon(
                    CupertinoIcons.list_bullet,
                    color: textColor,
                    size: 22,
                  ),
                ),
              Consumer<AuthProvider>(
                builder: (context, auth, _) {
                  final sectionIndex = _selectedSectionIndex ?? 0;
                  final key = '${item.id}_$sectionIndex';
                  final bookmarked =
                      auth.currentUser?.sectionBookmarks.contains(key) ?? false;
                  return CupertinoButton(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    onPressed: () =>
                        auth.toggleSectionBookmark(item.id, sectionIndex),
                    child: Icon(
                      bookmarked
                          ? CupertinoIcons.bookmark_fill
                          : CupertinoIcons.bookmark,
                      color: bookmarked ? _paperAccent : textColor,
                      size: 22,
                    ),
                  );
                },
              ),
              Consumer<AuthProvider>(
                builder: (context, auth, _) {
                  final favorited =
                      auth.currentUser?.favoritePosts.contains(item.id) ?? false;
                  return CupertinoButton(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    onPressed: () => auth.toggleFavorite(item.id),
                    child: Icon(
                      favorited
                          ? CupertinoIcons.star_fill
                          : CupertinoIcons.star,
                      color: favorited
                          ? const Color(0xFFFBBF24)
                          : textColor,
                      size: 22,
                    ),
                  );
                },
              ),
            ] else ...[
              // Phase 4: download for offline reading. Hidden when this
              // build wasn't shipped with a license public key (the
              // provider tells us so via [unavailableReason]).
              Consumer<OfflineProvider>(
                builder: (context, offline, _) {
                  // First touch initialises the on-disk store; safe to
                  // call repeatedly because [ensureReady] short-circuits.
                  if (offline.status == OfflineStatus.idle) {
                    Future.microtask(() => offline.ensureReady());
                  }
                  if (offline.unavailableReason != null) {
                    return const SizedBox.shrink();
                  }
                  final s = offline.stateOf(item.id);
                  IconData icon;
                  bool busy = false;
                  switch (s) {
                    case BookDownloadState.downloading:
                      busy = true;
                      icon = CupertinoIcons.cloud_download;
                      break;
                    case BookDownloadState.downloaded:
                      icon = CupertinoIcons.checkmark_alt_circle_fill;
                      break;
                    case BookDownloadState.failed:
                      icon = CupertinoIcons.exclamationmark_circle;
                      break;
                    case BookDownloadState.idle:
                      icon = CupertinoIcons.cloud_download;
                  }
                  return CupertinoButton(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    onPressed: busy
                        ? null
                        : () => _onTapOfflineDownload(offline, isDark),
                    child: busy
                        ? AppSpinner(size: 18, color: textColor)
                        : Icon(icon, color: textColor, size: 22),
                  );
                },
              ),
              if (item.sections.length > 1 && _selectedSectionIndex != null)
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
                  child: Icon(
                    CupertinoIcons.list_bullet,
                    color: textColor,
                    size: 22,
                  ),
                ),
            ],
            const SizedBox(width: 4),
          ],
            ),
          ),
        ),
        // Sections drawer
        endDrawer: item.sections.length > 1
            ? _buildSectionsDrawer(isDark, textColor, subtleColor, bgColor, item)
            : null,
        // The AppBar slides up off-screen in immersive mode (handled by
        // AnimatedSlide above). Body sits behind the AppBar layout-wise
        // (extendBodyBehindAppBar: true) and uses an animated top inset
        // that shrinks from `statusBar + kToolbarHeight` to just
        // `statusBar` in sync with the AppBar slide — no body snap on
        // toggle, just one continuous motion.
        body: GestureDetector(
          onDoubleTap: _onDoubleTapLike,
          child: AnimatedPadding(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.only(
            top: (inReader && _immersiveReader)
                ? MediaQuery.of(context).padding.top
                : MediaQuery.of(context).padding.top + kToolbarHeight,
            bottom: (inReader && _immersiveReader)
                ? MediaQuery.of(context).padding.bottom
                : 0,
          ),
          child: Stack(
            children: [
              // Decide: overview or section detail
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                child: _selectedSectionIndex == null
                    ? _buildOverview(isDark, textColor, subtleColor, bgColor)
                    : _PullDownToExit(
                        // Wide layouts pin a chapter rail beside the
                        // reader; pulling down to exit there feels jarring
                        // because the rail stays put. Phones and narrow
                        // tablets get the gesture.
                        enabled: MediaQuery.of(context).size.width < 1280,
                        onExit: () {
                          _pageController?.dispose();
                          _pageController = null;
                          setState(() {
                            _selectedSectionIndex = null;
                            _immersiveReader = false;
                          });
                        },
                        child: _buildSectionsCarousel(
                          isDark,
                          textColor,
                          subtleColor,
                          bgColor,
                        ),
                      ),
              ),
              // Heart animation overlay
              AnimatedBuilder(
                animation: _likeAnimController,
                builder: (context, child) {
                  if (!_likeAnimController.isAnimating &&
                      _likeAnimController.status !=
                          AnimationStatus.completed) {
                    return const SizedBox.shrink();
                  }
                  return Center(
                    child: Opacity(
                      opacity: heartOpacity.value,
                      child: Transform.scale(
                        scale: heartScale.value,
                        child: const Icon(
                          CupertinoIcons.heart_fill,
                          color: Color(0xFFEF4444),
                          size: 100,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        ),
      ),
          // Reader brightness overlay — covers the *entire* reading page
          // (app bar, body, bottom bar) when in reader mode and brightness
          // < 1.0. Sits above the Scaffold so chrome dims with the content.
          if (inReader && _readerBrightness < 0.99)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: Colors.black.withValues(
                    alpha: (1.0 - _readerBrightness).clamp(0.0, 0.6),
                  ),
                ),
              ),
            ),
        ],
      ),
      ),
    );
  }

  // ==========================================================================
  // SECTIONS DRAWER
  // ==========================================================================
  Widget _buildSectionsDrawer(
    bool isDark,
    Color textColor,
    Color subtleColor,
    Color bgColor,
    FeedItemModel item,
  ) {
    final inReader = _selectedSectionIndex != null;
    final palette = _readerPalette();
    final drawerBg = inReader
        ? palette.bg
        : (isDark ? const Color(0xFF141414) : Colors.white);
    final drawerText = inReader ? palette.text : textColor;
    final drawerSubtle = inReader ? palette.subtle : subtleColor;
    final dividerColor = drawerText.withValues(alpha: 0.08);
    final highlightCount =
        _highlights.values.fold<int>(0, (a, l) => a + l.length);

    return Drawer(
      backgroundColor: drawerBg,
      child: DefaultTabController(
        length: 4,
        child: SafeArea(
          child: Column(
            children: [
              // Header: title centered with close
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                child: Row(
                  children: [
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      onPressed: () => Navigator.pop(context),
                      child: Icon(CupertinoIcons.back,
                          size: 22, color: drawerText),
                    ),
                    Expanded(
                      child: Center(
                        child: Text(
                          item.title,
                          style: _readerTextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: drawerText,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    const SizedBox(width: 44),
                  ],
                ),
              ),
              // Tabs
              TabBar(
                isScrollable: false,
                labelColor: _paperAccent,
                unselectedLabelColor: drawerSubtle,
                indicatorColor: _paperAccent,
                indicatorSize: TabBarIndicatorSize.label,
                indicatorWeight: 2.5,
                labelStyle: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                unselectedLabelStyle: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
                tabs: const [
                  Tab(text: 'Chapters'),
                  Tab(text: 'Notes'),
                  Tab(text: 'Bookmarks'),
                  Tab(text: 'Quotes'),
                ],
              ),
              Divider(color: dividerColor, height: 1),
              Expanded(
                child: TabBarView(
                  physics: const BouncingScrollPhysics(),
                  children: [
                    // CHAPTERS tab
                    ListView.builder(
                      padding: EdgeInsets.zero,
                      itemCount: item.sections.length,
                      itemBuilder: (context, i) {
                        final isActive = i == _selectedSectionIndex;
                        final section = item.sections[i];
                        final updated = _isSectionUpdated(section);
                        return InkWell(
                          onTap: () {
                            if (_selectedSectionIndex == null) {
                              _enterSectionDetail(i);
                            } else {
                              _navigateToSection(i);
                            }
                            Navigator.pop(context);
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 14),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${i + 1}. ${section.title}',
                                    style: _readerTextStyle(
                                      fontSize: 15,
                                      fontWeight: isActive
                                          ? FontWeight.w600
                                          : FontWeight.w500,
                                      color: isActive ? _paperAccent : drawerText,
                                      height: 1.4,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (updated) ...[
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: _paperAccent.withValues(alpha: 0.14),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      'Updated',
                                      style: GoogleFonts.inter(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        color: _paperAccent,
                                        letterSpacing: 0.3,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    ),

                    // NOTES tab — placeholder
                    _drawerEmptyState(
                      icon: CupertinoIcons.pencil,
                      title: 'No notes yet',
                      subtitle:
                          'Long-press text in the reader to jot a note.',
                      textColor: drawerText,
                      subtleColor: drawerSubtle,
                    ),

                    // BOOKMARKS tab — favorited posts/sections
                    Consumer<AuthProvider>(
                      builder: (context, auth, _) {
                        final favorited = auth.currentUser?.favoritePosts
                                .contains(item.id) ??
                            false;
                        if (!favorited) {
                          return _drawerEmptyState(
                            icon: CupertinoIcons.bookmark,
                            title: 'No bookmarks yet',
                            subtitle:
                                'Tap the bookmark icon in the reader to save this story.',
                            textColor: drawerText,
                            subtleColor: drawerSubtle,
                          );
                        }
                        return ListView(
                          padding: EdgeInsets.zero,
                          children: [
                            ListTile(
                              leading: Icon(CupertinoIcons.bookmark_fill,
                                  color: _paperAccent, size: 20),
                              title: Text(
                                item.title,
                                style: _readerTextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: drawerText,
                                ),
                              ),
                              subtitle: Text(
                                'Saved · tap to open',
                                style: _readerTextStyle(
                                  fontSize: 12,
                                  color: drawerSubtle,
                                ),
                              ),
                              onTap: () => Navigator.pop(context),
                            ),
                          ],
                        );
                      },
                    ),

                    // QUOTES tab — list of in-session highlights
                    highlightCount == 0
                        ? _drawerEmptyState(
                            icon: CupertinoIcons.text_quote,
                            title: 'No quotes yet',
                            subtitle:
                                'Select text in the reader and tap a color to highlight it.',
                            textColor: drawerText,
                            subtleColor: drawerSubtle,
                          )
                        : ListView(
                            padding: EdgeInsets.zero,
                            children: [
                              for (final entry in _highlights.entries)
                                for (final h in entry.value)
                                  ListTile(
                                    leading: Container(
                                      width: 4,
                                      height: 28,
                                      decoration: BoxDecoration(
                                        color: _hexToColor(_themedHex(h.colorHex)),
                                        borderRadius:
                                            BorderRadius.circular(2),
                                      ),
                                    ),
                                    title: Row(
                                      children: [
                                        Text(
                                          'Chapter ${entry.key + 1}',
                                          style: _readerTextStyle(
                                            fontSize: 13,
                                            color: drawerSubtle,
                                          ),
                                        ),
                                        if (h.note.isNotEmpty) ...[
                                          const SizedBox(width: 8),
                                          Icon(
                                            CupertinoIcons.text_bubble_fill,
                                            size: 12,
                                            color: drawerSubtle,
                                          ),
                                        ],
                                      ],
                                    ),
                                    subtitle: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          _highlightExcerpt(entry.key, h),
                                          style: _readerTextStyle(
                                            fontSize: 14,
                                            color: drawerText,
                                            height: 1.35,
                                          ),
                                          maxLines: 3,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        if (h.note.isNotEmpty) ...[
                                          const SizedBox(height: 6),
                                          Container(
                                            padding:
                                                const EdgeInsets.symmetric(
                                                    horizontal: 10,
                                                    vertical: 6),
                                            decoration: BoxDecoration(
                                              color: drawerText
                                                  .withValues(alpha: 0.05),
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              border: Border(
                                                left: BorderSide(
                                                  color: _hexToColor(
                                                      h.colorHex),
                                                  width: 2,
                                                ),
                                              ),
                                            ),
                                            child: Text(
                                              h.note,
                                              style: _readerTextStyle(
                                                fontSize: 13,
                                                color: drawerText
                                                    .withValues(alpha: 0.85),
                                                height: 1.4,
                                              ),
                                              maxLines: 4,
                                              overflow:
                                                  TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                    onTap: () {
                                      if (_selectedSectionIndex == null) {
                                        _enterSectionDetail(entry.key);
                                      } else {
                                        _navigateToSection(entry.key);
                                      }
                                      Navigator.pop(context);
                                      // Scroll to the exact passage once the
                                      // page has settled. _scrollToHighlight
                                      // self-retries until the editor lays
                                      // out so this works whether the user
                                      // was already on the chapter or not.
                                      WidgetsBinding.instance
                                          .addPostFrameCallback((_) {
                                        _scrollToHighlight(entry.key, h);
                                      });
                                    },
                                    onLongPress: () {
                                      Navigator.pop(context);
                                      _openNoteSheet(
                                        sectionIndex: entry.key,
                                        highlight: h,
                                      );
                                    },
                                  ),
                            ],
                          ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // Empty state used inside drawer tabs
  // --------------------------------------------------------------------------
  Widget _drawerEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color textColor,
    required Color subtleColor,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: subtleColor.withValues(alpha: 0.6)),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: _readerTextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: _readerTextStyle(
                fontSize: 13,
                color: subtleColor,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // Highlight swatch slots — canonical (light theme) hex paired with a
  // dark-mode variant. Storage stays canonical; rendering picks the variant
  // appropriate to the current reader theme so white-on-pastel and
  // black-on-deep-tone never strain the user's eyes.
  // --------------------------------------------------------------------------
  static const _swatchSlots = <({String light, String dark})>[
    (light: '#FFE066', dark: '#5C4A1F'), // yellow → deep amber
    (light: '#FFB4A2', dark: '#5C3329'), // peach → rust
    (light: '#B5EAD7', dark: '#1F4D3D'), // mint → forest
    (light: '#B8C5FF', dark: '#2F3D70'), // periwinkle → indigo
    (light: '#E0B0FF', dark: '#4D2F66'), // lilac → deep violet
    (light: '#FFC8DD', dark: '#5C2F45'), // pink → mulberry
  ];

  bool _isReaderDark() =>
      _readerTheme == 'black' || _readerTheme == 'grey';

  // Resolve a stored (canonical) hex to the variant that should actually
  // paint on the page right now. Unknown hexes pass through unchanged.
  String _themedHex(String canonicalHex) {
    if (canonicalHex.isEmpty) return canonicalHex;
    final dark = _isReaderDark();
    final upper = canonicalHex.toUpperCase();
    for (final s in _swatchSlots) {
      if (s.light.toUpperCase() == upper) return dark ? s.dark : s.light;
      if (s.dark.toUpperCase() == upper) return dark ? s.dark : s.light;
    }
    return canonicalHex;
  }

  // Theme-aware style builder for the QuillEditor. Falls back to the
  // top-level `_customStyleBuilder` for font/size, and overrides 'background'
  // to render canonical highlight hexes in their current-theme variant. This
  // lets us paint canonical hex into the document and decide the actual
  // pixel color at render time, so theme switches re-tint instantly without
  // mutating any data.
  TextStyle _readerStyleBuilder(quill.Attribute attr) {
    if (attr.key == quill.Attribute.background.key) {
      final raw = attr.value;
      if (raw is String && raw.isNotEmpty) {
        return TextStyle(backgroundColor: _hexToColor(_themedHex(raw)));
      }
      return const TextStyle();
    }
    return _customStyleBuilder(attr);
  }

  // --------------------------------------------------------------------------
  // Helpers for highlight previews in the Quotes tab
  // --------------------------------------------------------------------------
  Color _hexToColor(String hex) {
    if (hex.isEmpty) return Colors.transparent;
    final clean = hex.replaceAll('#', '');
    return Color(int.parse('FF$clean', radix: 16));
  }

  String _highlightExcerpt(int sectionIndex, _Highlight h) {
    final controller = _quillControllers[sectionIndex];
    if (controller == null) return '';
    final plain = controller.document.toPlainText();
    final start = h.start.clamp(0, plain.length);
    final end = (h.start + h.length).clamp(0, plain.length);
    return plain.substring(start, end).trim();
  }

  // ==========================================================================
  // LEVEL 1: POST OVERVIEW — Apple Books style detail page
  // ==========================================================================
  Widget _buildOverview(
    bool isDark,
    Color textColor,
    Color subtleColor,
    Color bgColor,
  ) {
    final item = _item;
    final readingMinutes = _estimateReadingMinutes(item.sections);
    const contentPadding = 20.0;
    const maxContentWidth = 760.0;
    final cardColor = isDark ? const Color(0xFF141414) : Colors.white;
    final dividerColor =
        isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.06);
    const accentColor = Color(0xFF2563EB);
    final firstExcerpt = _firstExcerpt(item.sections);
    final startIndex =
        (_lastReadSection != null && _lastReadSection! < item.sections.length)
            ? _lastReadSection!
            : 0;
    final isWideOverview = MediaQuery.of(context).size.width >= 1024;
    final genreLabel = item.genres.isNotEmpty
        ? item.genres.first
        : (item.writingTypes.isNotEmpty ? item.writingTypes.first : null);
    final allTags = <String>[
      ...item.writingTypes,
      ...item.genres,
      ...item.tags,
    ];
    final progressFraction = item.sections.isEmpty
        ? 0.0
        : ((_lastReadSection ?? 0) + (_lastReadSection != null ? 1 : 0)) /
            item.sections.length;

    return Stack(
      key: const ValueKey('overview'),
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: _onOverviewScroll,
          child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).padding.bottom + 120,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ---- Book header ----
              if (isWideOverview)
                _OverviewHeroDesktop(
                  item: item,
                  isDark: isDark,
                  textColor: textColor,
                  subtleColor: subtleColor,
                  accent: accentColor,
                  readingMinutes: readingMinutes,
                  genre: genreLabel,
                  tags: allTags,
                  resumeIndex: _lastReadSection,
                  resumeTitle: (_lastReadSection != null &&
                          _lastReadSection! < item.sections.length)
                      ? item.sections[_lastReadSection!].title
                      : null,
                  progressFraction: progressFraction.clamp(0.0, 1.0),
                  onContinue: () => _enterSectionDetail(startIndex),
                )
              else
                _BookHeader(
                  imageUrl: item.imageUrl,
                  imageMeta: item.imageMeta,
                  title: item.title,
                  author: item.author,
                  authorId: item.authorId,
                  isDark: isDark,
                  textColor: textColor,
                  subtleColor: subtleColor,
                ),

              // ---- Constrained content column (centered on desktop) ----
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: maxContentWidth),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
              // ---- Stats / tags / description (mobile only — desktop hero
              // already carries them in the right column).
              if (!isWideOverview) ...[
                Padding(
                  padding: EdgeInsets.fromLTRB(
                      contentPadding, 24, contentPadding, 0),
                  child: _StatsRow(
                    sections: item.sections.length,
                    readingMinutes: readingMinutes,
                    createdAt: item.createdAt,
                    genre: genreLabel,
                    isDark: isDark,
                    textColor: textColor,
                    subtleColor: subtleColor,
                  ),
                ),
                if (allTags.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                        contentPadding, 16, contentPadding, 0),
                    child: _TagWrap(tags: allTags, isDark: isDark),
                  ),
                if (item.description.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                        contentPadding, 24, contentPadding, 0),
                    child: _ExpandableDescription(
                      text: item.description,
                      textColor: textColor,
                      subtleColor: subtleColor,
                    ),
                  ),
              ],

              // ---- Buy banner (paid books, viewer hasn't purchased) ----
              if (item.priceCents > 0 && !item.purchased)
                Padding(
                  padding: EdgeInsets.fromLTRB(
                      contentPadding, 24, contentPadding, 0),
                  child: _BuyBanner(
                    item: item,
                    busy: _checkoutBusy,
                    onTap: _startCheckout,
                  ),
                ),

              // ---- Action row (like, comment, bookmark, share) ----
              Padding(
                padding: EdgeInsets.fromLTRB(
                    contentPadding, 24, contentPadding, 0),
                child: _ActionRow(
                  item: item,
                  isDark: isDark,
                  textColor: textColor,
                  subtleColor: subtleColor,
                  dividerColor: dividerColor,
                  onCommentTap: _openCommentsSheet,
                ),
              ),

              const SizedBox(height: 28),

              // ---- Featured excerpt card (Apple Books "Quotes" style) ----
              if (firstExcerpt.isNotEmpty)
                Padding(
                  padding: EdgeInsets.fromLTRB(
                      contentPadding, 0, contentPadding, 24),
                  child: _ExcerptCard(
                    excerpt: firstExcerpt,
                    author: item.author,
                    authorId: item.authorId,
                    onTap: () => _enterSectionDetail(0),
                  ),
                ),

              // ---- Continue reading banner ----
              if (_lastReadSection != null &&
                  _lastReadSection! > 0 &&
                  _lastReadSection! < item.sections.length)
                Padding(
                  padding: EdgeInsets.fromLTRB(
                      contentPadding, 0, contentPadding, 24),
                  child: GestureDetector(
                    onTap: () => _enterSectionDetail(_lastReadSection!),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: accentColor.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: accentColor.withValues(alpha: 0.2),
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: accentColor.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(
                              CupertinoIcons.book_fill,
                              size: 20,
                              color: accentColor,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Continue reading',
                                  style: GoogleFonts.inter(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: textColor,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Section ${_lastReadSection! + 1} \u00B7 ${item.sections[_lastReadSection!].title}',
                                  style: GoogleFonts.inter(
                                    fontSize: 13,
                                    color: subtleColor,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          const Icon(
                            CupertinoIcons.chevron_right,
                            size: 16,
                            color: accentColor,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              // ---- Cast strip ----
              // Lazy-fetches /api/feed/{id}/characters and renders a
              // horizontal row of avatars + names. Returns a
              // zero-height SizedBox for books with no character
              // bible, so this widget is safe to drop in
              // unconditionally above the chapter list.
              CastStrip(
                feedItemId: item.id,
                textColor: textColor,
                subtleColor: subtleColor,
                isDark: isDark,
                horizontalPadding: contentPadding,
              ),

              // ---- Chapters header ----
              Padding(
                padding: EdgeInsets.fromLTRB(
                    contentPadding, 4, contentPadding, 12),
                child: Row(
                  children: [
                    Text(
                      'Chapters',
                      style: GoogleFonts.playfairDisplay(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: textColor,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${item.sections.length} ${item.sections.length == 1 ? "section" : "sections"}',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: subtleColor,
                      ),
                    ),
                  ],
                ),
              ),

              // ---- Section cards ----
              // For long books (1000+ sections) rendering every row in one
              // pass freezes the page — `shrinkWrap: true` forces the list
              // to lay out *every* child to size itself. We cap the initial
              // render at 50 and reveal the rest behind a "Show all" tap.
              _buildChaptersList(
                item: item,
                contentPadding: contentPadding,
                cardColor: cardColor,
                accentColor: accentColor,
                textColor: textColor,
                subtleColor: subtleColor,
                isDark: isDark,
              ),

              // ---- More like this (semantic neighbours) ----
              Padding(
                padding: EdgeInsets.fromLTRB(
                    contentPadding, 32, contentPadding, 96),
                child: MoreLikeThisCarousel(
                  feedItemId: item.id,
                  isDark: isDark,
                  textColor: textColor,
                  subtleColor: subtleColor,
                ),
              ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        ),

        // ---- Sticky bottom Read CTA (mobile only — desktop hero has its own pill)
        if (item.sections.isNotEmpty && !isWideOverview)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _ReadCtaBar(
              isDark: isDark,
              label: _lastReadSection != null && _lastReadSection! > 0
                  ? 'Continue'
                  : 'Read',
              onTap: () => _enterSectionDetail(startIndex),
            ),
          ),
      ],
    );
  }

  // --------------------------------------------------------------------------
  // Pull a short excerpt string from the first section for the featured card
  // --------------------------------------------------------------------------
  String _firstExcerpt(List<FeedItemSection> sections) {
    for (final s in sections) {
      if (s.content.isEmpty) continue;
      try {
        final decoded = jsonDecode(s.content);
        if (decoded is List) {
          final buf = StringBuffer();
          for (final op in decoded) {
            if (op is Map && op['insert'] is String) {
              buf.write(op['insert']);
              if (buf.length > 240) break;
            }
          }
          final text = buf.toString().trim();
          if (text.isNotEmpty) return text;
        }
      } catch (_) {}
    }
    return '';
  }

  // ==========================================================================
  // LEVEL 2: SECTIONS CAROUSEL — swipeable PageView of all sections
  // ==========================================================================
  Widget _buildSectionsCarousel(
    bool isDark,
    Color textColor,
    Color subtleColor,
    Color bgColor,
  ) {
    final item = _item;
    final totalSections = item.sections.length;
    final dividerColor =
        isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.06);
    final currentIndex = _selectedSectionIndex ?? 0;

    final width = MediaQuery.of(context).size.width;
    final isWide = width >= 900;
    final isXWide = width >= 1280;
    final showChapterRail = isXWide && totalSections > 1;
    final progress = totalSections <= 1
        ? 1.0
        : (currentIndex + 1) / totalSections;

    Widget chevron(Alignment alignment, IconData icon, VoidCallback onTap) {
      return ValueListenableBuilder<bool>(
        valueListenable: _readerHover,
        builder: (_, hovered, child) => _ReaderSideChevron(
          alignment: alignment,
          icon: icon,
          textColor: textColor,
          subtleColor: subtleColor,
          isDark: isDark,
          visible: hovered,
          onTap: onTap,
        ),
      );
    }

    final readerColumn = Column(
      children: [
        // Hairline reading-progress bar — replaces the need to glance at "X of Y".
        SizedBox(
          height: 2,
          child: Stack(
            children: [
              Container(color: dividerColor),
              FractionallySizedBox(
                widthFactor: progress.clamp(0.0, 1.0),
                child: Container(color: _paperAccent),
              ),
            ],
          ),
        ),
        Expanded(
          child: MouseRegion(
            onEnter: (_) => _readerHover.value = true,
            onExit: (_) => _readerHover.value = false,
            child: Stack(
              children: [
                PageView.builder(
                  controller: _pageController,
                  itemCount: totalSections,
                  onPageChanged: (index) {
                    setState(() => _selectedSectionIndex = index);
                    _resetImmersiveScrollTracking();
                    _saveProgress(index);
                    _ensureSectionLoaded(index);
                    _ensureSectionLoaded(index + 1);
                    _ensureSectionLoaded(index + 2);
                  },
                  itemBuilder: (context, index) {
                    return _buildSingleSectionPage(
                      index, isDark, textColor, subtleColor,
                    );
                  },
                ),
                if (isWide && currentIndex > 0)
                  chevron(
                    Alignment.centerLeft,
                    CupertinoIcons.chevron_left,
                    () => _pageController?.previousPage(
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.easeOutCubic,
                    ),
                  ),
                if (isWide && currentIndex < totalSections - 1)
                  chevron(
                    Alignment.centerRight,
                    CupertinoIcons.chevron_right,
                    () => _pageController?.nextPage(
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.easeOutCubic,
                    ),
                  ),
                Positioned(
                  top: 14,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: _ReaderSelectionBar(
                      key: ValueKey('selbar-$currentIndex-$_readerTheme'),
                      controller: _quillControllers[currentIndex],
                      sectionIndex: currentIndex,
                      palette: _readerPalette(),
                      paperAccent: _paperAccent,
                      swatches: [
                        for (final s in _swatchSlots)
                          (
                            display: _hexToColor(
                                _isReaderDark() ? s.dark : s.light),
                            canonical: s.light,
                          ),
                      ],
                      onApplyHighlight: _applyHighlightAt,
                      onOpenNote: _openNoteFromSelection,
                      onOpenBookmark: (idx) {
                        final c = _quillControllers[idx];
                        if (c != null) _openBookmarkSheet(idx, c);
                      },
                      findOverlap: _findOverlappingHighlight,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // Bottom bar uses AnimatedSize so its height shrinks/grows
        // smoothly when immersive toggles, instead of snapping in or out.
        // alignment: topCenter pins the top edge so the bar appears to
        // "lift off" the bottom of the viewport rather than collapsing
        // toward its centre.
        ClipRect(
          child: AnimatedSize(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _immersiveReader
                ? const SizedBox(width: double.infinity, height: 0)
                : _buildReaderBottomBar(
                    isDark: isDark,
                    textColor: textColor,
                    subtleColor: subtleColor,
                    bgColor: bgColor,
                    dividerColor: dividerColor,
                    currentIndex: currentIndex,
                    totalSections: totalSections,
                    // FAB takes over Listen at xwide so the bar stays calm.
                    showListen: !isXWide,
                  ),
          ),
        ),
      ],
    );

    if (!showChapterRail) {
      return KeyedSubtree(
        key: const ValueKey('sections_carousel'),
        child: readerColumn,
      );
    }

    // Two-pane reading view at >=1280px: persistent chapter rail on the left,
    // reader in the middle, soft Listen FAB floating bottom-right.
    return KeyedSubtree(
      key: const ValueKey('sections_carousel'),
      child: Stack(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ReaderChapterRail(
                sections: item.sections,
                currentIndex: currentIndex,
                isDark: isDark,
                textColor: textColor,
                subtleColor: subtleColor,
                accent: _paperAccent,
                dividerColor: dividerColor,
                onTap: _navigateToSection,
              ),
              Container(width: 1, color: dividerColor),
              Expanded(child: readerColumn),
            ],
          ),
          Positioned(
            right: 28,
            bottom: 28 + MediaQuery.of(context).padding.bottom,
            child: IgnorePointer(
              ignoring: _immersiveReader,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                opacity: _immersiveReader ? 0 : 1,
                child: _ReaderListenFab(
                  accent: _paperAccent,
                  onTap: _onListenPressed,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------------------------------
  // Reader bottom bar (chapter / page count / Listen)
  // --------------------------------------------------------------------------
  Widget _buildReaderBottomBar({
    required bool isDark,
    required Color textColor,
    required Color subtleColor,
    required Color bgColor,
    required Color dividerColor,
    required int currentIndex,
    required int totalSections,
    bool showListen = true,
  }) {
    final pillBg = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);
    final remaining = totalSections - currentIndex - 1;
    final remainingLabel = remaining <= 0
        ? 'Last page'
        : '$remaining more page${remaining == 1 ? '' : 's'}';
    final isWide = MediaQuery.of(context).size.width >= 900;

    final listenButton = SizedBox(
      width: isWide ? 280 : double.infinity,
      height: 48,
      child: CupertinoButton(
        padding: EdgeInsets.zero,
        color: _paperAccent,
        borderRadius: BorderRadius.circular(28),
        onPressed: _onListenPressed,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              CupertinoIcons.play_circle_fill,
              color: Colors.white,
              size: 22,
            ),
            const SizedBox(width: 8),
            Text(
              'Listen',
              style: GoogleFonts.inter(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );

    return Container(
      color: bgColor,
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).padding.bottom + 12,
        left: 20,
        right: 20,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Column-width hairline divider so the footer feels like a book
              // page footer instead of full-bleed browser chrome.
              Container(height: 1, color: dividerColor),
              const SizedBox(height: 12),
              Row(
                children: [
                  GestureDetector(
                    onTap: totalSections > 1
                        ? () => _scaffoldKey.currentState?.openEndDrawer()
                        : null,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: pillBg,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        'Chapter ${currentIndex + 1}',
                        style: GoogleFonts.lora(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: textColor,
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${currentIndex + 1} of $totalSections',
                    style: GoogleFonts.lora(
                      fontSize: 13,
                      color: subtleColor,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    width: 1,
                    height: 14,
                    color: subtleColor.withValues(alpha: 0.4),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    remainingLabel,
                    style: GoogleFonts.lora(
                      fontSize: 13,
                      color: subtleColor,
                    ),
                  ),
                ],
              ),
              if (showListen) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.center,
                  child: listenButton,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // Single section page content (used inside the PageView)
  // --------------------------------------------------------------------------
  Widget _buildSingleSectionPage(
    int sectionIndex,
    bool isDark,
    Color textColor,
    Color subtleColor,
  ) {
    final section = _item.sections[sectionIndex];
    final isWide = MediaQuery.of(context).size.width >= 900;
    final contentPadding = isWide ? 32.0 : 24.0;
    const maxContentWidth = 720.0;
    final canvasMaxWidth = isWide ? 560.0 : 600.0;
    // Desktop reading distance is farther than a phone — bump effective scale
    // ~8% so the body text sits at a comfortable eye-level size without the
    // user needing to crank the Aa control.
    final effectiveScale = _readerFontScale * (isWide ? 1.08 : 1.0);
    final titleScale = isWide ? 1.08 : 1.0;
    final styles = _quillStyles(
      textColor,
      isDark,
      paperMode: true,
      scale: effectiveScale,
    );

    final scrollController = _sectionScrollControllers.putIfAbsent(
      sectionIndex,
      () {
        final c = ScrollController();
        c.addListener(() => _onSectionScrollForImmersive(c));
        return c;
      },
    );
    final body = SingleChildScrollView(
      controller: scrollController,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      padding: const EdgeInsets.only(bottom: 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: maxContentWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          // Section title — italic serif (book chapter style)
          Padding(
            padding:
                EdgeInsets.fromLTRB(contentPadding, 12, contentPadding, 20),
            child: Text(
              section.title,
              style: _readerTextStyle(
                fontSize: 22 * _readerFontScale * titleScale,
                fontStyle: FontStyle.italic,
                fontWeight: FontWeight.w600,
                color: textColor,
                height: 1.3,
                letterSpacing: 0.1,
              ),
            ),
          ),

          // Canvas preview (constrained width for desktop)
          if (section.canvasData.isNotEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(
                  contentPadding, 0, contentPadding, 20),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: canvasMaxWidth),
                  child: _CanvasPreview(
                    canvasData: section.canvasData,
                    isDark: isDark,
                  ),
                ),
              ),
            ),

          // While the section body is being lazy-fetched (long books only
          // inline the first ~10 sections; the rest stream in on demand),
          // show a spinner so the page never appears empty.
          if (!_quillControllers.containsKey(sectionIndex) &&
              section.content.isEmpty)
            Padding(
              padding:
                  EdgeInsets.fromLTRB(contentPadding, 32, contentPadding, 32),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppSpinner(size: 22, color: subtleColor),
                    const SizedBox(height: 12),
                    Text(
                      'Loading section…',
                      style: TextStyle(color: subtleColor, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
          // Quill content (serif body, highlight-on-select)
          if (_quillControllers.containsKey(sectionIndex))
            Padding(
              padding: EdgeInsets.fromLTRB(
                  contentPadding, 0, contentPadding, 8),
              child: quill.QuillEditor(
                controller: _quillControllers[sectionIndex]!,
                focusNode: FocusNode(canRequestFocus: false),
                scrollController: ScrollController(),
                config: quill.QuillEditorConfig(
                  editorKey: _editorKeys.putIfAbsent(
                    sectionIndex,
                    GlobalKey<quill.EditorState>.new,
                  ),
                  showCursor: false,
                  autoFocus: false,
                  expands: false,
                  customStyleBuilder: _readerStyleBuilder,
                  embedBuilders: [
                    ImageEmbedBuilder(
                      controller: _quillControllers[sectionIndex]!,
                      readOnly: true,
                    ),
                  ],
                  padding: EdgeInsets.zero,
                  customStyles: styles,
                ),
              ),
            ),
            ],
          ),
        ),
      ),
    );

    // Tap on the reading content toggles immersive (full) reading mode —
    // hides the app bar + bottom bar so only the page chrome the user is
    // actually reading remains. Long-press / drag-select still reaches the
    // Quill below for highlight + note flow.
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => setState(() => _immersiveReader = !_immersiveReader),
      child: body,
    );
  }

  // --------------------------------------------------------------------------
  // Apply / clear a highlight on the active selection of a section's editor.
  // Used by the floating selection bar (replaces the old contextMenuBuilder
  // path, which doesn't fire on desktop drag-select).
  // --------------------------------------------------------------------------
  void _applyHighlightAt(int sectionIndex, String? hex) {
    final controller = _quillControllers[sectionIndex];
    if (controller == null) return;
    final sel = controller.selection;
    if (!sel.isValid || sel.isCollapsed) return;
    final start = sel.start;
    final length = sel.end - sel.start;
    controller.formatText(
      start,
      length,
      hex == null
          ? quill.BackgroundAttribute(null)
          : quill.BackgroundAttribute(_themedHex(hex)),
    );
    if (hex == null) {
      _removeHighlightsInRange(sectionIndex, start, length);
    } else {
      final id = const Uuid().v4();
      _highlights.putIfAbsent(sectionIndex, () => []).add(
            _Highlight(
              id: id,
              start: start,
              length: length,
              colorHex: hex,
            ),
          );
      if (_userId != null) {
        _dataService.addHighlight(
          userId: _userId!,
          feedItemId: _item.id,
          highlightId: id,
          sectionIndex: sectionIndex,
          start: start,
          length: length,
          colorHex: hex,
        );
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _onTapOfflineDownload(
      OfflineProvider offline, bool isDark) async {
    final item = _item;
    if (offline.hasOffline(item.id)) {
      final remove = await showCupertinoDialog<bool>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: Text(item.title),
          content: const Text('This book is available offline.\nRemove the offline copy?'),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            CupertinoDialogAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove'),
            ),
          ],
        ),
      );
      if (remove == true) {
        await offline.evict(item.id);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Offline copy removed.')),
          );
        }
      }
      return;
    }
    final ok = await offline.download(item.id);
    if (!mounted) return;
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${item.title}" saved for offline reading.')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(offline.errorMessage ?? 'Download failed.'),
        ),
      );
    }
  }

  /// Bottom sheet for naming + colouring a bookmark at the current
  /// selection. Anchor is derived from the selection start: paragraph =
  /// number of newline characters before the cursor; char_offset = chars
  /// since the most recent newline. That maps cleanly to the server's
  /// `(paragraph_idx, char_offset)` schema and survives reflow.
  Future<void> _openBookmarkSheet(
    int sectionIndex,
    quill.QuillController controller,
  ) async {
    final sel = controller.selection;
    final fullText = controller.document.toPlainText();
    final cursor = sel.isValid ? sel.start.clamp(0, fullText.length) : 0;
    final before = fullText.substring(0, cursor);
    final paragraphIdx = '\n'.allMatches(before).length;
    final lastBreak = before.lastIndexOf('\n');
    final charOffset = lastBreak == -1 ? cursor : cursor - lastBreak - 1;

    final defaultLabel = _selectionPreview(controller, max: 60);
    final labelCtl = TextEditingController(text: defaultLabel);
    final palette = _readerPalette();
    String pickedColor = '#FFB300';
    const swatches = <String>[
      '#FFB300', '#7E57C2', '#26A69A', '#EC407A', '#42A5F5', '#66BB6A',
    ];

    final saved = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: palette.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final mq = MediaQuery.of(ctx);
            return Padding(
              padding: EdgeInsets.fromLTRB(
                  20, 16, 20, 16 + mq.viewInsets.bottom),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: palette.text.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Bookmark this paragraph',
                    style: GoogleFonts.inter(
                      color: palette.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: labelCtl,
                    style: GoogleFonts.inter(
                        color: palette.text, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Optional label',
                      hintStyle: GoogleFonts.inter(color: palette.subtle),
                      filled: true,
                      fillColor: palette.text.withValues(alpha: 0.05),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      for (final hex in swatches) ...[
                        GestureDetector(
                          onTap: () => setSheet(() => pickedColor = hex),
                          child: Container(
                            width: 30,
                            height: 30,
                            margin: const EdgeInsets.only(right: 8),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _hexToColor(hex),
                              border: Border.all(
                                width: pickedColor == hex ? 3 : 1,
                                color: pickedColor == hex
                                    ? palette.text
                                    : palette.text.withValues(alpha: 0.2),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: palette.text,
                        foregroundColor: palette.bg,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: Text(
                        'Save bookmark',
                        style: GoogleFonts.inter(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    if (saved != true || !mounted) {
      labelCtl.dispose();
      return;
    }

    final raw = labelCtl.text.trim();
    final label = raw.isEmpty ? null : raw;
    labelCtl.dispose();

    final feedItemId = _item.id;
    try {
      await context.read<BookmarkProvider>().addBookmark(
            feedItemId: feedItemId,
            sectionIndex: sectionIndex,
            paragraphIdx: paragraphIdx,
            charOffset: charOffset,
            label: label,
            color: pickedColor,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Bookmark saved',
            style: GoogleFonts.inter(fontSize: 13),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not save bookmark — will retry when online',
            style: GoogleFonts.inter(fontSize: 13),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  String _selectionPreview(quill.QuillController controller, {int max = 60}) {
    final sel = controller.selection;
    if (!sel.isValid || sel.isCollapsed) return '';
    final text = controller.document.toPlainText();
    final start = sel.start.clamp(0, text.length);
    final end = sel.end.clamp(0, text.length);
    final raw = text.substring(start, end).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (raw.length <= max) return raw;
    return '${raw.substring(0, max)}…';
  }

  // --------------------------------------------------------------------------
  // Listen button stub (audio narration)
  // --------------------------------------------------------------------------
  void _onListenPressed() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Audio narration coming soon',
          style: GoogleFonts.lora(fontSize: 14),
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

// ============================================================================
// BOOK HEADER — soft gradient backdrop with floating cover, title, author
// ============================================================================
class _BookHeader extends StatelessWidget {
  final String imageUrl;
  final ImageMeta? imageMeta;
  final String title;
  final String author;
  final String authorId;
  final bool isDark;
  final Color textColor;
  final Color subtleColor;

  const _BookHeader({
    required this.imageUrl,
    this.imageMeta,
    required this.title,
    required this.author,
    required this.authorId,
    required this.isDark,
    required this.textColor,
    required this.subtleColor,
  });

  @override
  Widget build(BuildContext context) {
    final hasCover = imageUrl.isNotEmpty || imageMeta != null;
    final screenWidth = MediaQuery.of(context).size.width;
    final coverWidth = screenWidth > 720 ? 200.0 : 160.0;
    final coverHeight = coverWidth * 1.45;

    return Stack(
      children: [
        // Blurred backdrop derived from the cover
        Positioned.fill(
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (hasCover)
                  AppNetworkImage(
                    url: imageUrl,
                    meta: imageMeta,
                    width: MediaQuery.sizeOf(context).width,
                    fit: BoxFit.cover,
                    errorWidget: const SizedBox.shrink(),
                  )
                else
                  Container(
                    color: isDark
                        ? const Color(0xFF1A1A1A)
                        : const Color(0xFFE8EAF0),
                  ),
                BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 60, sigmaY: 60),
                  child: Container(
                    color: (isDark ? Colors.black : Colors.white)
                        .withValues(alpha: 0.55),
                  ),
                ),
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        (isDark ? Colors.black : Colors.white)
                            .withValues(alpha: 0.0),
                        (isDark
                                ? const Color(0xFF000000)
                                : const Color(0xFFFAFAFA))
                            .withValues(alpha: 0.9),
                      ],
                      stops: const [0.6, 1.0],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // Foreground content
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 12),
              Center(
                child: Container(
                  width: coverWidth,
                  height: coverHeight,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(
                            alpha: isDark ? 0.6 : 0.25),
                        blurRadius: 30,
                        offset: const Offset(0, 16),
                        spreadRadius: -4,
                      ),
                      BoxShadow(
                        color: Colors.black.withValues(
                            alpha: isDark ? 0.4 : 0.12),
                        blurRadius: 8,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: hasCover
                        ? LayoutBuilder(
                            builder: (ctx, c) => AppNetworkImage(
                              url: imageUrl,
                              meta: imageMeta,
                              width: c.maxWidth,
                              height: c.maxHeight,
                              fit: BoxFit.cover,
                              errorWidget: Container(
                                color: isDark
                                    ? const Color(0xFF1E1E1E)
                                    : const Color(0xFFEDEDED),
                                child: Icon(CupertinoIcons.photo,
                                    size: 36,
                                    color: isDark
                                        ? Colors.white24
                                        : Colors.black26),
                              ),
                            ),
                          )
                        : Container(
                            color: isDark
                                ? const Color(0xFF1E1E1E)
                                : const Color(0xFFEDEDED),
                            child: Center(
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Text(
                                  title,
                                  textAlign: TextAlign.center,
                                  style: GoogleFonts.playfairDisplay(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                    color: textColor,
                                  ),
                                ),
                              ),
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 22),
              Text(
                title,
                textAlign: TextAlign.center,
                style: GoogleFonts.playfairDisplay(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                  height: 1.2,
                  letterSpacing: -0.4,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              AuthorLink(
                name: author,
                authorId: authorId,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF2563EB),
                  letterSpacing: -0.2,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// DESKTOP HERO — Row(cover left, content right) sharing one cinematic
// backdrop. Carries title, author, stats inline, tag cloud, synopsis preview
// and a centered Continue pill with a thin progress sliver. Replaces the
// mobile `_BookHeader` on >=1024px viewports.
// ============================================================================
class _OverviewHeroDesktop extends StatelessWidget {
  final FeedItemModel item;
  final bool isDark;
  final Color textColor;
  final Color subtleColor;
  final Color accent;
  final int readingMinutes;
  final String? genre;
  final List<String> tags;
  final int? resumeIndex;
  final String? resumeTitle;
  final double progressFraction;
  final VoidCallback onContinue;

  const _OverviewHeroDesktop({
    required this.item,
    required this.isDark,
    required this.textColor,
    required this.subtleColor,
    required this.accent,
    required this.readingMinutes,
    required this.genre,
    required this.tags,
    required this.resumeIndex,
    required this.resumeTitle,
    required this.progressFraction,
    required this.onContinue,
  });

  @override
  Widget build(BuildContext context) {
    final hasCover = item.imageUrl.isNotEmpty || item.imageMeta != null;
    const coverWidth = 240.0;
    const coverHeight = coverWidth * 1.45;

    final hasResume = resumeIndex != null && resumeIndex! > 0;
    final ctaLabel = hasResume
        ? 'Resume · Chapter ${resumeIndex! + 1}'
        : (resumeIndex != null ? 'Continue reading' : 'Start reading');
    final ctaSub = hasResume && resumeTitle != null && resumeTitle!.isNotEmpty
        ? resumeTitle!
        : null;

    return Stack(
      children: [
        // Cinematic blurred backdrop derived from the cover.
        Positioned.fill(
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (hasCover)
                  AppNetworkImage(
                    url: item.imageUrl,
                    meta: item.imageMeta,
                    width: MediaQuery.sizeOf(context).width,
                    fit: BoxFit.cover,
                    errorWidget: const SizedBox.shrink(),
                  )
                else
                  Container(
                    color: isDark
                        ? const Color(0xFF1A1A1A)
                        : const Color(0xFFE8EAF0),
                  ),
                BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 80, sigmaY: 80),
                  child: Container(
                    color: (isDark ? Colors.black : Colors.white)
                        .withValues(alpha: 0.62),
                  ),
                ),
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        (isDark ? Colors.black : Colors.white)
                            .withValues(alpha: 0.0),
                        (isDark
                                ? const Color(0xFF000000)
                                : const Color(0xFFFAFAFA))
                            .withValues(alpha: 0.92),
                      ],
                      stops: const [0.55, 1.0],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // Foreground row.
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1080),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(40, 36, 40, 36),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: coverWidth,
                    height: coverHeight,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(
                              alpha: isDark ? 0.6 : 0.25),
                          blurRadius: 36,
                          offset: const Offset(0, 18),
                          spreadRadius: -4,
                        ),
                        BoxShadow(
                          color: Colors.black.withValues(
                              alpha: isDark ? 0.4 : 0.12),
                          blurRadius: 10,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: hasCover
                          ? LayoutBuilder(
                              builder: (ctx, c) => AppNetworkImage(
                                url: item.imageUrl,
                                meta: item.imageMeta,
                                width: c.maxWidth,
                                height: c.maxHeight,
                                fit: BoxFit.cover,
                                errorWidget: Container(
                                  color: isDark
                                      ? const Color(0xFF1E1E1E)
                                      : const Color(0xFFEDEDED),
                                  child: Icon(CupertinoIcons.photo,
                                      size: 36,
                                      color: isDark
                                          ? Colors.white24
                                          : Colors.black26),
                                ),
                              ),
                            )
                          : Container(
                              color: isDark
                                  ? const Color(0xFF1E1E1E)
                                  : const Color(0xFFEDEDED),
                              child: Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Text(
                                    item.title,
                                    textAlign: TextAlign.center,
                                    style: GoogleFonts.playfairDisplay(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w700,
                                      color: textColor,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: 36),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          style: GoogleFonts.playfairDisplay(
                            fontSize: 36,
                            fontWeight: FontWeight.w700,
                            color: textColor,
                            height: 1.1,
                            letterSpacing: -0.6,
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 8),
                        AuthorLink(
                          name: item.author,
                          authorId: item.authorId,
                          style: GoogleFonts.inter(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: accent,
                            letterSpacing: -0.2,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 18),
                        _HeroInlineStats(
                          sections: item.sections.length,
                          readingMinutes: readingMinutes,
                          createdAt: item.createdAt,
                          genre: genre,
                          subtleColor: subtleColor,
                        ),
                        if (tags.isNotEmpty) ...[
                          const SizedBox(height: 18),
                          _TagWrap(tags: tags, isDark: isDark, maxVisible: 10),
                        ],
                        if (item.description.isNotEmpty) ...[
                          const SizedBox(height: 18),
                          _ExpandableDescription(
                            text: item.description,
                            textColor: textColor,
                            subtleColor: subtleColor,
                          ),
                        ],
                        const SizedBox(height: 24),
                        _HeroContinueCta(
                          label: ctaLabel,
                          subLabel: ctaSub,
                          accent: accent,
                          progress: progressFraction,
                          isDark: isDark,
                          onTap: onContinue,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _HeroInlineStats extends StatelessWidget {
  final int sections;
  final int readingMinutes;
  final DateTime createdAt;
  final String? genre;
  final Color subtleColor;

  const _HeroInlineStats({
    required this.sections,
    required this.readingMinutes,
    required this.createdAt,
    required this.genre,
    required this.subtleColor,
  });

  String _shortDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}';
  }

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      '$sections section${sections == 1 ? '' : 's'}',
      '$readingMinutes min',
      _shortDate(createdAt),
      if (genre != null && genre!.isNotEmpty) genre!,
    ];
    final style = GoogleFonts.inter(
      fontSize: 13,
      fontWeight: FontWeight.w500,
      color: subtleColor,
      letterSpacing: 0.1,
    );
    final children = <Widget>[];
    for (var i = 0; i < parts.length; i++) {
      children.add(Text(parts[i], style: style));
      if (i < parts.length - 1) {
        children.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text('·', style: style),
        ));
      }
    }
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }
}

class _HeroContinueCta extends StatefulWidget {
  final String label;
  final String? subLabel;
  final Color accent;
  final double progress;
  final bool isDark;
  final VoidCallback onTap;

  const _HeroContinueCta({
    required this.label,
    required this.subLabel,
    required this.accent,
    required this.progress,
    required this.isDark,
    required this.onTap,
  });

  @override
  State<_HeroContinueCta> createState() => _HeroContinueCtaState();
}

class _HeroContinueCtaState extends State<_HeroContinueCta> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final trackColor = widget.isDark
        ? Colors.white.withValues(alpha: 0.10)
        : Colors.black.withValues(alpha: 0.08);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: AnimatedScale(
            duration: const Duration(milliseconds: 120),
            scale: _pressed ? 0.97 : 1.0,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 320,
              height: 52,
              decoration: BoxDecoration(
                color: widget.accent,
                borderRadius: BorderRadius.circular(28),
                boxShadow: [
                  BoxShadow(
                    color: widget.accent
                        .withValues(alpha: _hover ? 0.45 : 0.28),
                    blurRadius: _hover ? 26 : 16,
                    offset: const Offset(0, 8),
                    spreadRadius: -2,
                  ),
                ],
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: widget.onTap,
                  onTapDown: (_) => setState(() => _pressed = true),
                  onTapUp: (_) => setState(() => _pressed = false),
                  onTapCancel: () => setState(() => _pressed = false),
                  borderRadius: BorderRadius.circular(28),
                  splashColor: Colors.white.withValues(alpha: 0.20),
                  highlightColor: Colors.white.withValues(alpha: 0.10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        CupertinoIcons.book_fill,
                        color: Colors.white,
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        widget.label,
                        style: GoogleFonts.inter(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          letterSpacing: -0.1,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (widget.progress > 0) ...[
          const SizedBox(height: 12),
          SizedBox(
            width: 320,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: SizedBox(
                    height: 3,
                    child: Stack(
                      children: [
                        Container(color: trackColor),
                        FractionallySizedBox(
                          widthFactor: widget.progress.clamp(0.0, 1.0),
                          child: Container(color: widget.accent),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${(widget.progress * 100).round()}% read'
                  '${widget.subLabel != null ? '  ·  ${widget.subLabel}' : ''}',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: widget.isDark
                        ? Colors.white.withValues(alpha: 0.55)
                        : Colors.black.withValues(alpha: 0.50),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

// ============================================================================
// STATS ROW — divided metric tiles (sections, reading time, genre/date)
// ============================================================================
class _StatsRow extends StatelessWidget {
  final int sections;
  final int readingMinutes;
  final DateTime createdAt;
  final String? genre;
  final bool isDark;
  final Color textColor;
  final Color subtleColor;

  const _StatsRow({
    required this.sections,
    required this.readingMinutes,
    required this.createdAt,
    required this.genre,
    required this.isDark,
    required this.textColor,
    required this.subtleColor,
  });

  @override
  Widget build(BuildContext context) {
    final dividerColor =
        isDark ? Colors.white12 : Colors.black.withValues(alpha: 0.08);

    final tiles = <Widget>[
      _tile(
        label: sections == 1 ? 'Section' : 'Sections',
        primary: '$sections',
      ),
      _tile(
        label: 'Length',
        primary: '$readingMinutes min',
      ),
      _tile(
        label: 'Published',
        primary: _shortDate(createdAt),
      ),
      if (genre != null)
        _tile(
          label: 'Genre',
          primary: genre!,
          compact: true,
        ),
    ];

    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.04)
            : Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          for (int i = 0; i < tiles.length; i++) ...[
            Expanded(child: tiles[i]),
            if (i < tiles.length - 1)
              Container(width: 1, height: 28, color: dividerColor),
          ],
        ],
      ),
    );
  }

  Widget _tile({
    required String label,
    required String primary,
    bool compact = false,
  }) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          primary,
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
            fontSize: compact ? 13 : 15,
            fontWeight: FontWeight.w700,
            color: textColor,
            letterSpacing: -0.2,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          label.toUpperCase(),
          style: GoogleFonts.inter(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: subtleColor,
            letterSpacing: 0.8,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  String _shortDate(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final now = DateTime.now();
    if (dt.year == now.year) return '${months[dt.month - 1]} ${dt.day}';
    return '${months[dt.month - 1]} ${dt.year}';
  }
}

// ============================================================================
// EXPANDABLE DESCRIPTION
// ============================================================================
class _ExpandableDescription extends StatefulWidget {
  final String text;
  final Color textColor;
  final Color subtleColor;

  const _ExpandableDescription({
    required this.text,
    required this.textColor,
    required this.subtleColor,
  });

  @override
  State<_ExpandableDescription> createState() => _ExpandableDescriptionState();
}

class _ExpandableDescriptionState extends State<_ExpandableDescription> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final style = GoogleFonts.inter(
      fontSize: 15,
      color: widget.textColor.withValues(alpha: 0.85),
      height: 1.55,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final tp = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: 3,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = tp.didExceedMaxLines;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.text,
              style: style,
              maxLines: _expanded ? null : 3,
              overflow: _expanded
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
            ),
            if (overflows)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: GestureDetector(
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Text(
                    _expanded ? 'Less' : 'More',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF2563EB),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

// ============================================================================
// EXCERPT CARD — featured "Quotes" style preview
// ============================================================================
class _ExcerptCard extends StatelessWidget {
  final String excerpt;
  final String author;
  final String authorId;
  final VoidCallback onTap;

  const _ExcerptCard({
    required this.excerpt,
    required this.author,
    required this.authorId,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final trimmed = excerpt.length > 180
        ? '${excerpt.substring(0, 180).trim()}\u2026'
        : excerpt;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 22),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF1E3A8A),
              Color(0xFF2563EB),
            ],
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF2563EB).withValues(alpha: 0.25),
              blurRadius: 24,
              offset: const Offset(0, 10),
              spreadRadius: -6,
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(100),
                  ),
                  child: Text(
                    'EXCERPT',
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      letterSpacing: 1.4,
                    ),
                  ),
                ),
                const Spacer(),
                Icon(
                  CupertinoIcons.quote_bubble_fill,
                  color: Colors.white.withValues(alpha: 0.5),
                  size: 22,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              trimmed,
              style: GoogleFonts.playfairDisplay(
                fontSize: 18,
                fontStyle: FontStyle.italic,
                fontWeight: FontWeight.w500,
                color: Colors.white,
                height: 1.45,
              ),
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                AuthorLink(
                  name: author,
                  authorId: authorId,
                  prefix: '\u2014 ',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Colors.white.withValues(alpha: 0.8),
                  ),
                ),
                const Spacer(),
                Text(
                  'Start reading',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(
                  CupertinoIcons.arrow_right,
                  color: Colors.white,
                  size: 14,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// STICKY READ CTA BAR (bottom of overview)
// ============================================================================
class _ReadCtaBar extends StatelessWidget {
  final bool isDark;
  final String label;
  final VoidCallback onTap;

  const _ReadCtaBar({
    required this.isDark,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          padding: EdgeInsets.fromLTRB(20, 14, 20, 14 + bottomPad),
          decoration: BoxDecoration(
            color: (isDark ? Colors.black : Colors.white)
                .withValues(alpha: 0.75),
            border: Border(
              top: BorderSide(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.black.withValues(alpha: 0.06),
              ),
            ),
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: SizedBox(
                height: 52,
                width: double.infinity,
                child: CupertinoButton(
                  padding: EdgeInsets.zero,
                  borderRadius: BorderRadius.circular(14),
                  color: const Color(0xFF2563EB),
                  onPressed: onTap,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        CupertinoIcons.book_fill,
                        color: Colors.white,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        label,
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// TAG PILL
// ============================================================================
class _TagPill extends StatelessWidget {
  final String label;
  final bool isDark;

  const _TagPill({required this.label, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.07)
            : Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(100),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.black.withValues(alpha: 0.06),
          width: 0.5,
        ),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: isDark
              ? Colors.white.withValues(alpha: 0.6)
              : Colors.black.withValues(alpha: 0.5),
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

// ============================================================================
// TAG WRAP — replaces the old horizontal scroll. Caps at 8 visible pills with a
// "+N more" trailing chip when the list overflows so we never clip mid-word.
// ============================================================================
class _TagWrap extends StatelessWidget {
  final List<String> tags;
  final bool isDark;
  final int maxVisible;

  const _TagWrap({
    required this.tags,
    required this.isDark,
    this.maxVisible = 8,
  });

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) return const SizedBox.shrink();
    final visible =
        tags.length > maxVisible ? tags.take(maxVisible).toList() : tags;
    final overflow = tags.length - visible.length;
    final pills = <Widget>[
      for (final t in visible) _TagPill(label: t, isDark: isDark),
      if (overflow > 0) _TagPill(label: '+$overflow more', isDark: isDark),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: pills,
    );
  }
}

// ============================================================================
// BUY BANNER — paid books, viewer hasn't purchased
//
// Surfaces price, the platform's promise (instant payout to author), and
// a single CTA that opens a hosted Razorpay Payment Link via
// `url_launcher`. The detail page polls the purchases endpoint after
// the user returns so the gate dissolves the moment the webhook lands.
// ============================================================================
class _BuyBanner extends StatelessWidget {
  final FeedItemModel item;
  final bool busy;
  final Future<void> Function() onTap;

  const _BuyBanner({
    required this.item,
    required this.busy,
    required this.onTap,
  });

  String _formatPrice() {
    final dollars = item.priceCents / 100;
    final code = item.currency.toUpperCase();
    return '${dollars.toStringAsFixed(2)} $code';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = const Color(0xFF2F62E0);
    final bg = accent.withValues(alpha: isDark ? 0.18 : 0.08);
    final border = accent.withValues(alpha: 0.3);
    final textColor = isDark ? Colors.white : Colors.black;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: accent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              CupertinoIcons.lock_open_fill,
              color: Colors.white,
              size: 20,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Unlock the full book',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: textColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Pays the author instantly via Razorpay',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: textColor.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: busy ? null : () => onTap(),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: AppSpinner(color: Colors.white),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          CupertinoIcons.bag_fill,
                          color: Colors.white,
                          size: 14,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Buy ${_formatPrice()}',
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}


// ============================================================================
// ACTION ROW (Like / Comment / Bookmark / Share)
// ============================================================================
class _ActionRow extends StatelessWidget {
  final FeedItemModel item;
  final bool isDark;
  final Color textColor;
  final Color subtleColor;
  final Color dividerColor;
  final VoidCallback onCommentTap;

  const _ActionRow({
    required this.item,
    required this.isDark,
    required this.textColor,
    required this.subtleColor,
    required this.dividerColor,
    required this.onCommentTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Divider(color: dividerColor, height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Consumer2<AuthProvider, FeedProvider>(
            builder: (context, auth, feed, _) {
              final liked =
                  auth.currentUser?.likes.contains(item.id) ?? false;
              final saved =
                  auth.currentUser?.savedPosts.contains(item.id) ?? false;
              final liveLikes = feed.items
                      .where((i) => i.id == item.id)
                      .firstOrNull
                      ?.likesCount ??
                  item.likesCount;
              return Row(
                children: [
                  _ActionPill(
                    isDark: isDark,
                    tooltip: liked ? 'Unlike' : 'Like',
                    onTap: () =>
                        auth.toggleLike(item.id, feedProvider: feed),
                    icon: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      transitionBuilder: (child, anim) => ScaleTransition(
                        scale: anim,
                        child: child,
                      ),
                      child: Icon(
                        liked
                            ? CupertinoIcons.heart_fill
                            : CupertinoIcons.heart,
                        key: ValueKey(liked),
                        color: liked
                            ? const Color(0xFFEF4444)
                            : subtleColor,
                        size: 22,
                      ),
                    ),
                    label: '${liveLikes.clamp(0, 999999)}',
                    labelColor: textColor,
                  ),
                  const SizedBox(width: 4),
                  _ActionPill(
                    isDark: isDark,
                    tooltip: 'Reviews',
                    onTap: onCommentTap,
                    icon: Icon(
                      CupertinoIcons.chat_bubble,
                      color: subtleColor,
                      size: 20,
                    ),
                    label: '${item.commentsCount}',
                    labelColor: textColor,
                  ),
                  const Spacer(),
                  _ActionPill(
                    isDark: isDark,
                    tooltip: saved ? 'Saved' : 'Save',
                    onTap: () => auth.toggleSave(item.id),
                    icon: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      transitionBuilder: (child, anim) => ScaleTransition(
                        scale: anim,
                        child: child,
                      ),
                      child: Icon(
                        saved
                            ? CupertinoIcons.bookmark_fill
                            : CupertinoIcons.bookmark,
                        key: ValueKey(saved),
                        color: saved
                            ? const Color(0xFF2563EB)
                            : subtleColor,
                        size: 20,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  _ActionPill(
                    isDark: isDark,
                    tooltip: 'Share link',
                    onTap: () {
                      final shareUrl = '${Uri.base.origin}/post/${item.id}';
                      Clipboard.setData(
                        ClipboardData(text: shareUrl),
                      );
                      AnalyticsService.instance.track(
                        'post_link_copied',
                        screen: '/post/:id',
                        action: 'click',
                        entityType: 'post',
                        entityId: item.id,
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            'Link copied',
                            style: GoogleFonts.inter(fontSize: 14),
                          ),
                          behavior: SnackBarBehavior.floating,
                          duration: const Duration(seconds: 2),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      );
                    },
                    icon: Icon(
                      CupertinoIcons.share,
                      color: subtleColor,
                      size: 20,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        Divider(color: dividerColor, height: 1),
      ],
    );
  }
}

// Pill-shaped tappable surface used for like/comment/save/share. Adds a
// padded hit target, hover background, ripple, tooltip, and click cursor
// so the icons read as buttons rather than static glyphs.
class _ActionPill extends StatelessWidget {
  final Widget icon;
  final String? label;
  final Color? labelColor;
  final String tooltip;
  final VoidCallback onTap;
  final bool isDark;

  const _ActionPill({
    required this.icon,
    this.label,
    this.labelColor,
    required this.tooltip,
    required this.onTap,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final hoverBg = isDark
        ? Colors.white.withValues(alpha: 0.07)
        : Colors.black.withValues(alpha: 0.05);
    final splashBg = isDark
        ? Colors.white.withValues(alpha: 0.10)
        : Colors.black.withValues(alpha: 0.08);
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          hoverColor: hoverBg,
          splashColor: splashBg,
          highlightColor: hoverBg,
          mouseCursor: SystemMouseCursors.click,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: label == null ? 10 : 12,
              vertical: 8,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                icon,
                if (label != null) ...[
                  const SizedBox(width: 6),
                  Text(
                    label!,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: labelColor,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// COMMENTS SHEET — inline composer with optimistic UI
// ============================================================================
class _CommentsSheet extends StatefulWidget {
  final FeedItemModel item;
  const _CommentsSheet({required this.item});

  @override
  State<_CommentsSheet> createState() => _CommentsSheetState();
}

// Quick-react emoji bar — rendered with the OS native font so each
// emoji ships with the platform's color glyph (Apple Color Emoji on
// iOS, Noto Color Emoji on Android).
const List<String> _kQuickEmojis = [
  '\u{2764}\u{FE0F}',  // ❤️
  '\u{1F923}',         // 🤣
  '\u{1F525}',         // 🔥
  '\u{1F44F}',         // 👏
  '\u{1F622}',         // 😢
  '\u{1F60D}',         // 😍
  '\u{1F62E}',         // 😮
  '\u{1F602}',         // 😂
  '\u{1F44D}',         // 👍
  '\u{1F389}',         // 🎉
];

class _CommentsSheetState extends State<_CommentsSheet> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  final _scrollController = ScrollController();

  // Comments the user just submitted that haven't yet appeared in the
  // server stream. Cleared per-entry when the matching server comment arrives.
  final List<CommentModel> _pending = [];
  bool _sending = false;
  bool _hasText = false;

  void _insertEmoji(String emoji) {
    final sel = _controller.selection;
    final text = _controller.text;
    if (sel.isValid) {
      final start = sel.start;
      final end = sel.end;
      final next = text.replaceRange(start, end, emoji);
      _controller.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: start + emoji.length),
      );
    } else {
      _controller.text = text + emoji;
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
    }
    _focus.requestFocus();
  }

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final has = _controller.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // Merge pending (still-in-flight or unconfirmed) entries with the server
  // list. A pending entry is dropped once a server comment from the same
  // author with identical text shows up.
  List<CommentModel> _merge(List<CommentModel> server) {
    if (_pending.isEmpty) return server;
    final unconfirmed = _pending.where((p) {
      return !server.any((s) =>
          s.authorId == p.authorId && s.text.trim() == p.text.trim());
    }).toList();
    return [...unconfirmed, ...server];
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    final auth = context.read<AuthProvider>();
    final feed = context.read<FeedProvider>();
    final user = auth.currentUser;
    if (user == null) return;

    final optimistic = CommentModel(
      id: const Uuid().v4(),
      feedItemId: widget.item.id,
      authorId: user.id,
      authorName: user.name,
      authorPhotoUrl: user.photoUrl,
      authorPhotoMeta: user.photoMeta,
      text: text,
      createdAt: DateTime.now(),
      rating: 0,
    );

    setState(() {
      _pending.insert(0, optimistic);
      _sending = true;
    });
    _controller.clear();
    _focus.unfocus();

    // Fire and forget — UI already reflects the new comment.
    feed.addComment(optimistic).then((_) {
      if (!mounted) return;
      setState(() => _sending = false);
    }).catchError((Object _) {
      if (!mounted) return;
      setState(() {
        _pending.removeWhere((c) => c.id == optimistic.id);
        _sending = false;
      });
      _controller.text = text;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "Couldn't post your review. Tap send to retry.",
            style: GoogleFonts.inter(fontSize: 14),
          ),
          backgroundColor: const Color(0xFFDC2626),
          behavior: SnackBarBehavior.floating,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtleColor = isDark ? Colors.white54 : Colors.black45;
    final cardColor = isDark ? const Color(0xFF141414) : Colors.white;
    final dividerColor =
        isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.06);
    final fieldBg = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.04);
    final currentUser = context.watch<AuthProvider>().currentUser;
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, scrollController) => Container(
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              // Drag handle
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 8),
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white24 : Colors.black12,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Row(
                  children: [
                    Text(
                      'Reviews',
                      style: GoogleFonts.inter(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: textColor,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Icon(
                        CupertinoIcons.xmark_circle_fill,
                        color: subtleColor,
                        size: 24,
                      ),
                    ),
                  ],
                ),
              ),
              Divider(color: dividerColor, height: 1),
              // List
              Expanded(
                child: StreamBuilder<List<CommentModel>>(
                  stream: context
                      .read<FeedProvider>()
                      .getCommentsStream(widget.item.id),
                  builder: (context, snapshot) {
                    final server = snapshot.data ?? const <CommentModel>[];
                    final all = _merge(server);
                    final isInitialLoad =
                        snapshot.connectionState == ConnectionState.waiting &&
                            !snapshot.hasData &&
                            _pending.isEmpty;
                    if (isInitialLoad) {
                      return const Center(child: AppSpinner());
                    }
                    if (all.isEmpty) {
                      return Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              CupertinoIcons.chat_bubble_2,
                              size: 32,
                              color: subtleColor.withValues(alpha: 0.5),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'No reviews yet',
                              style: GoogleFonts.inter(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: subtleColor,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Be the first to share your thoughts.',
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                color: subtleColor.withValues(alpha: 0.7),
                              ),
                            ),
                          ],
                        ),
                      );
                    }
                    return ListView.builder(
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                      itemCount: all.length,
                      itemBuilder: (context, index) {
                        final c = all[index];
                        final pending =
                            _pending.any((p) => p.id == c.id);
                        return _CommentTile(
                          comment: c,
                          isDark: isDark,
                          isOwn: c.authorId == currentUser?.id,
                          isPending: pending,
                          onDelete: pending
                              ? () {}
                              : () {
                                  context
                                      .read<FeedProvider>()
                                      .deleteComment(widget.item.id, c.id);
                                },
                        );
                      },
                    );
                  },
                ),
              ),
              Divider(color: dividerColor, height: 1),
              // Quick-emoji reactions row (taps insert into the input)
              SizedBox(
                height: 44,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: _kQuickEmojis.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 4),
                  itemBuilder: (_, i) {
                    final e = _kQuickEmojis[i];
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _insertEmoji(e),
                      child: Container(
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Text(
                          e,
                          style: const TextStyle(fontSize: 24),
                        ),
                      ),
                    );
                  },
                ),
              ),
              // Inline composer
              Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  6,
                  10,
                  10 + MediaQuery.of(context).padding.bottom,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    ClipOval(
                      child: SizedBox(
                        width: 32,
                        height: 32,
                        child: (currentUser?.photoUrl != null &&
                                currentUser!.photoUrl!.isNotEmpty)
                            ? AppNetworkImage(
                                url: currentUser.photoUrl,
                                meta: currentUser.photoMeta,
                                width: 32,
                                height: 32,
                                fit: BoxFit.cover,
                              )
                            : Container(
                                color: const Color(0xFF2563EB),
                                alignment: Alignment.center,
                                child: Text(
                                  (currentUser?.name.isNotEmpty ?? false)
                                      ? currentUser!.name[0].toUpperCase()
                                      : 'U',
                                  style: GoogleFonts.inter(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: fieldBg,
                          borderRadius: BorderRadius.circular(22),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: CupertinoTextField(
                                controller: _controller,
                                focusNode: _focus,
                                placeholder: 'Share your thoughts...',
                                placeholderStyle: GoogleFonts.inter(
                                  color: subtleColor,
                                  fontSize: 15,
                                ),
                                style: GoogleFonts.inter(
                                  color: textColor,
                                  fontSize: 15,
                                ),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 10),
                                decoration: const BoxDecoration(),
                                maxLines: 4,
                                minLines: 1,
                                textInputAction: TextInputAction.send,
                                onSubmitted: (_) => _submit(),
                              ),
                            ),
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 150),
                              child: _hasText
                                  ? GestureDetector(
                                      key: const ValueKey('send'),
                                      behavior: HitTestBehavior.opaque,
                                      onTap: _submit,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 12, vertical: 8),
                                        child: Icon(
                                          CupertinoIcons
                                              .arrow_up_circle_fill,
                                          size: 30,
                                          color: const Color(0xFF2563EB),
                                        ),
                                      ),
                                    )
                                  : const SizedBox(
                                      key: ValueKey('empty'), width: 8),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// COMMENT TILE
// ============================================================================
class _CommentTile extends StatefulWidget {
  final CommentModel comment;
  final bool isDark;
  final bool isOwn;
  final bool isPending;
  final VoidCallback onDelete;

  const _CommentTile({
    required this.comment,
    required this.isDark,
    required this.isOwn,
    required this.onDelete,
    this.isPending = false,
  });

  @override
  State<_CommentTile> createState() => _CommentTileState();
}

class _CommentTileState extends State<_CommentTile> {
  bool _liked = false;
  int _likes = 0;

  void _toggleLike() {
    setState(() {
      if (_liked) {
        _liked = false;
        _likes = (_likes - 1).clamp(0, 999999);
      } else {
        _liked = true;
        _likes += 1;
      }
    });
  }

  void _showActions() {
    showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        actions: [
          if (widget.isOwn)
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () {
                Navigator.pop(ctx);
                widget.onDelete();
              },
              child: const Text('Delete'),
            )
          else
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () {
                Navigator.pop(ctx);
                showReportSheet(
                  context,
                  targetType: ReportTarget.comment,
                  targetId: widget.comment.id,
                  targetLabel: widget.comment.text,
                );
              },
              child: const Text('Report'),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final comment = widget.comment;
    final isDark = widget.isDark;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtleColor = isDark ? Colors.white38 : Colors.black38;

    return Opacity(
      opacity: widget.isPending ? 0.55 : 1.0,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: widget.isPending ? null : _showActions,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: comment.authorId.isEmpty
                    ? null
                    : () => context.push('/u/${comment.authorId}'),
                child: ClipOval(
                  child: SizedBox(
                    width: 34,
                    height: 34,
                    child: (comment.authorPhotoUrl != null &&
                            comment.authorPhotoUrl!.isNotEmpty)
                        ? AppNetworkImage(
                            url: comment.authorPhotoUrl,
                            meta: comment.authorPhotoMeta,
                            width: 34,
                            height: 34,
                            fit: BoxFit.cover,
                          )
                        : Container(
                            color: const Color(0xFF2563EB),
                            alignment: Alignment.center,
                            child: Text(
                              comment.authorName.isNotEmpty
                                  ? comment.authorName[0].toUpperCase()
                                  : 'U',
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: AuthorLink(
                            name: comment.authorName.isNotEmpty
                                ? comment.authorName
                                : 'User',
                            authorId: comment.authorId,
                            style: GoogleFonts.inter(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: textColor,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _timeAgo(comment.createdAt),
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            color: subtleColor,
                          ),
                        ),
                      ],
                    ),
                    if (comment.rating > 0) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: List.generate(5, (i) {
                          final filled = i < comment.rating;
                          return Padding(
                            padding: const EdgeInsets.only(right: 2),
                            child: Icon(
                              filled
                                  ? CupertinoIcons.star_fill
                                  : CupertinoIcons.star,
                              size: 13,
                              color: filled
                                  ? const Color(0xFFFBBF24)
                                  : subtleColor.withValues(alpha: 0.5),
                            ),
                          );
                        }),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Text(
                      comment.text,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        color: textColor.withValues(alpha: 0.85),
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.isPending ? null : _toggleLike,
                child: Padding(
                  padding: const EdgeInsets.only(top: 4, left: 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _liked
                            ? CupertinoIcons.heart_fill
                            : CupertinoIcons.heart,
                        size: 18,
                        color: _liked
                            ? const Color(0xFFEF4444)
                            : subtleColor,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _likes > 0 ? '$_likes' : '',
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: subtleColor,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}

// ============================================================================
// CANVAS PREVIEW
// ============================================================================
class _CanvasPreview extends StatelessWidget {
  final String canvasData;
  final bool isDark;

  const _CanvasPreview({required this.canvasData, required this.isDark});

  static const double _kRefWidth = 820.0;

  @override
  Widget build(BuildContext context) {
    Map<String, dynamic>? data;
    try {
      final decoded = jsonDecode(canvasData);
      if (decoded is Map<String, dynamic>) {
        data = decoded;
      } else if (decoded is List) {
        data = {
          'version': 1,
          'bgColor': 0,
          'bgImageUrl': '',
          'elements': decoded
        };
      }
    } catch (_) {
      return const SizedBox.shrink();
    }
    if (data == null) return const SizedBox.shrink();

    final version = data['version'] ?? 1;
    final bgColor = data['bgColor'] ?? 0;
    final bgImageUrl = (data['bgImageUrl'] ?? '') as String;
    final bgGradientStart = data['bgGradientStart'] as int?;
    final bgGradientEnd = data['bgGradientEnd'] as int?;
    final bgGradientDirection =
        (data['bgGradientDirection'] ?? 'top') as String;
    final hasBgGradient = bgGradientStart != null && bgGradientEnd != null;
    final elementsJson = data['elements'] as List? ?? [];
    if (elementsJson.isEmpty) return const SizedBox.shrink();

    final elements = elementsJson
        .map((e) => CanvasElement.fromJson(e as Map<String, dynamic>))
        .toList();

    if (version < 2) {
      for (final e in elements) {
        e.x = e.x / _kRefWidth;
        e.y = e.y / _kRefWidth;
        e.width = e.width / _kRefWidth;
        e.height = e.height / _kRefWidth;
      }
    }

    elements.sort((a, b) => a.zIndex.compareTo(b.zIndex));

    // Optional explicit aspect ratio (height / width). When canvas authors
    // set this we trust them; otherwise we keep the legacy 4:3 portrait frame
    // that existing element positions were laid out against.
    double heightOverWidth = 4 / 3;
    final ratioRaw = data['aspectRatio'];
    if (ratioRaw is num && ratioRaw > 0) {
      heightOverWidth = ratioRaw.toDouble();
    } else if (ratioRaw is String && ratioRaw.contains(':')) {
      final parts = ratioRaw.split(':');
      final w = double.tryParse(parts[0]);
      final h = parts.length > 1 ? double.tryParse(parts[1]) : null;
      if (w != null && h != null && w > 0 && h > 0) {
        heightOverWidth = h / w;
      }
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final canvasWidth = constraints.maxWidth;
        final canvasHeight = canvasWidth * heightOverWidth;

        final paperColor = bgColor != 0
            ? Color(bgColor)
            : (isDark ? const Color(0xFF131315) : Colors.white);

        final bgGradientAlign = _gradientAlignment(bgGradientDirection);

        final borderClr = isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.black.withValues(alpha: 0.06);

        return Container(
          width: canvasWidth,
          height: canvasHeight,
          decoration: BoxDecoration(
            color: hasBgGradient ? null : paperColor,
            gradient: hasBgGradient
                ? LinearGradient(
                    begin: bgGradientAlign.$1,
                    end: bgGradientAlign.$2,
                    colors: [
                      Color(bgGradientStart),
                      Color(bgGradientEnd)
                    ],
                  )
                : null,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderClr),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              if (bgImageUrl.isNotEmpty && bgImageUrl.startsWith('http'))
                Positioned.fill(
                  child: AppNetworkImage(
                    url: bgImageUrl,
                    meta: ImageMeta.fromInlineUrl(bgImageUrl),
                    width: canvasWidth,
                    height: canvasHeight,
                    fit: BoxFit.cover,
                    errorWidget: const SizedBox.shrink(),
                  ),
                ),
              for (final e in elements)
                _buildPreviewElement(e, canvasWidth, canvasHeight),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPreviewElement(
      CanvasElement e, double canvasWidth, double canvasHeight) {
    final pxX = e.x * canvasWidth;
    final pxY = e.y * canvasHeight;
    final pxW = e.width * canvasWidth;
    final pxH = e.height * canvasHeight;

    return Positioned(
      left: pxX,
      top: pxY,
      child: Transform.rotate(
        angle: e.rotation,
        child: SizedBox(
          width: pxW,
          height: pxH,
          child: e.type == CanvasElementType.image
              ? _buildImagePreview(e)
              : _buildTextPreview(e, canvasWidth),
        ),
      ),
    );
  }

  Widget _buildImagePreview(CanvasElement e) {
    Widget imageWidget;
    if (e.imageUrl.startsWith('data:image')) {
      try {
        final commaIdx = e.imageUrl.indexOf(',');
        final b64 = e.imageUrl.substring(commaIdx + 1);
        final bytes = base64Decode(b64);
        imageWidget =
            Image.memory(Uint8List.fromList(bytes), fit: BoxFit.cover);
      } catch (_) {
        imageWidget = _placeholder();
      }
    } else if (e.imageUrl.startsWith('http')) {
      imageWidget = AppNetworkImage(
        url: e.imageUrl,
        meta: ImageMeta.fromInlineUrl(e.imageUrl),
        fit: BoxFit.cover,
        errorWidget: _placeholder(),
      );
    } else {
      imageWidget = _placeholder();
    }

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: e.hasBorder
            ? Border.all(color: Color(e.borderColorValue), width: 2)
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(e.hasBorder ? 4 : 6),
        child: imageWidget,
      ),
    );
  }

  Widget _buildTextPreview(CanvasElement e, double canvasWidth) {
    final scale = canvasWidth / _kRefWidth;
    final scaledFontSize = e.fontSize * scale;

    TextStyle style;
    try {
      style = GoogleFonts.getFont(
        e.fontFamily,
        fontSize: scaledFontSize,
        color: Color(e.textColorValue),
        fontWeight: e.isBold ? FontWeight.bold : FontWeight.normal,
        fontStyle: e.isItalic ? FontStyle.italic : FontStyle.normal,
      );
    } catch (_) {
      style = TextStyle(
        fontFamily: e.fontFamily,
        fontSize: scaledFontSize,
        color: Color(e.textColorValue),
        fontWeight: e.isBold ? FontWeight.bold : FontWeight.normal,
        fontStyle: e.isItalic ? FontStyle.italic : FontStyle.normal,
      );
    }

    final align = {
      'left': TextAlign.left,
      'center': TextAlign.center,
      'right': TextAlign.right,
    }[e.textAlign] ??
        TextAlign.left;

    final hasGradient =
        e.gradientStartColor != null && e.gradientEndColor != null;
    final gradientAlign = _gradientAlignment(e.gradientDirection);

    return Container(
      padding: EdgeInsets.all(12 * scale),
      decoration: BoxDecoration(
        color: hasGradient
            ? null
            : (e.bgColorValue == 0x00000000
                ? null
                : Color(e.bgColorValue)),
        gradient: hasGradient
            ? LinearGradient(
                begin: gradientAlign.$1,
                end: gradientAlign.$2,
                colors: [
                  Color(e.gradientStartColor!),
                  Color(e.gradientEndColor!),
                ],
              )
            : null,
        borderRadius: BorderRadius.circular(8 * scale),
        border: e.hasBorder
            ? Border.all(color: Color(e.borderColorValue), width: 1.5)
            : null,
      ),
      alignment: Alignment.topLeft,
      child: Text(
        e.text,
        style: style,
        textAlign: align,
        overflow: TextOverflow.fade,
      ),
    );
  }

  static (Alignment, Alignment) _gradientAlignment(String direction) {
    switch (direction) {
      case 'top':
        return (Alignment.topCenter, Alignment.bottomCenter);
      case 'left':
        return (Alignment.centerLeft, Alignment.centerRight);
      case 'topRight':
        return (Alignment.topRight, Alignment.bottomLeft);
      case 'topLeft':
      default:
        return (Alignment.topLeft, Alignment.bottomRight);
    }
  }

  Widget _placeholder() {
    return Container(
      color: isDark
          ? Colors.white.withValues(alpha: 0.04)
          : Colors.black.withValues(alpha: 0.03),
      child: Center(
        child: Icon(
          CupertinoIcons.photo,
          color: isDark ? Colors.white24 : Colors.black26,
          size: 28,
        ),
      ),
    );
  }
}

// ============================================================================
// Square -/+ pill button for the reader settings font-size row
// ============================================================================
class _SizeButton extends StatelessWidget {
  final IconData icon;
  final Color bg;
  final Color border;
  final Color color;
  final VoidCallback onTap;
  const _SizeButton({
    required this.icon,
    required this.bg,
    required this.border,
    required this.color,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: border),
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 18, color: color),
      ),
    );
  }
}

// ============================================================================
// Reader text highlight model (session-only, per-section)
// ============================================================================
class _Highlight {
  final String id;
  final int start;
  final int length;
  final String colorHex; // '' -> removed
  final String note; // empty when none
  const _Highlight({
    required this.id,
    required this.start,
    required this.length,
    required this.colorHex,
    this.note = '',
  });

  _Highlight copyWith({String? note, String? colorHex}) => _Highlight(
        id: id,
        start: start,
        length: length,
        colorHex: colorHex ?? this.colorHex,
        note: note ?? this.note,
      );
}

// ============================================================================
// Result envelope from the note sheet
// ============================================================================
class _NoteSheetResult {
  final String? note;
  final String? canonicalHex; // null means "leave color unchanged"
  final bool delete;
  const _NoteSheetResult({this.note, this.canonicalHex, this.delete = false});
}

// ============================================================================
// Animated note sheet — opened from the highlight selection toolbar.
// Slide + fade + subtle scale composes into a flawless entrance.
// ============================================================================
class _NoteSheet extends StatefulWidget {
  final String excerpt;
  final Color bg;
  final Color textColor;
  final Color subtleColor;
  final String initial;
  // Display+canonical pairs the user can pick from. Display matches the
  // current reader theme (paint color); canonical is what gets saved.
  final List<({Color display, String canonical})> swatches;
  // Canonical hex of the currently-applied highlight, used to mark the
  // initially-selected swatch.
  final String initialCanonicalHex;

  const _NoteSheet({
    required this.excerpt,
    required this.bg,
    required this.textColor,
    required this.subtleColor,
    required this.initial,
    required this.swatches,
    required this.initialCanonicalHex,
  });

  @override
  State<_NoteSheet> createState() => _NoteSheetState();
}

class _NoteSheetState extends State<_NoteSheet> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  late String _selectedCanonical;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
    _focusNode = FocusNode();
    _selectedCanonical = widget.initialCanonicalHex.isNotEmpty
        ? widget.initialCanonicalHex
        : (widget.swatches.isNotEmpty
            ? widget.swatches.first.canonical
            : '#FFE066');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Color get _accentColor {
    for (final s in widget.swatches) {
      if (s.canonical.toUpperCase() == _selectedCanonical.toUpperCase()) {
        return s.display;
      }
    }
    return widget.swatches.isNotEmpty
        ? widget.swatches.first.display
        : const Color(0xFFFFE066);
  }

  @override
  Widget build(BuildContext context) {
    final isDark =
        ThemeData.estimateBrightnessForColor(widget.bg) == Brightness.dark;
    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    final fillColor = isDark
        ? Colors.white.withValues(alpha: 0.04)
        : Colors.black.withValues(alpha: 0.03);
    final outlineColor = widget.textColor.withValues(alpha: 0.08);
    final accent = _accentColor;

    return Material(
      type: MaterialType.transparency,
      child: SafeArea(
        child: AnimatedPadding(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          padding: EdgeInsets.fromLTRB(16, 16, 16, keyboardHeight + 16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Material(
                color: widget.bg,
                elevation: 4,
                shadowColor: Colors.black.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 12, 14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOut,
                            width: 4,
                            height: 22,
                            decoration: BoxDecoration(
                              color: accent,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              widget.initial.isEmpty ? 'Add note' : 'Edit note',
                              style: GoogleFonts.lora(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                color: widget.textColor,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.of(context).pop(),
                            icon: Icon(
                              CupertinoIcons.xmark,
                              size: 18,
                              color: widget.subtleColor,
                            ),
                            visualDensity: VisualDensity.compact,
                            splashRadius: 18,
                          ),
                        ],
                      ),
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOut,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: accent.withValues(alpha: 0.35),
                            ),
                          ),
                          child: Text(
                            widget.excerpt,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.lora(
                              fontSize: 14,
                              color: widget.textColor,
                              height: 1.4,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      // Swatch picker — taps update the live accent and the
                      // canonical hex returned on save.
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.start,
                          children: [
                            for (final s in widget.swatches) ...[
                              _NoteSheetSwatch(
                                color: s.display,
                                selected: s.canonical.toUpperCase() ==
                                    _selectedCanonical.toUpperCase(),
                                ringColor: widget.textColor
                                    .withValues(alpha: 0.4),
                                onTap: () => setState(
                                    () => _selectedCanonical = s.canonical),
                              ),
                              const SizedBox(width: 8),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                              minHeight: 110, maxHeight: 240),
                          child: TextField(
                            controller: _controller,
                            focusNode: _focusNode,
                            maxLines: null,
                            minLines: 4,
                            textAlignVertical: TextAlignVertical.top,
                            cursorColor: accent,
                            style: GoogleFonts.lora(
                              fontSize: 15,
                              color: widget.textColor,
                              height: 1.5,
                            ),
                            decoration: InputDecoration(
                              hintText: 'Write your note…',
                              hintStyle: GoogleFonts.lora(
                                fontSize: 15,
                                color: widget.subtleColor,
                              ),
                              filled: true,
                              fillColor: fillColor,
                              contentPadding: const EdgeInsets.fromLTRB(
                                  14, 12, 14, 12),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(color: outlineColor),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(color: outlineColor),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide:
                                    BorderSide(color: accent, width: 1.5),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Row(
                          children: [
                            if (widget.initial.isNotEmpty)
                              TextButton.icon(
                                onPressed: () {
                                  Navigator.of(context).pop(
                                    const _NoteSheetResult(delete: true),
                                  );
                                },
                                icon: Icon(
                                  CupertinoIcons.trash,
                                  size: 16,
                                  color: Colors.redAccent.shade200,
                                ),
                                label: Text(
                                  'Remove',
                                  style: GoogleFonts.inter(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.redAccent.shade200,
                                  ),
                                ),
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 8),
                                ),
                              ),
                            const Spacer(),
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: Text(
                                'Cancel',
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: widget.subtleColor,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            FilledButton(
                              onPressed: () {
                                Navigator.of(context).pop(
                                  _NoteSheetResult(
                                    note: _controller.text.trim(),
                                    canonicalHex: _selectedCanonical,
                                  ),
                                );
                              },
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF2F62E0),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 18, vertical: 10),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              child: Text(
                                'Save',
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// A single swatch chip in the note sheet — animates a ring when selected.
class _NoteSheetSwatch extends StatelessWidget {
  final Color color;
  final bool selected;
  final Color ringColor;
  final VoidCallback onTap;

  const _NoteSheetSwatch({
    required this.color,
    required this.selected,
    required this.ringColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? ringColor : ringColor.withValues(alpha: 0.25),
            width: selected ? 2 : 1,
          ),
        ),
        padding: EdgeInsets.all(selected ? 3 : 2),
        child: Container(
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: ringColor.withValues(alpha: 0.15)),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// Floating selection toolbar for the reader. Mirrors the writer's pattern:
// listens to the active QuillController and surfaces highlight + note +
// bookmark actions when the user has a non-collapsed selection. Lives at
// top-center of the reader pane and slides in/out smoothly.
// ============================================================================
class _ReaderSelectionBar extends StatefulWidget {
  final quill.QuillController? controller;
  final int sectionIndex;
  final ({Color bg, Color text, Color subtle}) palette;
  final Color paperAccent;
  // Pairs of (display color, canonical hex). The display color is theme-aware
  // and used to paint the swatch circle; the canonical hex is what the parent
  // saves so highlight identity stays stable across theme switches.
  final List<({Color display, String canonical})> swatches;
  final void Function(int sectionIndex, String? hex) onApplyHighlight;
  final void Function(int sectionIndex) onOpenNote;
  final void Function(int sectionIndex) onOpenBookmark;
  final _Highlight? Function(int sectionIndex, int start, int length)
      findOverlap;

  const _ReaderSelectionBar({
    super.key,
    required this.controller,
    required this.sectionIndex,
    required this.palette,
    required this.paperAccent,
    required this.swatches,
    required this.onApplyHighlight,
    required this.onOpenNote,
    required this.onOpenBookmark,
    required this.findOverlap,
  });

  @override
  State<_ReaderSelectionBar> createState() => _ReaderSelectionBarState();
}

class _ReaderSelectionBarState extends State<_ReaderSelectionBar> {
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    widget.controller?.addListener(_onControllerChange);
  }

  @override
  void didUpdateWidget(covariant _ReaderSelectionBar old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller?.removeListener(_onControllerChange);
      widget.controller?.addListener(_onControllerChange);
      _onControllerChange();
    }
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_onControllerChange);
    super.dispose();
  }

  void _onControllerChange() {
    final sel = widget.controller?.selection;
    final next = sel != null && sel.isValid && !sel.isCollapsed;
    if (next != _visible && mounted) {
      setState(() => _visible = next);
    } else if (next && mounted) {
      // selection range changed but bar already visible — refresh hasNote dot
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final palette = widget.palette;

    _Highlight? overlap;
    if (controller != null) {
      final sel = controller.selection;
      if (sel.isValid && !sel.isCollapsed) {
        overlap = widget.findOverlap(
            widget.sectionIndex, sel.start, sel.end - sel.start);
      }
    }
    final hasNote = overlap != null && overlap.note.isNotEmpty;

    return IgnorePointer(
      ignoring: !_visible,
      child: AnimatedSlide(
        offset: _visible ? Offset.zero : const Offset(0, -0.6),
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          opacity: _visible ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          child: Material(
            elevation: 3,
            borderRadius: BorderRadius.circular(28),
            color: palette.bg,
            shadowColor: Colors.black.withValues(alpha: 0.18),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                  color: palette.text.withValues(alpha: 0.1),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final s in widget.swatches)
                    GestureDetector(
                      onTap: () => widget
                          .onApplyHighlight(widget.sectionIndex, s.canonical),
                      child: Container(
                        width: 26,
                        height: 26,
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        decoration: BoxDecoration(
                          color: s.display,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: palette.text.withValues(alpha: 0.15),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(width: 4),
                  GestureDetector(
                    onTap: () =>
                        widget.onApplyHighlight(widget.sectionIndex, null),
                    child: Container(
                      width: 26,
                      height: 26,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: palette.text.withValues(alpha: 0.4),
                        ),
                      ),
                      child: Icon(
                        CupertinoIcons.clear,
                        size: 14,
                        color: palette.text.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: () => widget.onOpenNote(widget.sectionIndex),
                    child: Container(
                      width: 26,
                      height: 26,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: palette.text.withValues(alpha: 0.06),
                        border: Border.all(
                          color: palette.text.withValues(alpha: 0.4),
                        ),
                      ),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Icon(
                            CupertinoIcons.pencil,
                            size: 14,
                            color: palette.text.withValues(alpha: 0.75),
                          ),
                          if (hasNote)
                            Positioned(
                              right: 1,
                              top: 1,
                              child: Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  color: widget.paperAccent,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: palette.bg,
                                    width: 1.2,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: () => widget.onOpenBookmark(widget.sectionIndex),
                    child: Container(
                      width: 26,
                      height: 26,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: palette.text.withValues(alpha: 0.06),
                        border: Border.all(
                          color: palette.text.withValues(alpha: 0.4),
                        ),
                      ),
                      child: Icon(
                        CupertinoIcons.bookmark,
                        size: 14,
                        color: palette.text.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// Side-gutter chevron used to advance/retreat chapters on wide screens.
// Hidden until the reader area is hovered so the page stays calm at rest.
// The hover state is owned by the parent (the whole reader pane).
// ============================================================================
class _ReaderSideChevron extends StatefulWidget {
  final Alignment alignment;
  final IconData icon;
  final Color textColor;
  final Color subtleColor;
  final bool isDark;
  final bool visible;
  final VoidCallback onTap;

  const _ReaderSideChevron({
    required this.alignment,
    required this.icon,
    required this.textColor,
    required this.subtleColor,
    required this.isDark,
    required this.visible,
    required this.onTap,
  });

  @override
  State<_ReaderSideChevron> createState() => _ReaderSideChevronState();
}

class _ReaderSideChevronState extends State<_ReaderSideChevron> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.isDark
        ? Colors.white.withValues(alpha: _hover ? 0.12 : 0.05)
        : Colors.black.withValues(alpha: _hover ? 0.10 : 0.04);
    return Align(
      alignment: widget.alignment,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: widget.visible ? 1.0 : 0.0,
          child: IgnorePointer(
            ignoring: !widget.visible,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) => setState(() => _hover = true),
              onExit: (_) => setState(() => _hover = false),
              child: GestureDetector(
                onTap: widget.onTap,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: bg,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    widget.icon,
                    size: 22,
                    color: _hover ? widget.textColor : widget.subtleColor,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// Persistent chapter rail shown on >=1280px viewports. Surfaces the
// table-of-contents that's otherwise hidden behind the end-drawer so the
// reader can jump chapters without leaving the page.
// ============================================================================
class _ReaderChapterRail extends StatefulWidget {
  final List<FeedItemSection> sections;
  final int currentIndex;
  final bool isDark;
  final Color textColor;
  final Color subtleColor;
  final Color accent;
  final Color dividerColor;
  final ValueChanged<int> onTap;

  const _ReaderChapterRail({
    required this.sections,
    required this.currentIndex,
    required this.isDark,
    required this.textColor,
    required this.subtleColor,
    required this.accent,
    required this.dividerColor,
    required this.onTap,
  });

  @override
  State<_ReaderChapterRail> createState() => _ReaderChapterRailState();
}

class _ReaderChapterRailState extends State<_ReaderChapterRail> {
  final ScrollController _scroll = ScrollController();

  @override
  void didUpdateWidget(covariant _ReaderChapterRail old) {
    super.didUpdateWidget(old);
    if (old.currentIndex != widget.currentIndex) {
      _scrollToActive();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToActive());
  }

  void _scrollToActive() {
    if (!_scroll.hasClients) return;
    const rowHeight = 52.0;
    final target = (widget.currentIndex * rowHeight) - 120;
    _scroll.animateTo(
      target.clamp(0.0, _scroll.position.maxScrollExtent),
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 268,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
            child: Text(
              'Chapters',
              style: GoogleFonts.playfairDisplay(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: widget.textColor,
                letterSpacing: -0.2,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              '${widget.sections.length} sections',
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: widget.subtleColor,
              ),
            ),
          ),
          Container(height: 1, color: widget.dividerColor),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.symmetric(vertical: 6),
              itemCount: widget.sections.length,
              itemBuilder: (_, i) {
                final isActive = i == widget.currentIndex;
                return _ReaderChapterRailRow(
                  index: i,
                  title: widget.sections[i].title,
                  isActive: isActive,
                  isDark: widget.isDark,
                  textColor: widget.textColor,
                  subtleColor: widget.subtleColor,
                  accent: widget.accent,
                  onTap: () => widget.onTap(i),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ReaderChapterRailRow extends StatefulWidget {
  final int index;
  final String title;
  final bool isActive;
  final bool isDark;
  final Color textColor;
  final Color subtleColor;
  final Color accent;
  final VoidCallback onTap;

  const _ReaderChapterRailRow({
    required this.index,
    required this.title,
    required this.isActive,
    required this.isDark,
    required this.textColor,
    required this.subtleColor,
    required this.accent,
    required this.onTap,
  });

  @override
  State<_ReaderChapterRailRow> createState() => _ReaderChapterRailRowState();
}

class _ReaderChapterRailRowState extends State<_ReaderChapterRailRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.isActive
        ? widget.accent.withValues(alpha: 0.10)
        : (_hover
            ? (widget.isDark
                ? Colors.white.withValues(alpha: 0.04)
                : Colors.black.withValues(alpha: 0.03))
            : Colors.transparent);
    final color = widget.isActive
        ? widget.accent
        : (_hover ? widget.textColor : widget.subtleColor);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 22,
                child: Text(
                  '${widget.index + 1}',
                  style: GoogleFonts.lora(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: color.withValues(alpha: widget.isActive ? 1.0 : 0.7),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.title.isEmpty
                      ? 'Section ${widget.index + 1}'
                      : widget.title,
                  style: GoogleFonts.lora(
                    fontSize: 13.5,
                    fontWeight:
                        widget.isActive ? FontWeight.w600 : FontWeight.w500,
                    color: color,
                    height: 1.35,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// Soft floating Listen action shown on >=1280px viewports. Replaces the
// bottom-bar Listen pill so the bar can stay quiet on long, wide screens.
// ============================================================================
class _ReaderListenFab extends StatefulWidget {
  final Color accent;
  final VoidCallback onTap;

  const _ReaderListenFab({required this.accent, required this.onTap});

  @override
  State<_ReaderListenFab> createState() => _ReaderListenFabState();
}

class _ReaderListenFabState extends State<_ReaderListenFab> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.symmetric(
            horizontal: _hover ? 22 : 18,
            vertical: 14,
          ),
          decoration: BoxDecoration(
            color: widget.accent,
            borderRadius: BorderRadius.circular(40),
            boxShadow: [
              BoxShadow(
                color: widget.accent
                    .withValues(alpha: _hover ? 0.45 : 0.30),
                blurRadius: _hover ? 28 : 18,
                offset: const Offset(0, 8),
                spreadRadius: -2,
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                CupertinoIcons.play_circle_fill,
                color: Colors.white,
                size: 22,
              ),
              const SizedBox(width: 8),
              Text(
                'Listen',
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Pull-down-to-exit gesture ───
//
// Wraps the section reader so that when the user is scrolled to the very
// top and continues pulling down, the whole page follows the finger
// (translate + scale + fade). Releasing past a threshold dismisses back
// to the section overview; releasing below it springs back. Works in both
// immersive (no chrome) and chrome-on modes, giving readers a discoverable
// exit that matches the iOS Photos/Messages pattern.
//
// Implementation rides on the existing BouncingScrollPhysics on each
// section's SingleChildScrollView: pulling past the top makes
// metrics.pixels go negative, which we read as the drag amount. We only
// react while dragDetails != null so momentum bounces don't trigger
// dismissal on their own.
class _PullDownToExit extends StatefulWidget {
  const _PullDownToExit({
    required this.child,
    required this.onExit,
    this.enabled = true,
  });

  final Widget child;
  final VoidCallback onExit;
  final bool enabled;

  @override
  State<_PullDownToExit> createState() => _PullDownToExitState();
}

class _PullDownToExitState extends State<_PullDownToExit>
    with SingleTickerProviderStateMixin {
  static const double _threshold = 110;
  static const double _maxDrag = 320;

  double _drag = 0;
  bool _dragging = false;
  late final AnimationController _spring;
  Animation<double>? _springTween;

  @override
  void initState() {
    super.initState();
    _spring = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    )..addListener(() {
        if (_springTween != null && mounted) {
          setState(() => _drag = _springTween!.value);
        }
      });
  }

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }

  bool _onNotif(ScrollNotification n) {
    if (!widget.enabled) return false;
    if (n.metrics.axis != Axis.vertical) return false;

    if (n is ScrollUpdateNotification && n.dragDetails != null) {
      // Negative pixels = pulled past top with bouncing physics.
      final overscroll = n.metrics.minScrollExtent - n.metrics.pixels;
      if (_spring.isAnimating) _spring.stop();
      if (overscroll > 0) {
        setState(() {
          _dragging = true;
          _drag = overscroll.clamp(0.0, _maxDrag);
        });
      } else if (_drag != 0) {
        // User dragged back into normal scroll range — drop the offset
        // immediately so the page snaps back to rest without lag.
        setState(() => _drag = 0);
      }
    } else if (n is ScrollEndNotification && _dragging) {
      _dragging = false;
      if (_drag >= _threshold) {
        _drag = 0;
        widget.onExit();
      } else if (_drag > 0) {
        _springTween = Tween<double>(begin: _drag, end: 0).animate(
          CurvedAnimation(parent: _spring, curve: Curves.easeOutCubic),
        );
        _spring.forward(from: 0);
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final progress = (_drag / 200).clamp(0.0, 1.0);
    final translateY = _drag * 0.6;
    final scale = 1 - progress * 0.05;
    final opacity = (1 - progress * 0.4).clamp(0.0, 1.0);

    return NotificationListener<ScrollNotification>(
      onNotification: _onNotif,
      child: Transform.translate(
        offset: Offset(0, translateY),
        child: Transform.scale(
          scale: scale,
          alignment: Alignment.topCenter,
          child: Opacity(
            opacity: opacity,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
