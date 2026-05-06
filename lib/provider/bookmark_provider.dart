import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:inkspacex/models/bookmark_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/services/analytics_service.dart';
import 'package:inkspacex/services/app_log.dart';
import 'package:inkspacex/services/sync/outbox.dart';
import 'package:inkspacex/services/sync/outbox_drainer.dart';
import 'package:inkspacex/services/sync/pending_op.dart';

/// Owns the bookmark cache + the enqueue path for create/delete.
///
/// Reads (`loadAllForUser`, `loadForFeedItem`) hit the network directly;
/// writes go through the outbox so they survive offline + crash. The
/// drainer's [IdRemapEvent.bookmark] events bubble back through here so
/// that the cache flips local ids to server ids without a refetch.
///
/// Why a dedicated provider instead of folding this into FeedProvider:
/// bookmarks are a separate sync concern (their own outbox kinds, their
/// own page) and FeedProvider already owns three other lists. Keeping
/// them apart means the bookmarks page rebuilds independently from the
/// feed.
class BookmarkProvider extends ChangeNotifier {
  BookmarkProvider({
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

  /// All bookmarks the user owns, newest first. Loaded by `loadAllForUser`
  /// and kept in sync with create/delete calls.
  List<BookmarkModel> _all = const [];
  List<BookmarkModel> get all => List.unmodifiable(_all);
  bool get isEmpty => _all.isEmpty;

  /// Bookmarks grouped by feed item id, suitable for the per-writing
  /// margin tabs in the reader.
  Map<String, List<BookmarkModel>> get byFeedItem {
    final out = <String, List<BookmarkModel>>{};
    for (final b in _all) {
      out.putIfAbsent(b.feedItemId, () => <BookmarkModel>[]).add(b);
    }
    return out;
  }

  bool _loading = false;
  bool get loading => _loading;
  String? _error;
  String? get error => _error;

  Future<void> loadAllForUser() async {
    if (!_auth.isAuthenticated) return;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _all = await _auth.dataService.listBookmarks();
    } catch (e) {
      log.w('[bookmarks] load failed: $e');
      _error = '$e';
      _all = const [];
    }
    _loading = false;
    notifyListeners();
  }

  Future<List<BookmarkModel>> loadForFeedItem(String feedItemId) async {
    try {
      final list =
          await _auth.dataService.listBookmarksForFeedItem(feedItemId);
      // Merge into the cache so the bookmarks page sees fresh data
      // without a separate refetch.
      final keep =
          _all.where((b) => b.feedItemId != feedItemId).toList(growable: true);
      keep.addAll(list);
      keep.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      _all = keep;
      notifyListeners();
      return list;
    } catch (e) {
      log.w('[bookmarks] loadForFeedItem $feedItemId failed: $e');
      return const [];
    }
  }

  /// Create a bookmark locally, enqueue an `upsertBookmark` op, and kick
  /// the drainer. The bookmark is returned with the client-generated id;
  /// once the server acks, the [IdRemapEvent.bookmark] handler swaps the
  /// id in [_all] and any pending ops in the outbox.
  Future<BookmarkModel> addBookmark({
    required String feedItemId,
    required int sectionIndex,
    String? sectionId,
    required int paragraphIdx,
    required int charOffset,
    String? label,
    String color = '#FFB300',
  }) async {
    final op = PendingOp(
      kind: PendingOpKind.upsertBookmark,
      payload: {
        'bookmarkId': '', // filled below once we know the local id
        'fields': {
          'feed_item_id': feedItemId,
          'section_id': ?sectionId,
          'section_index': sectionIndex,
          'anchor': {
            'paragraph_idx': paragraphIdx,
            'char_offset': charOffset,
          },
          'label': ?label,
          'color': color,
        },
      },
    );
    // Use the op's id as the local bookmark id so [_applyRemap] can
    // resolve the server id back to the right cached bookmark.
    final payload = Map<String, dynamic>.from(op.payload);
    payload['bookmarkId'] = op.id;
    final concrete = PendingOp(
      id: op.id,
      kind: op.kind,
      payload: payload,
      createdAt: op.createdAt,
    );
    final bookmark = BookmarkModel(
      id: op.id,
      feedItemId: feedItemId,
      sectionId: sectionId,
      sectionIndex: sectionIndex,
      paragraphIdx: paragraphIdx,
      charOffset: charOffset,
      label: label,
      color: color,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    _all = [bookmark, ..._all];
    notifyListeners();
    await _outbox.enqueue(concrete);
    _drainer.kick();
    AnalyticsService.instance.track(
      'bookmark_added',
      action: 'click',
      entityType: 'post',
      entityId: feedItemId,
      properties: {
        'section_index': sectionIndex,
        'has_label': label != null,
      },
    );
    return bookmark;
  }

  Future<void> deleteBookmark(String bookmarkId) async {
    _all = _all.where((b) => b.id != bookmarkId).toList();
    notifyListeners();
    await _outbox.enqueue(PendingOp(
      kind: PendingOpKind.deleteBookmark,
      payload: {'bookmarkId': bookmarkId},
    ));
    _drainer.kick();
    AnalyticsService.instance.track(
      'bookmark_removed',
      action: 'click',
      entityType: 'bookmark',
      entityId: bookmarkId,
    );
  }

  void _applyRemap(IdRemapEvent event) {
    if (event.kind != IdRemapKind.bookmark) return;
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
