/// A single footnote belonging to a section.
///
/// Stored as part of the section payload (not its own outbox kind) so it
/// rides through the existing `upsertSection` pipeline. The `id` is
/// stable across renumbering — we re-derive [number] from list order
/// at render and publish time, but the inline embed in the prose uses
/// [id] to look up the entry. Renaming or reordering footnotes never
/// rewrites the Quill delta.
class FootnoteModel {
  FootnoteModel({
    required this.id,
    required this.text,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  /// Stable identifier referenced by the inline `BlockEmbed` in the
  /// section's Quill delta. We use a short `fn-<n>` form on insert; the
  /// id stays put even if the user reorders, so embeds never need to be
  /// rewritten when the visible number changes.
  final String id;
  String text;
  DateTime createdAt;
  DateTime updatedAt;

  factory FootnoteModel.fromJson(Map<String, dynamic> json) {
    return FootnoteModel(
      id: json['id'] as String,
      text: (json['text'] as String?) ?? '',
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'].toString()) ?? DateTime.now()
          : DateTime.now(),
      updatedAt: json['updatedAt'] != null
          ? DateTime.tryParse(json['updatedAt'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  FootnoteModel copyWith({String? id, String? text}) {
    return FootnoteModel(
      id: id ?? this.id,
      text: text ?? this.text,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }
}
