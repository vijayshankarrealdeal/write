/// In-app notification surfaced in the notifications center.
///
/// The shape mirrors the backend `Notification` schema. Server payloads
/// arrive in two contexts:
///   1. REST list response — uses the snake_case keys directly.
///   2. SSE event payload — same keys, plus a `type: "notification"`
///      tag we strip before parsing here.
class NotificationModel {
  NotificationModel({
    required this.id,
    required this.kind,
    this.actorId,
    this.actorName,
    this.actorPhotoUrl,
    this.feedItemId,
    this.feedItemTitle,
    this.data,
    required this.read,
    required this.createdAt,
  });

  final String id;
  final String kind;
  final String? actorId;
  final String? actorName;
  final String? actorPhotoUrl;
  final String? feedItemId;
  final String? feedItemTitle;
  final Map<String, dynamic>? data;
  final bool read;
  final DateTime createdAt;

  NotificationModel copyWith({bool? read}) => NotificationModel(
        id: id,
        kind: kind,
        actorId: actorId,
        actorName: actorName,
        actorPhotoUrl: actorPhotoUrl,
        feedItemId: feedItemId,
        feedItemTitle: feedItemTitle,
        data: data,
        read: read ?? this.read,
        createdAt: createdAt,
      );

  factory NotificationModel.fromJson(Map<String, dynamic> json) {
    return NotificationModel(
      id: (json['id'] ?? '').toString(),
      kind: (json['kind'] ?? 'system').toString(),
      actorId: json['actor_id']?.toString(),
      actorName: json['actor_name'] as String?,
      actorPhotoUrl: json['actor_photo_url'] as String?,
      feedItemId: json['feed_item_id']?.toString(),
      feedItemTitle: json['feed_item_title'] as String?,
      data: json['data'] is Map<String, dynamic>
          ? json['data'] as Map<String, dynamic>
          : (json['data'] is Map)
              ? Map<String, dynamic>.from(json['data'] as Map)
              : null,
      read: json['read'] == true,
      createdAt: json['created_at'] is String
          ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  /// Short title surfaced in the notifications list.
  String get title {
    final actor = actorName ?? 'Someone';
    switch (kind) {
      case 'like':
        return '$actor liked your story';
      case 'comment':
        return '$actor commented on your story';
      case 'reply':
        return '$actor replied to your comment';
      case 'system':
        final t = data?['title'];
        return (t is String && t.isNotEmpty) ? t : 'InkSpaceX';
      default:
        return actor;
    }
  }

  /// Optional second line — the story title when relevant, or a snippet.
  String? get subtitle {
    if (kind == 'system') {
      final b = data?['body'];
      if (b is String && b.isNotEmpty) return b;
    }
    final excerpt = data?['excerpt'];
    if (excerpt is String && excerpt.isNotEmpty) return excerpt;
    return feedItemTitle;
  }
}
