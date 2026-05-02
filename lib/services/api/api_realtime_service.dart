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
  // Reference-counted channel acquisitions so multiple consumers can
  // share one underlying SSE socket. Each [commentsChannel] /
  // [writingChannel] call is one acquire; each matching `close…` is one
  // release. The socket disposes only when the count returns to zero.
  final Map<String, int> _refs = {};

  /// Op ids of mutating requests this client recently sent. Each request
  /// stamps an X-Op-Id header; the backend mirrors it in the broadcast
  /// payload. The originating client uses [wasIssuedByMe] to ignore its
  /// own echoes (otherwise the editor would re-apply its own writes and
  /// could clobber a newer local keystroke).
  ///
  /// Entries auto-expire after [_opIdTtl] — long enough to outlive any
  /// realistic round-trip, short enough that the set never grows
  /// unboundedly during a long session.
  final Map<String, DateTime> _issuedOpIds = {};
  static const Duration _opIdTtl = Duration(seconds: 60);

  Uri _streamUri(String path) {
    final base = Uri.parse(ApiClient.baseUrl);
    return base.replace(path: path);
  }

  Future<String?> _token() async => _storage.getAuthToken();

  /// Stream of per-feed-item events for [feedItemId]. The backend channel
  /// is `feed:{id}` and carries every event broadcast for the post —
  /// not only comments. Payloads include:
  ///   {"type": "comment.created", "comment": {...}, "comments_count": N}
  ///   {"type": "comment.deleted", "comment_id": "...", "comments_count": N}
  ///   {"type": "like.added",      "likes_count": N, "actor_id": "..."}
  ///   {"type": "like.removed",    "likes_count": N, "actor_id": "..."}
  /// Each call increments the channel's refcount; pair with
  /// [closeCommentsChannel] when done so the underlying socket survives
  /// other subscribers but is torn down when the last one releases.
  Stream<Map<String, dynamic>> commentsChannel(String feedItemId) {
    final key = 'comments:$feedItemId';
    _refs[key] = (_refs[key] ?? 0) + 1;
    return _channelFor(
      key,
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

  /// Live writing/section mutations for [writingId]. Payloads:
  ///   {"type": "writing.updated", "op_id": "...", "writing": {...}}
  ///   {"type": "writing.deleted", "op_id": "...", "writing_id": "..."}
  ///   {"type": "section.created", "op_id": "...", "section": {...}, "section_ids": [...]}
  ///   {"type": "section.updated", "op_id": "...", "section": {...}}
  ///   {"type": "section.deleted", "op_id": "...", "section_id": "...", "section_ids": [...]}
  Stream<Map<String, dynamic>> writingChannel(String writingId) {
    final key = 'writing:$writingId';
    _refs[key] = (_refs[key] ?? 0) + 1;
    return _channelFor(
      key,
      _streamUri('/api/stream/writings/$writingId'),
    );
  }

  /// Record an op id we are about to send. The data service calls this
  /// just before the HTTP request so an echo that races back via SSE is
  /// already known by the time it arrives.
  void recordIssuedOp(String opId) {
    if (opId.isEmpty) return;
    _issuedOpIds[opId] = DateTime.now().add(_opIdTtl);
    _gcIssuedOps();
  }

  /// True if [opId] was issued by this client within the TTL window —
  /// used to filter out broadcast echoes of our own writes.
  bool wasIssuedByMe(String? opId) {
    if (opId == null || opId.isEmpty) return false;
    final exp = _issuedOpIds[opId];
    if (exp == null) return false;
    if (exp.isBefore(DateTime.now())) {
      _issuedOpIds.remove(opId);
      return false;
    }
    return true;
  }

  void _gcIssuedOps() {
    if (_issuedOpIds.length < 64) return;
    final now = DateTime.now();
    _issuedOpIds.removeWhere((_, exp) => exp.isBefore(now));
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
    _refs.remove(key);
    await ch?.dispose();
  }

  Future<void> _release(String key) async {
    final remaining = (_refs[key] ?? 1) - 1;
    if (remaining > 0) {
      _refs[key] = remaining;
      return;
    }
    await closeChannel(key);
  }

  Future<void> closeCommentsChannel(String feedItemId) =>
      _release('comments:$feedItemId');

  Future<void> closeWritingChannel(String writingId) =>
      _release('writing:$writingId');

  Future<void> dispose() async {
    final all = _channels.values.toList();
    _channels.clear();
    for (final ch in all) {
      await ch.dispose();
    }
  }
}
