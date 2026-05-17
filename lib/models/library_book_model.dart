import 'package:flutter/material.dart';

/// One book in the user's Library — already bucketed server-side.
///
/// Mirrors `LibraryBook` in backend/app/schemas/reading.py. The shape is
/// the same regardless of which tab the client asked for; ``label``
/// drives the coloured chip in the corner of the card.
enum BookLabel {
  /// In-progress: ``completed=false AND last_read_at IS NOT NULL``.
  /// Warm amber chip — "yellow" in the user's mental model.
  reading,

  /// On a shelf but never opened. Blue chip — "to read".
  saved,

  /// ``completed=true``. Green chip — "done".
  finished,

  /// Soft heuristic: in-progress AND ``last_read_at < now()-30d`` AND
  /// scroll position < 80%. Slate chip — currently rendered as a muted
  /// dot; the UI may suppress it depending on user preference.
  abandoned,
}

BookLabel? bookLabelFromString(String? s) {
  switch (s) {
    case 'reading': return BookLabel.reading;
    case 'saved': return BookLabel.saved;
    case 'finished': return BookLabel.finished;
    case 'abandoned': return BookLabel.abandoned;
    default: return null;
  }
}

String bookLabelToString(BookLabel l) {
  switch (l) {
    case BookLabel.reading: return 'reading';
    case BookLabel.saved: return 'saved';
    case BookLabel.finished: return 'finished';
    case BookLabel.abandoned: return 'abandoned';
  }
}

/// The colour + display name for each label. Hexes match
/// `app/badges.py` so the Library chips and the reader-tier badges
/// share a visual vocabulary.
class BookLabelStyle {
  static const Map<BookLabel, Color> color = {
    BookLabel.reading:   Color(0xFFF59E0B),  // amber
    BookLabel.finished:  Color(0xFF22C55E),  // green
    BookLabel.saved:     Color(0xFF3B82F6),  // blue
    BookLabel.abandoned: Color(0xFF94A3B8),  // slate
  };
  static const Map<BookLabel, String> shortLabel = {
    BookLabel.reading:   'Reading',
    BookLabel.finished:  'Finished',
    BookLabel.saved:     'Saved',
    BookLabel.abandoned: 'Set aside',
  };
}

class LibraryBookModel {
  final String feedItemId;
  final String? writingId;
  final String? title;
  final String? author;
  final String? imageUrl;
  final Map<String, dynamic>? imageMeta;
  final BookLabel label;

  final double? scrollPosition;
  final DateTime? lastReadAt;
  final String? lastSectionId;
  final Map<String, dynamic>? lastAnchor;
  final DateTime? finishedAt;

  final String? shelfId;
  final String? shelfName;

  const LibraryBookModel({
    required this.feedItemId,
    required this.label,
    this.writingId,
    this.title,
    this.author,
    this.imageUrl,
    this.imageMeta,
    this.scrollPosition,
    this.lastReadAt,
    this.lastSectionId,
    this.lastAnchor,
    this.finishedAt,
    this.shelfId,
    this.shelfName,
  });

  factory LibraryBookModel.fromJson(Map<String, dynamic> json) {
    return LibraryBookModel(
      feedItemId: (json['feed_item_id'] ?? '').toString(),
      writingId: json['writing_id']?.toString(),
      title: json['title']?.toString(),
      author: json['author']?.toString(),
      imageUrl: json['image_url']?.toString(),
      imageMeta: json['image_meta'] is Map
          ? Map<String, dynamic>.from(json['image_meta'] as Map)
          : null,
      label: bookLabelFromString(json['label']?.toString()) ?? BookLabel.reading,
      scrollPosition: (json['scroll_position'] as num?)?.toDouble(),
      lastReadAt: json['last_read_at'] != null
          ? DateTime.tryParse(json['last_read_at'].toString())
          : null,
      lastSectionId: json['last_section_id']?.toString(),
      lastAnchor: json['last_anchor'] is Map
          ? Map<String, dynamic>.from(json['last_anchor'] as Map)
          : null,
      finishedAt: json['finished_at'] != null
          ? DateTime.tryParse(json['finished_at'].toString())
          : null,
      shelfId: json['shelf_id']?.toString(),
      shelfName: json['shelf_name']?.toString(),
    );
  }
}

/// Per-tab counts for the Library page's tab strip.
/// Mirrors `LibraryCounts` in the backend schema.
class LibraryCountsModel {
  final int reading;
  final int saved;
  final int finished;
  final int abandoned;
  final int all;

  const LibraryCountsModel({
    this.reading = 0,
    this.saved = 0,
    this.finished = 0,
    this.abandoned = 0,
    this.all = 0,
  });

  factory LibraryCountsModel.fromJson(Map<String, dynamic> json) {
    return LibraryCountsModel(
      reading: (json['reading'] as num?)?.toInt() ?? 0,
      saved: (json['saved'] as num?)?.toInt() ?? 0,
      finished: (json['finished'] as num?)?.toInt() ?? 0,
      abandoned: (json['abandoned'] as num?)?.toInt() ?? 0,
      all: (json['all'] as num?)?.toInt() ?? 0,
    );
  }

  int forLabel(BookLabel? label) {
    if (label == null) return all;
    switch (label) {
      case BookLabel.reading: return reading;
      case BookLabel.saved: return saved;
      case BookLabel.finished: return finished;
      case BookLabel.abandoned: return abandoned;
    }
  }
}
