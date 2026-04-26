import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:inkspacex/models/notification_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/services/api/api_notification_service.dart';
import 'package:inkspacex/services/api/api_realtime_service.dart';
import 'package:inkspacex/services/app_log.dart';

/// State for the notifications center + bell badge.
///
/// Subscribes to the SSE notifications channel as soon as the user is
/// authenticated. New events prepend to [_items] and bump
/// [_unreadCount] without a round-trip. The REST API is the source of
/// truth on cold start; SSE keeps it fresh.
class NotificationProvider extends ChangeNotifier {
  NotificationProvider({
    required ApiNotificationService api,
    required ApiRealtimeService realtime,
  })  : _api = api,
        _realtime = realtime;

  final ApiNotificationService _api;
  final ApiRealtimeService _realtime;

  StreamSubscription<Map<String, dynamic>>? _sseSub;
  bool _initialized = false;
  bool _loading = false;
  String? _error;
  List<NotificationModel> _items = const [];
  int _unreadCount = 0;

  bool get isLoading => _loading;
  String? get error => _error;
  List<NotificationModel> get items => _items;
  int get unreadCount => _unreadCount;
  bool get hasUnread => _unreadCount > 0;

  /// Idempotent — safe to call from any auth-state change. The first call
  /// loads history from REST and opens the SSE stream; subsequent calls
  /// are no-ops.
  Future<void> ensureStarted() async {
    if (_initialized) return;
    _initialized = true;
    await refresh();
    _sseSub = _realtime.notificationsChannel().listen(
      _onSseEvent,
      onError: (e, st) {
        log.w('[notifications] sse error: $e');
      },
    );
  }

  Future<void> refresh() async {
    _loading = true;
    notifyListeners();
    try {
      final results = await Future.wait([
        _api.list(),
        _api.unreadCount(),
      ]);
      _items = results[0] as List<NotificationModel>;
      _unreadCount = results[1] as int;
      _error = null;
    } catch (e, st) {
      log.e('[notifications] refresh failed', error: e, stackTrace: st);
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  void _onSseEvent(Map<String, dynamic> event) {
    if (event['type'] != 'notification') return;
    try {
      final notif = NotificationModel.fromJson(event);
      // Skip dupes — the same notification can arrive via SSE and via a
      // refresh() race-loss; key on id.
      if (_items.any((n) => n.id == notif.id)) return;
      _items = [notif, ..._items];
      if (!notif.read) _unreadCount += 1;
      notifyListeners();
    } catch (e) {
      log.w('[notifications] failed to parse sse event: $e');
    }
  }

  Future<void> markAllRead() async {
    if (_unreadCount == 0) return;
    final unreadIds = _items.where((n) => !n.read).map((n) => n.id).toList();
    if (unreadIds.isEmpty) return;
    // Optimistic: zero the counter and flip the items immediately.
    _items = _items.map((n) => n.read ? n : n.copyWith(read: true)).toList();
    _unreadCount = 0;
    notifyListeners();
    try {
      await _api.markRead(ids: unreadIds);
    } catch (e) {
      log.w('[notifications] markAllRead failed: $e');
      // Don't revert — the user has seen them; a stale-unread badge is
      // less bad than re-flashing "you have unread items".
    }
  }

  Future<void> markRead(NotificationModel notif) async {
    if (notif.read) return;
    final updated = _items
        .map((n) => n.id == notif.id ? n.copyWith(read: true) : n)
        .toList();
    _items = updated;
    _unreadCount = (_unreadCount - 1).clamp(0, 1 << 30);
    notifyListeners();
    try {
      await _api.markRead(ids: [notif.id]);
    } catch (e) {
      log.w('[notifications] markRead failed: $e');
    }
  }

  Future<void> delete(NotificationModel notif) async {
    final wasUnread = !notif.read;
    _items = _items.where((n) => n.id != notif.id).toList();
    if (wasUnread) {
      _unreadCount = (_unreadCount - 1).clamp(0, 1 << 30);
    }
    notifyListeners();
    try {
      await _api.delete(notif.id);
    } catch (e) {
      log.w('[notifications] delete failed: $e');
    }
  }

  Future<void> reset() async {
    await _sseSub?.cancel();
    _sseSub = null;
    _initialized = false;
    _items = const [];
    _unreadCount = 0;
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _sseSub?.cancel();
    super.dispose();
  }
}

/// Adapter so `AuthProvider` doesn't need to know about
/// `ApiNotificationService` directly — the provider is built off the
/// existing `ApiClient` exposed on AuthProvider.
NotificationProvider buildNotificationProvider(AuthProvider auth) {
  return NotificationProvider(
    api: ApiNotificationService(auth.apiClient),
    realtime: auth.realtimeService,
  );
}
