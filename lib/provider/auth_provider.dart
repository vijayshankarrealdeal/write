import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:writer/models/user_model.dart' as app;
import 'package:writer/models/user_preferences_model.dart';
import 'package:writer/services/firestore_service.dart';
import 'package:writer/services/storage_service.dart';

class AuthProvider extends ChangeNotifier {
  final StorageService _storage;
  final FirestoreService _firestore = FirestoreService();

  bool _isAuthenticated = false;
  app.User? _currentUser;
  bool _isLoading = false;
  bool _authStateKnown = false;
  bool _isRestoringSession = false;
  Timer? _authTimeout;

  AuthProvider(this._storage) {
    _initAuthListener();
    // Failsafe: if Firebase doesn't emit within 3s, assume not logged in
    _authTimeout = Timer(const Duration(seconds: 3), () {
      if (!_authStateKnown) {
        _authStateKnown = true;
        notifyListeners();
      }
    });
  }

  bool get isAuthenticated => _isAuthenticated;
  bool get isOnboardingComplete => _currentUser?.onboardingComplete ?? false;
  app.User? get currentUser => _currentUser;
  bool get isLoading => _isLoading;

  /// True once Firebase has reported auth state (logged in or not).
  bool get authStateKnown => _authStateKnown;

  /// True while restoring session (syncing user from Firebase on app start).
  bool get isRestoringSession => _isRestoringSession;

  void _initAuthListener() {
    firebase_auth.FirebaseAuth.instance.authStateChanges().listen((
      firebase_auth.User? fbUser,
    ) async {
      _authTimeout?.cancel();
      _authTimeout = null;
      if (fbUser != null) {
        _authStateKnown = true;
        _isRestoringSession = true;
        notifyListeners();
        try {
          await _syncUserFromFirebase(fbUser);
        } finally {
          _isRestoringSession = false;
        }
      } else {
        _currentUser = null;
        _isAuthenticated = false;
        _authStateKnown = true;
        _isRestoringSession = false;
        await _storage.clearAuth();
      }
      notifyListeners();
    });
  }

  Future<void> _syncUserFromFirebase(firebase_auth.User fbUser) async {
    app.User? user = await _firestore.getUser(fbUser.uid);
    final storedPrefs = _storage.getOnboardingPreferences();
    final prefs = storedPrefs != null
        ? UserPreferences.fromJson(storedPrefs)
        : null;

    if (user == null) {
      user = app.User(
        id: fbUser.uid,
        email: fbUser.email ?? '',
        name: fbUser.displayName ?? fbUser.email?.split('@').first ?? 'User',
        photoUrl: fbUser.photoURL,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        preferences: prefs ?? const UserPreferences(),
      );
      await _firestore.setUser(user);
      if (storedPrefs != null) await _storage.clearOnboardingPreferences();
    } else if (prefs != null &&
        (prefs.preferredGenres.isNotEmpty ||
            prefs.preferredWritingTypes.isNotEmpty ||
            prefs.interests.isNotEmpty)) {
      await _firestore.updateUserPreferences(user.id, prefs);
      user = user.copyWith(preferences: prefs);
      await _storage.clearOnboardingPreferences();
    }
    _currentUser = user;
    _isAuthenticated = true;
    await _storage.saveAuthToken(await fbUser.getIdToken() ?? '');
    await _storage.saveUser(user.toJson());
  }

  Future<void> login(String email, String password) async {
    _isLoading = true;
    notifyListeners();
    try {
      final cred = await firebase_auth.FirebaseAuth.instance
          .signInWithEmailAndPassword(email: email, password: password);
      if (cred.user != null) await _syncUserFromFirebase(cred.user!);
    } on firebase_auth.FirebaseAuthException catch (e) {
      _isLoading = false;
      notifyListeners();
      throw Exception(_authErrorMessage(e.code));
    } catch (e) {
      _isLoading = false;
      notifyListeners();
      rethrow;
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<void> signup(String name, String email, String password) async {
    _isLoading = true;
    notifyListeners();
    try {
      final cred = await firebase_auth.FirebaseAuth.instance
          .createUserWithEmailAndPassword(email: email, password: password);
      if (cred.user != null) {
        await cred.user!.updateDisplayName(name);
        await _syncUserFromFirebase(cred.user!);
      }
    } on firebase_auth.FirebaseAuthException catch (e) {
      _isLoading = false;
      notifyListeners();
      throw Exception(_authErrorMessage(e.code));
    } catch (e) {
      _isLoading = false;
      notifyListeners();
      rethrow;
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<void> signInWithGoogle() async {
    _isLoading = true;
    notifyListeners();
    try {
      final GoogleSignIn googleSignIn = GoogleSignIn(
        clientId:
            "769888184610-8dbhulriuoccftjfk4jj1ke0to3fohnu.apps.googleusercontent.com",
        scopes: ['email', 'profile'],
      );

      final GoogleSignInAccount? googleUser = await googleSignIn.signIn();
      if (googleUser == null) {
        _isLoading = false;
        notifyListeners();
        return; // User cancelled
      }

      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;
      final credential = firebase_auth.GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      final cred = await firebase_auth.FirebaseAuth.instance
          .signInWithCredential(credential);
      if (cred.user != null) await _syncUserFromFirebase(cred.user!);
    } on firebase_auth.FirebaseAuthException catch (e) {
      _isLoading = false;
      notifyListeners();
      throw Exception(_authErrorMessage(e.code));
    } catch (e) {
      _isLoading = false;
      notifyListeners();
      rethrow;
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<void> logout() async {
    try {
      await GoogleSignIn().signOut();
    } catch (_) {}
    await firebase_auth.FirebaseAuth.instance.signOut();
    await _storage.clearAuth();
    _isAuthenticated = false;
    _currentUser = null;
    notifyListeners();
  }

  Future<void> forgotPassword(String email) async {
    _isLoading = true;
    notifyListeners();
    try {
      await firebase_auth.FirebaseAuth.instance.sendPasswordResetEmail(
        email: email,
      );
    } on firebase_auth.FirebaseAuthException catch (e) {
      _isLoading = false;
      notifyListeners();
      throw Exception(_authErrorMessage(e.code));
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
    await _firestore.completeOnboarding(_currentUser!.id, preferences);
    _currentUser = _currentUser!.copyWith(
      onboardingComplete: true,
      preferences: preferences,
    );
    await _storage.saveUser(_currentUser!.toJson());
    notifyListeners();
  }

  Future<void> saveOnboardingPreferences(UserPreferences preferences) async {
    if (_currentUser == null) return;
    await _firestore.updateUserPreferences(_currentUser!.id, preferences);
    _currentUser = _currentUser!.copyWith(preferences: preferences);
    notifyListeners();
  }

  Future<void> toggleLike(String feedItemId) async {
    if (_currentUser == null) return;
    final liked = _currentUser!.likes.contains(feedItemId);
    if (liked) {
      await _firestore.removeLike(_currentUser!.id, feedItemId);
      _currentUser = _currentUser!.copyWith(
        likes: _currentUser!.likes.where((id) => id != feedItemId).toList(),
      );
    } else {
      await _firestore.addLike(_currentUser!.id, feedItemId);
      _currentUser = _currentUser!.copyWith(
        likes: [..._currentUser!.likes, feedItemId],
      );
    }
    notifyListeners();
  }

  String _authErrorMessage(String code) {
    switch (code) {
      case 'user-not-found':
      case 'invalid-credential':
        return 'Invalid email or password.';
      case 'wrong-password':
        return 'Invalid password.';
      case 'email-already-in-use':
        return 'An account already exists with this email.';
      case 'weak-password':
        return 'Password is too weak.';
      case 'invalid-email':
        return 'Invalid email address.';
      case 'user-disabled':
        return 'This account has been disabled.';
      case 'too-many-requests':
        return 'Too many attempts. Please try again later.';
      case 'operation-not-allowed':
        return 'This sign-in method is not enabled.';
      default:
        return 'Authentication failed. Please try again.';
    }
  }
}
