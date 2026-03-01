import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:inkspacex/models/comment_model.dart';
import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/models/reading_progress_model.dart';
import 'package:inkspacex/models/user_preferences_model.dart';
import 'package:inkspacex/services/firestore_service.dart';

class FeedProvider extends ChangeNotifier {
  final FirestoreService _firestore = FirestoreService();

  List<FeedItemModel> _items = [];
  bool _isLoading = true;
  String? _error;
  UserPreferences? _lastPreferences;
  String? _currentUserId;

  DocumentSnapshot? _lastDocument;
  bool _hasMore = true;
  bool _isLoadingMore = false;

  List<ReadingProgressModel> _readingProgress = [];

  List<FeedItemModel> get items => _items;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get hasMore => _hasMore;
  bool get isLoadingMore => _isLoadingMore;
  List<ReadingProgressModel> get readingProgress => _readingProgress;

  /// Load feed only when empty.
  Future<void> loadFeedIfNeeded(
    UserPreferences preferences, {
    String? userId,
  }) async {
    _currentUserId = userId;
    if (_items.isNotEmpty) return;
    _lastDocument = null;
    _hasMore = true;
    await loadFeed(preferences, userId: userId);
  }

  /// Load the feed using the recommendation engine.
  Future<void> loadFeed(
    UserPreferences preferences, {
    bool forceRefresh = false,
    String? userId,
  }) async {
    if (!forceRefresh && _items.isNotEmpty) return;
    _currentUserId = userId ?? _currentUserId;

    _lastDocument = null;
    _hasMore = true;
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      final result = await _firestore.getPersonalizedFeed(
        preferences,
        currentUserId: _currentUserId,
      );
      _items = result.items;
      _lastDocument = result.lastDoc;
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
    try {
      _readingProgress = await _firestore.getAllReadingProgress(userId);
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
    if (_items.isEmpty || _lastPreferences == null) return;
    try {
      final result = await _firestore.getPersonalizedFeed(
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
    _lastDocument = null;
    _hasMore = true;
    _isLoadingMore = false;
    _readingProgress = [];
    notifyListeners();
  }

  /// Load the next page of feed items (cursor-based pagination).
  Future<void> loadMore({String? userId}) async {
    if (_isLoadingMore || !_hasMore) return;
    _isLoadingMore = true;
    notifyListeners();
    try {
      final result = await _firestore.getPersonalizedFeed(
        _lastPreferences ?? const UserPreferences(),
        lastDocument: _lastDocument,
        currentUserId: userId ?? _currentUserId,
      );
      _lastDocument = result.lastDoc;
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
    return _firestore.getComments(feedItemId);
  }

  Stream<List<CommentModel>> getCommentsStream(String feedItemId) {
    return _firestore.getCommentsStream(feedItemId);
  }

  Future<void> addComment(CommentModel comment) async {
    await _firestore.addComment(comment);
    final idx = _items.indexWhere((i) => i.id == comment.feedItemId);
    if (idx != -1) {
      final old = _items[idx];
      _items[idx] = FeedItemModel(
        id: old.id,
        title: old.title,
        author: old.author,
        authorId: old.authorId,
        description: old.description,
        imageUrl: old.imageUrl,
        genres: old.genres,
        writingTypes: old.writingTypes,
        tags: old.tags,
        createdAt: old.createdAt,
        likesCount: old.likesCount,
        commentsCount: old.commentsCount + 1,
        content: old.content,
        bookTitle: old.bookTitle,
        bookId: old.bookId,
      );
      notifyListeners();
    }
  }

  Future<void> deleteComment(String feedItemId, String commentId) async {
    await _firestore.deleteComment(feedItemId, commentId);
    final idx = _items.indexWhere((i) => i.id == feedItemId);
    if (idx != -1) {
      final old = _items[idx];
      _items[idx] = FeedItemModel(
        id: old.id,
        title: old.title,
        author: old.author,
        authorId: old.authorId,
        description: old.description,
        imageUrl: old.imageUrl,
        genres: old.genres,
        writingTypes: old.writingTypes,
        tags: old.tags,
        createdAt: old.createdAt,
        likesCount: old.likesCount,
        commentsCount: (old.commentsCount - 1).clamp(0, 999999),
        content: old.content,
        bookTitle: old.bookTitle,
        bookId: old.bookId,
      );
      notifyListeners();
    }
  }
}
