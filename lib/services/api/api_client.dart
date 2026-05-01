import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
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

  // Main domain proxies /api/* to FastAPI via Caddy, so web hits same-origin
  // and native builds reach the same backend. Override via
  // --dart-define=API_BASE_URL=... (e.g. http://localhost:8000 for dev).
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://inkspacex.com',
  );

  static const Duration _timeout = Duration(seconds: 30);

  ApiClient(this._storage);

  Future<ApiResponse> _request(
    String method,
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParams,
    Map<String, String>? extraHeaders,
    bool isRetry = false,
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
    if (status >= 500) {
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

  Future<bool> _refreshToken() async {
    final refreshToken = _storage.getRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) return false;

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
    } catch (e, st) {
      log.e('[auth] Token refresh failed', error: e, stackTrace: st);
    }
    return false;
  }

  // -- Convenience methods (signatures preserved from the Dio version) --

  Future<ApiResponse> get(String path, {Map<String, dynamic>? queryParams}) =>
      _request('GET', path, queryParams: queryParams);

  Future<ApiResponse> post(
    String path, {
    dynamic data,
    Map<String, String>? headers,
  }) =>
      _request('POST', path, data: data, extraHeaders: headers);

  Future<ApiResponse> put(
    String path, {
    dynamic data,
    Map<String, String>? headers,
  }) =>
      _request('PUT', path, data: data, extraHeaders: headers);

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
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final token = _storage.getAuthToken();

    final request = http.MultipartRequest('POST', uri);
    if (token != null && token.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $token';
    }
    request.files.add(
      http.MultipartFile.fromBytes(fieldName, bytes, filename: filename),
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
