import 'package:inkspacex/models/image_meta.dart';

/// A named figure that recurs across a book's chapters.
///
/// Populated server-side by the test_model ingest pipeline's scout
/// phase, then surfaced to readers as a "Cast" strip above the chapter
/// list on the book detail page. Tapping a strip avatar opens a
/// dedicated character page with the larger portrait and the appearance
/// description.
///
/// `imageUrl` points at the medium WebP variant for inline rendering
/// in the strip; `imageMeta` carries the full variant table + blurhash
/// + dominant color so `AppNetworkImage` can blur-up and pick a higher
/// resolution on the detail page. Both nullable — books whose pipeline
/// run failed to generate portraits still expose the cast list, just
/// with text-only entries.
class BookCharacterModel {
  const BookCharacterModel({
    required this.id,
    required this.name,
    required this.appearance,
    this.bio,
    this.imageUrl,
    this.imageMeta,
    this.sortOrder = 0,
  });

  final String id;
  final String name;
  /// Image-gen prompt — physical description used to seed character
  /// portrait generation. Not user-facing.
  final String appearance;
  /// 2-3 sentence reader-facing bio. Falls back to [appearance] on
  /// older books that pre-date the bio field.
  final String? bio;
  final String? imageUrl;
  final ImageMeta? imageMeta;
  final int sortOrder;

  /// What to show on the character detail page — prefer the bio when
  /// the scout wrote one, otherwise the appearance string.
  String get displayDescription =>
      (bio != null && bio!.trim().isNotEmpty) ? bio!.trim() : appearance;

  factory BookCharacterModel.fromJson(Map<String, dynamic> json) {
    return BookCharacterModel(
      id: json['id'].toString(),
      name: (json['name'] as String?) ?? '',
      appearance: (json['appearance'] as String?) ?? '',
      bio: json['bio'] as String?,
      imageUrl: json['image_url'] as String? ?? json['imageUrl'] as String?,
      imageMeta: ImageMeta.tryFromJson(json['image_meta'] ?? json['imageMeta']),
      sortOrder: (json['sort_order'] as num?)?.toInt() ??
          (json['sortOrder'] as num?)?.toInt() ??
          0,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'appearance': appearance,
        if (bio != null) 'bio': bio,
        'image_url': imageUrl,
        'image_meta': imageMeta?.toJson(),
        'sort_order': sortOrder,
      };
}
