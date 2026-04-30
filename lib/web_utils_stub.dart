void listenForUpdates() {
  // No-op on non-web platforms
}

({String access, String refresh})? consumeOAuthTokensFromUrl() => null;

String? consumeGoogleErrorFromUrl() => null;

void redirectToGoogleSignIn(String apiBaseUrl) {
  throw UnsupportedError('redirectToGoogleSignIn is web-only');
}
