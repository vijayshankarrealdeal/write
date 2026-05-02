import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

import 'package:inkspacex/services/api/api_client.dart';

/// App-wide logger.
///
/// Console output is suppressed on web (browser console stays clean) and
/// in release builds. Everywhere else, info/warn/error/fatal entries are
/// shipped to the backend telemetry pipeline (`POST /api/logs`) so they
/// surface in the admin "Application Logs" viewer.
///
/// Usage stays the same: `log.d/i/w/e/f(message, error: ..., stackTrace: ...)`.
final Logger log = Logger(
  level: kReleaseMode ? Level.info : Level.trace,
  printer: PrettyPrinter(
    methodCount: 0,
    errorMethodCount: 8,
    lineLength: 100,
    colors: false,
    printEmojis: true,
    dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
  ),
  output: MultiOutput([
    // Native dev still gets a console — devs need it. Web (any mode) and
    // release builds skip it: web is the noisy case the user called out,
    // and release shouldn't be writing to stderr/stdout at all.
    if (!kIsWeb && !kReleaseMode) ConsoleOutput(),
    _RemoteLogSink(),
  ]),
);

/// `LogOutput` shim — the actual queue lives on [RemoteLogger] so logs
/// emitted before `RemoteLogger.init` (very early bootstrap) still buffer
/// and get flushed once the API client is ready.
class _RemoteLogSink extends LogOutput {
  @override
  void output(OutputEvent event) {
    RemoteLogger.instance._enqueue(event);
  }
}

/// Batches log entries and ships them to `POST /api/logs`.
///
/// Singleton, attached to the app from `main.dart` once StorageService
/// (and therefore ApiClient) is ready. Until `init()` runs, entries
/// accumulate in a bounded in-memory queue — first 500 entries are kept,
/// the rest dropped.
class RemoteLogger {
  RemoteLogger._();

  static final RemoteLogger _instance = RemoteLogger._();
  static RemoteLogger get instance => _instance;

  ApiClient? _api;
  Timer? _flushTimer;
  bool _flushing = false;
  String? _userId;

  bool _enabled = true;

  final List<Map<String, dynamic>> _buffer = <Map<String, dynamic>>[];

  static const int _flushBatchSize = 20;
  static const int _maxBufferSize = 500;
  static const Duration _flushInterval = Duration(seconds: 5);
  // Backend's AppLog columns cap at 10k for message and Text for details;
  // bound details client-side too so a giant stack trace doesn't bloat
  // payloads.
  static const int _messageCap = 10000;
  static const int _detailsCap = 20000;

  /// Attach the API client + start the periodic flush timer. Idempotent.
  static void init({required ApiClient api}) {
    final svc = _instance;
    if (svc._api != null) return;
    svc._api = api;
    svc._scheduleFlushTimer();
    // Drain anything that was emitted during bootstrap before init ran.
    if (svc._enabled && svc._buffer.isNotEmpty) {
      unawaited(svc.flush());
    }
  }

  /// Tag subsequent entries with this user_id so the admin viewer can
  /// correlate frontend errors back to the user. Pass null on logout.
  void setUserId(String? userId) {
    _userId = userId;
  }

  /// Whether remote logging is on for this build/runtime.
  bool get enabled => _enabled;
  set enabled(bool value) {
    _enabled = value;
    if (value) {
      _scheduleFlushTimer();
    } else {
      _flushTimer?.cancel();
      _flushTimer = null;
    }
  }

  void _enqueue(OutputEvent event) {
    if (!_enabled) return;

    final origin = event.origin;
    final level = _mapLevel(origin.level);
    if (level == null) return; // trace/debug — skip

    final rawMessage = origin.message?.toString() ?? '';
    if (rawMessage.isEmpty) return;

    // Loop-breaker: the api_client logs every request (including the one
    // we make to /api/logs itself). Without this skip, every flush would
    // produce two new info entries which would trigger another flush,
    // which would produce two more, forever.
    if (rawMessage.contains('/api/logs')) return;

    String? details;
    if (origin.error != null || origin.stackTrace != null) {
      final buf = StringBuffer();
      if (origin.error != null) {
        buf.writeln(origin.error.toString());
      }
      if (origin.stackTrace != null) {
        buf.writeln(origin.stackTrace.toString());
      }
      details = buf.toString();
    }

    final message = rawMessage.length > _messageCap
        ? rawMessage.substring(0, _messageCap)
        : rawMessage;
    if (details != null && details.length > _detailsCap) {
      details = details.substring(0, _detailsCap);
    }

    if (_buffer.length >= _maxBufferSize) {
      _buffer.removeAt(0); // drop oldest
    }
    _buffer.add({
      'level': level,
      'source': 'frontend',
      'env': kReleaseMode ? 'prod' : 'dev',
      'logger': kIsWeb ? 'flutter-web' : 'flutter',
      'message': message,
      'details': ?details,
      'user_id': ?_userId,
    });

    // Errors flush immediately so a crash right before the OS evicts us
    // still has a chance to land server-side.
    if (level == 'error' || _buffer.length >= _flushBatchSize) {
      unawaited(flush());
    }
  }

  String? _mapLevel(Level level) {
    switch (level) {
      case Level.fatal:
      case Level.error:
        return 'error';
      case Level.warning:
        return 'warn';
      case Level.info:
        return 'info';
      default:
        return null; // trace, debug, off, all, verbose, wtf
    }
  }

  void _scheduleFlushTimer() {
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(_flushInterval, (_) {
      if (_buffer.isNotEmpty) unawaited(flush());
    });
  }

  /// Send up to [_flushBatchSize] entries. Failures keep the batch
  /// queued for the next tick — no retries, no exponential backoff,
  /// just "try again in 5s".
  Future<void> flush() async {
    if (!_enabled || _flushing) return;
    final api = _api;
    if (api == null || _buffer.isEmpty) return;

    _flushing = true;
    try {
      final take = _buffer.length > _flushBatchSize
          ? _flushBatchSize
          : _buffer.length;
      final batch = List<Map<String, dynamic>>.from(_buffer.take(take));

      try {
        await api.post('/api/logs', data: {'logs': batch});
        _buffer.removeRange(0, take);
      } catch (_) {
        // Server unreachable / 5xx — keep the entries buffered. We never
        // re-throw from here: a logging pipeline that crashes the app
        // would defeat its own purpose.
      }
    } finally {
      _flushing = false;
    }
  }

  @visibleForTesting
  void clearForTest() {
    _buffer.clear();
    _flushTimer?.cancel();
    _flushTimer = null;
    _api = null;
    _userId = null;
  }
}
