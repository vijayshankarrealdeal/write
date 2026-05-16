import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:inkspacex/models/comment_model.dart';
import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/models/reading_progress_model.dart';
import 'package:inkspacex/models/user_preferences_model.dart';
import 'package:inkspacex/services/analytics_service.dart';
import 'package:inkspacex/services/api/api_data_service.dart';
import 'package:inkspacex/services/storage_service.dart';

class FeedProvider extends ChangeNotifier {
  ApiDataService? _dataService;
  StorageService? _storage;

  void setDataService(ApiDataService service) {
    _dataService = service;
  }

  void setStorage(StorageService storage) {
    _storage = storage;
  }

  List<FeedItemModel> _items = [];
  bool _isLoading = true;
  bool _isRefreshing = false;
  bool _hydratedFromCache = false;
  String? _error;
  UserPreferences? _lastPreferences;
  String? _currentUserId;

  String? _nextCursor;
  bool _hasMore = true;
  bool _isLoadingMore = false;

  // Items the silent-refresh probe found ahead of `_items` but hasn't
  // surfaced yet. Twitter/Instagram pattern: don't shove new posts into
  // the user's reading position — buffer them and let the user opt in
  // via a "X new posts" pill so the scroll position is never disturbed.
  List<FeedItemModel> _pendingNewItems = const [];

  List<ReadingProgressModel> _readingProgress = [];

  // ── Persistent filter chip row state ─────────────────────────────
  // When any of these sets are non-empty, the feed surface collapses
  // its multi-shelf layout into a single filtered list. Filters are
  // OR within a column (overlap on `genres`, `tags`, `writing_types`)
  // and AND across columns — same semantics the backend applies at
  // `/api/feed/?genres=…&tags=…&writing_types=…`.
  final Set<String> _filterGenres = <String>{};
  final Set<String> _filterTags = <String>{};
  final Set<String> _filterTypes = <String>{};

  // Cache `/api/feed/facets` so the chip strip doesn't refetch on
  // every rebuild. Loaded lazily on first chip-row render.
  FeedFacets? _facets;
  Future<FeedFacets>? _facetsInflight;

  List<FeedItemModel> _filteredItems = const [];
  String? _filteredCursor;
  bool _hasMoreFiltered = true;
  bool _isLoadingFiltered = false;
  bool _isLoadingMoreFiltered = false;
  String? _filteredError;

  // ── Composed home feed (rails) ───────────────────────────────────
  // Single-call home shape from `GET /api/feed/home`: 8 deduped rails
  // (Featured, Continue Reading, New Releases, For You, Trending Now,
  // Top 10 This Week, Hidden Gems, Editor's Picks). Replaces the
  // multi-call shelf assembly the home tab used to do client-side.
  // The flat `_items` list still backs filter / search drill-downs.
  List<HomeRail> _rails = const [];
  bool _isLoadingRails = false;

  // ── Recommendation engine state ───────────────────────────────────
  // Items returned by /api/ai/recommendations. Each carries a
  // [RecommendationMeta] with the engine score, optional LLM-generated
  // "why" reason, and the session id for impression / click events.
  List<FeedItemModel> _recommended = const [];
  String? _recommendationSessionId;
  bool _isLoadingRecommendations = false;
  // Tracks which (sessionId, feedItemId) pairs already had an
  // impression logged, so a card scrolling in and out of view doesn't
  // double-count.
  final Set<String> _loggedImpressions = <String>{};
  // Pending impression events waiting to be flushed in a single batch.
  final List<RecommendationEventPayload> _pendingImpressionEvents = [];
  Timer? _impressionFlushTimer;

  List<FeedItemModel> get items => _items;
  bool get isLoading => _isLoading;
  bool get isRefreshing => _isRefreshing;
  bool get hydratedFromCache => _hydratedFromCache;
  String? get error => _error;
  int get pendingNewItemsCount => _pendingNewItems.length;
  bool get hasMore => _hasMore;
  bool get isLoadingMore => _isLoadingMore;
  List<ReadingProgressModel> get readingProgress => _readingProgress;
  List<FeedItemModel> get recommendedItems => _recommended;
  bool get isLoadingRecommendations => _isLoadingRecommendations;
  String? get recommendationSessionId => _recommendationSessionId;

  List<HomeRail> get rails => _rails;
  bool get isLoadingRails => _isLoadingRails;

  Set<String> get filterGenres => Set.unmodifiable(_filterGenres);
  Set<String> get filterTags => Set.unmodifiable(_filterTags);
  Set<String> get filterWritingTypes => Set.unmodifiable(_filterTypes);
  bool get hasActiveFilters =>
      _filterGenres.isNotEmpty ||
      _filterTags.isNotEmpty ||
      _filterTypes.isNotEmpty;
  List<FeedItemModel> get filteredItems => _filteredItems;
  bool get isLoadingFiltered => _isLoadingFiltered;
  bool get isLoadingMoreFiltered => _isLoadingMoreFiltered;
  bool get hasMoreFiltered => _hasMoreFiltered;
  String? get filteredError => _filteredError;
  FeedFacets? get cachedFacets => _facets;

  /// Feed items deduped by id and then collapsed by work.
  /// Merges sections from duplicate entries into one combined item.
  List<FeedItemModel> get groupedItems => _groupByWork(_items);

  /// Defensive dedup-by-id used anywhere a UI surface hands us a list of
  /// items it doesn't own (e.g. backend rails). One pass, O(N), preserves
  /// first-seen order.
  static List<FeedItemModel> dedupById(List<FeedItemModel> items) {
    if (items.length < 2) return items;
    final seen = <String>{};
    final out = <FeedItemModel>[];
    for (final item in items) {
      if (seen.add(item.id)) out.add(item);
    }
    return out;
  }

  /// Two-pass collapse:
  ///   1. Strip duplicate ``feed_item_id`` rows — same row, no ambiguity,
  ///      the one immutable identity. This is what caught us when a
  ///      cover regen forked the imageUrl: the SAME book was rendering
  ///      twice because the previous group key was content-based.
  ///   2. Merge sibling listings of the same work (e.g. two accounts
  ///      republishing the same public-domain title) keyed by
  ///      ``authorId|lowercased-title``. ``imageUrl`` deliberately stays
  ///      OUT of the key — it's mutable content, not identity, and using
  ///      it caused exactly the duplicate-on-cover-change bug.
  static List<FeedItemModel> _groupByWork(List<FeedItemModel> items) {
    if (items.isEmpty) return items;

    // Pass 1 — identity dedup.
    final unique = dedupById(items);

    // Pass 2 — work-level merge.
    final Map<String, FeedItemModel> byWork = {};
    final List<String> order = [];

    for (final item in unique) {
      final normalisedTitle = item.title.trim().toLowerCase();
      final key = (item.authorId.isNotEmpty && normalisedTitle.isNotEmpty)
          ? '${item.authorId}|$normalisedTitle'
          : item.id;

      if (byWork.containsKey(key)) {
        final existing = byWork[key]!;
        final existingIds = existing.sections.map((s) => s.id).toSet();
        final newSections = item.sections
            .where((s) => !existingIds.contains(s.id))
            .toList();
        byWork[key] = existing.copyWith(
          sections: [...existing.sections, ...newSections],
        );
      } else {
        byWork[key] = item;
        order.add(key);
      }
    }
    return order.map((k) => byWork[k]!).toList();
  }

  /// Load feed only when empty.
  ///
  /// Cache-first: if disk has a previous render for this user, hydrate
  /// `_items` from it synchronously and return without a network round-trip.
  /// Callers can follow up with [silentRefresh] to merge any new items the
  /// server has produced since. Mirrors the cold-start pattern Instagram and
  /// Twitter use — paint the last-known feed instantly, reconcile in
  /// background.
  Future<void> loadFeedIfNeeded(
    UserPreferences preferences, {
    String? userId,
  }) async {
    _currentUserId = userId;
    if (_items.isNotEmpty) return;
    _nextCursor = null;
    _hasMore = true;
    if (_hydrateFromCache(preferences)) {
      // Paint the cache instantly, then reconcile counts / cover / tags
      // with the server in the background. Without this the cold-start
      // path would freeze last session's like and comment counts on
      // screen until the user pulled to refresh.
      unawaited(silentRefresh());
      return;
    }
    await loadFeed(preferences, userId: userId);
  }

  /// Read the last persisted feed for the current user. Returns true when
  /// items were loaded, in which case `_isLoading` flips off so the UI can
  /// paint without a spinner.
  bool _hydrateFromCache(UserPreferences preferences) {
    if (_hydratedFromCache) return _items.isNotEmpty;
    final storage = _storage;
    if (storage == null) return false;
    final raw = storage.getCachedFeedItems();
    if (raw.isEmpty) return false;
    try {
      _items = raw.map(FeedItemModel.fromJson).toList();
    } catch (_) {
      _items = const [];
      return false;
    }
    _hydratedFromCache = true;
    _lastPreferences = preferences;
    _isLoading = false;
    _hasMore = true;
    notifyListeners();
    return true;
  }

  void _persistCache() {
    final storage = _storage;
    if (storage == null) return;
    // Fire-and-forget; cache writes shouldn't block UI updates.
    storage.saveCachedFeedItems(_items.map((e) => e.toJson()).toList());
  }

  /// Load the feed using the recommendation engine.
  Future<void> loadFeed(
    UserPreferences preferences, {
    bool forceRefresh = false,
    String? userId,
  }) async {
    if (_dataService == null) return;
    if (!forceRefresh && _items.isNotEmpty) return;
    _currentUserId = userId ?? _currentUserId;

    _nextCursor = null;
    _hasMore = true;
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      final result = await _dataService!.getPersonalizedFeed(
        preferences,
        currentUserId: _currentUserId,
      );
      _items = result.items;
      _nextCursor = result.nextCursor;
      _hasMore = result.items.isNotEmpty;
      _lastPreferences = preferences;
      _hydratedFromCache = true;
      _persistCache();
    } catch (e) {
      _error = e.toString();
      if (forceRefresh) _items = [];
    }
    _isLoading = false;
    if (_currentUserId != null) {
      await loadReadingProgress(_currentUserId!);
    }
    notifyListeners();
  }

  /// Single-call composed home — fills the eight rails the home page
  /// renders. Idempotent: safe to call on every home-tab focus; the
  /// in-flight guard keeps repeated taps from doubling up requests.
  /// Failure clears the rail set so the UI falls back to the flat
  /// `items` listing — better empty-state than a half-loaded home.
  Future<void> loadHomeRails({bool forceRefresh = false}) async {
    if (_dataService == null) return;
    if (_isLoadingRails) return;
    if (!forceRefresh && _rails.isNotEmpty) return;
    _isLoadingRails = true;
    notifyListeners();
    try {
      _rails = await _dataService!.getHomeFeed();
    } catch (_) {
      _rails = const [];
    }
    _isLoadingRails = false;
    notifyListeners();
  }

  Future<void> loadReadingProgress(String userId) async {
    if (_dataService == null) return;
    try {
      _readingProgress = await _dataService!.getAllReadingProgress(userId);
    } catch (_) {
      _readingProgress = [];
    }
    notifyListeners();
  }

  List<FeedItemModel> getContinueReadingItems() {
    if (_readingProgress.isEmpty || _items.isEmpty) return [];
    final progressIds =
        _readingProgress.where((p) => !p.completed).map((p) => p.feedItemId).toSet();
    final matching =
        _items.where((item) => progressIds.contains(item.id)).toList();
    return _groupByWork(matching);
  }

  /// Silent background refresh: reconcile the cached feed with the
  /// server. Two jobs in one round-trip:
  ///
  ///  1. Items already on screen get their mutable fields updated in
  ///     place — like / comment counts, cover, title, tags. Order is
  ///     preserved so the user's scroll position never moves. Without
  ///     this, the cache on cold start would paint last week's
  ///     like-count forever until the user pulled to refresh.
  ///  2. Items the server returned that the client doesn't have yet
  ///     get buffered into `_pendingNewItems` and surfaced via the
  ///     "X new posts" pill — Twitter/Instagram pattern, no
  ///     auto-prepend onto the user's reading position.
  ///
  /// Cache is rewritten if any in-place update changed a field; the
  /// buffered-new-items slice still waits for [applyPendingNewItems].
  Future<void> silentRefresh() async {
    if (_dataService == null) return;
    if (_items.isEmpty || _lastPreferences == null) return;
    if (_isRefreshing) return;
    _isRefreshing = true;
    notifyListeners();
    try {
      final result = await _dataService!.getPersonalizedFeed(
        _lastPreferences!,
        currentUserId: _currentUserId,
      );
      final freshById = {for (final item in result.items) item.id: item};
      final mergedItems = <FeedItemModel>[];
      bool changed = false;
      for (final cached in _items) {
        final fresh = freshById[cached.id];
        if (fresh == null) {
          mergedItems.add(cached);
          continue;
        }
        // Listings strip `sections`, so don't clobber any chapter list
        // the detail page already loaded into the cached copy. Adopt
        // every other server-authoritative field so stale counts /
        // covers / tags refresh on the next cold start.
        final merged = cached.copyWith(
          title: fresh.title,
          author: fresh.author,
          description: fresh.description,
          imageUrl: fresh.imageUrl,
          imageMeta: fresh.imageMeta,
          genres: fresh.genres,
          writingTypes: fresh.writingTypes,
          tags: fresh.tags,
          likesCount: fresh.likesCount,
          commentsCount: fresh.commentsCount,
          updatedAt: fresh.updatedAt,
          isDraft: fresh.isDraft,
          sections: cached.sections.isNotEmpty ? cached.sections : fresh.sections,
        );
        if (!changed && _itemDiffers(cached, merged)) {
          changed = true;
        }
        mergedItems.add(merged);
      }
      if (changed) {
        _items = mergedItems;
        _persistCache();
      }

      final existingIds = {
        ..._items.map((e) => e.id),
        ..._pendingNewItems.map((e) => e.id),
      };
      final newItems =
          result.items.where((e) => !existingIds.contains(e.id)).toList();
      if (newItems.isNotEmpty) {
        _pendingNewItems = [...newItems, ..._pendingNewItems];
      }
    } catch (_) {
    } finally {
      _isRefreshing = false;
      notifyListeners();
    }
  }

  /// Cheap field-by-field diff between a cached item and its freshly
  /// merged counterpart. Drives the "did anything actually change?" gate
  /// in [silentRefresh] so we don't rewrite the cache on every cold
  /// start when nothing on the server moved.
  static bool _itemDiffers(FeedItemModel a, FeedItemModel b) {
    return a.title != b.title ||
        a.description != b.description ||
        a.imageUrl != b.imageUrl ||
        a.likesCount != b.likesCount ||
        a.commentsCount != b.commentsCount ||
        a.updatedAt != b.updatedAt ||
        !listEquals(a.tags, b.tags) ||
        !listEquals(a.genres, b.genres) ||
        !listEquals(a.writingTypes, b.writingTypes);
  }

  /// Flush buffered new items into the visible feed and clear the pill.
  /// Returns the number of items applied so the caller can scroll to top.
  int applyPendingNewItems() {
    if (_pendingNewItems.isEmpty) return 0;
    final count = _pendingNewItems.length;
    _items = [..._pendingNewItems, ..._items];
    _pendingNewItems = const [];
    _persistCache();
    notifyListeners();
    return count;
  }

  /// Clear feed (e.g. on logout).
  void clearFeed() {
    _items = [];
    _pendingNewItems = const [];
    _hydratedFromCache = false;
    _isRefreshing = false;
    _storage?.clearCachedFeed();
    _lastPreferences = null;
    _currentUserId = null;
    _error = null;
    _nextCursor = null;
    _hasMore = true;
    _isLoadingMore = false;
    _readingProgress = [];
    _recommended = const [];
    _recommendationSessionId = null;
    _isLoadingRecommendations = false;
    _loggedImpressions.clear();
    _pendingImpressionEvents.clear();
    _impressionFlushTimer?.cancel();
    _impressionFlushTimer = null;
    _filterGenres.clear();
    _filterTags.clear();
    _filterTypes.clear();
    _facets = null;
    _facetsInflight = null;
    _filteredItems = const [];
    _filteredCursor = null;
    _hasMoreFiltered = true;
    _isLoadingFiltered = false;
    _isLoadingMoreFiltered = false;
    _filteredError = null;
    notifyListeners();
  }

  // ── Recommendations ──

  /// Fetch personalised recommendations from the AI engine. Safe to
  /// call repeatedly; in-flight requests are deduped, and a previous
  /// list stays visible while a new one loads (no flash-of-empty).
  Future<void> loadRecommendations({int limit = 24}) async {
    if (_dataService == null || _isLoadingRecommendations) return;
    _isLoadingRecommendations = true;
    notifyListeners();
    try {
      final result = await _dataService!.getRecommendations(limit: limit);
      _recommended = result.items;
      _recommendationSessionId = result.sessionId;
      // A new render starts a new impression set — old keys can't
      // collide because they were namespaced by the prior session id,
      // but clearing keeps the set bounded.
      _loggedImpressions.clear();
    } catch (_) {
      // Recommendations are an enhancement; if the engine call fails
      // the regular feed still renders. Stay silent.
    } finally {
      _isLoadingRecommendations = false;
      notifyListeners();
    }
  }

  /// Record that a recommendation card has been visible to the user.
  /// Called once per (session, item) — repeats are deduped here so the
  /// callsite can fire it from a viewport-visibility callback without
  /// extra bookkeeping.
  void recordRecommendationImpression(
    FeedItemModel item, {
    required int position,
  }) {
    if (_dataService == null) return;
    final meta = item.recommendation;
    if (meta == null) return;
    final key = '${meta.sessionId}:${item.id}';
    if (!_loggedImpressions.add(key)) return;

    _pendingImpressionEvents.add(
      RecommendationEventPayload(
        feedItemId: item.id,
        eventType: 'impression',
        position: position,
        score: meta.score,
        source: meta.source,
        sessionId: meta.sessionId,
      ),
    );
    _scheduleImpressionFlush();
  }

  /// Flush queued impressions ~1s after the most recent one. Batching
  /// keeps the network busy with at most one POST per scroll burst.
  void _scheduleImpressionFlush() {
    _impressionFlushTimer?.cancel();
    _impressionFlushTimer = Timer(const Duration(seconds: 1), _flushImpressions);
  }

  Future<void> _flushImpressions() async {
    if (_dataService == null) return;
    if (_pendingImpressionEvents.isEmpty) return;
    final batch = List<RecommendationEventPayload>.from(_pendingImpressionEvents);
    _pendingImpressionEvents.clear();
    await _dataService!.logRecommendationEvents(batch);
  }

  /// Record that the user opened a recommended item. Sent immediately
  /// (no batching) since clicks are low-volume and high-signal.
  Future<void> recordRecommendationClick(
    FeedItemModel item, {
    required int position,
  }) async {
    if (_dataService == null) return;
    final meta = item.recommendation;
    if (meta == null) return;
    await _dataService!.logRecommendationEvents([
      RecommendationEventPayload(
        feedItemId: item.id,
        eventType: 'click',
        position: position,
        score: meta.score,
        source: meta.source,
        sessionId: meta.sessionId,
      ),
    ]);
  }

  @override
  void dispose() {
    _impressionFlushTimer?.cancel();
    // Best-effort drain of the last batch so a logout / app-kill
    // doesn't lose the trailing scroll.
    if (_pendingImpressionEvents.isNotEmpty) {
      _dataService?.logRecommendationEvents(
        List<RecommendationEventPayload>.from(_pendingImpressionEvents),
      );
      _pendingImpressionEvents.clear();
    }
    super.dispose();
  }

  /// Load the next page of feed items (cursor-based pagination).
  Future<void> loadMore({String? userId}) async {
    if (_dataService == null) return;
    if (_isLoadingMore || !_hasMore) return;
    _isLoadingMore = true;
    notifyListeners();
    try {
      final result = await _dataService!.getPersonalizedFeed(
        _lastPreferences ?? const UserPreferences(),
        cursor: _nextCursor,
        currentUserId: userId ?? _currentUserId,
      );
      _nextCursor = result.nextCursor;
      _hasMore = result.items.isNotEmpty;
      _items.addAll(result.items);
      if (result.items.isNotEmpty) _persistCache();
    } catch (_) {
      // silently fail on loadMore
    } finally {
      _isLoadingMore = false;
      notifyListeners();
    }
  }

  // ── Comments ──

  Future<List<CommentModel>> getComments(String feedItemId) {
    return _dataService!.getComments(feedItemId);
  }

  Stream<List<CommentModel>> getCommentsStream(String feedItemId) {
    return _dataService!.getCommentsStream(feedItemId);
  }

  Future<void> addComment(CommentModel comment) async {
    await _dataService!.addComment(comment);
    AnalyticsService.instance.track(
      'post_comment_added',
      action: 'submit',
      entityType: 'post',
      entityId: comment.feedItemId,
    );
    final idx = _items.indexWhere((i) => i.id == comment.feedItemId);
    if (idx != -1) {
      _items[idx] = _items[idx].copyWith(
        commentsCount: _items[idx].commentsCount + 1,
      );
      notifyListeners();
    }
  }

  /// Replace the reactions on a single section in the cached feed item
  /// after the user toggles an emoji. Keeps the chapter list / overview
  /// in sync without a refetch — the bar widget already has the
  /// authoritative aggregate from the server response.
  void updateSectionReactions(
    String feedItemId,
    String sectionId,
    List<SectionReactionAggregate> reactions,
  ) {
    final idx = _items.indexWhere((i) => i.id == feedItemId);
    if (idx == -1) return;
    final item = _items[idx];
    final updated = [
      for (final s in item.sections)
        s.id == sectionId ? s.copyWithReactions(reactions) : s,
    ];
    _items[idx] = item.copyWith(sections: updated);
    notifyListeners();
  }

  Future<void> deleteComment(String feedItemId, String commentId) async {
    await _dataService!.deleteComment(feedItemId, commentId);
    AnalyticsService.instance.track(
      'post_comment_deleted',
      action: 'click',
      entityType: 'comment',
      entityId: commentId,
      properties: {'post_id': feedItemId},
    );
    final idx = _items.indexWhere((i) => i.id == feedItemId);
    if (idx != -1) {
      _items[idx] = _items[idx].copyWith(
        commentsCount: (_items[idx].commentsCount - 1).clamp(0, 999999),
      );
      notifyListeners();
    }
  }

  // ── Persistent filter chip row ───────────────────────────────────

  /// Lazy-load and cache the top-N facets used by the persistent chip
  /// strip on the feed. Subsequent calls return the cached value; any
  /// concurrent loads share a single in-flight future so the endpoint
  /// is hit at most once per app session (until `clearFeed()`).
  Future<FeedFacets> ensureFacets() {
    if (_facets != null) return Future.value(_facets!);
    if (_facetsInflight != null) return _facetsInflight!;
    if (_dataService == null) {
      return Future.value(
          const FeedFacets(genres: [], tags: [], writingTypes: []));
    }
    final inflight = _dataService!.getFeedFacets();
    _facetsInflight = inflight;
    return inflight.then((f) {
      _facets = f;
      _facetsInflight = null;
      notifyListeners();
      return f;
    }).catchError((Object _) {
      _facetsInflight = null;
      return const FeedFacets(genres: [], tags: [], writingTypes: []);
    });
  }

  /// Toggle a filter chip. `kind` is one of `'genre' | 'tag' | 'type'`.
  /// Triggers a filtered fetch (debounced via the in-flight guard) when
  /// any filter remains active; clears `_filteredItems` when the last
  /// filter is removed.
  void toggleFilter(String kind, String value) {
    final set = _setFor(kind);
    if (set == null) return;
    if (set.contains(value)) {
      set.remove(value);
    } else {
      set.add(value);
    }
    if (hasActiveFilters) {
      _reloadFiltered();
    } else {
      _filteredItems = const [];
      _filteredCursor = null;
      _hasMoreFiltered = true;
      _filteredError = null;
    }
    notifyListeners();
  }

  void clearFilters() {
    if (!hasActiveFilters) return;
    _filterGenres.clear();
    _filterTags.clear();
    _filterTypes.clear();
    _filteredItems = const [];
    _filteredCursor = null;
    _hasMoreFiltered = true;
    _filteredError = null;
    notifyListeners();
  }

  Set<String>? _setFor(String kind) {
    switch (kind) {
      case 'genre':
        return _filterGenres;
      case 'tag':
        return _filterTags;
      case 'type':
        return _filterTypes;
      default:
        return null;
    }
  }

  Future<void> _reloadFiltered() async {
    if (_dataService == null || !hasActiveFilters) return;
    _isLoadingFiltered = true;
    _filteredError = null;
    _filteredCursor = null;
    _hasMoreFiltered = true;
    notifyListeners();
    try {
      final result = await _dataService!.getPersonalizedFeed(
        _lastPreferences ?? const UserPreferences(),
        currentUserId: _currentUserId,
        genres: _filterGenres,
        tags: _filterTags,
        writingTypes: _filterTypes,
      );
      _filteredItems = result.items;
      _filteredCursor = result.nextCursor;
      _hasMoreFiltered = result.items.isNotEmpty;
    } catch (e) {
      _filteredItems = const [];
      _filteredError = e.toString();
    } finally {
      _isLoadingFiltered = false;
      notifyListeners();
    }
  }

  Future<void> loadMoreFiltered() async {
    if (_dataService == null) return;
    if (!hasActiveFilters) return;
    if (_isLoadingMoreFiltered || !_hasMoreFiltered) return;
    _isLoadingMoreFiltered = true;
    notifyListeners();
    try {
      final result = await _dataService!.getPersonalizedFeed(
        _lastPreferences ?? const UserPreferences(),
        cursor: _filteredCursor,
        currentUserId: _currentUserId,
        genres: _filterGenres,
        tags: _filterTags,
        writingTypes: _filterTypes,
      );
      _filteredCursor = result.nextCursor;
      _hasMoreFiltered = result.items.isNotEmpty;
      _filteredItems = [..._filteredItems, ...result.items];
    } catch (_) {
      // Silent on paging failure — leave the existing list intact so
      // the user can retry by scrolling again.
    } finally {
      _isLoadingMoreFiltered = false;
      notifyListeners();
    }
  }

  /// Update the like count on a feed item after a like/unlike toggle.
  void updateItemLikeCount(String feedItemId, {required bool increment}) {
    for (int idx = 0; idx < _items.length; idx++) {
      if (_items[idx].id == feedItemId) {
        final current = _items[idx].likesCount;
        _items[idx] = _items[idx].copyWith(
          likesCount: increment
              ? current + 1
              : (current - 1).clamp(0, 999999),
        );
      }
    }
    notifyListeners();
  }

  /// Drop a feed item the server has confirmed is gone (404 on fetch),
  /// so the on-screen list, the buffered "new posts" pill, and the
  /// per-user disk cache all stop surfacing a card whose reader will
  /// crash on open. Called from any read path that catches
  /// [FeedItemMissing] — typically the post-detail loader or an SSE
  /// `feed_item.deleted` event.
  void dropMissingItem(String feedItemId) {
    final beforeItems = _items.length;
    final beforePending = _pendingNewItems.length;
    _items = _items.where((i) => i.id != feedItemId).toList();
    _pendingNewItems =
        _pendingNewItems.where((i) => i.id != feedItemId).toList();
    _filteredItems =
        _filteredItems.where((i) => i.id != feedItemId).toList();
    _recommended = _recommended.where((i) => i.id != feedItemId).toList();
    _storage?.removeCachedFeedItem(feedItemId: feedItemId);
    if (_items.length != beforeItems ||
        _pendingNewItems.length != beforePending) {
      _persistCache();
    }
    notifyListeners();
  }

  /// Apply absolute counts received from a backend SSE broadcast so two
  /// clients viewing the same post converge in real time. Either count
  /// may be omitted; only fields that change trigger a notify.
  void applyRemoteCounts(
    String feedItemId, {
    int? likesCount,
    int? commentsCount,
  }) {
    bool changed = false;
    for (int idx = 0; idx < _items.length; idx++) {
      final item = _items[idx];
      if (item.id != feedItemId) continue;
      final nextLikes = likesCount ?? item.likesCount;
      final nextComments = commentsCount ?? item.commentsCount;
      if (nextLikes == item.likesCount && nextComments == item.commentsCount) {
        continue;
      }
      _items[idx] = item.copyWith(
        likesCount: nextLikes,
        commentsCount: nextComments,
      );
      changed = true;
    }
    if (changed) notifyListeners();
  }
}
