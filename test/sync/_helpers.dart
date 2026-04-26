/// Shared test fakes for Phase 6 sync scenario tests.
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
  Future<WritingModel> createWriting(String userId, WritingModel book) async {
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
  }) async {
    calls.add('updateWritingMetadata:$writingId');
    _maybeThrow('updateWritingMetadata');
  }

  @override
  Future<void> deleteWriting(String userId, String writingId) async {
    calls.add('deleteWriting:$writingId');
    _maybeThrow('deleteWriting');
  }

  @override
  Future<void> addSection(
      String userId, String writingId, SectionModel section) async {
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
  }) async {
    calls.add('updateSectionContent:$writingId/$sectionId');
    _maybeThrow('updateSectionContent');
  }

  @override
  Future<void> renameSection(String userId, String writingId, String sectionId,
      String newTitle) async {
    calls.add('renameSection:$writingId/$sectionId');
    _maybeThrow('renameSection');
  }

  @override
  Future<void> deleteSection(
      String userId, String writingId, String sectionId) async {
    calls.add('deleteSection:$writingId/$sectionId');
    _maybeThrow('deleteSection');
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
