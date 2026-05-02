import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import 'package:inkspacex/models/user_model.dart' as app;
import 'package:inkspacex/services/api/api_client.dart';
import 'package:inkspacex/services/storage_service.dart';
import 'package:inkspacex/web_utils_stub.dart'
    if (dart.library.html) 'package:inkspacex/web_utils.dart' as web_utils;

/// Auth service backed by the FastAPI backend.
class ApiAuthService {
  final ApiClient _client;
  final StorageService _storage;
  static const _uuid = Uuid();

  // How long to wait for the user to finish the Google flow in the system
  // browser before we give up. Backend's pending-token TTL is 5min — match it.
  static const Duration _googlePollTimeout = Duration(minutes: 5);
  static const Duration _googlePollInterval = Duration(seconds: 2);

  ApiAuthService(this._client, this._storage);

  /// Login with email/password → returns tokens and user.
  Future<app.User> login(String email, String password) async {
    try {
      final response = await _client.post('/api/auth/login', data: {
        'email': email,
        'password': password,
      });
      await _saveTokens(response.data);
      // Stash creds for silent re-login if both tokens later expire.
      await _storage.saveCredentials(email, password);
      return _fetchMe();
    } on ApiException catch (e) {
      throw _humanizeApiError(e, fallback: 'Login failed');
    }
  }

  /// Register with email/password/name → returns tokens and user.
  Future<app.User> signup(String name, String email, String password) async {
    try {
      final response = await _client.post('/api/auth/register', data: {
        'email': email,
        'password': password,
        'name': name,
      });
      await _saveTokens(response.data);
      await _storage.saveCredentials(email, password);
      return _fetchMe();
    } on ApiException catch (e) {
      throw _humanizeApiError(e, fallback: 'Signup failed');
    }
  }

  /// Turn raw ApiException into a user-friendly message.
  /// Full stack traces still flow to the crash reporter via the caller's catch block.
  Exception _humanizeApiError(ApiException e, {required String fallback}) {
    final data = e.data;
    if (data is Map && data['detail'] is String) {
      return Exception(data['detail']);
    }
    if (e.type == ApiErrorType.timeout) {
      return Exception('Connection timed out. Please try again.');
    }
    if (e.type == ApiErrorType.connection) {
      return Exception('Cannot reach the server. Check your internet connection.');
    }
    return Exception(fallback);
  }

  /// Google Sign-In — fully server-side. The app never talks to Google.
  ///
  /// - Web: full-page redirect to `/api/auth/google/start`. The backend does
  ///   the OAuth dance and bounces the browser back to the SPA with tokens
  ///   in the URL fragment (consumed in main.dart on next boot).
  /// - Native: opens the same backend URL in the system browser via
  ///   `url_launcher`, then polls `/api/auth/google/session/{id}` until the
  ///   backend has parked the freshly-minted tokens against that id.
  Future<app.User> signInWithGoogle() async {
    if (kIsWeb) {
      web_utils.redirectToGoogleSignIn(ApiClient.baseUrl);
      // Page navigates away; this future never resolves on the unloaded page.
      return Completer<app.User>().future;
    }

    final sessionId = _uuid.v4();
    final startUrl = Uri.parse(
      '${ApiClient.baseUrl}/api/auth/google/start?session_id=$sessionId',
    );

    // Mobile: Chrome Custom Tabs / SFSafariViewController keeps the user in
    // our app's task. Desktop: in-app web view isn't supported, fall back to
    // the system browser. Web is handled above.
    final isMobile = defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final mode =
        isMobile ? LaunchMode.inAppBrowserView : LaunchMode.externalApplication;

    final launched = await launchUrl(startUrl, mode: mode);
    if (!launched) {
      throw Exception('Could not open browser for Google sign-in');
    }

    try {
      final tokens = await _pollForGoogleTokens(sessionId);
      await _saveTokens(tokens);
      return await _fetchMe();
    } finally {
      // Auto-dismiss the OAuth tab once we're done — success or failure —
      // so the user lands back on the app instead of staring at a stale page.
      if (isMobile) {
        await closeInAppWebView();
      }
    }
  }

  /// Polls the backend's session endpoint. The endpoint returns 404 until the
  /// user finishes the OAuth flow in the browser, then 200 with tokens.
  Future<Map<String, dynamic>> _pollForGoogleTokens(String sessionId) async {
    final deadline = DateTime.now().add(_googlePollTimeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(_googlePollInterval);
      try {
        final response =
            await _client.get('/api/auth/google/session/$sessionId');
        if (response.data is Map<String, dynamic>) {
          return response.data as Map<String, dynamic>;
        }
      } on ApiException catch (e) {
        // 404 = "user hasn't finished yet". Connection / timeout errors are
        // transient (e.g. socket closed by proxy between polls, app briefly
        // backgrounded behind the OAuth browser). 5xx is also worth retrying.
        // Only bail on real client-side failures (4xx other than 404).
        if (e.statusCode == 404) {
          continue;
        }
        if (e.type == ApiErrorType.connection ||
            e.type == ApiErrorType.timeout) {
          continue;
        }
        if (e.statusCode != null && e.statusCode! >= 500) {
          continue;
        }
        rethrow;
      }
    }
    throw Exception('Google sign-in timed out. Please try again.');
  }

  /// Restore session silently. Order: stored access token → refresh token →
  /// stashed email/password. The last one rescues users whose refresh token
  /// also expired (long offline / server key rotation) so they don't get
  /// dumped on the login screen unnecessarily.
  Future<app.User?> restoreSession() async {
    final token = _storage.getAuthToken();
    if (token != null && token.isNotEmpty) {
      try {
        return await _fetchMe();
      } catch (_) {
        // Fall through to refresh / cred fallback below.
      }
    }

    final refreshToken = _storage.getRefreshToken();
    if (refreshToken != null && refreshToken.isNotEmpty) {
      try {
        final response = await _client.post('/api/auth/refresh', data: {
          'refresh_token': refreshToken,
        });
        await _saveTokens(response.data);
        return await _fetchMe();
      } catch (_) {
        // Refresh failed — try saved credentials before giving up.
      }
    }

    final creds = await _storage.getCredentials();
    if (creds != null) {
      try {
        return await login(creds.email, creds.password);
      } catch (_) {
        // Creds no longer valid (password changed, account deleted) —
        // wipe them so we don't keep retrying on every cold start.
        await _storage.clearCredentials();
      }
    }

    await _storage.clearAuth();
    return null;
  }

  /// Request password reset email.
  Future<void> forgotPassword(String email) async {
    await _client.post('/api/auth/reset-password', data: {'email': email});
  }

  /// Sign out. The backend holds no Google session for us — auth is just our
  /// own JWTs — so all we do is clear local state. Stashed credentials get
  /// wiped too: an explicit logout is the user opting out of silent re-login.
  Future<void> logout() async {
    await _storage.clearAuth();
    await _storage.clearCredentials();
  }

  // -- Private helpers --

  Future<app.User> _fetchMe() async {
    final response = await _client.get('/api/auth/me');
    return _userFromJson(response.data);
  }

  Future<void> _saveTokens(Map<String, dynamic> data) async {
    await _storage.saveAuthToken(data['access_token']);
    await _storage.saveRefreshToken(data['refresh_token']);
  }

  app.User _userFromJson(Map<String, dynamic> json) {
    return app.User.fromJson({
      ...json,
      // Map backend field names to app model field names
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
}
