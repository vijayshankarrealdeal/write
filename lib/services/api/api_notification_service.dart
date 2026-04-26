import 'package:inkspacex/models/notification_model.dart';
import 'package:inkspacex/services/api/api_client.dart';

/// REST client for the notifications API.
class ApiNotificationService {
  ApiNotificationService(this._client);

  final ApiClient _client;

  Future<List<NotificationModel>> list({int limit = 50, String? cursor}) async {
    final response = await _client.get(
      '/api/notifications/',
      queryParams: {
        'limit': limit,
        if (cursor != null) 'cursor': cursor,
      },
    );
    return (response.data as List)
        .map((d) => NotificationModel.fromJson(Map<String, dynamic>.from(d as Map)))
        .toList();
  }

  Future<int> unreadCount() async {
    final response = await _client.get('/api/notifications/unread-count');
    final data = response.data;
    if (data is Map && data['unread'] is num) {
      return (data['unread'] as num).toInt();
    }
    return 0;
  }

  /// Mark notifications as read. When [ids] is null, marks ALL as read.
  Future<void> markRead({List<String>? ids}) async {
    await _client.post('/api/notifications/mark-read', data: {
      if (ids != null) 'ids': ids,
    });
  }

  Future<void> delete(String id) async {
    await _client.delete('/api/notifications/$id');
  }
}
