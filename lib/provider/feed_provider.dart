import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:inkspacex/models/comment_model.dart';
import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/models/reading_progress_model.dart';
import 'package:inkspacex/models/user_preferences_model.dart';
import 'package:inkspacex/services/api/api_data_service.dart';

class FeedProvider extends ChangeNotifier {
  ApiDataService? _dataService;

  void setDataService(ApiDataService service) {
    _dataService = service;
  }

  List<FeedItemModel> _items = [];
  bool _isLoading = true;
  String? _error;
  UserPreferences? _lastPreferences;
  String? _currentUserId;

  String? _nextCursor;
  bool _hasMore = true;
  bool _isLoadingMore = false;

  List<ReadingProgressModel> _readingProgress = [];

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
  String? get error => _error;
  bool get hasMore => _hasMore;
  bool get isLoadingMore => _isLoadingMore;
  List<ReadingProgressModel> get readingProgress => _readingProgress;
  List<FeedItemModel> get recommendedItems => _recommended;
  bool get isLoadingRecommendations => _isLoadingRecommendations;
  String? get recommendationSessionId => _recommendationSessionId;

  /// Feed items grouped by same author + same cover image.
  /// Merges sections from duplicate entries into one combined item.
  List<FeedItemModel> get groupedItems {
    if (_items.isEmpty) return _items;

    final Map<String, FeedItemModel> byKey = {};
    final List<String> order = [];

    for (final item in _items) {
      // Group by authorId + imageUrl (same author + same cover = same work)
      final key = item.imageUrl.isNotEmpty
          ? '${item.authorId}|${item.imageUrl}'
          : item.id; // never group items without a cover image

      if (byKey.containsKey(key)) {
        final existing = byKey[key]!;
        // Merge sections (deduplicate by section id)
        final existingIds = existing.sections.map((s) => s.id).toSet();
        final newSections = item.sections
            .where((s) => !existingIds.contains(s.id))
            .toList();
        byKey[key] = existing.copyWith(
          sections: [...existing.sections, ...newSections],
        );
      } else {
        byKey[key] = item;
        order.add(key);
      }
    }
    return order.map((k) => byKey[k]!).toList();
  }

  /// Load feed only when empty.
  Future<void> loadFeedIfNeeded(
    UserPreferences preferences, {
    String? userId,
  }) async {
    _currentUserId = userId;
    if (_items.isNotEmpty) return;
    _nextCursor = null;
    _hasMore = true;
    await loadFeed(preferences, userId: userId);
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
    return _items.where((item) => progressIds.contains(item.id)).toList();
  }

  /// Silent background refresh: prepend new items without loading indicator.
  Future<void> silentRefresh() async {
    if (_dataService == null) return;
    if (_items.isEmpty || _lastPreferences == null) return;
    try {
      final result = await _dataService!.getPersonalizedFeed(
        _lastPreferences!,
        currentUserId: _currentUserId,
      );
      final existingIds = _items.map((e) => e.id).toSet();
      final newItems =
          result.items.where((e) => !existingIds.contains(e.id)).toList();
      if (newItems.isEmpty) return;
      _items = [...newItems, ..._items];
      notifyListeners();
    } catch (_) {}
  }

  /// Clear feed (e.g. on logout).
  void clearFeed() {
    _items = [];
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
    final idx = _items.indexWhere((i) => i.id == comment.feedItemId);
    if (idx != -1) {
      _items[idx] = _items[idx].copyWith(
        commentsCount: _items[idx].commentsCount + 1,
      );
      notifyListeners();
    }
  }

  Future<void> deleteComment(String feedItemId, String commentId) async {
    await _dataService!.deleteComment(feedItemId, commentId);
    final idx = _items.indexWhere((i) => i.id == feedItemId);
    if (idx != -1) {
      _items[idx] = _items[idx].copyWith(
        commentsCount: (_items[idx].commentsCount - 1).clamp(0, 999999),
      );
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
}
