import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:inkspacex/models/notification_model.dart';
import 'package:inkspacex/services/api/api_realtime_service.dart';
import 'package:inkspacex/services/app_log.dart';

typedef NotificationTapHandler = void Function(NotificationModel notif);

/// Bridges incoming SSE notification events to OS-level notifications.
///
/// When the app is in foreground and a new notification arrives, this
/// service displays it through the system tray (Android) /
/// banner+sound (iOS). For background or killed-app delivery, an FCM /
/// APNS token also has to be registered with the backend — see
/// [PushTokenService]. Both can coexist; the local notifier is just
/// the foreground half.
///
/// Web isn't supported by `flutter_local_notifications` — calls are
/// no-ops there. The browser tab already shows the notifications page
/// live via SSE, so users don't lose anything.
class LocalNotificationService {
  LocalNotificationService();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  StreamSubscription<Map<String, dynamic>>? _sseSub;
  bool _initialized = false;
  bool _supported = false;
  NotificationTapHandler? _onTap;

  static const String _channelId = 'inkspacex_default';
  static const String _channelName = 'Activity';
  static const String _channelDesc =
      'Likes, comments, and replies on your stories';

  /// Initialize the plugin + create the Android notification channel.
  /// Idempotent. Returns true if local notifications are usable on
  /// this platform.
  Future<bool> init({NotificationTapHandler? onTap}) async {
    if (_initialized) return _supported;
    _initialized = true;
    _onTap = onTap;

    if (kIsWeb) {
      // Web has its own notification API; we don't wire it here.
      _supported = false;
      return false;
    }
    if (!(Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) {
      _supported = false;
      return false;
    }

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    final settings = const InitializationSettings(
      android: android,
      iOS: darwin,
      macOS: darwin,
    );

    try {
      await _plugin.initialize(
        settings,
        onDidReceiveNotificationResponse: _onResponse,
      );
      _supported = true;

      if (Platform.isAndroid) {
        // Channel must exist before posting (Android 8+). Idempotent.
        final androidImpl = _plugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>();
        await androidImpl?.createNotificationChannel(
          const AndroidNotificationChannel(
            _channelId,
            _channelName,
            description: _channelDesc,
            importance: Importance.high,
          ),
        );
        await androidImpl?.requestNotificationsPermission();
      }
      if (Platform.isIOS) {
        await _plugin
            .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(alert: true, badge: true, sound: true);
      }
      return true;
    } catch (e, st) {
      log.w('[local-notif] init failed: $e\n$st');
      _supported = false;
      return false;
    }
  }

  /// Subscribe to the realtime notifications channel and surface every
  /// new notification as an OS-level notification.
  void attachToSse(ApiRealtimeService realtime) {
    if (!_supported) return;
    _sseSub?.cancel();
    _sseSub = realtime.notificationsChannel().listen(
      _onSseEvent,
      onError: (e) => log.w('[local-notif] sse error: $e'),
    );
  }

  Future<void> _onSseEvent(Map<String, dynamic> event) async {
    if (event['type'] != 'notification') return;
    if (!_supported) return;
    try {
      final notif = NotificationModel.fromJson(event);
      await _show(notif);
    } catch (e) {
      log.w('[local-notif] failed to display: $e');
    }
  }

  Future<void> _show(NotificationModel notif) async {
    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.high,
      priority: Priority.high,
      ticker: notif.title,
    );
    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    final details = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
      macOS: darwinDetails,
    );
    // Stable `int` id derived from the UUID — short hash is fine here
    // because we're only avoiding duplicate-stack collisions, not
    // cross-device uniqueness.
    final id = notif.id.hashCode & 0x7fffffff;
    await _plugin.show(
      id,
      notif.title,
      notif.subtitle ?? '',
      details,
      payload: notif.id,
    );
  }

  void _onResponse(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;
    // Caller bridges the tap to navigation (it has go_router context).
    _onTap?.call(_payloadStub(payload));
  }

  NotificationModel _payloadStub(String id) {
    // We don't carry the full notification through the OS payload to
    // keep it small; the caller can refetch from history if needed.
    return NotificationModel(
      id: id,
      kind: 'unknown',
      read: true,
      createdAt: DateTime.now(),
    );
  }

  Future<void> dispose() async {
    await _sseSub?.cancel();
    _sseSub = null;
  }
}
