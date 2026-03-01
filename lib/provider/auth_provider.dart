import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:writer/models/user_model.dart';
import 'package:writer/services/storage_service.dart';

class AuthProvider extends ChangeNotifier {
  final StorageService _storage;
  bool _isAuthenticated = false;
  User? _currentUser;
  bool _isLoading = false;

  AuthProvider(this._storage) {
    _checkAuthStatus();
  }

  bool get isAuthenticated => _isAuthenticated;
  bool get isOnboardingComplete => _storage.isOnboardingComplete();
  User? get currentUser => _currentUser;
  bool get isLoading => _isLoading;

  void _checkAuthStatus() {
    final token = _storage.getAuthToken();
    if (token != null) {
      final userJson = _storage.getUser();
      if (userJson != null) {
        _currentUser = User.fromJson(userJson);
        _isAuthenticated = true;
      }
    }
    notifyListeners();
  }

  Future<void> login(String email, String password) async {
    _isLoading = true;
    notifyListeners();
    await Future.delayed(const Duration(seconds: 2)); // Simulate network

    if (email.isNotEmpty && password.length >= 6) {
      _isAuthenticated = true;
      _currentUser = User(
        id: const Uuid().v4(),
        email: email,
        name: email.split('@')[0],
      );
      await _storage.saveAuthToken('mock_jwt_token');
      await _storage.saveUser(_currentUser!.toJson());
      _isLoading = false;
      notifyListeners();
    } else {
      _isLoading = false;
      notifyListeners();
      throw Exception('Invalid credentials');
    }
  }

  Future<void> signup(String name, String email, String password) async {
    _isLoading = true;
    notifyListeners();
    await Future.delayed(const Duration(seconds: 2));

    if (email.isNotEmpty && password.length >= 6) {
      _isAuthenticated = true;
      _currentUser = User(id: const Uuid().v4(), email: email, name: name);
      await _storage.saveAuthToken('mock_jwt_token');
      await _storage.saveUser(_currentUser!.toJson());
      _isLoading = false;
      notifyListeners();
    } else {
      _isLoading = false;
      notifyListeners();
      throw Exception('Sign up failed');
    }
  }

  Future<void> logout() async {
    await _storage.clearAuth();
    _isAuthenticated = false;
    _currentUser = null;
    notifyListeners();
  }

  Future<void> forgotPassword(String email) async {
    _isLoading = true;
    notifyListeners();
    await Future.delayed(const Duration(seconds: 2));
    _isLoading = false;
    notifyListeners();
    // In a real app, integrate API here
  }

  Future<void> completeOnboarding() async {
    await _storage.completeOnboarding();
    notifyListeners();
  }
}
