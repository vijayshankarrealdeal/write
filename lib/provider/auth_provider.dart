import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:inkspacex/models/user_model.dart' as app;
import 'package:inkspacex/models/user_preferences_model.dart';
import 'package:inkspacex/services/api/api_auth_service.dart';
import 'package:inkspacex/services/api/api_client.dart';
import 'package:inkspacex/services/api/api_data_service.dart';
import 'package:inkspacex/services/api/api_storage_service.dart';
import 'package:inkspacex/services/storage_service.dart';
import 'package:inkspacex/provider/feed_provider.dart';
import 'package:inkspacex/services/app_log.dart';
import 'package:inkspacex/services/gemini_service.dart';

class AuthProvider extends ChangeNotifier {
  final StorageService _storage;
  late final ApiClient _apiClient;
  late final ApiAuthService _authService;
  late final ApiDataService _dataService;
  late final ApiStorageService _storageService;

  bool _isAuthenticated = false;
  app.User? _currentUser;
  bool _isLoading = false;
  bool _authStateKnown = false;
  bool _isRestoringSession = false;
  String? _pendingDeepLink;

  /// Expose the API services for use by other providers.
  ApiClient get apiClient => _apiClient;
  ApiDataService get dataService => _dataService;
  ApiStorageService get storageService => _storageService;

  AuthProvider(this._storage) {
    _apiClient = ApiClient(_storage);
    _authService = ApiAuthService(_apiClient, _storage);
    _dataService = ApiDataService(_apiClient);
    _storageService = ApiStorageService(_apiClient);
    GeminiService().init(_apiClient);
    _restoreSession();
  }

  bool get isAuthenticated => _isAuthenticated;
  bool get isOnboardingComplete => _currentUser?.onboardingComplete ?? false;
  app.User? get currentUser => _currentUser;
  bool get isLoading => _isLoading;

  /// True once Firebase has reported auth state (logged in or not).
  bool get authStateKnown => _authStateKnown;

  /// True while restoring session (syncing user from Firebase on app start).
  bool get isRestoringSession => _isRestoringSession;

  /// Stores the URL the user was trying to reach before being sent to login.
  String? get pendingDeepLink => _pendingDeepLink;
  void setPendingDeepLink(String? url) => _pendingDeepLink = url;

  /// Returns and clears the pending deep link (consume once after login).
  String? consumePendingDeepLink() {
    final link = _pendingDeepLink;
    _pendingDeepLink = null;
    return link;
  }

  /// Restore session from stored JWT tokens on app start.
  Future<void> _restoreSession() async {
    _isRestoringSession = true;
    notifyListeners();

    try {
      final user = await _authService.restoreSession();
      if (user != null) {
        _currentUser = user;
        _isAuthenticated = true;
        log.i('[auth] Session restored (uid=${user.id})');
        await _storage.saveUser(user.toJson());

        // Apply any pending onboarding prefs
        final storedPrefs = _storage.getOnboardingPreferences();
        if (storedPrefs != null) {
          final prefs = UserPreferences.fromJson(storedPrefs);
          if (prefs.preferredGenres.isNotEmpty ||
              prefs.preferredWritingTypes.isNotEmpty ||
              prefs.interests.isNotEmpty) {
            await _dataService.updateUserPreferences(user.id, prefs);
            _currentUser = _currentUser!.copyWith(preferences: prefs);
            await _storage.clearOnboardingPreferences();
          }
        }
      } else {
        _currentUser = null;
        _isAuthenticated = false;
      }
    } catch (e, st) {
      log.e('[auth] Session restore failed', error: e, stackTrace: st);
      _currentUser = null;
      _isAuthenticated = false;
    } finally {
      _authStateKnown = true;
      _isRestoringSession = false;
      notifyListeners();
    }
  }

  Future<void> login(String email, String password) async {
    _isLoading = true;
    notifyListeners();
    try {
      final user = await _authService.login(email, password);
      _currentUser = user;
      _isAuthenticated = true;
      log.i('[auth] Login succeeded (uid=${user.id})');
      await _storage.saveUser(user.toJson());
    } catch (e, st) {
      _isLoading = false;
      notifyListeners();
      log.e('[auth] Login failed', error: e, stackTrace: st);
      rethrow;
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<void> signup(String name, String email, String password) async {
    _isLoading = true;
    notifyListeners();
    try {
      final user = await _authService.signup(name, email, password);
      _currentUser = user;
      _isAuthenticated = true;
      log.i('[auth] Signup succeeded (uid=${user.id})');
      await _storage.saveUser(user.toJson());
    } catch (e, st) {
      _isLoading = false;
      notifyListeners();
      log.e('[auth] Signup failed', error: e, stackTrace: st);
      rethrow;
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<void> signInWithGoogle() async {
    _isLoading = true;
    notifyListeners();
    try {
      final user = await _authService.signInWithGoogle();
      _currentUser = user;
      _isAuthenticated = true;
      log.i('[auth] Google sign-in succeeded (uid=${user.id})');
      await _storage.saveUser(user.toJson());
    } catch (e, st) {
      _isLoading = false;
      notifyListeners();
      log.e('[auth] Google sign-in failed', error: e, stackTrace: st);
      rethrow;
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<void> logout() async {
    log.i('[auth] Logout');
    await _authService.logout();
    _isAuthenticated = false;
    _currentUser = null;
    notifyListeners();
  }

  Future<void> forgotPassword(String email) async {
    _isLoading = true;
    notifyListeners();
    try {
      await _authService.forgotPassword(email);
    } catch (e) {
      _isLoading = false;
      notifyListeners();
      rethrow;
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<void> completeOnboarding(UserPreferences preferences) async {
    if (_currentUser == null) return;

    // Optimistic: update local state + notify router immediately so navigation
    // happens even if Firestore's Future hangs (known web SDK quirk).
    _currentUser = _currentUser!.copyWith(
      onboardingComplete: true,
      preferences: preferences,
    );
    notifyListeners();

    // Persist in the background — errors logged, state already committed.
    unawaited(_storage.saveUser(_currentUser!.toJson()));
    unawaited(
      _dataService.completeOnboarding(_currentUser!.id, preferences).catchError(
        (e, st) {
          log.e('[auth] completeOnboarding failed', error: e, stackTrace: st);
        },
      ),
    );
  }

  Future<void> saveOnboardingPreferences(UserPreferences preferences) async {
    if (_currentUser == null) return;
    await _dataService.updateUserPreferences(_currentUser!.id, preferences);
    _currentUser = _currentUser!.copyWith(preferences: preferences);
    notifyListeners();
  }

  Future<void> toggleLike(
    String feedItemId, {
    FeedProvider? feedProvider,
  }) async {
    if (_currentUser == null) return;
    final liked = _currentUser!.likes.contains(feedItemId);

    // Optimistic update: update UI immediately
    if (liked) {
      _currentUser = _currentUser!.copyWith(
        likes: _currentUser!.likes.where((id) => id != feedItemId).toList(),
      );
      feedProvider?.updateItemLikeCount(feedItemId, increment: false);
    } else {
      _currentUser = _currentUser!.copyWith(
        likes: [..._currentUser!.likes, feedItemId],
      );
      feedProvider?.updateItemLikeCount(feedItemId, increment: true);
    }
    notifyListeners();

    // Fire to Firebase in background; revert on failure
    try {
      if (liked) {
        await _dataService.removeLike(_currentUser!.id, feedItemId);
      } else {
        await _dataService.addLike(_currentUser!.id, feedItemId);
      }
    } catch (_) {
      // Revert optimistic update
      if (liked) {
        _currentUser = _currentUser!.copyWith(
          likes: [..._currentUser!.likes, feedItemId],
        );
        feedProvider?.updateItemLikeCount(feedItemId, increment: true);
      } else {
        _currentUser = _currentUser!.copyWith(
          likes: _currentUser!.likes.where((id) => id != feedItemId).toList(),
        );
        feedProvider?.updateItemLikeCount(feedItemId, increment: false);
      }
      notifyListeners();
    }
  }

  Future<void> toggleSave(String feedItemId) async {
    if (_currentUser == null) return;
    final saved = _currentUser!.savedPosts.contains(feedItemId);

    // Optimistic update
    if (saved) {
      _currentUser = _currentUser!.copyWith(
        savedPosts: _currentUser!.savedPosts
            .where((id) => id != feedItemId)
            .toList(),
      );
    } else {
      _currentUser = _currentUser!.copyWith(
        savedPosts: [..._currentUser!.savedPosts, feedItemId],
      );
    }
    notifyListeners();

    try {
      if (saved) {
        await _dataService.removeSave(_currentUser!.id, feedItemId);
      } else {
        await _dataService.addSave(_currentUser!.id, feedItemId);
      }
    } catch (_) {
      // Revert
      if (saved) {
        _currentUser = _currentUser!.copyWith(
          savedPosts: [..._currentUser!.savedPosts, feedItemId],
        );
      } else {
        _currentUser = _currentUser!.copyWith(
          savedPosts: _currentUser!.savedPosts
              .where((id) => id != feedItemId)
              .toList(),
        );
      }
      notifyListeners();
    }
  }

  Future<void> toggleSectionBookmark(
    String feedItemId,
    int sectionIndex,
  ) async {
    if (_currentUser == null) return;
    final key = '${feedItemId}_$sectionIndex';
    final bookmarked = _currentUser!.sectionBookmarks.contains(key);

    if (bookmarked) {
      _currentUser = _currentUser!.copyWith(
        sectionBookmarks: _currentUser!.sectionBookmarks
            .where((k) => k != key)
            .toList(),
      );
    } else {
      _currentUser = _currentUser!.copyWith(
        sectionBookmarks: [..._currentUser!.sectionBookmarks, key],
      );
    }
    notifyListeners();

    try {
      if (bookmarked) {
        await _dataService.removeSectionBookmark(_currentUser!.id, key);
      } else {
        await _dataService.addSectionBookmark(_currentUser!.id, key);
      }
    } catch (_) {
      if (bookmarked) {
        _currentUser = _currentUser!.copyWith(
          sectionBookmarks: [..._currentUser!.sectionBookmarks, key],
        );
      } else {
        _currentUser = _currentUser!.copyWith(
          sectionBookmarks: _currentUser!.sectionBookmarks
              .where((k) => k != key)
              .toList(),
        );
      }
      notifyListeners();
    }
  }

  Future<void> toggleFavorite(String feedItemId) async {
    if (_currentUser == null) return;
    final favorited = _currentUser!.favoritePosts.contains(feedItemId);

    // Optimistic update
    if (favorited) {
      _currentUser = _currentUser!.copyWith(
        favoritePosts: _currentUser!.favoritePosts
            .where((id) => id != feedItemId)
            .toList(),
      );
    } else {
      _currentUser = _currentUser!.copyWith(
        favoritePosts: [..._currentUser!.favoritePosts, feedItemId],
      );
    }
    notifyListeners();

    try {
      if (favorited) {
        await _dataService.removeFavorite(_currentUser!.id, feedItemId);
      } else {
        await _dataService.addFavorite(_currentUser!.id, feedItemId);
      }
    } catch (_) {
      // Revert
      if (favorited) {
        _currentUser = _currentUser!.copyWith(
          favoritePosts: [..._currentUser!.favoritePosts, feedItemId],
        );
      } else {
        _currentUser = _currentUser!.copyWith(
          favoritePosts: _currentUser!.favoritePosts
              .where((id) => id != feedItemId)
              .toList(),
        );
      }
      notifyListeners();
    }
  }

  Future<void> updateProfilePhoto(Uint8List bytes) async {
    if (_currentUser == null) return;
    final url = await _storageService.uploadProfilePhoto(
      _currentUser!.id,
      bytes,
    );
    _currentUser = _currentUser!.copyWith(photoUrl: url);
    await _dataService.setUser(_currentUser!);
    await _storage.saveUser(_currentUser!.toJson());
    notifyListeners();
  }

  Future<void> updateProfile({
    required String name,
    required String email,
  }) async {
    if (_currentUser == null) return;
    _currentUser = _currentUser!.copyWith(
      name: name,
      email: email,
      updatedAt: DateTime.now(),
    );
    await _dataService.setUser(_currentUser!);
    await _storage.saveUser(_currentUser!.toJson());
    notifyListeners();
  }
}
