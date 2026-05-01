void useWebPathUrlStrategy() {
  // No-op on non-web platforms
}

void listenForUpdates() {
  // No-op on non-web platforms
}

({String access, String refresh})? consumeOAuthTokensFromUrl() => null;

String? consumeGoogleErrorFromUrl() => null;

void Function() installFindShortcutSuppressor() => () {};

void redirectToGoogleSignIn(String apiBaseUrl) {
  throw UnsupportedError('redirectToGoogleSignIn is web-only');
}
