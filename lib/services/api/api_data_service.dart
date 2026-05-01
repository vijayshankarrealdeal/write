import 'dart:async';
import 'dart:convert';

import 'package:inkspacex/models/bookmark_model.dart';
import 'package:inkspacex/models/bookshelf_model.dart';
import 'package:inkspacex/models/comment_model.dart';
import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/models/image_meta.dart';
import 'package:inkspacex/models/reading_progress_model.dart';
import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/models/user_model.dart';
import 'package:inkspacex/models/user_preferences_model.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/services/api/api_client.dart';
import 'package:inkspacex/services/api/api_realtime_service.dart';
import 'package:inkspacex/services/sync/sync_dispatcher.dart';
import 'package:flutter/material.dart' show Color;

/// Cursor-based feed page (replaces Firestore DocumentSnapshot cursor).
class ApiFeedPage {
  final List<FeedItemModel> items;
  final String? nextCursor;
  const ApiFeedPage({required this.items, this.nextCursor});
}

/// One bucket in the facet sidebar — a (label, count) pair.
class FacetEntry {
  final String value;
  final int count;
  const FacetEntry({required this.value, required this.count});
}

/// Slim author record returned by `/api/users/search` and the public
/// profile endpoint. Excludes private fields (email, lists, onboarding).
class PublicUser {
  final String id;
  final String? name;
  final String? photoUrl;
  final ImageMeta? photoMeta;
  final int postsCount;
  const PublicUser({
    required this.id,
    required this.name,
    required this.photoUrl,
    required this.photoMeta,
    required this.postsCount,
  });

  factory PublicUser.fromJson(Map<String, dynamic> j) => PublicUser(
        id: j['id'] as String,
        name: j['name'] as String?,
        photoUrl: j['photo_url'] as String?,
        photoMeta: ImageMeta.tryFromJson(j['photo_meta']),
        postsCount: (j['posts_count'] as num?)?.toInt() ?? 0,
      );
}

/// Top-N genres / tags / writing_types served by `/api/feed/facets`.
class FeedFacets {
  final List<FacetEntry> genres;
  final List<FacetEntry> tags;
  final List<FacetEntry> writingTypes;
  const FeedFacets({
    required this.genres,
    required this.tags,
    required this.writingTypes,
  });

  bool get isEmpty => genres.isEmpty && tags.isEmpty && writingTypes.isEmpty;
}

/// Result of a `/api/ai/recommendations` call. The `sessionId` ties
/// every impression / click logged from this render back to the same
/// recommendation batch, so we can compute per-render CTR.
class RecommendationsResult {
  final List<FeedItemModel> items;
  final String sessionId;
  const RecommendationsResult({
    required this.items,
    required this.sessionId,
  });
}

/// Single impression / click event posted to
/// `/api/ai/recommendations/events`. Echoes the engine's score and the
/// recommendation source so analytics can segment CTR by both.
class RecommendationEventPayload {
  final String feedItemId;
  final String eventType; // 'impression' | 'click'
  final int? position;
  final double? score;
  final String? source;
  final String? sessionId;

  const RecommendationEventPayload({
    required this.feedItemId,
    required this.eventType,
    this.position,
    this.score,
    this.source,
    this.sessionId,
  });

  Map<String, dynamic> toJson() => {
        'feed_item_id': feedItemId,
        'event_type': eventType,
        if (position != null) 'position': position,
        if (score != null) 'score': score,
        if (source != null) 'source': source,
        if (sessionId != null) 'session_id': sessionId,
      };
}

/// SectionModel stores `content` and `canvasData` as JSON-encoded strings,
/// but the backend column is JSONB and Pydantic validates the value's shape.
/// Decode the string into a real list/map before sending; send null for empty.
dynamic _decodeJsonField(String raw) {
  if (raw.isEmpty) return null;
  try {
    return jsonDecode(raw);
  } catch (_) {
    // Not valid JSON — pass it through as a string and let the server reject.
    return raw;
  }
}

/// Inverse of [_decodeJsonField] for response parsing — re-encode a JSON
/// value back to the string the local model expects.
String _encodeJsonField(dynamic value) {
  if (value == null) return '';
  if (value is String) return value;
  return jsonEncode(value);
}

/// Data service backed by the FastAPI backend (replaces FirestoreService).
///
/// **Comment streaming:** [getCommentsStream] now prefers an SSE channel
/// (`/api/stream/feed/{id}/comments`) and falls back to polling when
/// realtime is unavailable or [_realtime] isn't wired up. A polling
/// safety-net runs alongside SSE on a long interval so the list still
/// converges if a single SSE event is dropped (the SSE stream is
/// best-effort — see [ApiRealtimeService]).
class ApiDataService implements SyncDispatcher {
  final ApiClient _client;
  ApiRealtimeService? _realtime;

  ApiDataService(this._client);

  /// Wires the realtime service after construction. Called by
  /// [AuthProvider] once both services exist; if never set, the
  /// comment stream silently falls back to polling-only.
  // ignore: use_setters_to_change_properties
  void attachRealtime(ApiRealtimeService realtime) {
    _realtime = realtime;
  }

  // =========================================================================
  // USER
  // =========================================================================

  Future<User?> getUser(String userId) async {
    try {
      final response = await _client.get('/api/users/me');
      return _userFromJson(response.data);
    } catch (_) {
      return null;
    }
  }

  Future<void> setUser(User user) async {
    await _client.put('/api/users/me', data: {
      'name': user.name,
      'photo_url': user.photoUrl,
      if (user.photoMeta != null) 'photo_meta': user.photoMeta!.toJson(),
      'onboarding_complete': user.onboardingComplete,
      'onboarding_data': user.preferences.toJson(),
    });
  }

  Future<void> updateUserPreferences(
      String userId, UserPreferences prefs) async {
    await _client.put('/api/users/me', data: {
      'onboarding_data': prefs.toJson(),
    });
  }

  Future<void> completeOnboarding(
      String userId, UserPreferences prefs) async {
    await _client.put('/api/users/me', data: {
      'onboarding_complete': true,
      'onboarding_data': prefs.toJson(),
    });
  }

  // =========================================================================
  // USER LISTS (likes, saves, favorites, bookmarks)
  // =========================================================================

  Future<void> addLike(String userId, String feedItemId) async {
    await _client.post('/api/feed/$feedItemId/like');
  }

  Future<void> removeLike(String userId, String feedItemId) async {
    await _client.delete('/api/feed/$feedItemId/like');
  }

  Future<void> addSave(String userId, String feedItemId) async {
    await _client.post('/api/users/me/saved-posts', data: {
      'action': 'add',
      'item_id': feedItemId,
    });
  }

  Future<void> removeSave(String userId, String feedItemId) async {
    await _client.post('/api/users/me/saved-posts', data: {
      'action': 'remove',
      'item_id': feedItemId,
    });
  }

  Future<void> addFavorite(String userId, String feedItemId) async {
    await _client.post('/api/users/me/favorite-posts', data: {
      'action': 'add',
      'item_id': feedItemId,
    });
  }

  Future<void> removeFavorite(String userId, String feedItemId) async {
    await _client.post('/api/users/me/favorite-posts', data: {
      'action': 'remove',
      'item_id': feedItemId,
    });
  }

  Future<void> addToReadingList(String userId, String feedItemId) async {
    await _client.post('/api/users/me/reading-list', data: {
      'action': 'add',
      'item_id': feedItemId,
    });
  }

  Future<void> addSectionBookmark(String userId, String key) async {
    await _client.post('/api/users/me/section-bookmarks', data: {
      'action': 'add',
      'item_id': key,
    });
  }

  Future<void> removeSectionBookmark(String userId, String key) async {
    await _client.post('/api/users/me/section-bookmarks', data: {
      'action': 'remove',
      'item_id': key,
    });
  }

  // =========================================================================
  // FEED ITEMS
  // =========================================================================

  /// Fetches a feed item. By default the server inlines only the first
  /// [sectionsLimit] section bodies; remaining sections come down as
  /// title-only stubs (`content: []`) so the response stays small for
  /// long books. Use [getFeedItemSection] to lazy-load a missing body.
  Future<FeedItemModel?> getFeedItem(
    String feedItemId, {
    int sectionsLimit = 10,
  }) async {
    try {
      final response = await _client.get(
        '/api/feed/$feedItemId',
        queryParams: {'sections_limit': sectionsLimit.toString()},
      );
      return _feedItemFromJson(response.data);
    } catch (_) {
      return null;
    }
  }

  /// Lazy-fetch a single section's full content by index. Returns the
  /// raw map ({title, content, canvasData}) so the caller can fold it
  /// back into the FeedItem's sections list.
  Future<Map<String, dynamic>?> getFeedItemSection(
    String feedItemId,
    int index,
  ) async {
    try {
      final response = await _client.get(
        '/api/feed/$feedItemId/sections/$index',
      );
      return Map<String, dynamic>.from(response.data as Map);
    } catch (_) {
      return null;
    }
  }

  Future<FeedItemModel?> getExistingSpace(String bookId) async {
    return getFeedItem(bookId);
  }

  Future<List<FeedItemModel>> getFeedItemsByIds(List<String> ids) async {
    if (ids.isEmpty) return [];
    final results = <FeedItemModel>[];
    for (final id in ids) {
      final item = await getFeedItem(id);
      if (item != null) results.add(item);
    }
    return results;
  }

  Future<ApiFeedPage> getPersonalizedFeed(
    UserPreferences preferences, {
    int pageSize = 20,
    String? cursor,
    String? currentUserId,
    Iterable<String>? genres,
    Iterable<String>? tags,
    Iterable<String>? writingTypes,
    String sort = 'recent',
  }) async {
    final params = <String, dynamic>{
      'sort': sort,
      'limit': pageSize,
    };
    if (cursor != null) params['cursor'] = cursor;
    // Repeated `?genres=a&genres=b` matches the FastAPI `list[str]`
    // declaration; ApiClient passes lists through verbatim.
    if (genres != null && genres.isNotEmpty) {
      params['genres'] = genres.toList(growable: false);
    }
    if (tags != null && tags.isNotEmpty) {
      params['tags'] = tags.toList(growable: false);
    }
    if (writingTypes != null && writingTypes.isNotEmpty) {
      params['writing_types'] = writingTypes.toList(growable: false);
    }

    final response = await _client.get('/api/feed/', queryParams: params);
    final items = (response.data as List)
        .map((d) => _feedItemFromJson(d))
        .where((item) => currentUserId == null || item.authorId != currentUserId)
        .toList();

    final nextCursor = items.isNotEmpty ? items.last.id : null;

    return ApiFeedPage(items: items, nextCursor: nextCursor);
  }

  /// Personalised list from the recommendation engine. Returns the
  /// scored items plus a `sessionId` that ties impression / click
  /// events back to this render.
  Future<RecommendationsResult> getRecommendations({
    int limit = 20,
    bool? useLlmRerank,
  }) async {
    final params = <String, dynamic>{'limit': limit};
    // Backend treats absent param as "auto"; only forward when the
    // caller explicitly opts in or out so the auto path is the default.
    if (useLlmRerank != null) {
      params['use_llm_rerank'] = useLlmRerank;
    }
    final response =
        await _client.get('/api/ai/recommendations', queryParams: params);
    final data = response.data as Map<String, dynamic>;
    final sessionId = (data['session_id'] ?? '') as String;
    final rawItems = (data['items'] as List?) ?? const [];
    final items = rawItems
        .map((e) => _recommendedItemFromJson(
              e as Map<String, dynamic>,
              sessionId: sessionId,
            ))
        .toList();
    return RecommendationsResult(items: items, sessionId: sessionId);
  }

  /// Drill-down — every item carrying `tag` (paginated).
  Future<ApiFeedPage> getFeedByTag(
    String tag, {
    int pageSize = 20,
    String sort = 'recent',
    String? cursor,
  }) async {
    final params = <String, dynamic>{'sort': sort, 'limit': pageSize};
    if (cursor != null) params['cursor'] = cursor;
    final response =
        await _client.get('/api/feed/by-tag/$tag', queryParams: params);
    final items =
        (response.data as List).map((d) => _feedItemFromJson(d)).toList();
    final nextCursor = items.isNotEmpty ? items.last.id : null;
    return ApiFeedPage(items: items, nextCursor: nextCursor);
  }

  /// Drill-down — every item in `genre` (paginated).
  Future<ApiFeedPage> getFeedByGenre(
    String genre, {
    int pageSize = 20,
    String sort = 'recent',
    String? cursor,
  }) async {
    final params = <String, dynamic>{'sort': sort, 'limit': pageSize};
    if (cursor != null) params['cursor'] = cursor;
    final response =
        await _client.get('/api/feed/by-genre/$genre', queryParams: params);
    final items =
        (response.data as List).map((d) => _feedItemFromJson(d)).toList();
    final nextCursor = items.isNotEmpty ? items.last.id : null;
    return ApiFeedPage(items: items, nextCursor: nextCursor);
  }

  /// Top-N facet buckets for the Explore tab + chip filters. Empty
  /// `FeedFacets` on any failure — Explore should silently degrade
  /// rather than show an empty error state.
  Future<FeedFacets> getFeedFacets() async {
    try {
      final response = await _client.get('/api/feed/facets');
      final data = response.data as Map<String, dynamic>;
      List<FacetEntry> parse(String key) {
        final raw = (data[key] as List?) ?? const [];
        return raw
            .map((e) => FacetEntry(
                  value: (e as Map)['value'] as String,
                  count: (e['count'] as num).toInt(),
                ))
            .toList();
      }

      return FeedFacets(
        genres: parse('genres'),
        tags: parse('tags'),
        writingTypes: parse('writing_types'),
      );
    } catch (_) {
      return const FeedFacets(genres: [], tags: [], writingTypes: []);
    }
  }

  /// Semantic-neighbour list ("More like this") for a single feed item.
  /// Returns the top-N nearest items by pgvector cosine distance. Empty
  /// list when the seed has no embedding yet — the carousel hides itself
  /// in that case rather than showing a stale fallback.
  Future<List<FeedItemModel>> getSimilarFeedItems(
    String feedItemId, {
    int limit = 10,
  }) async {
    try {
      final response = await _client.get(
        '/api/ai/recommendations/similar/$feedItemId',
        queryParams: {'limit': limit},
      );
      final raw = (response.data as List?) ?? const [];
      return raw
          .map((e) => _recommendedItemFromJson(
                e as Map<String, dynamic>,
                sessionId: '',
              ))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Bulk-log impressions / clicks for the recommendation engine. Fire
  /// and forget — analytics shouldn't block the UI, and a 4xx/5xx here
  /// is silently swallowed.
  Future<void> logRecommendationEvents(
    List<RecommendationEventPayload> events,
  ) async {
    if (events.isEmpty) return;
    try {
      await _client.post(
        '/api/ai/recommendations/events',
        data: {'events': events.map((e) => e.toJson()).toList()},
      );
    } catch (_) {
      // Drop — telemetry is best-effort.
    }
  }

  Future<List<FeedItemModel>> getPopularFeedItems({int limit = 12}) async {
    final response = await _client.get('/api/feed/', queryParams: {
      'sort': 'trending',
      'limit': limit,
    });
    return (response.data as List).map((d) => _feedItemFromJson(d)).toList();
  }

  /// Author search by display name. Hits `/api/users/search` — ranked
  /// by published-post count so productive writers float above empty
  /// profiles. Never throws on transport error: empty list is safer
  /// than killing the whole search surface for a flaky network blip.
  Future<List<PublicUser>> searchUsers(String query, {int limit = 20}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    try {
      final response = await _client.get('/api/users/search', queryParams: {
        'q': q,
        'limit': limit,
      });
      final raw = (response.data as List?) ?? const [];
      return raw
          .map((d) => PublicUser.fromJson(d as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Public profile fetch — same shape as a search hit. 404 returns null
  /// so the caller can render an inline "user not found" instead of a
  /// crash.
  Future<PublicUser?> getPublicUser(String userId) async {
    try {
      final response = await _client.get('/api/users/$userId');
      final data = response.data as Map<String, dynamic>;
      return PublicUser.fromJson(data);
    } catch (_) {
      return null;
    }
  }

  /// Diversified search across title / author / description / tag / genre /
  /// writing-type. Hits `/api/feed/search`, which ranks server-side and
  /// caps per-author so a single prolific writer can't dominate the page.
  Future<List<FeedItemModel>> searchFeedItems(String query,
      {int limit = 50}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    try {
      final response = await _client.get('/api/feed/search', queryParams: {
        'q': q,
        'limit': limit,
      });
      final raw = (response.data as List?) ?? const [];
      return raw.map((d) => _feedItemFromJson(d as Map<String, dynamic>)).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> publishCover(
    WritingModel book,
    List<SectionModel> sections,
    User author, {
    List<String> tags = const [],
    String? descriptionOverride,
    bool isDraft = false,
  }) async {
    final feedSections = sections
        .map((s) => {
              'id': s.id,
              'title': s.title,
              'content': s.content,
              'canvasData': s.canvasData,
            })
        .toList();

    // Check if existing space exists
    final existing = await getExistingSpace(book.id);
    if (existing != null) {
      // Update existing
      await _client.put('/api/feed/${book.id}', data: {
        'title': book.title,
        'description': descriptionOverride ?? book.description,
        'image_url': book.coverImagePath,
        if (book.coverImageMeta != null)
          'image_meta': book.coverImageMeta!.toJson(),
        'genres': book.subtype.isNotEmpty ? [book.subtype] : [],
        'writing_types': [book.writingType.displayName],
        'tags': tags,
        'is_draft': isDraft,
        'sections': feedSections,
      });
    } else {
      // Create new
      await _client.post('/api/feed/', data: {
        'title': book.title,
        'description': descriptionOverride ?? book.description,
        'image_url': book.coverImagePath,
        if (book.coverImageMeta != null)
          'image_meta': book.coverImageMeta!.toJson(),
        'genres': book.subtype.isNotEmpty ? [book.subtype] : [],
        'writing_types': [book.writingType.displayName],
        'tags': tags,
        'is_draft': isDraft,
        'sections': feedSections,
      });
    }
  }

  Future<List<FeedItemModel>> getDrafts(String userId) async {
    final response =
        await _client.get('/api/feed/by-author/$userId', queryParams: {
      'include_drafts': true,
    });
    return (response.data as List)
        .map((d) => _feedItemFromJson(d))
        .where((item) => item.isDraft)
        .toList();
  }

  /// Published items for an author. Used by the public profile page —
  /// drafts are filtered server-side because `include_drafts=false` is
  /// the default unless the requesting user is the author themselves.
  Future<List<FeedItemModel>> getFeedItemsByAuthor(String authorId) async {
    try {
      final response = await _client.get('/api/feed/by-author/$authorId');
      return (response.data as List)
          .map((d) => _feedItemFromJson(d as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> publishDraft(String feedItemId) async {
    await _client.put('/api/feed/$feedItemId', data: {'is_draft': false});
  }

  Future<void> deleteDraft(String feedItemId) async {
    await _client.delete('/api/feed/$feedItemId');
  }

  // =========================================================================
  // COMMENTS
  // =========================================================================

  Future<void> addComment(CommentModel comment) async {
    await _client.post('/api/feed/${comment.feedItemId}/comments/', data: {
      'text': comment.text,
      'rating': comment.rating,
    });
  }

  Future<void> deleteComment(String feedItemId, String commentId) async {
    await _client.delete('/api/feed/$feedItemId/comments/$commentId');
  }

  Future<List<CommentModel>> getComments(String feedItemId,
      {int limit = 50}) async {
    final response =
        await _client.get('/api/feed/$feedItemId/comments/');
    return (response.data as List).map((d) => _commentFromJson(d)).toList();
  }

  /// Default polling interval for [getCommentsStream] when SSE isn't
  /// available, and the safety-net interval when SSE is also active.
  static const Duration commentsPollInterval = Duration(seconds: 15);

  /// Live stream of comments for [feedItemId]. Strategy:
  ///   * subscribe to the SSE channel — apply `comment.created` /
  ///     `comment.deleted` events to a local list and emit the whole
  ///     list each time it changes.
  ///   * also poll on a long interval as a safety-net so the list
  ///     converges even if an SSE event is dropped.
  ///   * if no realtime service has been attached, fall back to the
  ///     original polling-only stream.
  ///
  /// Identical successive payloads (by JSON shape) are suppressed so
  /// the UI doesn't repaint when nothing changed.
  Stream<List<CommentModel>> getCommentsStream(
    String feedItemId, {
    Duration interval = commentsPollInterval,
  }) {
    final realtime = _realtime;
    if (realtime == null) {
      return pollComments(
        interval: interval,
        fetch: () => getComments(feedItemId),
      );
    }

    late StreamController<List<CommentModel>> controller;
    StreamSubscription<Map<String, dynamic>>? sseSub;
    Timer? pollTimer;
    var current = <CommentModel>[];
    String? lastSig;

    void emit(List<CommentModel> next) {
      final sig = jsonEncode(next.map((c) => c.toJson()).toList());
      if (sig == lastSig) return;
      lastSig = sig;
      current = next;
      if (!controller.isClosed) controller.add(next);
    }

    Future<void> initialFetch() async {
      try {
        final initial = await getComments(feedItemId);
        emit(initial);
      } catch (_) {
        // surface nothing — UI shows "loading" until first emit
      }
    }

    Future<void> safetyPoll() async {
      try {
        final fresh = await getComments(feedItemId);
        emit(fresh);
      } catch (_) {
        // ignore — next tick will retry
      }
    }

    void onSseEvent(Map<String, dynamic> event) {
      switch (event['type']) {
        case 'comment.created':
          final raw = event['comment'];
          if (raw is Map) {
            final comment =
                _commentFromJson(Map<String, dynamic>.from(raw));
            if (current.any((c) => c.id == comment.id)) return;
            // Newest-first matches the REST list ordering.
            emit([comment, ...current]);
          }
          break;
        case 'comment.deleted':
          final id = event['comment_id']?.toString();
          if (id == null) return;
          emit(current.where((c) => c.id != id).toList());
          break;
        default:
          break;
      }
    }

    controller = StreamController<List<CommentModel>>(
      onListen: () {
        sseSub = realtime.commentsChannel(feedItemId).listen(onSseEvent);
        pollTimer = Timer.periodic(interval, (_) => safetyPoll());
        initialFetch();
      },
      onCancel: () async {
        await sseSub?.cancel();
        pollTimer?.cancel();
        await realtime.closeCommentsChannel(feedItemId);
      },
    );
    return controller.stream;
  }

  /// Test seam: build a polling stream around any `fetch` callback. The
  /// stream emits the initial payload immediately, then a fresh payload
  /// at every [interval] tick — but only when the JSON shape differs
  /// from the previous emission. Cancelling the subscription stops the
  /// timer; transient fetch failures are swallowed and retried on the
  /// next tick.
  static Stream<List<CommentModel>> pollComments({
    required Duration interval,
    required Future<List<CommentModel>> Function() fetch,
  }) {
    late StreamController<List<CommentModel>> controller;
    Timer? timer;
    String? lastSig;

    Future<void> tick() async {
      if (controller.isClosed) return;
      try {
        final result = await fetch();
        if (controller.isClosed) return;
        final sig = jsonEncode(result.map((c) => c.toJson()).toList());
        if (sig != lastSig) {
          lastSig = sig;
          controller.add(result);
        }
      } catch (_) {
        // Per-tick failures are swallowed: next tick retries. The whole
        // stream only closes when the consumer cancels.
      }
    }

    controller = StreamController<List<CommentModel>>(
      onListen: () {
        tick();
        timer = Timer.periodic(interval, (_) => tick());
      },
      onCancel: () {
        timer?.cancel();
        timer = null;
      },
    );
    return controller.stream;
  }

  // =========================================================================
  // HIGHLIGHTS
  // =========================================================================

  Future<void> addHighlight({
    required String userId,
    required String feedItemId,
    required String highlightId,
    required int sectionIndex,
    required int start,
    required int length,
    required String colorHex,
    String note = '',
  }) async {
    await _client.post('/api/highlights/', data: {
      'feed_item_id': feedItemId,
      'section_index': sectionIndex,
      'start': start,
      'length': length,
      'color_hex': colorHex,
      if (note.isNotEmpty) 'note': note,
    });
  }

  Future<void> updateHighlightNote({
    required String userId,
    required String highlightId,
    required String note,
  }) async {
    await _client.put('/api/highlights/$highlightId', data: {
      'note': note,
    });
  }

  Future<void> updateHighlightColor({
    required String userId,
    required String highlightId,
    required String colorHex,
  }) async {
    await _client.put('/api/highlights/$highlightId', data: {
      'color_hex': colorHex,
    });
  }

  Future<void> deleteHighlight({
    required String userId,
    required String highlightId,
  }) async {
    await _client.delete('/api/highlights/$highlightId');
  }

  Future<List<Map<String, dynamic>>> getHighlightsForFeedItem({
    required String userId,
    required String feedItemId,
  }) async {
    final response = await _client.get('/api/highlights/', queryParams: {
      'feed_item_id': feedItemId,
    });
    return (response.data as List).map((d) {
      return {
        'id': d['id'],
        'feedItemId': d['feed_item_id'],
        'sectionIndex': d['section_index'],
        'start': d['start'],
        'length': d['length'],
        'colorHex': d['color_hex'],
        'note': d['note'] ?? '',
        'createdAt': d['created_at'],
      };
    }).toList();
  }

  // =========================================================================
  // BOOKMARKS (Phase 3 / P2 — paragraph-precise marks the user can resume to)
  // =========================================================================

  /// Idempotent server-side: the (user, feed_item, section_index, anchor)
  /// tuple dedupes, so the outbox can replay this op without producing
  /// duplicates. Returns the server-issued bookmark id; the drainer will
  /// remap any pending follow-up patches/deletes to this id.
  @override
  Future<String> upsertBookmark(
    BookmarkModel bookmark, {
    String? clientOpId,
  }) async {
    final response = await _client.post(
      '/api/bookmarks/',
      data: bookmark.toCreateJson(clientOpId: clientOpId),
    );
    return (response.data['id'] ?? '').toString();
  }

  @override
  Future<void> deleteBookmark(String bookmarkId) async {
    await _client.delete('/api/bookmarks/$bookmarkId');
  }

  Future<List<BookmarkModel>> listBookmarks({String? feedItemId}) async {
    final query = <String, dynamic>{};
    if (feedItemId != null) query['feed_item_id'] = feedItemId;
    final response = await _client.get(
      '/api/bookmarks/',
      queryParams: query.isEmpty ? null : query,
    );
    final raw = response.data;
    if (raw is! List) return const [];
    return raw
        .map((e) => BookmarkModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<BookmarkModel>> listBookmarksForFeedItem(
      String feedItemId) async {
    final response =
        await _client.get('/api/bookmarks/by-feed-item/$feedItemId');
    final raw = response.data;
    if (raw is! List) return const [];
    return raw
        .map((e) => BookmarkModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // =========================================================================
  // WRITINGS
  // =========================================================================

  Future<List<WritingModel>> getWritings(String userId) async {
    final response = await _client.get('/api/writings/');
    final writings = <WritingModel>[];
    for (final data in response.data as List) {
      final writingId = data['id'];
      // Fetch sections for each writing
      final sectionsResponse =
          await _client.get('/api/writings/$writingId/sections');
      final sections = (sectionsResponse.data as List)
          .map((s) => _sectionFromJson(s))
          .toList();

      writings.add(_writingFromJson(data, sections));
    }
    return writings;
  }

  @override
  Future<WritingModel> createWriting(
    String userId,
    WritingModel book, {
    String? opId,
  }) async {
    final response = await _client.post(
      '/api/writings/',
      data: {
        'title': book.title,
        'description': book.description,
        'cover_image_path': book.coverImagePath,
        if (book.coverImageMeta != null)
          'cover_image_meta': book.coverImageMeta!.toJson(),
        'status': book.status.index.toString(),
        'writing_type': book.writingType.index.toString(),
        'subtype': book.subtype,
      },
      headers: _opHeaders(opId),
    );

    book.id = response.data['id'] as String;

    for (final section in book.sections) {
      final sectionResp = await _client.post(
        '/api/writings/${book.id}/sections',
        data: {
          'title': section.title,
          'content': _decodeJsonField(section.content),
          'canvas_data': _decodeJsonField(section.canvasData),
          'section_color': section.sectionColor.toARGB32(),
        },
        headers: _opHeaders(opId),
      );
      section.id = sectionResp.data['id'] as String;
      section.isSynced = true;
    }

    return book;
  }

  @override
  Future<void> updateSectionContent(
    String userId,
    String writingId,
    String sectionId,
    String content, {
    String canvasData = '',
    String? opId,
  }) async {
    final data = <String, dynamic>{'content': _decodeJsonField(content)};
    if (canvasData.isNotEmpty) {
      data['canvas_data'] = _decodeJsonField(canvasData);
    }
    await _client.put(
      '/api/writings/$writingId/sections/$sectionId',
      data: data,
      headers: _opHeaders(opId),
    );
  }

  @override
  Future<void> addSection(
    String userId,
    String writingId,
    SectionModel section, {
    String? opId,
  }) async {
    final response = await _client.post(
      '/api/writings/$writingId/sections',
      data: {
        'title': section.title,
        'content': _decodeJsonField(section.content),
        'canvas_data': _decodeJsonField(section.canvasData),
        'section_color': section.sectionColor.toARGB32(),
      },
      headers: _opHeaders(opId),
    );
    section.id = response.data['id'] as String;
    section.isSynced = true;
  }

  @override
  Future<void> renameSection(
    String userId,
    String writingId,
    String sectionId,
    String newTitle, {
    String? opId,
  }) async {
    await _client.put(
      '/api/writings/$writingId/sections/$sectionId',
      data: {'title': newTitle},
      headers: _opHeaders(opId),
    );
  }

  @override
  Future<void> deleteSection(
    String userId,
    String writingId,
    String sectionId, {
    String? opId,
  }) async {
    await _client.delete(
      '/api/writings/$writingId/sections/$sectionId',
      headers: _opHeaders(opId),
    );
  }

  @override
  Future<void> updateWritingMetadata(
    String userId,
    String writingId, {
    String? title,
    String? description,
    String? coverImagePath,
    ImageMeta? coverImageMeta,
    String? opId,
  }) async {
    final data = <String, dynamic>{};
    if (title != null) data['title'] = title;
    if (description != null) data['description'] = description;
    if (coverImagePath != null) data['cover_image_path'] = coverImagePath;
    if (coverImageMeta != null) {
      data['cover_image_meta'] = coverImageMeta.toJson();
    }
    await _client.put(
      '/api/writings/$writingId',
      data: data,
      headers: _opHeaders(opId),
    );
  }

  @override
  Future<void> deleteWriting(
    String userId,
    String writingId, {
    String? opId,
  }) async {
    await _client.delete(
      '/api/writings/$writingId',
      headers: _opHeaders(opId),
    );
  }

  /// Stamp a request with an `X-Op-Id` header and prime the realtime
  /// service so the originating client can ignore the SSE echo of its
  /// own write. No-op when the caller didn't supply an op id (e.g.
  /// internal/admin paths) or when realtime hasn't been wired up yet.
  Map<String, String>? _opHeaders(String? opId) {
    if (opId == null || opId.isEmpty) return null;
    _realtime?.recordIssuedOp(opId);
    return {'X-Op-Id': opId};
  }

  // =========================================================================
  // READING PROGRESS
  // =========================================================================

  Future<void> updateReadingProgress(
    String userId,
    String feedItemId,
    double scrollPosition, {
    bool completed = false,
    String? lastSectionId,
    int? lastParagraphIdx,
    int? lastCharOffset,
  }) async {
    final body = <String, dynamic>{
      'scroll_position': scrollPosition,
      'completed': completed,
    };
    if (lastSectionId != null) body['last_section_id'] = lastSectionId;
    if (lastParagraphIdx != null && lastCharOffset != null) {
      body['last_anchor'] = {
        'paragraph_idx': lastParagraphIdx,
        'char_offset': lastCharOffset,
      };
    }
    await _client.put('/api/reading-progress/$feedItemId', data: body);
  }

  /// Items the user started but hasn't finished, newest activity first.
  /// Drives the "Continue reading" rail on the home shell.
  Future<List<ContinueReadingItem>> getContinueReading({int limit = 8}) async {
    final response = await _client.get(
      '/api/reading-progress/continue-reading',
      queryParams: {'limit': limit},
    );
    final raw = response.data;
    if (raw is! List) return const [];
    return raw
        .map((e) => ContinueReadingItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<ReadingProgressModel?> getReadingProgress(
    String userId,
    String feedItemId,
  ) async {
    try {
      final response = await _client.get('/api/reading-progress/$feedItemId');
      if (response.data == null) return null;
      return ReadingProgressModel.fromJson({
        'feedItemId': response.data['feed_item_id'],
        'scrollPosition': response.data['scroll_position'],
        'lastReadAt': response.data['last_read_at'],
        'completed': response.data['completed'],
      });
    } catch (_) {
      return null;
    }
  }

  Future<List<ReadingProgressModel>> getAllReadingProgress(
      String userId) async {
    // Backed by the Phase 3 (P2) `/continue-reading` endpoint — that
    // route already filters out completed items and joins enough feed
    // metadata to render the rail, so we adapt its shape into the
    // legacy ReadingProgressModel rather than maintaining a separate
    // `/list-all` endpoint that nobody else needs.
    try {
      final items = await getContinueReading(limit: 24);
      return items
          .map((it) => ReadingProgressModel(
                feedItemId: it.feedItemId,
                scrollPosition: it.scrollPosition,
                lastReadAt: it.lastReadAt ?? DateTime.now(),
                completed: it.completed,
              ))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  // =========================================================================
  // BOOKSHELVES
  // =========================================================================

  Future<List<Bookshelf>> getBookshelves(String userId) async {
    final response = await _client.get('/api/bookshelves/');
    return (response.data as List).map((d) => _bookshelfFromJson(d)).toList();
  }

  Future<Bookshelf?> getBookshelf(String userId, String bookshelfId) async {
    try {
      final response = await _client.get('/api/bookshelves/$bookshelfId');
      return _bookshelfFromJson(response.data);
    } catch (_) {
      return null;
    }
  }

  Future<void> createBookshelf(String userId, Bookshelf shelf) async {
    await _client.post('/api/bookshelves/', data: {
      'name': shelf.name,
      'description': shelf.description,
      'is_private': shelf.isPrivate,
    });
  }

  Future<void> updateBookshelf(
    String userId,
    String bookshelfId, {
    String? name,
    String? description,
    bool? isPrivate,
    String? coverImageUrl,
    ImageMeta? coverImageMeta,
  }) async {
    final data = <String, dynamic>{};
    if (name != null) data['name'] = name;
    if (description != null) data['description'] = description;
    if (isPrivate != null) data['is_private'] = isPrivate;
    if (coverImageUrl != null) data['cover_image_url'] = coverImageUrl;
    if (coverImageMeta != null) {
      data['cover_image_meta'] = coverImageMeta.toJson();
    }
    await _client.put('/api/bookshelves/$bookshelfId', data: data);
  }

  Future<void> deleteBookshelf(String userId, String bookshelfId) async {
    await _client.delete('/api/bookshelves/$bookshelfId');
  }

  Future<void> addItemsToBookshelf(
    String userId,
    String bookshelfId,
    List<String> feedItemIds,
  ) async {
    // Get current bookshelf, add items, update
    final shelf = await getBookshelf(userId, bookshelfId);
    if (shelf == null) return;
    final updatedIds = {...shelf.itemIds, ...feedItemIds}.toList();
    await _client.put('/api/bookshelves/$bookshelfId', data: {
      'item_ids': updatedIds,
    });
  }

  Future<void> removeItemFromBookshelf(
    String userId,
    String bookshelfId,
    String feedItemId,
  ) async {
    final shelf = await getBookshelf(userId, bookshelfId);
    if (shelf == null) return;
    final updatedIds =
        shelf.itemIds.where((id) => id != feedItemId).toList();
    await _client.put('/api/bookshelves/$bookshelfId', data: {
      'item_ids': updatedIds,
    });
  }

  // =========================================================================
  // JSON HELPERS
  // =========================================================================

  User _userFromJson(Map<String, dynamic> json) {
    return User.fromJson({
      ...json,
      'photoUrl': json['photo_url'],
      'photoMeta': json['photo_meta'],
      'onboardingComplete': json['onboarding_complete'] ?? false,
      'onboardingData': json['onboarding_data'],
      'readingList': json['reading_list'] ?? [],
      'savedPosts': json['saved_posts'] ?? [],
      'favoritePosts': json['favorite_posts'] ?? [],
      'sectionBookmarks': json['section_bookmarks'] ?? [],
      'createdAt': json['created_at'],
      'updatedAt': json['updated_at'],
    });
  }

  FeedItemModel _feedItemFromJson(Map<String, dynamic> json) {
    return FeedItemModel.fromJson({
      ...json,
      'authorId': json['author_id'],
      'imageUrl': json['image_url'],
      'imageMeta': json['image_meta'],
      'writingTypes': json['writing_types'] ?? [],
      'likesCount': json['likes_count'] ?? 0,
      'commentsCount': json['comments_count'] ?? 0,
      'isDraft': json['is_draft'] ?? false,
      'createdAt': json['created_at'],
      'updatedAt': json['updated_at'],
    });
  }

  /// Recommendation responses are shaped like a FeedItem with `feed_item_id`
  /// (not `id`) plus `score` / `reason` / `source`. Re-key into the
  /// FeedItem JSON shape and stamp the recommendation metadata.
  FeedItemModel _recommendedItemFromJson(
    Map<String, dynamic> json, {
    required String sessionId,
  }) {
    final remapped = <String, dynamic>{
      ...json,
      'id': json['feed_item_id'],
    };
    final base = _feedItemFromJson(remapped);
    return base.copyWith(
      recommendation: RecommendationMeta(
        score: ((json['score'] as num?) ?? 0).toDouble(),
        reason: json['reason'] as String?,
        source: (json['source'] as String?) ?? 'engine',
        sessionId: sessionId,
      ),
    );
  }

  CommentModel _commentFromJson(Map<String, dynamic> json) {
    return CommentModel.fromJson({
      ...json,
      'feedItemId': json['feed_item_id'],
      'authorId': json['author_id'],
      'authorName': json['author_name'],
      'authorPhotoUrl': json['author_photo_url'],
      'authorPhotoMeta': json['author_photo_meta'],
      'createdAt': json['created_at'],
    });
  }

  WritingModel _writingFromJson(
      Map<String, dynamic> json, List<SectionModel> sections) {
    return WritingModel(
      id: json['id'],
      title: json['title'] ?? '',
      author: json['author'] ?? '',
      description: json['description'] ?? '',
      coverImagePath: json['cover_image_path'] ?? '',
      coverImageMeta: ImageMeta.tryFromJson(json['cover_image_meta']),
      status: WritingStatus.values[int.tryParse(json['status'] ?? '0') ?? 0],
      writingType:
          WritingType.values[int.tryParse(json['writing_type'] ?? '0') ?? 0],
      subtype: json['subtype'] ?? '',
      sections: sections,
    );
  }

  SectionModel _sectionFromJson(Map<String, dynamic> json) {
    return SectionModel(
      id: json['id'],
      title: json['title'] ?? '',
      content: _encodeJsonField(json['content']),
      canvasData: _encodeJsonField(json['canvas_data']),
      sectionColor: Color((json['section_color'] as num?)?.toInt() ?? 0xFF1982C4),
      updatedAt: DateTime.tryParse(json['updated_at'] ?? '') ?? DateTime.now(),
      isSynced: true,
    );
  }

  Bookshelf _bookshelfFromJson(Map<String, dynamic> json) {
    return Bookshelf.fromJson({
      ...json,
      'isPrivate': json['is_private'] ?? true,
      'itemIds': json['item_ids'] ?? [],
      'coverImageUrl': json['cover_image_url'],
      'coverImageMeta': json['cover_image_meta'],
      'createdAt': json['created_at'],
      'updatedAt': json['updated_at'],
    });
  }
}
