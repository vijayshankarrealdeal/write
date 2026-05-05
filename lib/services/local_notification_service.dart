import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'package:inkspacex/models/chat_message_model.dart';
import 'package:inkspacex/models/notification_model.dart';
import 'package:inkspacex/services/api/api_realtime_service.dart';
import 'package:inkspacex/services/app_log.dart';

typedef NotificationTapHandler = void Function(NotificationModel notif);
typedef ChatTapHandler = void Function(String conversationId);

/// Bridges incoming SSE notification events to OS-level notifications.
///
/// Three surfaces:
///   1. Activity (likes / comments / replies) — the existing `notification`
///      SSE event.
///   2. Chat — `chat.message` SSE events. Suppressed when the app is in
///      foreground AND the user is on the corresponding conversation
///      page (or it's the user's own outgoing message). When the app is
///      backgrounded these surface even if the conversation is "open".
///   3. Upload progress — book publish flows surface a sticky, ongoing
///      notification that updates as the publish moves through stages.
///
/// Web isn't supported by `flutter_local_notifications` — calls are
/// no-ops there.
class LocalNotificationService {
  LocalNotificationService();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  StreamSubscription<Map<String, dynamic>>? _sseSub;
  bool _initialized = false;
  bool _supported = false;
  NotificationTapHandler? _onTap;
  ChatTapHandler? _onChatTap;

  // Identity / UI hints used to suppress noisy chat notifications.
  String? _currentUserId;
  String? _activeConversationId;
  bool _appInForeground = true;

  // Channels.
  static const String _channelId = 'inkspacex_default';
  static const String _channelName = 'Activity';
  static const String _channelDesc =
      'Likes, comments, and replies on your stories';

  static const String _chatChannelId = 'inkspacex_chat';
  static const String _chatChannelName = 'Messages';
  static const String _chatChannelDesc = 'New chat messages';

  static const String _uploadChannelId = 'inkspacex_uploads';
  static const String _uploadChannelName = 'Uploads';
  static const String _uploadChannelDesc =
      'Book publishing and upload progress';

  static const String _goalChannelId = 'inkspacex_goal';
  static const String _goalChannelName = 'Writing Goals';
  static const String _goalChannelDesc =
      'Daily writing goal reminders';

  // Notification id namespaces (prevent collision across surfaces).
  static const int _uploadIdBase = 0x10000000;
  static const int _chatIdBase = 0x20000000;
  static const int _goalIdBase = 0x30000000;
  static const int _goalReminderId = _goalIdBase | 1;

  /// Initialize the plugin + create the Android notification channels.
  /// Idempotent. Returns true if local notifications are usable on
  /// this platform.
  Future<bool> init({
    NotificationTapHandler? onTap,
    ChatTapHandler? onChatTap,
  }) async {
    if (_initialized) return _supported;
    _initialized = true;
    _onTap = onTap;
    _onChatTap = onChatTap;

    if (kIsWeb) {
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
      // `zonedSchedule` (used for the daily goal reminder) needs the
      // timezone DB initialized at least once per process.
      tz_data.initializeTimeZones();

      if (Platform.isAndroid) {
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
        await androidImpl?.createNotificationChannel(
          const AndroidNotificationChannel(
            _chatChannelId,
            _chatChannelName,
            description: _chatChannelDesc,
            importance: Importance.high,
          ),
        );
        await androidImpl?.createNotificationChannel(
          const AndroidNotificationChannel(
            _uploadChannelId,
            _uploadChannelName,
            description: _uploadChannelDesc,
            // Low importance: progress should be visible but never
            // pop a heads-up banner.
            importance: Importance.low,
          ),
        );
        await androidImpl?.createNotificationChannel(
          const AndroidNotificationChannel(
            _goalChannelId,
            _goalChannelName,
            description: _goalChannelDesc,
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

  /// Late-bind the tap handlers. The router doesn't exist when [init]
  /// runs, so the route-aware code calls this once it does.
  void setTapHandlers({
    NotificationTapHandler? onTap,
    ChatTapHandler? onChatTap,
  }) {
    if (onTap != null) _onTap = onTap;
    if (onChatTap != null) _onChatTap = onChatTap;
  }

  /// Track the signed-in user so we can drop the user's own outgoing
  /// chat echoes (the SSE stream fans out to all of the user's
  /// devices).
  void setCurrentUser(String? userId) {
    _currentUserId = userId;
  }

  /// Mark which conversation page is on top, if any. Used to suppress
  /// chat notifications for the conversation the user is already
  /// reading. Pass `null` when leaving the page.
  void setActiveConversation(String? conversationId) {
    _activeConversationId = conversationId;
  }

  /// Update foreground state. Chat notifications are suppressed for
  /// the active conversation only when the app is in foreground —
  /// otherwise the user can't see the page anyway, so we surface the
  /// notification regardless.
  void setAppForegrounded(bool foreground) {
    _appInForeground = foreground;
  }

  /// Subscribe to the realtime notifications channel and surface every
  /// new notification (or chat message) as an OS-level notification.
  void attachToSse(ApiRealtimeService realtime) {
    if (!_supported) return;
    _sseSub?.cancel();
    _sseSub = realtime.notificationsChannel().listen(
      _onSseEvent,
      onError: (e) => log.w('[local-notif] sse error: $e'),
    );
  }

  Future<void> _onSseEvent(Map<String, dynamic> event) async {
    if (!_supported) return;
    final type = event['type'];
    try {
      if (type == 'notification') {
        final notif = NotificationModel.fromJson(event);
        await _showNotification(notif);
      } else if (type == 'chat.message') {
        final raw = event['message'];
        if (raw is Map) {
          final msg =
              ChatMessageModel.fromJson(Map<String, dynamic>.from(raw));
          await _showChatMessage(msg);
        }
      }
    } catch (e) {
      log.w('[local-notif] failed to display $type: $e');
    }
  }

  Future<void> _showNotification(NotificationModel notif) async {
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
    final id = notif.id.hashCode & 0x7fffffff;
    await _plugin.show(
      id,
      notif.title,
      notif.subtitle ?? '',
      details,
      payload: 'notif:${notif.id}',
    );
  }

  Future<void> _showChatMessage(ChatMessageModel msg) async {
    // Drop the user's own outgoing echoes.
    if (_currentUserId != null && msg.senderId == _currentUserId) return;
    // While the user is reading this exact thread in the foreground,
    // posting a notification is just noise.
    if (_appInForeground && _activeConversationId == msg.conversationId) {
      return;
    }

    final title = _chatTitle(msg);
    final body = _chatPreview(msg);

    final androidDetails = AndroidNotificationDetails(
      _chatChannelId,
      _chatChannelName,
      channelDescription: _chatChannelDesc,
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.message,
      ticker: title,
      groupKey: 'chat_${msg.conversationId}',
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

    // One notification slot per conversation — newer messages replace
    // the prior one so the tray doesn't pile up.
    final id = _chatIdBase | (msg.conversationId.hashCode & 0x0fffffff);
    await _plugin.show(
      id,
      title,
      body,
      details,
      payload: 'chat:${msg.conversationId}',
    );
  }

  String _chatTitle(ChatMessageModel msg) {
    // We don't have the sender's name on the SSE frame — the
    // ConversationParticipant lives on the conversation summary the
    // chat list page already has. Keep this simple; the chat page will
    // resolve the name on tap.
    return 'New message';
  }

  String _chatPreview(ChatMessageModel msg) {
    switch (msg.kind) {
      case ChatMessageKind.text:
        return (msg.body ?? '').isEmpty ? 'Sent you a message' : msg.body!;
      case ChatMessageKind.image:
        return 'Sent a photo';
      case ChatMessageKind.book:
        return 'Shared a book';
      case ChatMessageKind.excerpt:
        return 'Shared an excerpt';
      case ChatMessageKind.section:
        return 'Shared a section';
    }
  }

  // ── Upload / publish progress ───────────────────────────────────

  /// Show or update an ongoing progress notification for a long-running
  /// upload (e.g. publishing a book). Pass the same [tag] on every call
  /// so the system replaces the prior tile in place.
  ///
  /// `progress` and `maxProgress` are 0–100 percentages. Pass
  /// `indeterminate: true` for a spinner-style bar when you don't have
  /// granular progress.
  Future<void> showUploadProgress({
    required String tag,
    required String title,
    required String body,
    int progress = 0,
    int maxProgress = 100,
    bool indeterminate = true,
  }) async {
    if (!_supported) return;
    final androidDetails = AndroidNotificationDetails(
      _uploadChannelId,
      _uploadChannelName,
      channelDescription: _uploadChannelDesc,
      importance: Importance.low,
      priority: Priority.low,
      onlyAlertOnce: true,
      ongoing: true,
      autoCancel: false,
      showProgress: true,
      progress: progress,
      maxProgress: maxProgress,
      indeterminate: indeterminate,
      category: AndroidNotificationCategory.progress,
    );
    const darwinDetails = DarwinNotificationDetails(
      presentAlert: false,
      presentBadge: false,
      presentSound: false,
    );
    final details = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
      macOS: darwinDetails,
    );
    await _plugin.show(
      _uploadId(tag),
      title,
      body,
      details,
      payload: 'upload:$tag',
    );
  }

  /// Replace the in-progress notification with a final completion
  /// state (success or failure). Auto-dismissable; surfaces a banner
  /// on iOS so the user knows the background task finished.
  Future<void> showUploadResult({
    required String tag,
    required String title,
    required String body,
    bool success = true,
  }) async {
    if (!_supported) return;
    final androidDetails = AndroidNotificationDetails(
      _uploadChannelId,
      _uploadChannelName,
      channelDescription: _uploadChannelDesc,
      importance: Importance.high,
      priority: Priority.high,
      ongoing: false,
      autoCancel: true,
      showProgress: false,
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
    await _plugin.show(
      _uploadId(tag),
      title,
      body,
      details,
      payload: success ? 'upload-done:$tag' : 'upload-fail:$tag',
    );
  }

  /// Cancel an in-flight upload notification (e.g. when the user
  /// navigates back into the publish page mid-flight and we want to
  /// replace the tray tile with an in-app indicator).
  Future<void> cancelUpload(String tag) async {
    if (!_supported) return;
    await _plugin.cancel(_uploadId(tag));
  }

  int _uploadId(String tag) =>
      _uploadIdBase | (tag.hashCode & 0x0fffffff);

  // ── Daily writing goal reminder ─────────────────────────────────

  /// Schedule a single one-shot reminder at [when] (local wall-clock).
  /// Replaces any previously-scheduled goal reminder. The caller is
  /// responsible for re-arming this on a new day — typically by calling
  /// from app startup and from the goal settings UI.
  ///
  /// Past times are silently ignored (the system would either fire
  /// immediately or refuse, neither of which is useful here).
  Future<void> scheduleDailyGoalReminder({
    required DateTime when,
    required int wordsRemaining,
    required int dailyGoal,
  }) async {
    if (!_supported) return;
    await _plugin.cancel(_goalReminderId);

    // Convert the local wall-clock time to a TZDateTime in UTC. We don't
    // depend on `flutter_timezone` to detect the system zone — going
    // through UTC sidesteps that and the OS still fires at the right
    // wall-clock moment.
    final whenUtc = when.toUtc();
    final tzWhen = tz.TZDateTime.utc(
      whenUtc.year,
      whenUtc.month,
      whenUtc.day,
      whenUtc.hour,
      whenUtc.minute,
      whenUtc.second,
    );
    if (!tzWhen.isAfter(tz.TZDateTime.now(tz.UTC))) {
      return;
    }

    final body = wordsRemaining > 0
        ? "You're $wordsRemaining words short of your $dailyGoal-word goal — finish strong."
        : "Don't break the streak — open the editor and write today.";

    final androidDetails = AndroidNotificationDetails(
      _goalChannelId,
      _goalChannelName,
      channelDescription: _goalChannelDesc,
      importance: Importance.high,
      priority: Priority.high,
      ticker: 'Daily writing goal',
    );
    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: false,
      presentSound: true,
    );
    final details = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
      macOS: darwinDetails,
    );

    try {
      await _plugin.zonedSchedule(
        _goalReminderId,
        'Keep your writing streak alive',
        body,
        tzWhen,
        details,
        // Inexact is fine: a few minutes of drift on a writing reminder
        // is invisible, and exact alarms need a runtime permission on
        // Android 13+ that we'd rather not ask for.
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        // 17.x still requires this arg even though it's iOS-only legacy.
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        // Daily-repeat at the wall-clock time encoded in `tzWhen`. Without
        // this the notification is a one-shot and the user only ever gets
        // a reminder if they re-open the app each day.
        matchDateTimeComponents: DateTimeComponents.time,
        payload: 'goal-reminder',
      );
    } catch (e, st) {
      log.w('[local-notif] failed to schedule goal reminder: $e\n$st');
    }
  }

  /// Returns true if the OS will actually deliver notifications.
  ///
  /// Useful when surfacing an opt-in toggle: if this returns false,
  /// the toggle should warn the user that nothing will fire until
  /// they grant permission in Settings.
  Future<bool> areNotificationsEnabled() async {
    if (!_supported) return false;
    if (Platform.isAndroid) {
      final impl = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      return (await impl?.areNotificationsEnabled()) ?? false;
    }
    if (Platform.isIOS) {
      final impl = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      final perms = await impl?.checkPermissions();
      return perms?.isEnabled ?? false;
    }
    // macOS / others: assume enabled — the plugin no-ops if not.
    return true;
  }

  /// Re-prompt for notification permission. Safe to call multiple
  /// times: on iOS this only shows the dialog once per install (the
  /// system caches the user's choice), and on Android 13+ it shows
  /// once per app launch until the user decides.
  ///
  /// Returns the resulting "are notifications enabled" state.
  Future<bool> requestNotificationPermission() async {
    if (!_supported) return false;
    if (Platform.isAndroid) {
      final impl = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await impl?.requestNotificationsPermission();
      return (await impl?.areNotificationsEnabled()) ?? false;
    }
    if (Platform.isIOS) {
      final impl = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      final granted = await impl?.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
      return granted ?? false;
    }
    return true;
  }

  Future<void> cancelDailyGoalReminder() async {
    if (!_supported) return;
    await _plugin.cancel(_goalReminderId);
  }

  // ── Tap handling ─────────────────────────────────────────────────

  void _onResponse(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;
    if (payload.startsWith('chat:')) {
      _onChatTap?.call(payload.substring('chat:'.length));
      return;
    }
    if (payload.startsWith('notif:')) {
      _onTap?.call(_payloadStub(payload.substring('notif:'.length)));
      return;
    }
    // upload:* and upload-done:* taps just bring the app forward —
    // no deep link necessary.
  }

  NotificationModel _payloadStub(String id) {
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
