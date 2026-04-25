import 'package:flutter/foundation.dart';
import 'package:inkspacex/models/bookshelf_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/services/api/api_data_service.dart';

class BookshelfProvider extends ChangeNotifier {
  final AuthProvider _auth;
  ApiDataService get _dataService => _auth.dataService;

  BookshelfProvider(this._auth) {
    _auth.addListener(_onAuthChanged);
    if (_auth.isAuthenticated) load();
  }

  List<Bookshelf> _shelves = [];
  bool _loading = false;
  bool _loaded = false;

  List<Bookshelf> get shelves => _shelves;
  bool get loading => _loading;
  bool get loaded => _loaded;

  String? get _userId => _auth.currentUser?.id;

  void _onAuthChanged() {
    if (!_auth.isAuthenticated) {
      _shelves = [];
      _loaded = false;
      notifyListeners();
    }
  }

  Future<void> load({bool force = false}) async {
    final userId = _userId;
    if (userId == null) return;
    if (_loaded && !force) return;
    _loading = true;
    notifyListeners();
    try {
      _shelves = await _dataService.getBookshelves(userId);
      _loaded = true;
    } catch (e) {
      debugPrint('[BookshelfProvider] load error: $e');
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Bookshelf? byId(String id) {
    for (final s in _shelves) {
      if (s.id == id) return s;
    }
    return null;
  }

  Future<Bookshelf?> create({
    required String name,
    String description = '',
    bool isPrivate = false,
  }) async {
    final userId = _userId;
    if (userId == null) return null;
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final now = DateTime.now();
    final shelf = Bookshelf(
      id: id,
      name: name,
      description: description,
      isPrivate: isPrivate,
      createdAt: now,
      updatedAt: now,
    );
    // Optimistic insert
    _shelves = [shelf, ..._shelves];
    notifyListeners();
    try {
      await _dataService.createBookshelf(userId, shelf);
      return shelf;
    } catch (e) {
      debugPrint('[BookshelfProvider] create error: $e');
      _shelves = _shelves.where((s) => s.id != id).toList();
      notifyListeners();
      return null;
    }
  }

  Future<void> update(
    String bookshelfId, {
    String? name,
    String? description,
    bool? isPrivate,
    String? coverImageUrl,
  }) async {
    final userId = _userId;
    if (userId == null) return;
    final idx = _shelves.indexWhere((s) => s.id == bookshelfId);
    if (idx == -1) return;
    final prev = _shelves[idx];
    final next = prev.copyWith(
      name: name,
      description: description,
      isPrivate: isPrivate,
      coverImageUrl: coverImageUrl,
      updatedAt: DateTime.now(),
    );
    _shelves = [..._shelves]..[idx] = next;
    notifyListeners();
    try {
      await _dataService.updateBookshelf(
        userId,
        bookshelfId,
        name: name,
        description: description,
        isPrivate: isPrivate,
        coverImageUrl: coverImageUrl,
      );
    } catch (e) {
      debugPrint('[BookshelfProvider] update error: $e');
      _shelves = [..._shelves]..[idx] = prev;
      notifyListeners();
    }
  }

  Future<void> delete(String bookshelfId) async {
    final userId = _userId;
    if (userId == null) return;
    final prev = _shelves;
    _shelves = _shelves.where((s) => s.id != bookshelfId).toList();
    notifyListeners();
    try {
      await _dataService.deleteBookshelf(userId, bookshelfId);
    } catch (e) {
      debugPrint('[BookshelfProvider] delete error: $e');
      _shelves = prev;
      notifyListeners();
    }
  }

  Future<void> addItems(String bookshelfId, List<String> feedItemIds) async {
    final userId = _userId;
    if (userId == null || feedItemIds.isEmpty) return;
    final idx = _shelves.indexWhere((s) => s.id == bookshelfId);
    if (idx == -1) return;
    final prev = _shelves[idx];
    final existing = prev.itemIds.toSet();
    final merged = [
      ...prev.itemIds,
      ...feedItemIds.where((id) => !existing.contains(id)),
    ];
    _shelves = [..._shelves]
      ..[idx] = prev.copyWith(itemIds: merged, updatedAt: DateTime.now());
    notifyListeners();
    try {
      await _dataService.addItemsToBookshelf(userId, bookshelfId, feedItemIds);
    } catch (e) {
      debugPrint('[BookshelfProvider] addItems error: $e');
      _shelves = [..._shelves]..[idx] = prev;
      notifyListeners();
    }
  }

  Future<void> removeItem(String bookshelfId, String feedItemId) async {
    final userId = _userId;
    if (userId == null) return;
    final idx = _shelves.indexWhere((s) => s.id == bookshelfId);
    if (idx == -1) return;
    final prev = _shelves[idx];
    _shelves = [..._shelves]
      ..[idx] = prev.copyWith(
        itemIds: prev.itemIds.where((id) => id != feedItemId).toList(),
        updatedAt: DateTime.now(),
      );
    notifyListeners();
    try {
      await _dataService.removeItemFromBookshelf(
        userId,
        bookshelfId,
        feedItemId,
      );
    } catch (e) {
      debugPrint('[BookshelfProvider] removeItem error: $e');
      _shelves = [..._shelves]..[idx] = prev;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    super.dispose();
  }
}
