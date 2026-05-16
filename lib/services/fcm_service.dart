import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'package:inkspacex/services/api/api_push_token_service.dart';
import 'package:inkspacex/services/app_log.dart' as applog;

/// Web Push VAPID key — required by firebase_messaging.getToken on the web,
/// ignored on Android/iOS. VAPID keys are PUBLIC by design (they identify
/// the sender to the push service); embedding in source is safe and the
/// flutterfire CLI follows the same pattern.
///
/// Sourced from Firebase Console → Project Settings → Cloud Messaging →
/// "Web Push certificates". Built-in default = the inkspacex project's
/// current key. Override per-build with `--dart-define=FCM_VAPID_KEY=...`
/// (useful for staging projects or post-rotation builds).
const _fcmVapidKey = String.fromEnvironment(
  'FCM_VAPID_KEY',
  defaultValue:
      'BPwRksw6_rXvu2pXEKPtq3iZHYkJ-aFZoMxwGDjmMhi-1EFki7YfUv2W6lAdeLiRoH8ACob4enxnUOLYd-AZBLk',
);

/// Bridges Firebase Cloud Messaging tokens + foreground/background message
/// delivery into the existing notification pipeline.
///
/// Lifecycle:
///   1. [initialize] runs once at app start (after Firebase.initializeApp).
///   2. After a user signs in, call [registerForCurrentUser] to grab the
///      FCM token and POST it to /api/notifications/push-token.
///   3. On sign-out, call [unregisterForCurrentUser] so the token is
///      removed from the recipient list for that user.
///   4. Token rotation is handled automatically via onTokenRefresh.
class FcmService {
  FcmService({
    required ApiPushTokenService pushTokenService,
  }) : _pushTokenService = pushTokenService;

  final ApiPushTokenService _pushTokenService;

  FirebaseMessaging? _messaging;
  StreamSubscription<String>? _tokenSub;
  String? _lastToken;
  bool _initialized = false;

  bool get isSupported =>
      kIsWeb || (!kIsWeb && (Platform.isAndroid || Platform.isIOS));

  /// One-time global setup. Must run after [Firebase.initializeApp].
  Future<void> initialize() async {
    if (_initialized || !isSupported) return;
    try {
      _messaging = FirebaseMessaging.instance;

      // Refresh tokens get pushed to the backend so we keep delivering
      // to the new token after Google Play resets / app reinstall.
      _tokenSub = _messaging!.onTokenRefresh.listen((token) async {
        applog.log.i('FCM token refreshed');
        await _registerToken(token);
      });

      // Foreground messages with a `notification` payload don't auto-show
      // on Android — Firebase only shows them when the app is in the
      // background. We let the existing SSE pipeline (which already drives
      // LocalNotificationService) handle in-app display; the data payload
      // arriving via SSE has the same `data.title`/`data.body` keys.
      _initialized = true;
    } catch (e, st) {
      applog.log.w('FCM initialize failed: $e\n$st');
    }
  }

  /// Call this when a user finishes signing in. Asks for notification
  /// permission, fetches the FCM token, and posts it to the backend.
  Future<void> registerForCurrentUser() async {
    if (!isSupported || _messaging == null) return;
    try {
      final settings = await _messaging!.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        applog.log.i('FCM permission denied by user');
        return;
      }

      // Web getToken needs a VAPID key (Firebase Cloud Messaging Web
      // certificate). When not built with --dart-define=FCM_VAPID_KEY=...
      // we skip token registration — the analytics + foreground
      // notification surfaces still work; only OS push is gated.
      String? token;
      if (kIsWeb) {
        if (_fcmVapidKey.isEmpty) {
          applog.log.i('FCM web: VAPID key not set, skipping token register');
          return;
        }
        token = await _messaging!.getToken(vapidKey: _fcmVapidKey);
      } else {
        token = await _messaging!.getToken();
      }
      if (token == null) {
        applog.log.w('FCM getToken returned null');
        return;
      }
      await _registerToken(token);
    } catch (e, st) {
      applog.log.w('FCM registerForCurrentUser failed: $e\n$st');
    }
  }

  /// Call on sign-out to stop sending pushes to this device for the
  /// just-signed-out user.
  Future<void> unregisterForCurrentUser() async {
    if (_lastToken == null) return;
    try {
      await _pushTokenService.unregister(_lastToken!);
    } catch (e) {
      applog.log.w('FCM unregister failed: $e');
    } finally {
      _lastToken = null;
    }
  }

  Future<void> _registerToken(String token) async {
    _lastToken = token;
    final String platform;
    final String deviceLabel;
    if (kIsWeb) {
      platform = 'web';
      deviceLabel = 'web';
    } else if (Platform.isAndroid) {
      platform = 'fcm';
      deviceLabel = 'android';
    } else {
      platform = 'apns';
      deviceLabel = 'ios';
    }
    try {
      await _pushTokenService.register(
        platform: platform,
        token: token,
        deviceLabel: deviceLabel,
      );
      applog.log.i('FCM token registered with backend ($platform)');
    } catch (e) {
      applog.log.w('FCM token register failed: $e');
    }
  }

  Future<void> dispose() async {
    await _tokenSub?.cancel();
  }
}

/// Background message handler. Must be top-level + annotated as a VM
/// entry point because flutter_messaging spawns an isolate to deliver
/// these. We don't do work here — Android shows the notification
/// automatically when the payload has a `notification` block.
@pragma('vm:entry-point')
Future<void> firebaseBackgroundHandler(RemoteMessage message) async {
  // intentionally empty — kept as a placeholder for future analytics
}
