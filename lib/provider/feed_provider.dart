import 'package:flutter/foundation.dart';
import 'package:writer/models/feed_item_model.dart';
import 'package:writer/models/user_preferences_model.dart';
import 'package:writer/services/firestore_service.dart';

class FeedProvider extends ChangeNotifier {
  final FirestoreService _firestore = FirestoreService();

  List<FeedItemModel> _items = [];
  bool _isLoading = true; // Show loading until first load completes
  String? _error;
  UserPreferences? _lastPreferences;

  List<FeedItemModel> get items => _items;
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// Load feed only when empty. Keeps state when switching tabs.
  Future<void> loadFeedIfNeeded(UserPreferences preferences) async {
    if (_items.isNotEmpty) return;
    await loadFeed(preferences, forceRefresh: false);
  }

  /// Load feed. Use forceRefresh for pull-to-refresh.
  Future<void> loadFeed(UserPreferences preferences, {bool forceRefresh = false}) async {
    if (!forceRefresh && _items.isNotEmpty) return;

    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      _items = await _firestore.getPersonalizedFeed(preferences);
      _lastPreferences = preferences;
    } catch (e) {
      _error = e.toString();
      if (forceRefresh) _items = [];
    }
    _isLoading = false;
    notifyListeners();
  }

  /// Silent background fetch: append new items at top. No loading indicator.
  Future<void> silentRefresh() async {
    if (_items.isEmpty || _lastPreferences == null) return;
    try {
      final fresh = await _firestore.getPersonalizedFeed(_lastPreferences!);
      final existingIds = _items.map((e) => e.id).toSet();
      final newItems = fresh.where((e) => !existingIds.contains(e.id)).toList();
      if (newItems.isEmpty) return;
      _items = [...newItems, ..._items];
      notifyListeners();
    } catch (_) {
      // Ignore; keep existing state
    }
  }

  /// Clear feed (e.g. on logout). Next login will load fresh.
  void clearFeed() {
    _items = [];
    _lastPreferences = null;
    _error = null;
    notifyListeners();
  }

  /// Ensure feed has seed data (call once on first launch).
  Future<void> ensureSeedData() async {
    try {
      await _firestore.seedDefaultFeedItems();
    } catch (_) {
      // Ignore if already seeded
    }
  }
}
