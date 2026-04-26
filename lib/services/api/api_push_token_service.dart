import 'package:inkspacex/services/api/api_client.dart';

/// Tiny REST client for registering / unregistering OS push tokens.
///
/// The actual token comes from FCM (Android) or APNS (iOS). The
/// frontend doesn't bundle the Firebase SDK directly — most apps
/// integrate that natively or via a separate package — but once a
/// token is acquired, hand it to [register] and the backend will
/// route push deliveries through it. See backend ``push_dispatcher``.
class ApiPushTokenService {
  ApiPushTokenService(this._client);

  final ApiClient _client;

  Future<void> register({
    required String platform,
    required String token,
    String? deviceLabel,
  }) async {
    await _client.post('/api/notifications/push-token', data: {
      'platform': platform,
      'token': token,
      if (deviceLabel != null) 'device_label': deviceLabel,
    });
  }

  Future<void> unregister(String token) async {
    await _client.delete(
      '/api/notifications/push-token?token=${Uri.encodeQueryComponent(token)}',
    );
  }
}
