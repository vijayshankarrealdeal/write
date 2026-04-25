class ReadingProgressModel {
  final String feedItemId;
  final double scrollPosition;
  final DateTime lastReadAt;
  final bool completed;

  const ReadingProgressModel({
    required this.feedItemId,
    required this.scrollPosition,
    required this.lastReadAt,
    this.completed = false,
  });

  factory ReadingProgressModel.fromJson(Map<String, dynamic> json) {
    return ReadingProgressModel(
      feedItemId: json['feedItemId'] ?? '',
      scrollPosition: (json['scrollPosition'] ?? 0.0).toDouble(),
      lastReadAt: json['lastReadAt'] != null
          ? DateTime.tryParse(json['lastReadAt'].toString()) ?? DateTime.now()
          : DateTime.now(),
      completed: json['completed'] ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'feedItemId': feedItemId,
        'scrollPosition': scrollPosition,
        'lastReadAt': lastReadAt.toIso8601String(),
        'completed': completed,
      };
}
