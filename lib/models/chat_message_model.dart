import 'package:inkspacex/models/image_meta.dart';

/// One-on-one chat message. Mirrors the backend `ChatMessage` schema.
///
/// `kind` is a discriminator. The richer payloads (book, excerpt, section,
/// image) live in `attachment` so the same row holds plain text alongside
/// share cards. Add a kind here AND in the backend `MESSAGE_KINDS` set —
/// they must stay in lockstep.
enum ChatMessageKind {
  text,
  image,
  book,
  excerpt,
  section;

  String get wire => name;

  static ChatMessageKind fromWire(String? raw) {
    switch (raw) {
      case 'image':
        return ChatMessageKind.image;
      case 'book':
        return ChatMessageKind.book;
      case 'excerpt':
        return ChatMessageKind.excerpt;
      case 'section':
        return ChatMessageKind.section;
      default:
        return ChatMessageKind.text;
    }
  }
}

class ChatMessageModel {
  ChatMessageModel({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.kind,
    this.body,
    this.attachment,
    required this.createdAt,
    this.pending = false,
  });

  final String id;
  final String conversationId;
  final String senderId;
  final ChatMessageKind kind;
  final String? body;
  final Map<String, dynamic>? attachment;
  final DateTime createdAt;

  /// True for an optimistic local message that hasn't been confirmed by
  /// the server yet. Replaced by the server-stamped row on the next emit.
  final bool pending;

  factory ChatMessageModel.fromJson(Map<String, dynamic> json) {
    return ChatMessageModel(
      id: (json['id'] ?? '').toString(),
      conversationId: (json['conversation_id'] ?? '').toString(),
      senderId: (json['sender_id'] ?? '').toString(),
      kind: ChatMessageKind.fromWire(json['kind'] as String?),
      body: json['body'] as String?,
      attachment: _asMap(json['attachment']),
      createdAt: json['created_at'] is String
          ? DateTime.tryParse(json['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  ChatMessageModel copyWith({
    String? id,
    bool? pending,
  }) {
    return ChatMessageModel(
      id: id ?? this.id,
      conversationId: conversationId,
      senderId: senderId,
      kind: kind,
      body: body,
      attachment: attachment,
      createdAt: createdAt,
      pending: pending ?? this.pending,
    );
  }

  /// Pull the attachment image meta, if the kind carries one.
  ImageMeta? get attachmentImageMeta {
    final meta = attachment?['image_meta'];
    return ImageMeta.tryFromJson(meta);
  }

  String? get attachmentTitle => attachment?['title'] as String?;
  String? get attachmentSubtitle => attachment?['subtitle'] as String?;
  String? get attachmentUrl => attachment?['url'] as String?;
  String? get attachmentBookId => attachment?['book_id']?.toString();
  String? get attachmentSectionId => attachment?['section_id']?.toString();
}

Map<String, dynamic>? _asMap(dynamic v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) return Map<String, dynamic>.from(v);
  return null;
}
