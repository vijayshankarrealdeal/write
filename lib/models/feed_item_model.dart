/// A feed post – one published section from a book.
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
  final int likesCount;
  final int commentsCount;

  /// The Quill delta JSON of the section content.
  final String content;

  /// The parent book's title (for context, e.g. "From: My Poetry Book").
  final String bookTitle;

  /// The parent book's ID so we can group posts by book.
  final String bookId;

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
    this.likesCount = 0,
    this.commentsCount = 0,
    this.content = '',
    this.bookTitle = '',
    this.bookId = '',
  });

  factory FeedItemModel.fromJson(Map<String, dynamic> json) {
    return FeedItemModel(
      id: json['id'] ?? '',
      title: json['title'] ?? '',
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
      likesCount: json['likesCount'] ?? 0,
      commentsCount: json['commentsCount'] ?? 0,
      content: json['content'] ?? '',
      bookTitle: json['bookTitle'] ?? '',
      bookId: json['bookId'] ?? '',
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
        'likesCount': likesCount,
        'commentsCount': commentsCount,
        'content': content,
        'bookTitle': bookTitle,
        'bookId': bookId,
      };
}
