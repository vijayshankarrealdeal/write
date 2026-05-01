import 'dart:convert';

/// A single point-in-time snapshot of a section's content. We store the
/// full Quill Delta JSON (small enough — typical section is a few KB) to
/// keep restore deterministic. Computing reverse-deltas is faster on disk
/// but pays for it in restore complexity, and writing tooling is more
/// reliable starting from full snapshots.
class SectionVersion {
  final String id;
  final String sectionId;

  /// Full Quill Delta JSON for the section at this point in time.
  final String contentJson;

  /// Plain-text word count at the time of capture — surfaced in the
  /// version list so users can scan deltas without opening each entry.
  final int wordCount;

  /// Optional label set by the user when manually creating a version
  /// ("before rewrite", "draft 2"). Empty for auto-snapshots.
  final String label;

  /// True if the user explicitly created the version (vs. an auto-capture
  /// from idle / session-close). Manual versions are excluded from the
  /// retention prune so they can't be silently dropped.
  final bool manual;

  final DateTime createdAt;

  const SectionVersion({
    required this.id,
    required this.sectionId,
    required this.contentJson,
    required this.wordCount,
    required this.createdAt,
    this.label = '',
    this.manual = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'sectionId': sectionId,
        'contentJson': contentJson,
        'wordCount': wordCount,
        'label': label,
        'manual': manual,
        'createdAt': createdAt.toIso8601String(),
      };

  factory SectionVersion.fromJson(Map<String, dynamic> json) {
    return SectionVersion(
      id: json['id'] as String,
      sectionId: json['sectionId'] as String,
      contentJson: (json['contentJson'] ?? '') as String,
      wordCount: (json['wordCount'] as num?)?.toInt() ?? 0,
      label: (json['label'] ?? '') as String,
      manual: (json['manual'] ?? false) as bool,
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          DateTime.now(),
    );
  }

  String encode() => jsonEncode(toJson());
  static SectionVersion decode(String s) =>
      SectionVersion.fromJson(jsonDecode(s) as Map<String, dynamic>);
}
