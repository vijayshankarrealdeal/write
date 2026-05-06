import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_quill/flutter_quill.dart';

import 'package:inkspacex/models/author_bookmark.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/services/analytics_service.dart';
import 'package:inkspacex/services/app_log.dart';
import 'package:inkspacex/services/sync/outbox.dart';
import 'package:inkspacex/services/sync/outbox_drainer.dart';
import 'package:inkspacex/services/sync/pending_op.dart';

/// Owns the author-bookmark cache, the create/patch/delete enqueue path,
/// and the offset-adjustment hook the editor calls on every doc change.
///
/// Reads (`loadForWriting`) hit the network directly; writes go through
/// the outbox so they survive offline + crash. The drainer's
/// [IdRemapEvent.authorBookmark] events bubble back here so the cache
/// flips local ids to server ids without a refetch.
///
/// Why a dedicated provider instead of folding into [BookmarkProvider]:
/// the two domains share a name but nothing else — author bookmarks are
/// keyed by section+offset (not feed_item+paragraph), patchable (vs.
/// delete-and-recreate for reader bookmarks), and only relevant inside
/// the editor. Splitting the providers keeps the editor rebuilding
/// independently from the reader.
class AuthorBookmarkProvider extends ChangeNotifier {
  AuthorBookmarkProvider({
    required AuthProvider auth,
    required Outbox outbox,
    required OutboxDrainer drainer,
  })  : _auth = auth,
        _outbox = outbox,
        _drainer = drainer {
    _remapSub = _drainer.onRemap.listen(_applyRemap);
  }

  final AuthProvider _auth;
  final Outbox _outbox;
  final OutboxDrainer _drainer;
  StreamSubscription<IdRemapEvent>? _remapSub;

  /// Author bookmarks the user owns, ordered by (sectionId asc, offset asc)
  /// so the Inspector renders them top-down through the section.
  List<AuthorBookmark> _all = const [];
  List<AuthorBookmark> get all => List.unmodifiable(_all);
  bool get isEmpty => _all.isEmpty;

  /// Writing → marks (project-wide Inspector view).
  Map<String, List<AuthorBookmark>> get byWriting {
    final out = <String, List<AuthorBookmark>>{};
    for (final b in _all) {
      out.putIfAbsent(b.writingId, () => <AuthorBookmark>[]).add(b);
    }
    return out;
  }

  /// Sorted marks for [sectionId]. The Inspector tab renders this list.
  List<AuthorBookmark> forSection(String sectionId) =>
      _all.where((b) => b.sectionId == sectionId).toList()
        ..sort((a, b) => a.offset.compareTo(b.offset));

  /// Marks for the writing — used by the project-wide section of the
  /// Inspector that lists every spot across the book.
  List<AuthorBookmark> forWriting(String writingId) =>
      _all.where((b) => b.writingId == writingId).toList()
        ..sort((a, b) {
          final s = a.sectionId.compareTo(b.sectionId);
          if (s != 0) return s;
          return a.offset.compareTo(b.offset);
        });

  bool _loading = false;
  bool get loading => _loading;
  String? _error;
  String? get error => _error;

  /// Pull all marks for [writingId] from the server and merge them into
  /// the cache. Called when the editor opens a project.
  Future<void> loadForWriting(String writingId) async {
    if (!_auth.isAuthenticated) return;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final list = await _auth.dataService
          .listAuthorBookmarks(writingId: writingId);
      // Merge: keep marks for other writings, replace marks for this one.
      final keep = _all.where((b) => b.writingId != writingId).toList();
      keep.addAll(list);
      _all = keep;
    } catch (e) {
      log.w('[author_bookmarks] load failed: $e');
      _error = '$e';
    }
    _loading = false;
    notifyListeners();
  }

  /// Create a bookmark locally, enqueue an `upsertAuthorBookmark` op,
  /// and kick the drainer. Returns the bookmark with the
  /// client-generated id; once the server acks, [_applyRemap] swaps
  /// the id in [_all] and any pending follow-up ops.
  Future<AuthorBookmark> addBookmark({
    required String writingId,
    required String sectionId,
    required int offset,
    String? label,
    String color = '#FFB300',
  }) async {
    final op = PendingOp(
      kind: PendingOpKind.upsertAuthorBookmark,
      payload: {
        'bookmarkId': '',
        'fields': {
          'writing_id': writingId,
          'section_id': sectionId,
          'offset': offset,
          'label': ?label,
          'color': color,
        },
      },
    );
    final payload = Map<String, dynamic>.from(op.payload);
    payload['bookmarkId'] = op.id;
    final concrete = PendingOp(
      id: op.id,
      kind: op.kind,
      payload: payload,
      createdAt: op.createdAt,
    );
    final bookmark = AuthorBookmark(
      id: op.id,
      writingId: writingId,
      sectionId: sectionId,
      offset: offset,
      label: label,
      color: color,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    _all = [..._all, bookmark];
    notifyListeners();
    await _outbox.enqueue(concrete);
    _drainer.kick();
    AnalyticsService.instance.track(
      'author_bookmark_added',
      action: 'click',
      entityType: 'section',
      entityId: sectionId,
      properties: {
        'has_label': label != null,
        'offset': offset,
      },
    );
    return bookmark;
  }

  /// Patch label/color on an existing mark.
  Future<void> renameBookmark(
    String id, {
    required String label,
  }) async {
    final updated = _all
        .map((b) => b.id == id
            ? b.copyWith(
                label: label,
                clearLabel: label.isEmpty,
                updatedAt: DateTime.now(),
              )
            : b)
        .toList();
    _all = updated;
    notifyListeners();
    await _outbox.enqueue(PendingOp(
      kind: PendingOpKind.patchAuthorBookmark,
      payload: {
        'bookmarkId': id,
        'fields': {
          if (label.isNotEmpty) 'label': label,
          if (label.isEmpty) 'clearLabel': true,
        },
      },
    ));
    _drainer.kick();
  }

  Future<void> recolorBookmark(String id, String color) async {
    final updated = _all
        .map((b) => b.id == id
            ? b.copyWith(color: color, updatedAt: DateTime.now())
            : b)
        .toList();
    _all = updated;
    notifyListeners();
    await _outbox.enqueue(PendingOp(
      kind: PendingOpKind.patchAuthorBookmark,
      payload: {
        'bookmarkId': id,
        'fields': {'color': color},
      },
    ));
    _drainer.kick();
  }

  Future<void> deleteBookmark(String id) async {
    _all = _all.where((b) => b.id != id).toList();
    notifyListeners();
    await _outbox.enqueue(PendingOp(
      kind: PendingOpKind.deleteAuthorBookmark,
      payload: {'bookmarkId': id},
    ));
    _drainer.kick();
    AnalyticsService.instance.track(
      'author_bookmark_removed',
      action: 'click',
      entityType: 'author_bookmark',
      entityId: id,
    );
  }

  /// Hook the editor calls after every Quill ``DocChange`` for the
  /// active section. Walks the change once, recomputes each affected
  /// marker's offset, and queues a single `patchAuthorBookmark` per
  /// changed mark. Marks that didn't move emit no traffic.
  ///
  /// Marks for sections other than [sectionId] are left alone — a doc
  /// change in chapter 4 cannot affect chapter 5's offsets.
  void applyDocChange(String sectionId, DocChange event) {
    final ops = <DocOp>[];
    for (final delta in event.change.toList()) {
      if (delta.isRetain) {
        ops.add(DocOp.retain((delta.value as int?) ?? 0));
      } else if (delta.isInsert) {
        final v = delta.data;
        if (v is String) {
          ops.add(DocOp.insert(v.length));
        } else {
          // Embeds (images) count as a single character in Quill's
          // length accounting.
          ops.add(DocOp.insert(1));
        }
      } else if (delta.isDelete) {
        ops.add(DocOp.delete((delta.value as int?) ?? 0));
      }
    }
    if (ops.isEmpty) return;

    final affected = _all.where((b) => b.sectionId == sectionId).toList();
    if (affected.isEmpty) return;

    var changed = false;
    final next = <AuthorBookmark>[];
    for (final b in _all) {
      if (b.sectionId != sectionId) {
        next.add(b);
        continue;
      }
      final newOffset = adjustOffsetForDelta(b.offset, ops);
      if (newOffset == b.offset) {
        next.add(b);
      } else {
        next.add(b.copyWith(offset: newOffset, updatedAt: DateTime.now()));
        changed = true;
        unawaited(_outbox.enqueue(PendingOp(
          kind: PendingOpKind.patchAuthorBookmark,
          payload: {
            'bookmarkId': b.id,
            'fields': {'offset': newOffset},
          },
        )));
      }
    }
    if (changed) {
      _all = next;
      _drainer.kick();
      notifyListeners();
    }
  }

  void _applyRemap(IdRemapEvent event) {
    if (event.kind != IdRemapKind.authorBookmark) return;
    final next = _all
        .map((b) => b.id == event.localId ? b.copyWith(id: event.serverId) : b)
        .toList();
    _all = next;
    notifyListeners();
  }

  void clear() {
    _all = const [];
    notifyListeners();
  }

  @override
  void dispose() {
    _remapSub?.cancel();
    super.dispose();
  }
}
