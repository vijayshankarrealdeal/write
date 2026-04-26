import 'dart:convert';

import 'package:inkspacex/models/bookshelf_model.dart';
import 'package:inkspacex/models/comment_model.dart';
import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/models/reading_progress_model.dart';
import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/models/user_model.dart';
import 'package:inkspacex/models/user_preferences_model.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/services/api/api_client.dart';
import 'package:flutter/material.dart' show Color;

/// Cursor-based feed page (replaces Firestore DocumentSnapshot cursor).
class ApiFeedPage {
  final List<FeedItemModel> items;
  final String? nextCursor;
  const ApiFeedPage({required this.items, this.nextCursor});
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
class ApiDataService {
  final ApiClient _client;

  ApiDataService(this._client);

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

  Future<FeedItemModel?> getFeedItem(String feedItemId) async {
    try {
      final response = await _client.get('/api/feed/$feedItemId');
      return _feedItemFromJson(response.data);
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
  }) async {
    final params = <String, dynamic>{
      'sort': 'recent',
      'limit': pageSize,
    };
    if (cursor != null) params['cursor'] = cursor;

    final response = await _client.get('/api/feed/', queryParams: params);
    final items = (response.data as List)
        .map((d) => _feedItemFromJson(d))
        .where((item) => currentUserId == null || item.authorId != currentUserId)
        .toList();

    final nextCursor = items.isNotEmpty ? items.last.id : null;

    return ApiFeedPage(items: items, nextCursor: nextCursor);
  }

  Future<List<FeedItemModel>> getPopularFeedItems({int limit = 12}) async {
    final response = await _client.get('/api/feed/', queryParams: {
      'sort': 'trending',
      'limit': limit,
    });
    return (response.data as List).map((d) => _feedItemFromJson(d)).toList();
  }

  Future<List<FeedItemModel>> searchFeedItems(String query,
      {int limit = 50}) async {
    // For now, use the feed endpoint with client-side filtering
    // In future, add a dedicated search endpoint
    final response = await _client.get('/api/feed/', queryParams: {
      'sort': 'recent',
      'limit': 200,
    });
    final items =
        (response.data as List).map((d) => _feedItemFromJson(d)).toList();
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return [];
    final tokens = q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    final scored = <({FeedItemModel item, int score})>[];
    for (final item in items) {
      final score = _scoreMatch(item, tokens);
      if (score > 0) scored.add((item: item, score: score));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(limit).map((s) => s.item).toList();
  }

  int _scoreMatch(FeedItemModel item, List<String> tokens) {
    final title = item.title.toLowerCase();
    final author = item.author.toLowerCase();
    final desc = item.description.toLowerCase();
    final tagLine = item.tags.join(' ').toLowerCase();
    final genreLine = item.genres.join(' ').toLowerCase();
    int score = 0;
    for (final t in tokens) {
      if (title.startsWith(t)) {
        score += 100;
      } else if (title.contains(t)) {
        score += 60;
      }
      if (author.startsWith(t)) {
        score += 50;
      } else if (author.contains(t)) {
        score += 30;
      }
      if (tagLine.contains(t)) score += 20;
      if (genreLine.contains(t)) score += 15;
      if (desc.contains(t)) score += 5;
    }
    return score;
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

  // Note: Real-time comment streaming is not available with REST.
  // For live updates, use polling or add WebSocket support later.
  Stream<List<CommentModel>> getCommentsStream(String feedItemId) {
    // Simulate with a single-event stream for now
    return Stream.fromFuture(getComments(feedItemId));
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
  }) async {
    await _client.post('/api/highlights/', data: {
      'feed_item_id': feedItemId,
      'section_index': sectionIndex,
      'start': start,
      'length': length,
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
        'createdAt': d['created_at'],
      };
    }).toList();
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

  Future<WritingModel> createWriting(String userId, WritingModel book) async {
    final response = await _client.post('/api/writings/', data: {
      'title': book.title,
      'description': book.description,
      'cover_image_path': book.coverImagePath,
      'status': book.status.index.toString(),
      'writing_type': book.writingType.index.toString(),
      'subtype': book.subtype,
    });

    final writingId = response.data['id'];

    // Create sections
    for (final section in book.sections) {
      await _client.post('/api/writings/$writingId/sections', data: {
        'title': section.title,
        'content': _decodeJsonField(section.content),
        'canvas_data': _decodeJsonField(section.canvasData),
        'section_color': section.sectionColor.toARGB32(),
      });
    }

    return book;
  }

  Future<void> updateSectionContent(
    String userId,
    String writingId,
    String sectionId,
    String content, {
    String canvasData = '',
  }) async {
    final data = <String, dynamic>{'content': _decodeJsonField(content)};
    if (canvasData.isNotEmpty) {
      data['canvas_data'] = _decodeJsonField(canvasData);
    }
    await _client.put('/api/writings/$writingId/sections/$sectionId',
        data: data);
  }

  Future<void> addSection(
    String userId,
    String writingId,
    SectionModel section,
  ) async {
    await _client.post('/api/writings/$writingId/sections', data: {
      'title': section.title,
      'content': _decodeJsonField(section.content),
      'canvas_data': _decodeJsonField(section.canvasData),
      'section_color': section.sectionColor.toARGB32(),
    });
  }

  Future<void> renameSection(
    String userId,
    String writingId,
    String sectionId,
    String newTitle,
  ) async {
    await _client.put('/api/writings/$writingId/sections/$sectionId', data: {
      'title': newTitle,
    });
  }

  Future<void> deleteSection(
    String userId,
    String writingId,
    String sectionId,
  ) async {
    await _client.delete('/api/writings/$writingId/sections/$sectionId');
  }

  Future<void> updateWritingMetadata(
    String userId,
    String writingId, {
    String? title,
    String? description,
    String? coverImagePath,
  }) async {
    final data = <String, dynamic>{};
    if (title != null) data['title'] = title;
    if (description != null) data['description'] = description;
    if (coverImagePath != null) data['cover_image_path'] = coverImagePath;
    await _client.put('/api/writings/$writingId', data: data);
  }

  Future<void> deleteWriting(String userId, String writingId) async {
    await _client.delete('/api/writings/$writingId');
  }

  // =========================================================================
  // READING PROGRESS
  // =========================================================================

  Future<void> updateReadingProgress(
    String userId,
    String feedItemId,
    double scrollPosition, {
    bool completed = false,
  }) async {
    await _client.put('/api/reading-progress/$feedItemId', data: {
      'scroll_position': scrollPosition,
      'completed': completed,
    });
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
    // The API doesn't have a list-all endpoint yet; return empty for now.
    // TODO: Add GET /api/reading-progress/ endpoint.
    return [];
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
  }) async {
    final data = <String, dynamic>{};
    if (name != null) data['name'] = name;
    if (description != null) data['description'] = description;
    if (isPrivate != null) data['is_private'] = isPrivate;
    if (coverImageUrl != null) data['cover_image_url'] = coverImageUrl;
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
      'writingTypes': json['writing_types'] ?? [],
      'likesCount': json['likes_count'] ?? 0,
      'commentsCount': json['comments_count'] ?? 0,
      'isDraft': json['is_draft'] ?? false,
      'createdAt': json['created_at'],
      'updatedAt': json['updated_at'],
    });
  }

  CommentModel _commentFromJson(Map<String, dynamic> json) {
    return CommentModel.fromJson({
      ...json,
      'feedItemId': json['feed_item_id'],
      'authorId': json['author_id'],
      'authorName': json['author_name'],
      'authorPhotoUrl': json['author_photo_url'],
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
      'createdAt': json['created_at'],
      'updatedAt': json['updated_at'],
    });
  }
}
