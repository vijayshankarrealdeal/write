import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;
import 'package:inkspacex/services/app_log.dart';
import 'package:inkspacex/services/storage_service.dart';

/// Minimal response shape returned by [ApiClient] methods.
/// Kept compatible with the previous Dio-based interface (`.data`, `.statusCode`).
class ApiResponse {
  final int statusCode;
  final dynamic data;
  final Map<String, String> headers;

  ApiResponse({
    required this.statusCode,
    required this.data,
    required this.headers,
  });
}

enum ApiErrorType { timeout, connection, badResponse, unknown }

/// Extracts a human-readable message from a parsed API error body.
/// Handles FastAPI's two error shapes:
///   - Plain HTTPException:        {"detail": "string"}
///   - Pydantic validation (422):  {"detail": [{"loc": [...], "msg": "..."}, ...]}
String _extractErrorMessage(dynamic parsed, int status, {String? fallback}) {
  if (parsed is Map) {
    final detail = parsed['detail'];
    if (detail is String && detail.isNotEmpty) return detail;
    if (detail is List && detail.isNotEmpty) {
      final parts = <String>[];
      for (final entry in detail) {
        if (entry is Map) {
          final msg = entry['msg'];
          final loc = entry['loc'];
          final field = (loc is List && loc.length > 1)
              ? loc.skip(1).join('.')
              : null;
          if (msg is String && msg.isNotEmpty) {
            parts.add(field != null ? '$field: $msg' : msg);
          }
        }
      }
      if (parts.isNotEmpty) return parts.join('; ');
    }
  }
  return fallback ?? 'HTTP $status';
}

class ApiException implements Exception {
  final int? statusCode;
  final dynamic data;
  final String message;
  final String? path;
  final ApiErrorType type;

  ApiException({
    this.statusCode,
    this.data,
    required this.message,
    this.path,
    required this.type,
  });

  @override
  String toString() => 'ApiException($statusCode, $type): $message';
}

/// HTTP client with JWT injection, automatic token refresh, and a guard
/// that rejects HTML responses on /api/* paths (so a proxy misconfig can
/// never reach jsonDecode and crash the app).
class ApiClient {
  final StorageService _storage;
  final http.Client _http = http.Client();
  // Single-flight refresh: a burst of parallel 401s should trigger one
  // refresh, not N. Without this, racing refreshes overwrite each other's
  // rotated refresh tokens and the loser silently logs the user out.
  Future<bool>? _refreshInFlight;

  /// Invoked when the refresh endpoint itself rejects our refresh token
  /// (401/403/410). At that point our session is genuinely dead and the
  /// app must redirect to login — the AuthProvider sets this hook in its
  /// constructor to call [logout]. We do *not* fire this on transient
  /// network failures; those should keep the queued ops around so the
  /// user's writing isn't lost when the network comes back.
  void Function()? onSessionExpired;
  bool _sessionExpiredFired = false;

  // Main domain proxies /api/* to FastAPI via Caddy, so web hits same-origin
  // and native builds reach the same backend. Override via
  // --dart-define=API_BASE_URL=... (e.g. http://localhost:8000 for dev).
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://inkspacex.com',
  );

  static const Duration _timeout = Duration(seconds: 30);

  /// Window before access-token expiry within which a passing API call
  /// (or a scheduled tick, or an app-resume) will pre-emptively refresh.
  /// Wide enough that a slow network has time to complete the refresh
  /// before the token actually expires; narrow enough that we don't burn
  /// a refresh on every keystroke.
  static const Duration _refreshBuffer = Duration(minutes: 5);

  Timer? _refreshTimer;

  ApiClient(this._storage);

  /// Decode a JWT's `exp` claim as a UTC DateTime. Returns null if the
  /// token is malformed or missing `exp` — callers must treat null as
  /// "can't tell, assume valid" so a malformed-but-accepted token doesn't
  /// log the user out.
  DateTime? _parseJwtExp(String token) {
    try {
      final parts = token.split('.');
      if (parts.length < 2) return null;
      final normalized = base64.normalize(parts[1]);
      final payload = jsonDecode(utf8.decode(base64Url.decode(normalized)))
          as Map<String, dynamic>;
      final exp = payload['exp'];
      if (exp is! int) return null;
      return DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
    } catch (_) {
      return null;
    }
  }

  /// Pre-emptively refresh if the access token is missing, already
  /// expired, or expires within [_refreshBuffer]. Returns true if a
  /// usable token is available afterwards. Safe to call repeatedly —
  /// the underlying [_refreshToken] is single-flight and shared across
  /// concurrent callers.
  ///
  /// This is what makes the user feel "always logged in" Firebase-style:
  /// every app-resume / lifecycle wake-up calls this, so the access
  /// token is rotated *before* it can produce a 401, and the refresh
  /// token's TTL clock resets each time.
  Future<bool> ensureFreshAccessToken() async {
    final access = _storage.getAuthToken();
    if (access == null || access.isEmpty) return false;
    final exp = _parseJwtExp(access);
    if (exp == null) return true;
    final now = DateTime.now().toUtc();
    if (exp.isAfter(now.add(_refreshBuffer))) {
      _scheduleNextRefresh();
      return true;
    }
    final ok = await _refreshToken();
    if (ok) _scheduleNextRefresh();
    return ok;
  }

  /// Arm a one-shot timer to refresh the access token shortly before it
  /// expires. Re-armed automatically each time a refresh succeeds, so a
  /// foreground session keeps a continuously-fresh token without any
  /// caller having to think about it.
  void _scheduleNextRefresh() {
    _refreshTimer?.cancel();
    final access = _storage.getAuthToken();
    if (access == null || access.isEmpty) return;
    final exp = _parseJwtExp(access);
    if (exp == null) return;
    final now = DateTime.now().toUtc();
    final fireAt = exp.subtract(_refreshBuffer);
    final delay = fireAt.difference(now);
    if (delay.isNegative) {
      // Already past the refresh point — fire on next microtask.
      unawaited(ensureFreshAccessToken());
      return;
    }
    _refreshTimer = Timer(delay, () {
      unawaited(ensureFreshAccessToken());
    });
  }

  /// Stop the periodic refresh — called on logout so we don't keep
  /// trying to refresh tokens for a signed-out user.
  void cancelRefreshSchedule() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _sessionExpiredFired = false;
  }

  Future<ApiResponse> _request(
    String method,
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParams,
    Map<String, String>? extraHeaders,
    bool isRetry = false,
    bool silent = false,
  }) async {
    // Iterable values pass through as repeated `?k=a&k=b` (Uri.replace
    // recognises Iterable<String>). Everything else gets stringified.
    final uri = Uri.parse('$baseUrl$path').replace(
      queryParameters: queryParams?.map((k, v) {
        if (v is Iterable && v is! String) {
          return MapEntry(k, v.map((e) => e?.toString() ?? '').toList());
        }
        return MapEntry(k, v?.toString() ?? '');
      }),
    );

    final token = _storage.getAuthToken();
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      if (extraHeaders != null) ...extraHeaders,
    };

    final started = DateTime.now().millisecondsSinceEpoch;
    log.d('[http] → $method $path');

    final bodyStr = data == null
        ? null
        : (data is String ? data : jsonEncode(data));

    http.Response resp;
    try {
      switch (method) {
        case 'GET':
          resp = await _http.get(uri, headers: headers).timeout(_timeout);
          break;
        case 'POST':
          resp = await _http
              .post(uri, headers: headers, body: bodyStr)
              .timeout(_timeout);
          break;
        case 'PUT':
          resp = await _http
              .put(uri, headers: headers, body: bodyStr)
              .timeout(_timeout);
          break;
        case 'PATCH':
          resp = await _http
              .patch(uri, headers: headers, body: bodyStr)
              .timeout(_timeout);
          break;
        case 'DELETE':
          resp = await _http
              .delete(uri, headers: headers, body: bodyStr)
              .timeout(_timeout);
          break;
        default:
          throw ApiException(
            message: 'Unsupported method $method',
            type: ApiErrorType.unknown,
            path: path,
          );
      }
    } on TimeoutException {
      throw ApiException(
        message: 'Connection timed out',
        type: ApiErrorType.timeout,
        path: path,
      );
    } on ApiException {
      rethrow;
    } catch (e) {
      log.w('[http] connection error on $method $path: $e (${e.runtimeType})');
      throw ApiException(
        message: 'Cannot reach the server. Check your internet connection.',
        type: ApiErrorType.connection,
        path: path,
      );
    }

    final duration = DateTime.now().millisecondsSinceEpoch - started;
    final status = resp.statusCode;
    final contentType = resp.headers['content-type'] ?? '';
    final body = resp.body;

    // Guard: an /api/* endpoint that returned HTML (proxy misconfig,
    // SPA fallback, gateway error page) gets surfaced as an exception
    // instead of crashing the app with an unhandled JSON parse error.
    final looksLikeHtml =
        contentType.contains('text/html') || body.trimLeft().startsWith('<');
    if (path.startsWith('/api') && looksLikeHtml) {
      log.e('[http] API returned HTML instead of JSON (status $status) for $path');
      throw ApiException(
        statusCode: status,
        message: 'Unexpected HTML response from $path',
        path: path,
        type: ApiErrorType.badResponse,
      );
    }

    dynamic parsed;
    if (body.isNotEmpty) {
      try {
        parsed = jsonDecode(body);
      } catch (_) {
        parsed = body;
      }
    }

    final logMsg = '[http] ← $method $path → $status (${duration}ms)';
    if (silent && status >= 400) {
      // Best-effort caller — failures are expected and already handled.
      // Keep the line at debug so it never ships to remote logs.
      log.d(logMsg);
    } else if (status >= 500) {
      log.e(logMsg);
    } else if (status >= 400) {
      log.w(logMsg);
    } else {
      log.i(logMsg);
    }

    if (status == 401 && !isRetry) {
      final refreshed = await _refreshToken();
      if (refreshed) {
        return _request(
          method,
          path,
          data: data,
          queryParams: queryParams,
          extraHeaders: extraHeaders,
          isRetry: true,
          silent: silent,
        );
      }
    }

    if (status >= 400) {
      throw ApiException(
        statusCode: status,
        data: parsed,
        message: _extractErrorMessage(parsed, status),
        path: path,
        type: ApiErrorType.badResponse,
      );
    }

    return ApiResponse(
      statusCode: status,
      data: parsed,
      headers: resp.headers,
    );
  }

  Future<bool> _refreshToken() {
    return _refreshInFlight ??= _doRefresh()
      ..whenComplete(() => _refreshInFlight = null);
  }

  Future<bool> _doRefresh() async {
    final refreshToken = _storage.getRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) {
      _signalSessionExpired();
      return false;
    }

    try {
      final resp = await http.post(
        Uri.parse('$baseUrl/api/auth/refresh'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'refresh_token': refreshToken}),
      ).timeout(_timeout);

      if (resp.statusCode == 200) {
        final body = resp.body;
        if (body.isEmpty || body.trimLeft().startsWith('<')) return false;
        final data = jsonDecode(body) as Map<String, dynamic>;
        await _storage.saveAuthToken(data['access_token']);
        await _storage.saveRefreshToken(data['refresh_token']);
        return true;
      }
      // The refresh endpoint itself rejected us — our refresh token is
      // expired or revoked. No retry will help; the session is dead.
      // Network errors (caught below) deliberately do NOT fire this so a
      // brief offline window doesn't sign the user out and discard their
      // local edits.
      if (resp.statusCode == 401 ||
          resp.statusCode == 403 ||
          resp.statusCode == 410) {
        _signalSessionExpired();
      }
    } catch (e, st) {
      log.e('[auth] Token refresh failed', error: e, stackTrace: st);
    }
    return false;
  }

  void _signalSessionExpired() {
    if (_sessionExpiredFired) return;
    _sessionExpiredFired = true;
    log.w('[auth] Session expired — refresh token is dead');
    final cb = onSessionExpired;
    if (cb != null) cb();
  }

  // -- Convenience methods (signatures preserved from the Dio version) --

  Future<ApiResponse> get(String path, {Map<String, dynamic>? queryParams}) =>
      _request('GET', path, queryParams: queryParams);

  Future<ApiResponse> post(
    String path, {
    dynamic data,
    Map<String, String>? headers,
    bool silent = false,
  }) =>
      _request(
        'POST',
        path,
        data: data,
        extraHeaders: headers,
        silent: silent,
      );

  Future<ApiResponse> put(
    String path, {
    dynamic data,
    Map<String, String>? headers,
  }) =>
      _request('PUT', path, data: data, extraHeaders: headers);

  Future<ApiResponse> patch(
    String path, {
    dynamic data,
    Map<String, String>? headers,
  }) =>
      _request('PATCH', path, data: data, extraHeaders: headers);

  Future<ApiResponse> delete(
    String path, {
    Map<String, String>? headers,
  }) =>
      _request('DELETE', path, extraHeaders: headers);

  Future<ApiResponse> uploadFile(
    String path,
    Uint8List bytes, {
    String filename = 'file.jpg',
    String fieldName = 'file',
    bool isRetry = false,
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final token = _storage.getAuthToken();

    final request = http.MultipartRequest('POST', uri);
    if (token != null && token.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $token';
    }
    request.files.add(
      http.MultipartFile.fromBytes(
        fieldName,
        bytes,
        filename: filename,
        contentType: _sniffImageMediaType(bytes),
      ),
    );

    http.Response resp;
    try {
      final streamed = await request.send().timeout(_timeout);
      resp = await http.Response.fromStream(streamed);
    } on TimeoutException {
      throw ApiException(
        message: 'Upload timed out',
        type: ApiErrorType.timeout,
        path: path,
      );
    } catch (e) {
      throw ApiException(
        message: 'Cannot reach the server. Check your internet connection.',
        type: ApiErrorType.connection,
        path: path,
      );
    }

    final body = resp.body;
    final contentType = resp.headers['content-type'] ?? '';
    final looksLikeHtml =
        contentType.contains('text/html') || body.trimLeft().startsWith('<');
    if (path.startsWith('/api') && looksLikeHtml) {
      throw ApiException(
        statusCode: resp.statusCode,
        message: 'Unexpected HTML response from $path',
        path: path,
        type: ApiErrorType.badResponse,
      );
    }

    if (resp.statusCode == 401 && !isRetry) {
      final refreshed = await _refreshToken();
      if (refreshed) {
        return uploadFile(
          path,
          bytes,
          filename: filename,
          fieldName: fieldName,
          isRetry: true,
        );
      }
    }

    dynamic parsed;
    if (body.isNotEmpty) {
      try {
        parsed = jsonDecode(body);
      } catch (_) {
        parsed = body;
      }
    }

    if (resp.statusCode >= 400) {
      throw ApiException(
        statusCode: resp.statusCode,
        data: parsed,
        message: _extractErrorMessage(parsed, resp.statusCode,
            fallback: 'Upload failed'),
        path: path,
        type: ApiErrorType.badResponse,
      );
    }

    return ApiResponse(
      statusCode: resp.statusCode,
      data: parsed,
      headers: resp.headers,
    );
  }
}

/// Sniffs the MIME type of an image from its leading magic bytes. Used so the
/// backend's `image/*` content-type check accepts the upload regardless of
/// what extension the caller hardcoded into the filename.
MediaType _sniffImageMediaType(Uint8List bytes) {
  if (bytes.length >= 4 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return MediaType('image', 'png');
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return MediaType('image', 'jpeg');
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return MediaType('image', 'webp');
  }
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38) {
    return MediaType('image', 'gif');
  }
  return MediaType('image', 'jpeg');
}
