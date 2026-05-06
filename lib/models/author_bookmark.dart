/// Writer-side flag-this-spot mark inside a draft section.
///
/// Distinct from [BookmarkModel] (reader-side, anchored to a feed item +
/// paragraph). Author bookmarks live on a draft section and record a
/// single character offset into the section's plain-text view. Offsets
/// travel with the document — the editor adjusts each marker via Quill
/// delta math whenever text is inserted/deleted before it (see
/// [adjustOffsetForDelta] below), then flushes the new value through
/// the outbox.
///
/// `id` is server-issued once the upsert lands; until then it holds the
/// client-generated uuid that the outbox queues with. The router
/// dedupes on `(user, section_id, offset)` so the client doesn't have
/// to know the server id ahead of time.
class AuthorBookmark {
  final String id;
  final String writingId;
  final String sectionId;
  final int offset;
  final String? label;
  final String color;
  final DateTime createdAt;
  final DateTime updatedAt;

  const AuthorBookmark({
    required this.id,
    required this.writingId,
    required this.sectionId,
    required this.offset,
    this.label,
    this.color = '#FFB300',
    required this.createdAt,
    required this.updatedAt,
  });

  factory AuthorBookmark.fromJson(Map<String, dynamic> json) {
    return AuthorBookmark(
      id: (json['id'] ?? '').toString(),
      writingId: (json['writing_id'] ?? '').toString(),
      sectionId: (json['section_id'] ?? '').toString(),
      offset: (json['offset'] as num?)?.toInt() ?? 0,
      label: json['label']?.toString(),
      color: (json['color'] ?? '#FFB300').toString(),
      createdAt: DateTime.tryParse((json['created_at'] ?? '').toString()) ??
          DateTime.now(),
      updatedAt: DateTime.tryParse((json['updated_at'] ?? '').toString()) ??
          DateTime.now(),
    );
  }

  Map<String, dynamic> toCreateJson({String? clientOpId}) => {
        'writing_id': writingId,
        'section_id': sectionId,
        'offset': offset,
        'label': ?label,
        'color': color,
        'client_op_id': ?clientOpId,
      };

  Map<String, dynamic> toPatchJson({
    String? newLabel,
    String? newColor,
    int? newOffset,
    bool clearLabel = false,
  }) =>
      {
        if (clearLabel) 'label': null else 'label': ?newLabel,
        'color': ?newColor,
        'offset': ?newOffset,
      };

  AuthorBookmark copyWith({
    String? id,
    String? label,
    String? color,
    int? offset,
    DateTime? updatedAt,
    bool clearLabel = false,
  }) =>
      AuthorBookmark(
        id: id ?? this.id,
        writingId: writingId,
        sectionId: sectionId,
        offset: offset ?? this.offset,
        label: clearLabel ? null : (label ?? this.label),
        color: color ?? this.color,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

/// A single-op slice of a Quill ``Delta`` change as the editor surfaces
/// it through ``DocChange``. Used by [adjustOffsetForDelta] so the
/// math is independent of the flutter_quill types — keeps the unit
/// tests free of widget binding.
class DocOp {
  const DocOp.retain(this.length)
      : isInsert = false,
        isDelete = false;
  const DocOp.insert(this.length)
      : isInsert = true,
        isDelete = false;
  const DocOp.delete(this.length)
      : isInsert = false,
        isDelete = true;

  final int length;
  final bool isInsert;
  final bool isDelete;

  bool get isRetain => !isInsert && !isDelete;
}

/// Recompute a marker offset after a document change.
///
/// The change is described as a flat list of ``DocOp``s — retain N,
/// insert N, delete N — applied left to right against the *source*
/// document (Quill's standard delta shape). Returns the new character
/// offset.
///
/// Rules — chosen to match Quill's own selection-after-edit semantics:
/// - Retain advances the source cursor without touching the marker.
/// - Insert at a source position ``s <= marker`` shifts the marker right
///   by the insert length. ``s > marker`` leaves it alone. (Insert at
///   exactly the marker shifts it right — same convention Quill uses
///   for an editor selection sitting at the insertion point.)
/// - Delete of a span entirely before the marker (``delEnd <= marker``)
///   shifts it left by the delete length.
/// - Delete strictly after the marker (``delStart >= marker``) leaves
///   it alone.
/// - Delete straddling the marker (``delStart < marker < delEnd``) pulls
///   the marker to the start of the deleted span — the marker
///   "collapses" to where the deleted text used to begin. Subsequent
///   ops are evaluated against the new marker position.
///
/// The function never returns ``null`` — bookmarks always survive an
/// edit, even one that wipes their anchoring text. Survivability is a
/// product decision (a bookmark is a writer-side waypoint, not a hard
/// link to specific characters); callers that want stricter semantics
/// can compare the returned offset against ``delStart`` and detect
/// collapse themselves.
int adjustOffsetForDelta(int initialOffset, List<DocOp> ops) {
  if (initialOffset < 0) return 0;

  // Walk the delta against the source document. ``src`` tracks our
  // position in the source; ``shift`` accumulates the running delta
  // between source and target offsets ("target = source + shift" at
  // any point); ``markerTarget`` is the marker's running position in
  // the *target* (post-edit) document.
  int src = 0;
  int shift = 0;
  int markerTarget = initialOffset;
  // True once a delete has straddled the marker — the marker no longer
  // tracks its original source position, so subsequent inserts at src
  // strictly after the (now-deleted) original marker source must not
  // move it. We record the source position at which this happened so
  // we can keep the same comparison semantics.
  int effectiveMarkerSrc = initialOffset;

  for (final op in ops) {
    if (op.isRetain) {
      src += op.length;
      continue;
    }
    if (op.isInsert) {
      // Insert at exactly the marker shifts the marker right (Quill's
      // selection-after-edit convention).
      if (src <= effectiveMarkerSrc) markerTarget += op.length;
      shift += op.length;
      // src does NOT advance for insert (no source consumed).
      continue;
    }
    // Delete.
    final delStart = src;
    final delEnd = src + op.length;
    if (delEnd <= effectiveMarkerSrc) {
      markerTarget -= op.length;
    } else if (delStart >= effectiveMarkerSrc) {
      // Delete strictly at/after the marker — no shift.
    } else {
      // Straddle: the source character the marker pointed to is being
      // deleted. Pull marker to the target offset of delStart, which
      // at this point is (delStart + shift_so_far). Future ops happen
      // at src > delEnd, all "after" the new marker, so no further
      // shifts are warranted.
      markerTarget = delStart + shift;
      effectiveMarkerSrc = delStart;
    }
    shift -= op.length;
    src += op.length;
  }

  return markerTarget < 0 ? 0 : markerTarget;
}
