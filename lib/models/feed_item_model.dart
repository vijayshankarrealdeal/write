import 'dart:convert';

import 'package:inkspacex/models/image_meta.dart';

/// A single page/section within a published cover.
class FeedItemSection {
  /// Stable section UUID. Used by the new `/sections/by-id/{section_id}`
  /// pagination so a reader on chapter X stays on X even after the
  /// author inserts/deletes/reorders chapters above it. Backend sends
  /// it as `section_id` (snake) on the chapter-list stubs and `id`
  /// (camel) on legacy section bodies — accept both.
  final String id;
  final String title;
  final String content; // Quill delta JSON
  final String canvasData; // Canvas JSON (creative/scrapbook layout)
  /// Server-side flag: `true` if this section's Quill delta contains at
  /// least one image embed. Set even when the body is lazy (content empty)
  /// so the chapter list can paint an image-dot marker without parsing.
  final bool hasImage;
  /// Server-side last-modified timestamp on the underlying `Section`
  /// row. Lets the reader diff against its cache and surface an
  /// "Updated" badge on chapters the author edited since the user
  /// last opened the book. Null on legacy responses.
  final DateTime? updatedAt;

  const FeedItemSection({
    required this.id,
    required this.title,
    this.content = '',
    this.canvasData = '',
    this.hasImage = false,
    this.updatedAt,
  });

  factory FeedItemSection.fromJson(Map<String, dynamic> json) {
    // `content` can arrive in two shapes:
    //   - JSON-encoded string of a Quill delta (user-authored sections,
    //     legacy editor save path)
    //   - Raw Quill delta list (server-side ingested books like the
    //     Mahābhārata, where the publisher stores the delta as JSONB
    //     directly).
    // Coerce to a single string form so `Document.fromJson(jsonDecode(...))`
    // works in both cases without branching at every render site.
    final rawContent = json['content'];
    final String contentJson;
    if (rawContent == null) {
      contentJson = '';
    } else if (rawContent is String) {
      contentJson = rawContent;
    } else {
      contentJson = jsonEncode(rawContent);
    }

    final rawCanvas = json['canvasData'];
    final String canvasJson;
    if (rawCanvas == null) {
      canvasJson = '';
    } else if (rawCanvas is String) {
      canvasJson = rawCanvas;
    } else {
      canvasJson = jsonEncode(rawCanvas);
    }

    final rawUpdated = json['updated_at'] ?? json['updatedAt'];
    final DateTime? updated = rawUpdated is String
        ? DateTime.tryParse(rawUpdated)
        : null;

    return FeedItemSection(
      // Chapter-list stubs send `section_id`; legacy bodies + author-side
      // models send `id`. The backend's new `/sections/by-id/...`
      // endpoint also returns `section_id`, so prefer it when present.
      id: (json['section_id'] ?? json['id'] ?? '').toString(),
      title: json['title'] ?? '',
      content: contentJson,
      canvasData: canvasJson,
      hasImage: json['_has_image'] == true,
      updatedAt: updated,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'content': content,
        if (canvasData.isNotEmpty) 'canvasData': canvasData,
        if (hasImage) '_has_image': true,
        if (updatedAt != null) 'updated_at': updatedAt!.toIso8601String(),
      };
}

/// A feed post – a published cover (book) containing one or more pages.
class FeedItemModel {
  final String id;
  final String title;
  final String author;
  final String authorId;
  final String description;
  final String imageUrl;
  final ImageMeta? imageMeta;
  final List<String> genres;
  final List<String> writingTypes;
  final List<String> tags;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int likesCount;
  final int commentsCount;

  /// All published pages/sections within this cover.
  final List<FeedItemSection> sections;

  /// The parent book's ID.
  final String bookId;

  /// Whether this post is a draft (not visible in the public feed).
  final bool isDraft;

  /// Set on items returned from `/api/ai/recommendations`. Carries the
  /// engine's score, the LLM-generated "why this" reason, and where in
  /// the pipeline the item came from (engine | cold_start | llm_rerank).
  /// The shelf widget surfaces `recommendationReason` as a chip and
  /// echoes the rest back on impression / click events.
  final RecommendationMeta? recommendation;

  const FeedItemModel({
    required this.id,
    required this.title,
    required this.author,
    required this.authorId,
    required this.description,
    required this.imageUrl,
    this.imageMeta,
    this.genres = const [],
    this.writingTypes = const [],
    this.tags = const [],
    required this.createdAt,
    DateTime? updatedAt,
    this.likesCount = 0,
    this.commentsCount = 0,
    this.sections = const [],
    this.bookId = '',
    this.isDraft = false,
    this.recommendation,
  }) : updatedAt = updatedAt ?? createdAt;

  factory FeedItemModel.fromJson(Map<String, dynamic> json) {
    // Parse sections array; fall back to legacy single-content format
    List<FeedItemSection> sections;
    if (json['sections'] != null && json['sections'] is List) {
      sections = (json['sections'] as List)
          .map((s) => FeedItemSection.fromJson(s as Map<String, dynamic>))
          .toList();
    } else if ((json['content'] ?? '').toString().isNotEmpty) {
      // Legacy: single section from old format
      sections = [
        FeedItemSection(
          id: json['id'] ?? '',
          title: json['title'] ?? '',
          content: json['content'] ?? '',
        ),
      ];
    } else {
      sections = [];
    }

    return FeedItemModel(
      id: json['id'] ?? '',
      title: json['title'] ?? json['bookTitle'] ?? '',
      author: json['author'] ?? '',
      authorId: json['authorId'] ?? '',
      description: json['description'] ?? '',
      imageUrl: json['imageUrl'] ?? '',
      imageMeta: ImageMeta.tryFromJson(json['imageMeta'] ?? json['image_meta']),
      genres: List<String>.from(json['genres'] ?? []),
      writingTypes: List<String>.from(json['writingTypes'] ?? []),
      tags: List<String>.from(json['tags'] ?? []),
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'].toString()) ?? DateTime.now()
          : DateTime.now(),
      updatedAt: json['updatedAt'] != null
          ? DateTime.tryParse(json['updatedAt'].toString())
          : null,
      likesCount: json['likesCount'] ?? 0,
      commentsCount: json['commentsCount'] ?? 0,
      sections: sections,
      // Server returns the link to the source writing as `writing_id`;
      // older cached payloads used the camelCase `bookId` key, so accept
      // both for forward + backward compatibility.
      bookId: (json['writing_id'] ?? json['writingId'] ?? json['bookId'] ?? '')
          .toString(),
      isDraft: json['isDraft'] ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'authorId': authorId,
        'description': description,
        'imageUrl': imageUrl,
        'imageMeta': imageMeta?.toJson(),
        'genres': genres,
        'writingTypes': writingTypes,
        'tags': tags,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'likesCount': likesCount,
        'commentsCount': commentsCount,
        'sections': sections.map((s) => s.toJson()).toList(),
        'bookId': bookId,
        'isDraft': isDraft,
      };

  FeedItemModel copyWith({
    String? id,
    String? title,
    String? author,
    String? authorId,
    String? description,
    String? imageUrl,
    ImageMeta? imageMeta,
    List<String>? genres,
    List<String>? writingTypes,
    List<String>? tags,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? likesCount,
    int? commentsCount,
    List<FeedItemSection>? sections,
    String? bookId,
    bool? isDraft,
    RecommendationMeta? recommendation,
  }) =>
      FeedItemModel(
        id: id ?? this.id,
        title: title ?? this.title,
        author: author ?? this.author,
        authorId: authorId ?? this.authorId,
        description: description ?? this.description,
        imageUrl: imageUrl ?? this.imageUrl,
        imageMeta: imageMeta ?? this.imageMeta,
        genres: genres ?? this.genres,
        writingTypes: writingTypes ?? this.writingTypes,
        tags: tags ?? this.tags,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        likesCount: likesCount ?? this.likesCount,
        commentsCount: commentsCount ?? this.commentsCount,
        sections: sections ?? this.sections,
        bookId: bookId ?? this.bookId,
        isDraft: isDraft ?? this.isDraft,
        recommendation: recommendation ?? this.recommendation,
      );
}

/// Provenance metadata attached to feed items returned by the
/// recommendation endpoint. `null` on items from the generic feed.
class RecommendationMeta {
  /// Engine score at serve time. Echoed back on impression / click
  /// events so we can correlate score with CTR.
  final double score;

  /// Optional one-sentence "why you'll like this" string. Set when
  /// the LLM re-ranker ran (`source == 'llm_rerank'`); `null` for
  /// pure engine / cold-start items.
  final String? reason;

  /// `engine` | `cold_start` | `llm_rerank`. Lets analytics segment
  /// CTR by recommendation source.
  final String source;

  /// Opaque grouping id from the response — same value for every
  /// item in a single recommendations render.
  final String sessionId;

  const RecommendationMeta({
    required this.score,
    required this.source,
    required this.sessionId,
    this.reason,
  });
}
