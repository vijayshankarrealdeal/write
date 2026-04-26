import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:inkspacex/models/user_model.dart' as app;
import 'package:inkspacex/services/api/api_client.dart';
import 'package:inkspacex/services/storage_service.dart';

/// Auth service backed by the FastAPI backend.
class ApiAuthService {
  final ApiClient _client;
  final StorageService _storage;
  bool _googleSignInInitialized = false;

  ApiAuthService(this._client, this._storage);

  /// Login with email/password → returns tokens and user.
  Future<app.User> login(String email, String password) async {
    try {
      final response = await _client.post('/api/auth/login', data: {
        'email': email,
        'password': password,
      });
      await _saveTokens(response.data);
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

  /// Google Sign-In → sends ID token to backend for verification.
  Future<app.User> signInWithGoogle() async {
    String? idToken;

    if (kIsWeb) {
      // On web, use Google Sign-In popup
      await _ensureGoogleSignInInitialized();
      final account = await GoogleSignIn.instance
          .authenticate(scopeHint: ['email', 'profile']);
      idToken = account.authentication.idToken;
    } else {
      // Native: use google_sign_in
      await _ensureGoogleSignInInitialized();
      final account = await GoogleSignIn.instance
          .authenticate(scopeHint: ['email', 'profile']);
      idToken = account.authentication.idToken;
    }

    if (idToken == null) throw Exception('Failed to get Google ID token');

    final response = await _client.post('/api/auth/google', data: {
      'id_token': idToken,
    });
    await _saveTokens(response.data);
    return _fetchMe();
  }

  /// Restore session from stored tokens.
  Future<app.User?> restoreSession() async {
    final token = _storage.getAuthToken();
    if (token == null || token.isEmpty) return null;

    try {
      return await _fetchMe();
    } catch (e) {
      // Token expired — try refresh
      final refreshToken = _storage.getRefreshToken();
      if (refreshToken != null && refreshToken.isNotEmpty) {
        try {
          final response = await _client.post('/api/auth/refresh', data: {
            'refresh_token': refreshToken,
          });
          await _saveTokens(response.data);
          return await _fetchMe();
        } catch (_) {
          await _storage.clearAuth();
          return null;
        }
      }
      await _storage.clearAuth();
      return null;
    }
  }

  /// Request password reset email.
  Future<void> forgotPassword(String email) async {
    await _client.post('/api/auth/reset-password', data: {'email': email});
  }

  /// Sign out.
  Future<void> logout() async {
    if (!kIsWeb) {
      try {
        await GoogleSignIn.instance.signOut();
      } catch (_) {}
    }
    await _storage.clearAuth();
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

  Future<void> _ensureGoogleSignInInitialized() async {
    if (_googleSignInInitialized) return;
    await GoogleSignIn.instance.initialize();
    _googleSignInInitialized = true;
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
