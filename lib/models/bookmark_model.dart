/// A named bookmark anchored to a paragraph + char offset within a section.
///
/// `id` is server-issued once the upsert lands; until then it holds the
/// client-generated uuid that the outbox queues with. The router upserts
/// on `(user, feed_item, section_index, anchor)` so the client doesn't
/// have to know the server id ahead of time.
class BookmarkModel {
  final String id;
  final String feedItemId;
  final String? sectionId;
  final int sectionIndex;
  final int paragraphIdx;
  final int charOffset;
  final String? label;
  final String color;
  final DateTime createdAt;
  final DateTime updatedAt;

  const BookmarkModel({
    required this.id,
    required this.feedItemId,
    required this.sectionIndex,
    required this.paragraphIdx,
    required this.charOffset,
    this.sectionId,
    this.label,
    this.color = '#FFB300',
    required this.createdAt,
    required this.updatedAt,
  });

  factory BookmarkModel.fromJson(Map<String, dynamic> json) {
    final anchor = json['anchor'] as Map?;
    return BookmarkModel(
      id: (json['id'] ?? '').toString(),
      feedItemId: (json['feed_item_id'] ?? '').toString(),
      sectionId: json['section_id']?.toString(),
      sectionIndex: (json['section_index'] as num?)?.toInt() ?? 0,
      paragraphIdx: (anchor?['paragraph_idx'] as num?)?.toInt() ?? 0,
      charOffset: (anchor?['char_offset'] as num?)?.toInt() ?? 0,
      label: json['label']?.toString(),
      color: (json['color'] ?? '#FFB300').toString(),
      createdAt: DateTime.tryParse((json['created_at'] ?? '').toString()) ??
          DateTime.now(),
      updatedAt: DateTime.tryParse((json['updated_at'] ?? '').toString()) ??
          DateTime.now(),
    );
  }

  Map<String, dynamic> toCreateJson({String? clientOpId}) => {
        'feed_item_id': feedItemId,
        if (sectionId != null) 'section_id': sectionId,
        'section_index': sectionIndex,
        'anchor': {
          'paragraph_idx': paragraphIdx,
          'char_offset': charOffset,
        },
        if (label != null) 'label': label,
        'color': color,
        if (clientOpId != null) 'client_op_id': clientOpId,
      };

  BookmarkModel copyWith({
    String? id,
    String? label,
    String? color,
    DateTime? updatedAt,
  }) =>
      BookmarkModel(
        id: id ?? this.id,
        feedItemId: feedItemId,
        sectionId: sectionId,
        sectionIndex: sectionIndex,
        paragraphIdx: paragraphIdx,
        charOffset: charOffset,
        label: label ?? this.label,
        color: color ?? this.color,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}


/// Joined "Continue reading" rail row — feed item + last position.
///
/// Mirrors `ContinueReadingItem` on the backend: a single round trip
/// produces enough data for a card (cover + title + author + progress).
class ContinueReadingItem {
  final String feedItemId;
  final String? title;
  final String? author;
  final String? imageUrl;
  final double scrollPosition;
  final DateTime? lastReadAt;
  final String? lastSectionId;
  final int? lastParagraphIdx;
  final int? lastCharOffset;
  final bool completed;

  const ContinueReadingItem({
    required this.feedItemId,
    this.title,
    this.author,
    this.imageUrl,
    this.scrollPosition = 0,
    this.lastReadAt,
    this.lastSectionId,
    this.lastParagraphIdx,
    this.lastCharOffset,
    this.completed = false,
  });

  factory ContinueReadingItem.fromJson(Map<String, dynamic> json) {
    final anchor = json['last_anchor'] as Map?;
    return ContinueReadingItem(
      feedItemId: (json['feed_item_id'] ?? '').toString(),
      title: json['title']?.toString(),
      author: json['author']?.toString(),
      imageUrl: json['image_url']?.toString(),
      scrollPosition: (json['scroll_position'] as num?)?.toDouble() ?? 0,
      lastReadAt: json['last_read_at'] != null
          ? DateTime.tryParse(json['last_read_at'].toString())
          : null,
      lastSectionId: json['last_section_id']?.toString(),
      lastParagraphIdx: (anchor?['paragraph_idx'] as num?)?.toInt(),
      lastCharOffset: (anchor?['char_offset'] as num?)?.toInt(),
      completed: json['completed'] == true,
    );
  }
}
