class CommentModel {
  final String id;
  final String feedItemId;
  final String authorId;
  final String authorName;
  final String? authorPhotoUrl;
  final String text;
  final DateTime createdAt;
  final int rating;

  const CommentModel({
    required this.id,
    required this.feedItemId,
    required this.authorId,
    required this.authorName,
    this.authorPhotoUrl,
    required this.text,
    required this.createdAt,
    this.rating = 0,
  });

  factory CommentModel.fromJson(Map<String, dynamic> json) {
    return CommentModel(
      id: json['id'] ?? '',
      feedItemId: json['feedItemId'] ?? '',
      authorId: json['authorId'] ?? '',
      authorName: json['authorName'] ?? '',
      authorPhotoUrl: json['authorPhotoUrl'],
      text: json['text'] ?? '',
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'].toString()) ?? DateTime.now()
          : DateTime.now(),
      rating: (json['rating'] is num) ? (json['rating'] as num).toInt() : 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'feedItemId': feedItemId,
        'authorId': authorId,
        'authorName': authorName,
        'authorPhotoUrl': authorPhotoUrl,
        'text': text,
        'createdAt': createdAt.toIso8601String(),
        'rating': rating,
      };
}
