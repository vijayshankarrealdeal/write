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
  final params = _parseFragmentParams(web.window.location.hash);
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
  final params = _parseFragmentParams(loc.hash);
  final err = params['google_error'];
  if (err != null) {
    web.window.history.replaceState(null, '', '${loc.pathname}${loc.search}');
    return err;
  }
  return null;
}

/// Parse a URL fragment into params, defensive against legacy hash-routing
/// residue (e.g. `#/login#access_token=…&refresh_token=…`, where the first
/// `#` is the routing prefix and the second is the OAuth fragment glued on
/// by an old build). The browser collapses both `#` into one fragment, so
/// the literal `#` survives inside the fragment string and ends up as part
/// of the first key. Strip any leading prefix up to (and including) the
/// last `#` in each segment's key before matching.
Map<String, String> _parseFragmentParams(String hash) {
  if (hash.isEmpty) return const {};
  final raw = hash.startsWith('#') ? hash.substring(1) : hash;
  final out = <String, String>{};
  for (final segment in raw.split('&')) {
    final eq = segment.indexOf('=');
    if (eq <= 0) continue;
    var key = segment.substring(0, eq);
    final lastHash = key.lastIndexOf('#');
    if (lastHash >= 0) key = key.substring(lastHash + 1);
    final value = Uri.decodeComponent(segment.substring(eq + 1));
    out[key] = value;
  }
  return out;
}

/// Suppress the browser's Cmd/Ctrl+F shortcut so the in-app Find bar can
/// claim it without the native find widget also opening. Returns a remover
/// the caller must invoke on dispose.
void Function() installFindShortcutSuppressor() {
  void handle(web.Event event) {
    final ke = event as web.KeyboardEvent;
    if (!(ke.metaKey || ke.ctrlKey)) return;
    if (ke.key.toLowerCase() == 'f') {
      ke.preventDefault();
    }
  }

  final jsHandler = handle.toJS;
  web.window.addEventListener('keydown', jsHandler);
  return () => web.window.removeEventListener('keydown', jsHandler);
}

/// Redirects the browser to the backend's Google OAuth start endpoint.
/// The page navigates away — any code after this call won't run.
void redirectToGoogleSignIn(String apiBaseUrl) {
  final callbackUri = Uri.encodeComponent(web.window.location.href);
  web.window.location.assign(
    '$apiBaseUrl/api/auth/google/start?callback_uri=$callbackUri',
  );
}
