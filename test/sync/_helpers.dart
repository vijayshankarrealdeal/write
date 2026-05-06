/// Shared test fakes for Phase 6 sync scenario tests.
import 'package:inkspacex/models/bookmark_model.dart';
import 'package:inkspacex/models/image_meta.dart';
import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/services/sync/pending_op.dart';
import 'package:inkspacex/services/sync/sync_dispatcher.dart';

/// SyncDispatcher fake that records every call and can be programmed to
/// throw on selected attempts.
class RecordingDispatcher implements SyncDispatcher {
  final List<String> calls = [];

  /// Per-method script. Each entry consumed in order; `null` = success,
  /// `Object` = throw.
  final Map<String, List<Object?>> scripts = {};
  final Map<String, int> _cursors = {};

  void scriptUpdateSectionContent(List<Object?> attempts) {
    scripts['updateSectionContent'] = attempts;
  }

  void _maybeThrow(String key) {
    final script = scripts[key];
    if (script == null) return;
    final i = _cursors[key] ?? 0;
    _cursors[key] = i + 1;
    if (i >= script.length) return;
    final v = script[i];
    if (v != null) throw v;
  }

  @override
  Future<WritingModel> createWriting(
    String userId,
    WritingModel book, {
    String? opId,
  }) async {
    calls.add('createWriting:${book.id}');
    _maybeThrow('createWriting');
    return book;
  }

  @override
  Future<void> updateWritingMetadata(
    String userId,
    String writingId, {
    String? title,
    String? description,
    String? coverImagePath,
    ImageMeta? coverImageMeta,
    String? opId,
  }) async {
    calls.add('updateWritingMetadata:$writingId');
    _maybeThrow('updateWritingMetadata');
  }

  @override
  Future<void> deleteWriting(
    String userId,
    String writingId, {
    String? opId,
  }) async {
    calls.add('deleteWriting:$writingId');
    _maybeThrow('deleteWriting');
  }

  @override
  Future<void> addSection(
    String userId,
    String writingId,
    SectionModel section, {
    String? opId,
  }) async {
    calls.add('addSection:$writingId/${section.id}');
    _maybeThrow('addSection');
  }

  @override
  Future<void> updateSectionContent(
    String userId,
    String writingId,
    String sectionId,
    String content, {
    String canvasData = '',
    String? opId,
  }) async {
    calls.add('updateSectionContent:$writingId/$sectionId');
    _maybeThrow('updateSectionContent');
  }

  @override
  Future<void> renameSection(
    String userId,
    String writingId,
    String sectionId,
    String newTitle, {
    String? opId,
  }) async {
    calls.add('renameSection:$writingId/$sectionId');
    _maybeThrow('renameSection');
  }

  @override
  Future<void> deleteSection(
    String userId,
    String writingId,
    String sectionId, {
    String? opId,
  }) async {
    calls.add('deleteSection:$writingId/$sectionId');
    _maybeThrow('deleteSection');
  }

  /// Records the call and returns the local id by default — tests that
  /// want to exercise the id-remap path can override `bookmarkServerIds`.
  Map<String, String> bookmarkServerIds = const {};

  @override
  Future<String> upsertBookmark(BookmarkModel bookmark,
      {String? clientOpId}) async {
    calls.add('upsertBookmark:${bookmark.id}');
    _maybeThrow('upsertBookmark');
    return bookmarkServerIds[bookmark.id] ?? bookmark.id;
  }

  @override
  Future<void> deleteBookmark(String bookmarkId) async {
    calls.add('deleteBookmark:$bookmarkId');
    _maybeThrow('deleteBookmark');
  }

  @override
  Future<void> updateSectionMetadata(
    String userId,
    String writingId,
    String sectionId,
    Map<String, dynamic> fields, {
    String? opId,
  }) async {
    calls.add('updateSectionMetadata:$writingId/$sectionId');
    _maybeThrow('updateSectionMetadata');
  }

  @override
  Future<void> updateWritingProjectFields(
    String userId,
    String writingId,
    Map<String, dynamic> fields, {
    String? opId,
  }) async {
    calls.add('updateWritingProjectFields:$writingId');
    _maybeThrow('updateWritingProjectFields');
  }
}

PendingOp contentOp(String wid, String sid, String body) => PendingOp(
      kind: PendingOpKind.upsertSection,
      payload: {
        'writingId': wid,
        'sectionId': sid,
        'isNew': false,
        'fields': {'content': body},
      },
    );
