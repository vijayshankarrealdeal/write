import 'package:inkspacex/models/image_meta.dart';

/// One-on-one conversation summary used in the chat list.
///
/// Mirrors the backend `ConversationResponse` schema. `otherUser` is the
/// participant that is NOT the signed-in user — the backend already
/// resolves which side that is, so the client doesn't have to.
class ConversationParticipant {
  ConversationParticipant({
    required this.id,
    this.name,
    this.photoUrl,
    this.photoMeta,
  });

  final String id;
  final String? name;
  final String? photoUrl;
  final ImageMeta? photoMeta;

  factory ConversationParticipant.fromJson(Map<String, dynamic> json) {
    return ConversationParticipant(
      id: (json['id'] ?? '').toString(),
      name: json['name'] as String?,
      photoUrl: json['photo_url'] as String?,
      photoMeta: ImageMeta.tryFromJson(json['photo_meta']),
    );
  }
}

class ConversationModel {
  ConversationModel({
    required this.id,
    required this.otherUser,
    this.lastMessageAt,
    this.lastMessagePreview,
    required this.unreadCount,
    required this.createdAt,
  });

  final String id;
  final ConversationParticipant otherUser;
  final DateTime? lastMessageAt;
  final String? lastMessagePreview;
  final int unreadCount;
  final DateTime createdAt;

  factory ConversationModel.fromJson(Map<String, dynamic> json) {
    final other = json['other_user'];
    return ConversationModel(
      id: (json['id'] ?? '').toString(),
      otherUser: other is Map
          ? ConversationParticipant.fromJson(Map<String, dynamic>.from(other))
          : ConversationParticipant(id: ''),
      lastMessageAt: json['last_message_at'] is String
          ? DateTime.tryParse(json['last_message_at'] as String)
          : null,
      lastMessagePreview: json['last_message_preview'] as String?,
      unreadCount: (json['unread_count'] as num?)?.toInt() ?? 0,
      createdAt: json['created_at'] is String
          ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  ConversationModel copyWith({
    DateTime? lastMessageAt,
    String? lastMessagePreview,
    int? unreadCount,
  }) {
    return ConversationModel(
      id: id,
      otherUser: otherUser,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
      unreadCount: unreadCount ?? this.unreadCount,
      createdAt: createdAt,
    );
  }
}
