import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';

import 'package:inkspacex/services/api/api_client.dart';
import 'package:inkspacex/services/app_log.dart';

// Dev/prod tag for analytics events. `kReleaseMode` covers Flutter build
// flavour; the API base URL covers release builds that target localhost
// (e.g. dogfooding from a dev machine before a deploy). Either signal
// flips the event to "dev", so the admin dashboard can filter local
// traffic out of production metrics.
String _resolveEnv() {
  if (!kReleaseMode) return 'dev';
  final url = ApiClient.baseUrl.toLowerCase();
  if (url.contains('localhost') || url.contains('127.0.0.1') || url.contains('://10.') || url.contains('://192.168.') || url.contains('://172.')) {
    return 'dev';
  }
  return 'prod';
}

/// User-behaviour analytics service.
///
/// One singleton, owned by `main.dart`. Buffers events in memory, flushes
/// in batches on a timer / size threshold / app-lifecycle hooks. Failed
/// flushes spill onto a Hive-backed offline queue so a poor connection
/// or server outage doesn't drop signal — the queue is drained on the
/// next successful flush (which usually means next app open).
///
/// Identity:
/// - `clientId` is a UUID generated on first run and persisted forever.
///   It survives logout/login and lets the backend stitch a user's
///   pre-auth events to their `user_id` once they sign in.
/// - `sessionId` rolls per app launch and on resume after >30min idle.
///
/// Privacy: never put passwords, tokens, or full email addresses in
/// `properties`. The backend is the only safe place for PII.
class AnalyticsService {
  AnalyticsService._({
    required Future<void> Function(List<Map<String, dynamic>>) poster,
    required Box<dynamic> queueBox,
    required String clientId,
    required bool enabled,
    required Map<String, dynamic> deviceContext,
  })  : _post = poster,
        _queueBox = queueBox,
        clientId = clientId,
        _enabled = enabled,
        _deviceContext = deviceContext;

  static AnalyticsService? _instance;

  /// Idiomatic accessor used by call sites that don't have the service
  /// in scope (most screens). `init()` must have been called first.
  static AnalyticsService get instance {
    final s = _instance;
    if (s == null) {
      throw StateError('AnalyticsService.init() not called yet');
    }
    return s;
  }

  static const String _boxName = 'analytics_queue';
  static const String _kClientId = 'analytics_client_id';
  // After this much foreground inactivity, the next event opens a new
  // session. Matches Mixpanel/Amplitude defaults — "I closed the app
  // for half an hour, came back" is two sessions, not one.
  static const Duration _sessionIdleTimeout = Duration(minutes: 30);
  static const int _flushBatchSize = 20;
  static const Duration _flushInterval = Duration(seconds: 5);
  // Cap the on-disk queue. Pathological offline runs shouldn't grow
  // local storage without bound; we'd rather drop the oldest than fill
  // the disk.
  static const int _queueMaxSize = 1000;

  /// Whether analytics is enabled in this build. Default: enabled in
  /// release builds, disabled in debug. Override with
  /// `--dart-define=ANALYTICS_ENABLED=true|false`.
  static bool defaultEnabled() {
    const override = String.fromEnvironment('ANALYTICS_ENABLED', defaultValue: '');
    if (override == 'true') return true;
    if (override == 'false') return false;
    return kReleaseMode;
  }

  final Future<void> Function(List<Map<String, dynamic>>) _post;
  final Box<dynamic> _queueBox;

  /// Stable per-install identifier. Same across logout/login on the same
  /// device, used by the backend to stitch anonymous events to the
  /// signed-in user.
  final String clientId;

  final bool _enabled;
  bool get enabled => _enabled;

  /// Device + app metadata, captured once at init and merged into every
  /// event's `properties`. Keys: `platform`, `device`, `app_version`.
  /// Region is derived server-side from the request IP — see
  /// privacy_policy.html §3.2.
  final Map<String, dynamic> _deviceContext;

  String _sessionId = const Uuid().v4();
  DateTime _lastActivityAt = DateTime.now();

  /// Currently-known user id from the auth provider, used to set the
  /// `screen` field's source on identify events. The backend doesn't
  /// need it — it reads the JWT — but it's useful in `properties` for
  /// tools that don't decode the auth header.
  String? _userId;

  String? _currentScreen;
  String? _previousScreen;

  final List<Map<String, dynamic>> _buffer = <Map<String, dynamic>>[];
  Timer? _flushTimer;
  bool _flushing = false;

  /// Initialise the singleton. Idempotent — safe to call once at startup
  /// and never again. Returns the live instance for convenience.
  static Future<AnalyticsService> init({
    required ApiClient api,
    bool? enabled,
  }) async {
    return _initWith(
      poster: (events) async {
        await api.post('/api/analytics/events', data: {'events': events});
      },
      enabled: enabled,
    );
  }

  /// Lower-level init for tests — accepts a poster directly so the
  /// service can be exercised without booting the real ApiClient.
  @visibleForTesting
  static Future<AnalyticsService> initForTest({
    required Future<void> Function(List<Map<String, dynamic>>) poster,
    bool enabled = true,
  }) async {
    return _initWith(poster: poster, enabled: enabled);
  }

  static Future<AnalyticsService> _initWith({
    required Future<void> Function(List<Map<String, dynamic>>) poster,
    bool? enabled,
  }) async {
    if (_instance != null) return _instance!;

    if (!Hive.isBoxOpen(_boxName)) {
      await Hive.openBox<dynamic>(_boxName);
    }
    final queue = Hive.box<dynamic>(_boxName);

    String? cid = queue.get(_kClientId) as String?;
    if (cid == null || cid.isEmpty) {
      cid = const Uuid().v4();
      await queue.put(_kClientId, cid);
    }

    final ctx = await _resolveDeviceContext();

    final svc = AnalyticsService._(
      poster: poster,
      queueBox: queue,
      clientId: cid,
      enabled: enabled ?? defaultEnabled(),
      deviceContext: ctx,
    );
    _instance = svc;
    if (svc._enabled) {
      svc._scheduleFlushTimer();
      // Drain anything left on disk from a prior crash/quit.
      unawaited(svc.flush());
    }
    return svc;
  }

  /// Resolve platform / device model / app version once at init. All
  /// three end up on every event's `properties` so the admin dashboard
  /// can break down activity without a separate identify call.
  ///
  /// We deliberately do NOT send a locale-derived region: most phones
  /// ship with en_US as the default English locale, so the field was
  /// tagging non-US English speakers as "US" and creating misleading
  /// region stats. The admin dashboard derives country from the request
  /// IP server-side instead. See the privacy policy for the wording.
  static Future<Map<String, dynamic>> _resolveDeviceContext() async {
    final ctx = <String, dynamic>{};

    // Build env so the admin dashboard can filter dev/local traffic out
    // of production metrics. See _resolveEnv() at file top for the rule.
    ctx['env'] = _resolveEnv();

    // Platform — coarse OS bucket. kIsWeb wins because dart:io.Platform
    // throws on web.
    if (kIsWeb) {
      ctx['platform'] = 'web';
    } else {
      try {
        ctx['platform'] = Platform.operatingSystem; // android/ios/macos/windows/linux/fuchsia
      } catch (_) {
        ctx['platform'] = 'unknown';
      }
    }

    // Device model — best-effort, never throw. device_info_plus reads
    // platform-specific APIs and can fail on heavily customised ROMs.
    try {
      final info = DeviceInfoPlugin();
      if (kIsWeb) {
        final w = await info.webBrowserInfo;
        // Chrome / Safari / Firefox + a hint of the OS — short, not the
        // full UA blob.
        final browser = w.browserName.name;
        ctx['device'] = w.platform != null ? '$browser / ${w.platform}' : browser;
      } else if (Platform.isAndroid) {
        final a = await info.androidInfo;
        ctx['device'] = '${a.manufacturer} ${a.model}'.trim();
      } else if (Platform.isIOS) {
        final i = await info.iosInfo;
        // utsname.machine is the precise hardware id (iPhone15,3); model
        // is the friendly name (iPhone). Send both joined.
        ctx['device'] = '${i.model} (${i.utsname.machine})';
      } else if (Platform.isMacOS) {
        final m = await info.macOsInfo;
        ctx['device'] = '${m.model} / macOS ${m.osRelease}';
      } else if (Platform.isWindows) {
        final w = await info.windowsInfo;
        ctx['device'] = '${w.computerName} / ${w.productName}';
      } else if (Platform.isLinux) {
        final l = await info.linuxInfo;
        ctx['device'] = l.prettyName;
      }
    } catch (_) {
      // Fall through — device is optional context.
    }

    // App version — useful for correlating regressions to a release.
    try {
      final pkg = await PackageInfo.fromPlatform();
      ctx['app_version'] = pkg.version.isNotEmpty
          ? '${pkg.version}+${pkg.buildNumber}'
          : pkg.buildNumber;
    } catch (_) {
      // Tests / unsupported platforms — skip.
    }

    return ctx;
  }

  /// Reset for tests — drops the singleton so a fresh init() can run.
  @visibleForTesting
  static void resetSingletonForTest() {
    _instance?._flushTimer?.cancel();
    _instance = null;
  }

  /// Record the current user id for inclusion as `properties.user_id`
  /// on subsequent events. Pass null on logout.
  void setUserId(String? userId) {
    _userId = userId;
  }

  /// Track a behaviour event. Fire-and-forget — never throws.
  ///
  /// `eventName` is the canonical event identifier (`post_liked`,
  /// `auth_login_viewed`, etc.). `screen` is the current route, `action`
  /// is one of view/click/submit/success/fail/impression. `entity*`
  /// names a single referenced object (e.g. `entity_type='post',
  /// entity_id=<post_id>`). `properties` carries any extra context —
  /// keep it small and PII-free.
  void track(
    String eventName, {
    String? screen,
    String? action,
    String? entityType,
    String? entityId,
    String? sourceScreen,
    int? durationMs,
    Map<String, dynamic>? properties,
  }) {
    if (!_enabled) return;
    _maybeRollSession();

    final props = <String, dynamic>{
      ..._deviceContext,
      if (_userId != null) 'user_id': _userId,
      ...?properties,
    };

    final entry = <String, dynamic>{
      'client_id': clientId,
      'session_id': _sessionId,
      'event_name': eventName,
      'screen': ?screen,
      'action': ?action,
      'entity_type': ?entityType,
      'entity_id': ?entityId,
      'source_screen': ?sourceScreen,
      'duration_ms': ?durationMs,
      'properties': props,
      'client_ts': DateTime.now().toUtc().toIso8601String(),
    };
    _buffer.add(entry);

    if (_buffer.length >= _flushBatchSize) {
      unawaited(flush());
    }
  }

  /// Record a route change. Fires `screen_viewed` plus tracks the
  /// previous → current screen edge so funnel queries can attribute a
  /// click to whichever screen the user came from.
  void trackScreenView(String? routeName) {
    if (routeName == null || routeName.isEmpty) return;
    _previousScreen = _currentScreen;
    _currentScreen = routeName;
    track(
      'screen_viewed',
      screen: routeName,
      action: 'view',
      sourceScreen: _previousScreen,
    );
  }

  /// Called by the app-lifecycle observer when the app comes to the
  /// foreground. Rolls the session if we've been idle long enough.
  void onAppForegrounded() {
    if (!_enabled) return;
    final wasIdle = DateTime.now().difference(_lastActivityAt) > _sessionIdleTimeout;
    if (wasIdle) {
      _rollSessionId();
    }
    _lastActivityAt = DateTime.now();
    track('app_foregrounded', action: 'lifecycle');
    _scheduleFlushTimer();
  }

  /// Called when the app goes to the background. Flushes the buffer so
  /// events written right before backgrounding don't get lost if the OS
  /// kills us next.
  void onAppBackgrounded() {
    if (!_enabled) return;
    track('app_backgrounded', action: 'lifecycle');
    _flushTimer?.cancel();
    _flushTimer = null;
    unawaited(flush());
  }

  void _maybeRollSession() {
    final now = DateTime.now();
    if (now.difference(_lastActivityAt) > _sessionIdleTimeout) {
      _rollSessionId();
    }
    _lastActivityAt = now;
  }

  void _rollSessionId() {
    _sessionId = const Uuid().v4();
  }

  void _scheduleFlushTimer() {
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(_flushInterval, (_) {
      if (_buffer.isNotEmpty || _queueBox.length > _queueReservedKeys) {
        unawaited(flush());
      }
    });
  }

  /// Number of Hive keys we use for our own bookkeeping (currently just
  /// the persisted `client_id`). Subtract from `length` to find the
  /// pending-events count.
  static const int _queueReservedKeys = 1;

  /// Push the buffer (and any persisted queue) to the backend. Safe to
  /// call concurrently — we serialise via `_flushing`.
  Future<void> flush() async {
    if (!_enabled || _flushing) return;
    _flushing = true;
    try {
      // Drain in-memory buffer first so any concurrent track()'s fall
      // into a fresh list rather than getting double-flushed.
      final mem = List<Map<String, dynamic>>.from(_buffer);
      _buffer.clear();

      // Pull anything queued on disk from prior failed flushes.
      final disk = _readDiskQueue();

      final all = [...disk, ...mem];
      if (all.isEmpty) return;

      // Cap the request to 100 events (matches the backend Pydantic
      // batch limit). If we have more, send the first 100 and leave
      // the rest on disk for the next tick.
      const sendCap = 100;
      final toSend = all.length > sendCap ? all.sublist(0, sendCap) : all;
      final remainder = all.length > sendCap ? all.sublist(sendCap) : const [];

      try {
        await _post(toSend);
        // Success — flush remainder back to disk for the next tick (so
        // we don't busy-loop the server with one giant batch).
        await _writeDiskQueue(remainder);
      } catch (e) {
        // Server rejected or unreachable. Persist EVERYTHING (mem +
        // disk) back to disk so we retry next time. Trim from the head
        // if we'd exceed the queue cap.
        log.w('[analytics] flush failed: $e — queued ${all.length} for retry');
        final trimmed = all.length > _queueMaxSize
            ? all.sublist(all.length - _queueMaxSize)
            : all;
        await _writeDiskQueue(trimmed);
      }
    } finally {
      _flushing = false;
    }
  }

  List<Map<String, dynamic>> _readDiskQueue() {
    final raw = _queueBox.get('queue');
    if (raw is! String || raw.isEmpty) return <Map<String, dynamic>>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <Map<String, dynamic>>[];
      return decoded
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
    } catch (_) {
      // Corrupt entry — drop it.
      return <Map<String, dynamic>>[];
    }
  }

  Future<void> _writeDiskQueue(List<dynamic> events) async {
    if (events.isEmpty) {
      await _queueBox.delete('queue');
    } else {
      await _queueBox.put('queue', jsonEncode(events));
    }
  }

  /// Clears everything except the persisted `client_id`. Used in tests
  /// and on full account reset.
  @visibleForTesting
  Future<void> resetForTest() async {
    _buffer.clear();
    await _queueBox.delete('queue');
    _userId = null;
    _flushTimer?.cancel();
    _flushTimer = null;
  }
}
