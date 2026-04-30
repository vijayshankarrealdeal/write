import 'package:web/web.dart' as web;
import 'dart:js_interop';
import 'package:flutter_web_plugins/url_strategy.dart';

void useWebPathUrlStrategy() {
  usePathUrlStrategy();
}

void listenForUpdates() {
  web.window.navigator.serviceWorker.addEventListener(
    'controllerchange',
    (web.Event event) {
      web.window.location.reload();
    }.toJS,
  );
}

/// Pulls auth tokens out of the URL fragment after the backend's Google OAuth
/// callback redirect. Returns null when the fragment carries no tokens.
/// Clears the fragment from the address bar on success so a refresh doesn't
/// re-import stale tokens.
({String access, String refresh})? consumeOAuthTokensFromUrl() {
  final hash = web.window.location.hash;
  if (hash.isEmpty) return null;
  final raw = hash.startsWith('#') ? hash.substring(1) : hash;
  if (!raw.contains('access_token=')) return null;

  final params = Uri.splitQueryString(raw);
  final access = params['access_token'];
  final refresh = params['refresh_token'];
  if (access == null || refresh == null || access.isEmpty || refresh.isEmpty) {
    return null;
  }

  final loc = web.window.location;
  final clean = '${loc.pathname}${loc.search}';
  web.window.history.replaceState(null, '', clean);

  return (access: access, refresh: refresh);
}

/// Reads `?google_error=...` (set by our callback when verification fails) so
/// the login page can surface it. Removes the param from the URL on read.
String? consumeGoogleErrorFromUrl() {
  final loc = web.window.location;
  final hash = loc.hash;
  String? err;

  if (hash.isNotEmpty) {
    final raw = hash.startsWith('#') ? hash.substring(1) : hash;
    final params = Uri.splitQueryString(raw);
    err = params['google_error'];
    if (err != null) {
      web.window.history.replaceState(null, '', '${loc.pathname}${loc.search}');
      return err;
    }
  }
  return null;
}

/// Redirects the browser to the backend's Google OAuth start endpoint.
/// The page navigates away — any code after this call won't run.
void redirectToGoogleSignIn(String apiBaseUrl) {
  final callbackUri = Uri.encodeComponent(web.window.location.href);
  web.window.location.assign(
    '$apiBaseUrl/api/auth/google/start?callback_uri=$callbackUri',
  );
}
