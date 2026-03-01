/// Feed article/item for personalized suggestions.
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
      };
}
