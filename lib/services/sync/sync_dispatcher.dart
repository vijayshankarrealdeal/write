import 'package:inkspacex/models/author_bookmark.dart';
import 'package:inkspacex/models/bookmark_model.dart';
import 'package:inkspacex/models/image_meta.dart';
import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/models/writing_model.dart';

/// The slice of `ApiDataService` the outbox drainer actually depends on.
///
/// Extracted so tests can substitute a fake without standing up the full
/// HTTP stack. `ApiDataService` declares `implements SyncDispatcher` so
/// production code passes the concrete service unchanged.
///
/// Mutation methods accept an optional [opId] (sent as `X-Op-Id`) so the
/// realtime hub can tag broadcasts and the originating client can ignore
/// echoes of its own writes.
abstract class SyncDispatcher {
  Future<WritingModel> createWriting(
    String userId,
    WritingModel book, {
    String? opId,
  });
  Future<void> updateWritingMetadata(
    String userId,
    String writingId, {
    String? title,
    String? description,
    String? coverImagePath,
    ImageMeta? coverImageMeta,
    String? opId,
  });
  Future<void> deleteWriting(String userId, String writingId, {String? opId});
  Future<void> addSection(
    String userId,
    String writingId,
    SectionModel section, {
    String? opId,
  });
  Future<void> updateSectionContent(
    String userId,
    String writingId,
    String sectionId,
    String content, {
    String canvasData = '',
    String? opId,
  });
  Future<void> renameSection(
    String userId,
    String writingId,
    String sectionId,
    String newTitle, {
    String? opId,
  });
  Future<void> deleteSection(
    String userId,
    String writingId,
    String sectionId, {
    String? opId,
  });

  /// Patch arbitrary section metadata (synopsis, notes, parent_id,
  /// sort_order, kind, label_color, keywords, include_in_publish).
  /// Used by the binder for drag-reorder / drag-between-folders / label
  /// changes — anything that isn't a title or content edit.
  Future<void> updateSectionMetadata(
    String userId,
    String writingId,
    String sectionId,
    Map<String, dynamic> fields, {
    String? opId,
  });

  /// Patch project-level fields on the writing (target word count,
  /// deadline, label meaning, label names palette).
  Future<void> updateWritingProjectFields(
    String userId,
    String writingId,
    Map<String, dynamic> fields, {
    String? opId,
  });

  /// Phase 3 (P2): bookmarks. Idempotent on the server (dedupe by
  /// `(user, feed_item, section_index, anchor)`), so the outbox can
  /// safely replay an upsert when a previous response was lost.
  /// Returns the server-issued bookmark id so the drainer can remap
  /// the local op id to the server id for subsequent patches/deletes.
  Future<String> upsertBookmark(BookmarkModel bookmark, {String? clientOpId});

  /// Phase 3 (P2): bookmark deletion. Server returns 204 on miss too,
  /// so an offline replay after a successful prior delete is a no-op.
  Future<void> deleteBookmark(String bookmarkId);

  /// P1 #6: author bookmarks (writer-side flag-this-spot marks inside
  /// drafts). Idempotent on the server (dedupe by `(user, section_id,
  /// offset)`), so the outbox can replay an upsert when a previous
  /// response was lost. Returns the server-issued bookmark id so the
  /// drainer can remap the local op id to the server id for subsequent
  /// patches/deletes.
  Future<String> upsertAuthorBookmark(
    AuthorBookmark bookmark, {
    String? clientOpId,
  });

  /// Patch label/color/offset on an existing author bookmark. Offset
  /// changes drive the "marker survives section edits" requirement —
  /// the editor recomputes the position via Quill delta math and
  /// flushes the new value through here.
  Future<void> patchAuthorBookmark(
    String bookmarkId, {
    String? label,
    String? color,
    int? offset,
    bool clearLabel,
  });

  /// Idempotent delete — the server returns 204 on miss too, so an
  /// offline replay after a successful prior delete is a no-op.
  Future<void> deleteAuthorBookmark(String bookmarkId);
}
