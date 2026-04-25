/// A single page/section within a published cover.
class FeedItemSection {
  final String id;
  final String title;
  final String content; // Quill delta JSON
  final String canvasData; // Canvas JSON (creative/scrapbook layout)

  const FeedItemSection({
    required this.id,
    required this.title,
    this.content = '',
    this.canvasData = '',
  });

  factory FeedItemSection.fromJson(Map<String, dynamic> json) {
    return FeedItemSection(
      id: json['id'] ?? '',
      title: json['title'] ?? '',
      content: json['content'] ?? '',
      canvasData: json['canvasData'] ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'content': content,
        if (canvasData.isNotEmpty) 'canvasData': canvasData,
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

  const FeedItemModel({
    required this.id,
    required this.title,
    required this.author,
    required this.authorId,
    required this.description,
    required this.imageUrl,
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
      bookId: json['bookId'] ?? '',
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
  }) =>
      FeedItemModel(
        id: id ?? this.id,
        title: title ?? this.title,
        author: author ?? this.author,
        authorId: authorId ?? this.authorId,
        description: description ?? this.description,
        imageUrl: imageUrl ?? this.imageUrl,
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
      );
}
