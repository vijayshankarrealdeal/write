import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:inkspacex/services/app_log.dart';
import 'package:inkspacex/services/api/api_client.dart';
import 'package:inkspacex/services/storage_service.dart';

/// One SSE subscription with auto-reconnect.
///
/// Yields decoded JSON payloads from the ``data:`` lines of an
/// EventSource-style stream. The client posts no messages — it's a
/// pure server-to-client channel. On disconnect (server close, network
/// blip) we wait with exponential backoff (capped at 30s) and reconnect
/// using the freshest auth token from [StorageService] so a token
/// refresh between connects works automatically.
class _SseChannel {
  _SseChannel({
    required this.uri,
    required Future<String?> Function() tokenFetcher,
  }) : _tokenFetcher = tokenFetcher;

  final Uri uri;
  final Future<String?> Function() _tokenFetcher;
  final _controller = StreamController<Map<String, dynamic>>.broadcast();
  http.Client? _client;
  StreamSubscription<String>? _sub;
  Timer? _retryTimer;
  Duration _backoff = const Duration(seconds: 1);
  bool _disposed = false;

  Stream<Map<String, dynamic>> get stream => _controller.stream;

  Future<void> connect() async {
    if (_disposed) return;
    final token = await _tokenFetcher();
    final client = http.Client();
    _client = client;

    final request = http.Request('GET', uri);
    request.headers['Accept'] = 'text/event-stream';
    request.headers['Cache-Control'] = 'no-cache';
    if (token != null && token.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $token';
    }

    try {
      final response = await client.send(request);
      if (response.statusCode != 200) {
        log.w('[sse] $uri returned ${response.statusCode}');
        client.close();
        _scheduleReconnect();
        return;
      }
      // Successful connect — reset backoff so a brief blip doesn't
      // waste a full 30s wait the next time it disconnects.
      _backoff = const Duration(seconds: 1);

      final lines = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      // SSE event accumulator: collect ``data:`` lines until a blank
      // line terminates the event, then dispatch.
      final dataBuffer = StringBuffer();
      _sub = lines.listen(
        (line) {
          if (line.isEmpty) {
            if (dataBuffer.isEmpty) return;
            final raw = dataBuffer.toString();
            dataBuffer.clear();
            try {
              final decoded = jsonDecode(raw);
              if (decoded is Map<String, dynamic>) {
                _controller.add(decoded);
              }
            } catch (_) {
              // ignore malformed payloads
            }
            return;
          }
          if (line.startsWith(':')) return; // comment / heartbeat
          if (line.startsWith('data:')) {
            final value = line.length > 5 && line[5] == ' '
                ? line.substring(6)
                : line.substring(5);
            if (dataBuffer.isNotEmpty) dataBuffer.write('\n');
            dataBuffer.write(value);
          }
          // ``id:`` and ``event:`` are accepted but unused — payloads
          // already carry their own ``type`` field.
        },
        onError: (_) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
        cancelOnError: true,
      );
    } catch (e) {
      log.w('[sse] connect failed for $uri: $e');
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _sub?.cancel();
    _sub = null;
    _client?.close();
    _client = null;
    _retryTimer?.cancel();
    final delay = _backoff;
    _backoff = Duration(
      milliseconds: (delay.inMilliseconds * 2).clamp(1000, 30000),
    );
    _retryTimer = Timer(delay, connect);
  }

  Future<void> dispose() async {
    _disposed = true;
    _retryTimer?.cancel();
    await _sub?.cancel();
    _client?.close();
    await _controller.close();
  }
}

/// Realtime client backed by Server-Sent Events.
///
/// One process-wide instance held alongside the auth/data services.
/// Each logical channel (notifications, comments-per-post) gets its
/// own underlying SSE connection so a screen leaving the comment view
/// can tear down just that socket without disturbing notifications.
class ApiRealtimeService {
  ApiRealtimeService(this._storage);

  final StorageService _storage;
  final Map<String, _SseChannel> _channels = {};

  Uri _streamUri(String path) {
    final base = Uri.parse(ApiClient.baseUrl);
    return base.replace(path: path);
  }

  Future<String?> _token() async => _storage.getAuthToken();

  /// Stream of comment events for [feedItemId]. Payloads are raw decoded
  /// JSON maps shaped like:
  ///   {"type": "comment.created", "comment": { ... }}
  ///   {"type": "comment.deleted", "comment_id": "..."}
  Stream<Map<String, dynamic>> commentsChannel(String feedItemId) {
    return _channelFor(
      'comments:$feedItemId',
      _streamUri('/api/stream/feed/$feedItemId/comments'),
    );
  }

  /// Singleton notifications channel for the signed-in user. Payloads:
  ///   {"type": "notification", "id": "...", "kind": "comment", ...}
  Stream<Map<String, dynamic>> notificationsChannel() {
    return _channelFor(
      'notifications:self',
      _streamUri('/api/stream/notifications'),
    );
  }

  Stream<Map<String, dynamic>> _channelFor(String key, Uri uri) {
    var ch = _channels[key];
    if (ch == null) {
      ch = _SseChannel(uri: uri, tokenFetcher: _token);
      _channels[key] = ch;
      unawaited(ch.connect());
    }
    return ch.stream;
  }

  Future<void> closeChannel(String key) async {
    final ch = _channels.remove(key);
    await ch?.dispose();
  }

  Future<void> closeCommentsChannel(String feedItemId) =>
      closeChannel('comments:$feedItemId');

  Future<void> dispose() async {
    final all = _channels.values.toList();
    _channels.clear();
    for (final ch in all) {
      await ch.dispose();
    }
  }
}
