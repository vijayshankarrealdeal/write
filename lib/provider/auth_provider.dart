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
import 'package:inkspacex/services/desktop_tray_service.dart';
import 'package:inkspacex/services/home_widget_service.dart';
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
    // When the refresh endpoint rejects our refresh token, our session
    // is genuinely over. Force a clean logout so the router redirects
    // to /login and the user can re-auth — silently retrying with a
    // dead token would just spin up failed ops forever. We skip the
    // pre-logout drain because the drainer would 401 on every push;
    // the user's local edits stay in their outbox to retry after they
    // sign in again as the same user.
    _apiClient.onSessionExpired = _handleSessionExpired;
    _restoreSession();
  }

  bool _handlingSessionExpiry = false;
  Future<void> _handleSessionExpired() async {
    if (_handlingSessionExpiry) return;
    _handlingSessionExpiry = true;
    if (!_isAuthenticated && !_isRestoringSession) {
      _handlingSessionExpiry = false;
      return;
    }
    log.w('[auth] Session expired — forcing logout');
    try {
      await logout(drainFirst: false);
    } finally {
      _handlingSessionExpiry = false;
    }
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
      // Pre-emptive refresh: rotate the access token *before* the first
      // API call goes out, so a returning user never sees a 401 on
      // their opening request and never feels logged out. Mirrors the
      // Firebase SDK's "always-fresh token" model on top of our JWTs.
      await _apiClient.ensureFreshAccessToken();
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

  /// Public hook for the app-lifecycle observer: when the app comes
  /// back to the foreground (or the OS resumes us from suspend), refresh
  /// the access token if it's near expiry. Cheap when the token is still
  /// fresh — `ensureFreshAccessToken` returns immediately in that case.
  Future<void> refreshOnResume() async {
    if (!_isAuthenticated) return;
    try {
      await _apiClient.ensureFreshAccessToken();
    } catch (_) {
      // Network blips during resume are fine — the next API call will
      // trigger a refresh on demand. Don't surface this to the user.
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
      // Arm proactive refresh so the user stays logged in indefinitely
      // as long as they keep using the app — the token rotates on every
      // periodic tick and resets the refresh-token TTL clock.
      await _apiClient.ensureFreshAccessToken();
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
      await _apiClient.ensureFreshAccessToken();
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
      await _apiClient.ensureFreshAccessToken();
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

  /// Run a final drain and wait up to [timeout] for the queue to settle.
  /// Caller (typically the logout dialog) passes a generous timeout when
  /// the user explicitly chose "wait for sync"; pass a short one for
  /// "sign out anyway".
  Future<void> drainBeforeLogout({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final drainer = _drainer;
    if (drainer == null) return;
    try {
      await drainer.drain().timeout(timeout);
    } catch (e) {
      log.w('[auth] pre-logout drain incomplete: $e');
    }
  }

  Future<void> logout({bool drainFirst = true}) async {
    log.i('[auth] Logout (drainFirst=$drainFirst)');
    AnalyticsService.instance.track('auth_logout', action: 'click');

    // Final drain while the auth token is still valid. The 30s ceiling is a
    // safety net — the logout dialog's "Sync now" path awaits drainBeforeLogout
    // with a longer/explicit timeout before calling logout(drainFirst:false),
    // so this branch only fires for legacy callers.
    if (drainFirst) {
      await drainBeforeLogout(timeout: const Duration(seconds: 30));
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
    // Wipe the home-screen widget / tray menu so the previous user's
    // draft titles don't linger on the OS surface after sign-out.
    unawaited(HomeWidgetService.instance.clear());
    unawaited(DesktopTrayService.instance.update(
      authorName: null,
      recentTitle: 'Sign in to InkSpaceX',
      recentId: '',
      bookCount: 0,
    ));
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

  /// Re-fetch the signed-in user from `/api/users/me` so per-user lists
  /// (likes, saved, reading list) reflect actions taken on other devices.
  /// Cheap to call on screen entry; safe under concurrent calls — the
  /// last response wins and a single notify fires.
  Future<void> refreshCurrentUser() async {
    final me = _currentUser;
    if (me == null) return;
    try {
      final fresh = await _dataService.getUser(me.id);
      if (fresh == null) return;
      // Preserve client-only fields the server doesn't echo back.
      _currentUser = fresh.copyWith(preferences: me.preferences);
      await _storage.saveUser(_currentUser!.toJson());
      notifyListeners();
    } catch (_) {
      // Network blips are silent — UI keeps the last-known list.
    }
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
    String? bio,
    bool clearBio = false,
    Map<String, String>? socialLinks,
  }) async {
    if (_currentUser == null) return;
    _currentUser = _currentUser!.copyWith(
      name: name,
      email: email,
      bio: bio,
      clearBio: clearBio,
      socialLinks: socialLinks,
      updatedAt: DateTime.now(),
    );
    await _dataService.setUser(_currentUser!);
    await _storage.saveUser(_currentUser!.toJson());
    notifyListeners();
  }
}
