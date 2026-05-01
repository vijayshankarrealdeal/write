import 'dart:convert';

/// In-document margin note / comment anchored to a text range inside a
/// section. Stored locally per section (Hive). The model carries
/// `authorId` so the same shape works once multi-user comments land.
///
/// Anchors are stored as `(start, length, anchoredText)`. On load, if the
/// text at the offset has drifted (edits before the anchor), we re-anchor
/// by searching for `anchoredText`. If it's gone, the annotation is marked
/// orphaned and surfaced separately in the side panel.
class EditorAnnotation {
  final String id;
  final String sectionId;
  final String authorId;
  final String authorName;

  /// Body of the comment (plain text for v1).
  final String body;

  /// Plain-text offset in the section's document where the highlight starts.
  final int anchorStart;

  /// Length of the anchored range, in plain-text characters.
  final int anchorLength;

  /// Snapshot of the originally-anchored text, used for re-anchoring when
  /// offsets drift due to edits elsewhere in the document.
  final String anchoredText;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// True if the user has marked the comment resolved. Resolved comments
  /// stay in storage but render muted and can be filtered out of the panel.
  final bool resolved;

  /// True if the anchored text could no longer be located on load. The
  /// comment is preserved but the in-document marker is hidden.
  final bool orphaned;

  /// Reply thread. Empty for v1; the field exists so multi-user threads
  /// can land without a model migration.
  final List<EditorAnnotationReply> replies;

  const EditorAnnotation({
    required this.id,
    required this.sectionId,
    required this.authorId,
    required this.authorName,
    required this.body,
    required this.anchorStart,
    required this.anchorLength,
    required this.anchoredText,
    required this.createdAt,
    required this.updatedAt,
    this.resolved = false,
    this.orphaned = false,
    this.replies = const [],
  });

  int get anchorEnd => anchorStart + anchorLength;

  EditorAnnotation copyWith({
    String? body,
    int? anchorStart,
    int? anchorLength,
    String? anchoredText,
    DateTime? updatedAt,
    bool? resolved,
    bool? orphaned,
    List<EditorAnnotationReply>? replies,
  }) {
    return EditorAnnotation(
      id: id,
      sectionId: sectionId,
      authorId: authorId,
      authorName: authorName,
      body: body ?? this.body,
      anchorStart: anchorStart ?? this.anchorStart,
      anchorLength: anchorLength ?? this.anchorLength,
      anchoredText: anchoredText ?? this.anchoredText,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
      resolved: resolved ?? this.resolved,
      orphaned: orphaned ?? this.orphaned,
      replies: replies ?? this.replies,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'sectionId': sectionId,
        'authorId': authorId,
        'authorName': authorName,
        'body': body,
        'anchorStart': anchorStart,
        'anchorLength': anchorLength,
        'anchoredText': anchoredText,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'resolved': resolved,
        'orphaned': orphaned,
        'replies': replies.map((r) => r.toJson()).toList(),
      };

  factory EditorAnnotation.fromJson(Map<String, dynamic> json) {
    return EditorAnnotation(
      id: json['id'] as String,
      sectionId: json['sectionId'] as String,
      authorId: (json['authorId'] ?? '') as String,
      authorName: (json['authorName'] ?? '') as String,
      body: (json['body'] ?? '') as String,
      anchorStart: (json['anchorStart'] as num).toInt(),
      anchorLength: (json['anchorLength'] as num).toInt(),
      anchoredText: (json['anchoredText'] ?? '') as String,
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? '') ??
          DateTime.now(),
      resolved: (json['resolved'] ?? false) as bool,
      orphaned: (json['orphaned'] ?? false) as bool,
      replies: ((json['replies'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => EditorAnnotationReply.fromJson(
              Map<String, dynamic>.from(m)))
          .toList(),
    );
  }

  String encode() => jsonEncode(toJson());
  static EditorAnnotation decode(String s) =>
      EditorAnnotation.fromJson(jsonDecode(s) as Map<String, dynamic>);
}

class EditorAnnotationReply {
  final String id;
  final String authorId;
  final String authorName;
  final String body;
  final DateTime createdAt;

  const EditorAnnotationReply({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.body,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'authorId': authorId,
        'authorName': authorName,
        'body': body,
        'createdAt': createdAt.toIso8601String(),
      };

  factory EditorAnnotationReply.fromJson(Map<String, dynamic> json) {
    return EditorAnnotationReply(
      id: json['id'] as String,
      authorId: (json['authorId'] ?? '') as String,
      authorName: (json['authorName'] ?? '') as String,
      body: (json['body'] ?? '') as String,
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}
