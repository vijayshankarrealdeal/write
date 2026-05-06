import 'dart:math';
import 'package:flutter/material.dart';

/// Hierarchical role of a section within the binder.
///
/// `chapter` and `scene` are the only nodes whose `content` is a meaningful
/// Quill Delta. `act` and `folder` are organizational containers. `research`
/// and `trash` are author-side scratch zones — never serialized into a
/// published artifact (see `includeInPublish`).
enum SectionKind { act, chapter, scene, folder, research, trash }

extension SectionKindCodec on SectionKind {
  String get code => name;
  static SectionKind fromCode(String? code) {
    if (code == null) return SectionKind.chapter;
    for (final k in SectionKind.values) {
      if (k.name == code) return k;
    }
    return SectionKind.chapter;
  }
}

class SectionModel {
  String id;
  String title;
  String content;
  String canvasData;
  bool isSynced;
  Color sectionColor;
  DateTime createdAt;
  DateTime updatedAt;

  // Binder hierarchy. `parentId == null` puts the section at the top
  // level of its writing — the legacy flat layout. Non-null nests the
  // section under another (e.g. a Chapter under an Act, a Scene under
  // a Chapter).
  String? parentId;
  // Explicit ordering within `parentId`. Doubles as a sort key in cards
  // and outline views; rewritten on drag-reorder.
  int order;
  SectionKind kind;

  // Short text shown on corkboard cards and outline rows. Author-side only.
  String synopsis;
  // Free-form scratchpad ("graveyard for cut text"). Author-side only.
  String notes;
  // ARGB int when the user has assigned a label. Distinct from
  // `sectionColor` (a per-section accent stamped at creation).
  int? labelColor;
  // Per-scene tags ("Daisy", "POV: Nick", "Romance"). Powers the binder
  // search like `keyword:Daisy`.
  List<String> keywords;
  // Author's per-section publish gate. Defaults to true so legacy flat
  // writings continue to publish unchanged. Sections under Research /
  // Trash are auto-set to false at folder-creation time.
  bool includeInPublish;

  SectionModel({
    required this.id,
    required this.title,
    required this.content,
    this.canvasData = '',
    this.isSynced = false,
    required this.sectionColor,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.parentId,
    this.order = 0,
    this.kind = SectionKind.chapter,
    this.synopsis = '',
    this.notes = '',
    this.labelColor,
    List<String>? keywords,
    this.includeInPublish = true,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now(),
        keywords = keywords ?? <String>[];

  factory SectionModel.fromJson(Map<String, dynamic> json) {
    return SectionModel(
      id: json['id'],
      title: json['title'],
      content: json['content'],
      canvasData: json['canvasData'] ?? '',
      sectionColor: json['sectionColor'] != null
          ? Color(json['sectionColor'])
          : Colors.primaries[Random().nextInt(Colors.primaries.length)]
                .withAlpha(150),
      isSynced: json['isSynced'] ?? false,
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'])
          : DateTime.now(),
      updatedAt: json['updatedAt'] != null
          ? DateTime.parse(json['updatedAt'])
          : DateTime.now(),
      parentId: json['parentId'] as String?,
      order: (json['order'] as num?)?.toInt() ?? 0,
      kind: SectionKindCodec.fromCode(json['kind'] as String?),
      synopsis: (json['synopsis'] as String?) ?? '',
      notes: (json['notes'] as String?) ?? '',
      labelColor: (json['labelColor'] as num?)?.toInt(),
      keywords: (json['keywords'] is List)
          ? (json['keywords'] as List).whereType<String>().toList()
          : <String>[],
      includeInPublish: json['includeInPublish'] is bool
          ? json['includeInPublish'] as bool
          : true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'content': content,
      'canvasData': canvasData,
      'isSynced': isSynced,
      'sectionColor': sectionColor.value,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'parentId': parentId,
      'order': order,
      'kind': kind.code,
      'synopsis': synopsis,
      'notes': notes,
      'labelColor': labelColor,
      'keywords': keywords,
      'includeInPublish': includeInPublish,
    };
  }
}
