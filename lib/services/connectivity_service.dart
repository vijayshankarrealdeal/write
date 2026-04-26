import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Lightweight wrapper over `connectivity_plus` that exposes a single
/// `bool isOnline` notion to the rest of the app.
///
/// We treat anything except `ConnectivityResult.none` as online. We do **not**
/// probe a real endpoint; this is link-state, not reachability. Callers that
/// need true reachability still have to handle network errors when they
/// happen — this service only tells you when *not* to bother trying.
class ConnectivityService {
  ConnectivityService({Connectivity? connectivity})
      : _connectivity = connectivity ?? Connectivity() {
    _isOnline = ValueNotifier<bool>(true);
  }

  final Connectivity _connectivity;
  late final ValueNotifier<bool> _isOnline;
  StreamSubscription<List<ConnectivityResult>>? _sub;
  final StreamController<bool> _streamController = StreamController.broadcast();

  /// Reactive flag, suitable for `ValueListenableBuilder` / `Selector`.
  ValueListenable<bool> get isOnline => _isOnline;

  /// Broadcast stream of online-state transitions.
  Stream<bool> get onChange => _streamController.stream;

  bool get isOnlineNow => _isOnline.value;

  /// Subscribe to platform connectivity events. Safe to call more than once.
  Future<void> init() async {
    if (_sub != null) return;
    try {
      final initial = await _connectivity.checkConnectivity();
      _emit(_resolve(initial));
    } catch (_) {
      _emit(true);
    }
    _sub = _connectivity.onConnectivityChanged.listen(
      (results) => _emit(_resolve(results)),
      onError: (_) => _emit(true),
    );
  }

  /// Force the cached state. Test-only — production callers should let
  /// [init] populate this from the platform.
  @visibleForTesting
  void debugSet(bool online) => _emit(online);

  void _emit(bool online) {
    if (_isOnline.value == online) return;
    _isOnline.value = online;
    _streamController.add(online);
  }

  static bool _resolve(List<ConnectivityResult> results) {
    if (results.isEmpty) return false;
    return results.any((r) => r != ConnectivityResult.none);
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    await _streamController.close();
    _isOnline.dispose();
  }
}
