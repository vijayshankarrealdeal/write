import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:inkspacex/models/user_model.dart' as app;
import 'package:inkspacex/models/user_preferences_model.dart';
import 'package:inkspacex/services/analytics_service.dart';
import 'package:inkspacex/services/api/api_auth_service.dart';
import 'package:inkspacex/services/api/api_client.dart';
import 'package:inkspacex/services/api/api_data_service.dart';
import 'package:inkspacex/services/api/api_push_token_service.dart';
import 'package:inkspacex/services/api/api_realtime_service.dart';
import 'package:inkspacex/services/api/api_storage_service.dart';
import 'package:inkspacex/services/storage_service.dart';
import 'package:inkspacex/services/sync/outbox.dart';
import 'package:inkspacex/services/sync/outbox_drainer.dart';
import 'package:inkspacex/provider/feed_provider.dart';
import 'package:inkspacex/services/app_log.dart';
import 'package:inkspacex/services/gemini_service.dart';

class AuthProvider extends ChangeNotifier {
  final StorageService _storage;
  final Outbox _outbox;
  late final ApiClient _apiClient;
  late final ApiAuthService _authService;
  late final ApiDataService _dataService;
  late final ApiStorageService _storageService;
  // Recreated on logout so the next user starts with fresh sockets.
  late ApiRealtimeService _realtimeService;
  OutboxDrainer? _drainer;

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
  ApiRealtimeService get realtimeService => _realtimeService;
  ApiPushTokenService get pushTokenService => ApiPushTokenService(_apiClient);

  AuthProvider(this._storage, this._outbox) {
    _apiClient = ApiClient(_storage);
    _authService = ApiAuthService(_apiClient, _storage);
    _dataService = ApiDataService(_apiClient);
    _storageService = ApiStorageService(_apiClient);
    _realtimeService = ApiRealtimeService(_storage);
    _dataService.attachRealtime(_realtimeService);
    GeminiService().init(_apiClient);
    _restoreSession();
  }

  /// The OutboxDrainer is created downstream (in the provider tree); it
  /// hands itself back here so logout can give it a final kick before the
  /// auth token gets cleared.
  void attachDrainer(OutboxDrainer drainer) {
    _drainer = drainer;
  }

  /// Open the per-user sandbox for [uid]. Called on every successful
  /// login/restore so books and the outbox land in the right slot before
  /// the UI starts reading.
  Future<void> _openUserScope(String uid) async {
    _storage.setUserScope(uid);
    await _outbox.switchUser(uid);
  }

  /// Close the per-user sandbox without wiping it on disk — pending ops
  /// stay queued until the same user signs in again.
  Future<void> _closeUserScope() async {
    await _outbox.switchUser(null);
    _storage.setUserScope(null);
  }

  bool get isAuthenticated => _isAuthenticated;
  bool get isOnboardingComplete => _currentUser?.onboardingComplete ?? false;
  app.User? get currentUser => _currentUser;
  bool get isLoading => _isLoading;

  /// True once auth state is known (logged in or not).
  bool get authStateKnown => _authStateKnown;

  /// True while restoring session on app start.
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
        await _openUserScope(user.id);
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
    AnalyticsService.instance.track('auth_login_submitted', action: 'submit');
    try {
      final user = await _authService.login(email, password);
      await _openUserScope(user.id);
      _currentUser = user;
      _isAuthenticated = true;
      log.i('[auth] Login succeeded (uid=${user.id})');
      await _storage.saveUser(user.toJson());
      AnalyticsService.instance.setUserId(user.id);
      // Anchor event for backend identity stitching.
      AnalyticsService.instance
          .track('auth_login_succeeded', action: 'success', entityType: 'user', entityId: user.id);
    } catch (e, st) {
      _isLoading = false;
      notifyListeners();
      log.e('[auth] Login failed', error: e, stackTrace: st);
      AnalyticsService.instance.track('auth_login_failed', action: 'fail');
      rethrow;
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<void> signup(String name, String email, String password) async {
    _isLoading = true;
    notifyListeners();
    AnalyticsService.instance.track('auth_signup_submitted', action: 'submit');
    try {
      final user = await _authService.signup(name, email, password);
      await _openUserScope(user.id);
      _currentUser = user;
      _isAuthenticated = true;
      log.i('[auth] Signup succeeded (uid=${user.id})');
      await _storage.saveUser(user.toJson());
      AnalyticsService.instance.setUserId(user.id);
      AnalyticsService.instance.track(
        'signup_completed',
        action: 'success',
        entityType: 'user',
        entityId: user.id,
      );
    } catch (e, st) {
      _isLoading = false;
      notifyListeners();
      log.e('[auth] Signup failed', error: e, stackTrace: st);
      AnalyticsService.instance.track('auth_signup_failed', action: 'fail');
      rethrow;
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<void> signInWithGoogle() async {
    _isLoading = true;
    notifyListeners();
    AnalyticsService.instance.track('auth_google_clicked', action: 'click');
    try {
      final user = await _authService.signInWithGoogle();
      await _openUserScope(user.id);
      _currentUser = user;
      _isAuthenticated = true;
      log.i('[auth] Google sign-in succeeded (uid=${user.id})');
      await _storage.saveUser(user.toJson());
      AnalyticsService.instance.setUserId(user.id);
      AnalyticsService.instance.track(
        'auth_google_succeeded',
        action: 'success',
        entityType: 'user',
        entityId: user.id,
      );
    } catch (e, st) {
      _isLoading = false;
      notifyListeners();
      log.e('[auth] Google sign-in failed', error: e, stackTrace: st);
      AnalyticsService.instance.track('auth_google_failed', action: 'fail');
      rethrow;
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<void> logout() async {
    log.i('[auth] Logout');
    AnalyticsService.instance.track('auth_logout', action: 'click');

    // Best-effort final drain while the auth token is still valid. Bounded
    // so a slow network can't block the sign-out flow indefinitely; any ops
    // that don't make it in time stay queued in the user's sandbox and
    // resume on next sign-in as that user.
    final drainer = _drainer;
    if (drainer != null) {
      try {
        await drainer.drain().timeout(const Duration(seconds: 3));
      } catch (e) {
        log.w('[auth] pre-logout drain skipped: $e');
      }
    }

    // Tear down any open realtime channels — they were authenticated as
    // the user we're signing out, so reusing them after sign-in would
    // leak the previous session's stream.
    await _realtimeService.dispose();
    _realtimeService = ApiRealtimeService(_storage);
    _dataService.attachRealtime(_realtimeService);
    await _authService.logout();
    // Drop any onboarding-prefs blob staged for the previous session — otherwise
    // it gets replayed onto the next user that signs in on this device.
    await _storage.clearOnboardingPreferences();
    // Close the per-user sandbox last so the drainer can never read or write
    // the previous user's box under the new (or absent) auth token.
    await _closeUserScope();
    _isAuthenticated = false;
    _currentUser = null;
    AnalyticsService.instance.setUserId(null);
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
    AnalyticsService.instance.track(
      'onboarding_completed',
      action: 'success',
      entityType: 'user',
      entityId: _currentUser!.id,
      properties: {
        'genre_count': preferences.preferredGenres.length,
        'writing_type_count': preferences.preferredWritingTypes.length,
        'interest_count': preferences.interests.length,
      },
    );

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
    AnalyticsService.instance.track(
      liked ? 'post_unliked' : 'post_liked',
      action: 'click',
      entityType: 'post',
      entityId: feedItemId,
    );

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

    // Fire to backend in background; revert on failure
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
    AnalyticsService.instance.track(
      favorited ? 'post_unfavorited' : 'post_favorited',
      action: 'click',
      entityType: 'post',
      entityId: feedItemId,
    );

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
    final result = await _storageService.uploadProfilePhoto(
      _currentUser!.id,
      bytes,
    );
    _currentUser = _currentUser!.copyWith(
      photoUrl: result.url,
      photoMeta: result.meta,
    );
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
