import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart'
    show ValueListenable, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_quill/flutter_quill.dart';
import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/models/footnote_model.dart';
import 'package:inkspacex/models/image_meta.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/services/analytics_service.dart';
import 'package:inkspacex/services/api/api_data_service.dart';
import 'package:inkspacex/services/api/api_storage_service.dart';
import 'package:inkspacex/services/connectivity_service.dart';
import 'package:inkspacex/services/desktop_tray_service.dart';
import 'package:inkspacex/services/home_widget_service.dart';
import 'package:inkspacex/services/scrivenings_session.dart';
import 'package:inkspacex/services/spell_check_decoration.dart';
import 'package:inkspacex/services/storage_service.dart';
import 'package:inkspacex/services/smart_substitutions.dart';
import 'package:inkspacex/services/sync/merge_log.dart';
import 'package:inkspacex/services/sync/outbox.dart';
import 'package:inkspacex/services/sync/outbox_drainer.dart';
import 'package:inkspacex/services/sync/pending_op.dart';
import 'package:uuid/uuid.dart';

class EditorProvider extends ChangeNotifier {
  final StorageService _storage;
  final AuthProvider _auth;
  final ConnectivityService _connectivity;
  final Outbox _outbox;
  final OutboxDrainer _drainer;
  final MergeLog _mergeLog;
  ApiDataService get _dataService => _auth.dataService;
  ApiStorageService get _storageService => _auth.storageService;

  EditorProvider(
    this._storage,
    this._auth,
    this._connectivity,
    this._outbox,
    this._drainer,
    this._mergeLog,
  ) {
    loadBooks();
    unawaited(SmartSubstitutions.loadEnabled().then((v) {
      smartPunctuationEnabled = v;
      _smartPunctuationLoaded = true;
    }));
    _connectivitySub = _connectivity.onChange.listen((online) {
      if (online) _drainer.kick();
      _recomputeSyncStatus();
    });
    _remapSub = _drainer.onRemap.listen(_applyRemap);
    _ackSub = _drainer.onAck.listen(_applyAck);
    _outbox.pendingCount.addListener(_onSyncCounterChanged);
    _drainer.failedCount.addListener(_onSyncCounterChanged);
    // Drain anything left over from a previous run.
    _drainer.kick();
  }

  /// Sync/typing/saving micro-state surfaced for the status chip.
  /// Updated independently from [notifyListeners] so per-keystroke status
  /// flips do not rebuild every `Consumer<EditorProvider>` in the tree.
  final ValueNotifier<SyncStatus> _syncStatusNotifier =
      ValueNotifier(SyncStatus.idle);
  ValueListenable<SyncStatus> get syncStatusListenable => _syncStatusNotifier;

  void _recomputeSyncStatus() {
    final next = _computeSyncStatus();
    if (_syncStatusNotifier.value != next) {
      _syncStatusNotifier.value = next;
    }
  }

  SyncStatus _computeSyncStatus() {
    if (_drainer.failedCount.value > 0) return SyncStatus.error;
    if (!_connectivity.isOnlineNow && _outbox.pendingCount.value > 0) {
      return SyncStatus.offline;
    }
    if (_typing) return SyncStatus.typing;
    if (_outbox.pendingCount.value > 0) return SyncStatus.syncing;
    if (_saving) return SyncStatus.saving;
    return SyncStatus.idle;
  }

  void _onSyncCounterChanged() {
    _recomputeSyncStatus();
    notifyListeners();
  }

  StreamSubscription<bool>? _connectivitySub;
  StreamSubscription<IdRemapEvent>? _remapSub;
  StreamSubscription<PendingOp>? _ackSub;

  /// Live mutations broadcast on the writing channel for [activeBook].
  /// Subscribed when a book is opened, torn down on book change / dispose.
  StreamSubscription<Map<String, dynamic>>? _writingChannelSub;
  String? _writingChannelKey;

  /// Reactive count of unsynced operations (for UI badges and the logout
  /// guard). Forwarded straight from the underlying outbox.
  ValueListenable<int> get pendingOpsCount => _outbox.pendingCount;
  ValueListenable<int> get failedOpsCount => _drainer.failedCount;
  bool get hasPendingOps => !_outbox.isEmpty;

  /// Coarse-grained sync state suitable for a status chip. Computed off
  /// outbox depth + connectivity + the user's typing/saving micro-state.
  SyncStatus get syncStatus => _computeSyncStatus();

  /// Snapshot of the failed ops queue for the failed-ops sheet UI.
  List<PendingOp> get failedOps => _drainer.snapshotFailed();
  Future<void> retryFailedOp(String opId) =>
      _drainer.retryFailedOp(opId);
  Future<void> discardFailedOp(String opId) => _drainer.discardOp(opId);

  bool _typing = false;
  bool _saving = false;

  /// Tactile beat at sentence and paragraph boundaries — adds a small
  /// punctuation feel to the typing rhythm. Toggled from the editor
  /// settings sheet; off-platform (web/desktop) it's a no-op regardless.
  bool typingHapticsEnabled = true;
  bool get _hapticsAvailable =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;
  DateTime _lastHapticAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Scrivener-style autocorrect (curly quotes, em dashes, ellipsis).
  /// Loaded from SharedPreferences on first read; default on. Toggled
  /// from the editor settings sheet.
  bool smartPunctuationEnabled = true;
  bool _smartPunctuationLoaded = false;
  // Set while a substitution is being applied so the doc-changes
  // listener doesn't re-enter on the synthetic delta we just emitted.
  bool _applyingSmartSubstitution = false;

  Future<void> _enqueue(PendingOp op) async {
    await _outbox.enqueue(op);
    _drainer.kick();
  }

  void _applyRemap(IdRemapEvent event) {
    if (event.isWriting) {
      for (final b in allBooks) {
        if (b.id == event.localId) b.id = event.serverId;
      }
      if (activeBook?.id == event.localId) activeBook!.id = event.serverId;
    } else {
      final wid = event.writingId!;
      for (final b in allBooks) {
        if (b.id != wid) continue;
        for (final s in b.sections) {
          if (s.id == event.localId) {
            s.id = event.serverId;
            s.isSynced = true;
          }
        }
      }
      if (activeSection?.id == event.localId) {
        activeSection!.id = event.serverId;
        activeSection!.isSynced = true;
      }
    }
    _storage.saveBooks(allBooks);
    notifyListeners();
  }

  void _applyAck(PendingOp op) {
    if (op.kind != PendingOpKind.upsertSection) return;
    final wid = op.payload['writingId'] as String?;
    final sid = op.payload['sectionId'] as String?;
    if (wid == null || sid == null) return;
    var changed = false;
    for (final b in allBooks) {
      if (b.id != wid) continue;
      for (final s in b.sections) {
        if (s.id == sid && !s.isSynced) {
          s.isSynced = true;
          changed = true;
        }
      }
    }
    if (changed) {
      _storage.saveBooks(allBooks);
      notifyListeners();
    }
  }

  List<WritingModel> allBooks = [];
  List<SectionModel> allBooksSection = [];

  WritingModel? activeBook;
  SectionModel? activeSection;

  bool showSectionsList = false;
  bool bookLoadingData = false;
  bool sectionLoadingData = false;
  QuillController controller = QuillController.basic();

  TextEditingController titleController = TextEditingController();
  TextEditingController descriptionController = TextEditingController();
  WritingType type = WritingType.freestyle;
  String subtype = "";

  final List<Color> sectionColors = [
    const Color(0xFFFF595E),
    const Color(0xFFFFCA3A),
    const Color(0xFF8AC926),
    const Color(0xFF1982C4),
    const Color(0xFF6A4C93),
  ];

  String? get _userId => _auth.currentUser?.id;

  void toggleShowSections() {
    showSectionsList = !showSectionsList;
    notifyListeners();
  }

  void selectWritingType(WritingType etype) {
    type = etype;
    subtype = "";
    notifyListeners();
  }

  void selectSubtype(String estype) {
    subtype = estype;
    notifyListeners();
  }

  Timer? _autoSaveTimer;
  Timer? _periodicSyncTimer;
  StreamSubscription? _docSubscription;
  String saveStatus = "";
  String _lastSavedContent = "";
  String _lastSyncedContent = "";
  bool _needsFirestoreSync = false;

  /// Live multi-section editing session, non-null while the editor is
  /// in Scrivenings (continuous-scroll) mode. Per-section QuillControllers
  /// live in the session; while it's active, [controller] is retargeted
  /// to whichever section currently owns keyboard focus so existing
  /// chrome (toolbar, find/replace, floating bars, spell check) keeps
  /// reading `provider.controller` and gets the right one.
  ScrivenningsSession? _scrivenningsSession;
  ScrivenningsSession? get scrivenningsSession => _scrivenningsSession;
  bool get inScrivenningsMode => _scrivenningsSession != null;

  /// Stash for the single-section controller while a scrivenings session
  /// is active. The controller field itself gets retargeted to focused
  /// per-section controllers; on exit we restore this one.
  QuillController? _draftControllerStash;
  String? _draftSectionIdStash;

  // Books that adopted a server UUID during ghost-duplicate reconciliation.
  // Each entry records the now-promoted book ID and the empty server-side
  // sections that should be deleted before local sections get pushed.
  final List<_GhostFix> _pendingGhostFixes = [];

  Future<void> loadBooks() async {
    bookLoadingData = true;
    notifyListeners();

    final localBooks = _storage.getBooks();
    final uid = _userId;
    if (uid != null) {
      try {
        final remoteBooks = await _dataService.getWritings(uid);
        _pendingGhostFixes.clear();
        allBooks = _mergeBooks(localBooks, remoteBooks);
        await _storage.saveBooks(allBooks);
        if (_pendingGhostFixes.isNotEmpty) {
          unawaited(_runGhostFixes(uid));
        }
        // Books created while logged out kept their digit-only local id and
        // were never registered server-side; promote them to a real UUID +
        // queue an isNew=true upsertWriting before _syncUnsyncedSections
        // enqueues content updates (those need the new writingId).
        await _migrateLegacyBookIds();
        _syncUnsyncedSections(uid);
      } catch (e) {
        allBooks = localBooks;
      }
    } else {
      allBooks = localBooks;
    }

    await _ensureBinderFolders();
    if (allBooks.isNotEmpty && activeBook == null) {
      setActiveBook(allBooks.first);
    }
    bookLoadingData = false;
    notifyListeners();
    _pushWidgetSnapshot();
  }

  void _pushWidgetSnapshot() {
    final author = _auth.currentUser?.name;
    unawaited(HomeWidgetService.instance.updateWritingWidget(
      authorName: author,
      books: allBooks,
    ));
    final sorted = [...allBooks]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final mostRecent = sorted.isEmpty ? null : sorted.first;
    unawaited(DesktopTrayService.instance.update(
      authorName: author,
      recentTitle: mostRecent?.title.isNotEmpty == true
          ? mostRecent!.title
          : 'Start a new story',
      recentId: mostRecent?.id ?? '',
      bookCount: allBooks.length,
    ));
  }

  /// Merge local and remote books. For each section present in both,
  /// keep whichever has the later updatedAt timestamp.
  /// IDs of books and sections the user has deleted locally but whose
  /// `deleteWriting` / `deleteSection` op hasn't drained yet. Pulled
  /// fresh from the outbox on every merge so we don't get stale.
  ({Set<String> bookIds, Set<String> sectionIds}) _pendingDeletes() {
    final bookIds = <String>{};
    final sectionIds = <String>{};
    for (final op in _outbox.snapshot()) {
      if (op.kind == PendingOpKind.deleteWriting) {
        final id = op.payload['writingId'];
        if (id is String) bookIds.add(id);
      } else if (op.kind == PendingOpKind.deleteSection) {
        final id = op.payload['sectionId'];
        if (id is String) sectionIds.add(id);
      }
    }
    return (bookIds: bookIds, sectionIds: sectionIds);
  }

  List<WritingModel> _mergeBooks(
    List<WritingModel> local,
    List<WritingModel> remote,
  ) {
    final pending = _pendingDeletes();
    // Drop remote books the user already deleted locally — without this,
    // a refresh fired between `deleteBook` and the outbox draining
    // resurrects the book from the server response. The outbox is the
    // source of truth: if a `deleteWriting` op is still queued for an
    // ID, the user's intent is "gone."
    final liveRemote = pending.bookIds.isEmpty
        ? remote
        : remote.where((r) => !pending.bookIds.contains(r.id)).toList();

    // Detect "ghost" duplicates produced by an old createWriting bug:
    // a local book kept its client-generated timestamp ID instead of the
    // server's UUID, so subsequent fetches saw the same book under both
    // IDs. Pair each legacy local book with a same-title remote book that
    // only contains untouched default sections, then promote the local
    // book to the server's UUID so it dedupes by ID from now on.
    final remoteByTitle = <String, List<WritingModel>>{};
    for (final r in liveRemote) {
      remoteByTitle.putIfAbsent(_titleKey(r.title), () => []).add(r);
    }
    final claimedRemoteIds = <String>{};
    for (final localBook in local) {
      if (!_isLegacyLocalBookId(localBook.id)) continue;
      final candidates =
          remoteByTitle[_titleKey(localBook.title)] ?? const <WritingModel>[];
      WritingModel? ghost;
      for (final r in candidates) {
        if (claimedRemoteIds.contains(r.id)) continue;
        if (_looksLikeGhostBook(r)) {
          ghost = r;
          break;
        }
      }
      if (ghost == null) continue;
      claimedRemoteIds.add(ghost.id);
      _pendingGhostFixes.add(_GhostFix(
        adoptedBookId: ghost.id,
        ghostSectionIds: ghost.sections.map((s) => s.id).toList(),
      ));
      localBook.id = ghost.id;
      for (final s in localBook.sections) {
        s.isSynced = false;
      }
    }

    final filteredRemote =
        liveRemote.where((r) => !claimedRemoteIds.contains(r.id)).toList();

    final localMap = {for (final b in local) b.id: b};
    final merged = <WritingModel>[];

    for (final remoteBook in filteredRemote) {
      final localBook = localMap.remove(remoteBook.id);
      if (localBook == null) {
        merged.add(remoteBook);
        continue;
      }
      final mergedSections = _mergeSections(
        localBook.sections,
        remoteBook.sections,
        pendingSectionDeletes: pending.sectionIds,
      );
      remoteBook.sections = mergedSections;
      merged.add(remoteBook);
    }
    // Local-only books (created offline, not yet in Firestore)
    merged.addAll(localMap.values);
    return merged;
  }

  static String _titleKey(String title) => title.trim().toLowerCase();

  // The buggy createWriting used DateTime.now().millisecondsSinceEpoch, so
  // legacy book IDs are pure digits. Real server IDs are UUIDs.
  static final RegExp _legacyIdPattern = RegExp(r'^\d+$');
  static bool _isLegacyLocalBookId(String id) =>
      _legacyIdPattern.hasMatch(id);

  static bool _looksLikeGhostBook(WritingModel b) {
    if (b.sections.isEmpty) return true;
    return b.sections.every(_isEmptyDefaultSection);
  }

  static bool _isEmptyDefaultSection(SectionModel s) {
    if (s.canvasData.isNotEmpty && s.canvasData != '[]') return false;
    if (s.content.isEmpty) return true;
    try {
      final ops = jsonDecode(s.content);
      if (ops is List) {
        if (ops.isEmpty) return true;
        if (ops.length == 1 && ops[0] is Map) {
          final insert = ops[0]['insert'];
          if (insert == '\n' || insert == '' || insert == null) return true;
        }
      }
    } catch (_) {}
    return false;
  }

  /// Finish ghost reconciliation by deleting the empty server sections and
  /// re-pushing the local sections under their now-server-known book IDs.
  /// Runs in the background; failures are tolerated and retried next load.
  Future<void> _runGhostFixes(String uid) async {
    final fixes = List<_GhostFix>.from(_pendingGhostFixes);
    _pendingGhostFixes.clear();
    var changed = false;
    for (final fix in fixes) {
      WritingModel? book;
      for (final b in allBooks) {
        if (b.id == fix.adoptedBookId) {
          book = b;
          break;
        }
      }
      if (book == null) continue;

      for (final ghostSectionId in fix.ghostSectionIds) {
        try {
          await _dataService.deleteSection(
              uid, fix.adoptedBookId, ghostSectionId);
        } catch (_) {}
      }

      for (final section in book.sections) {
        try {
          await _dataService.addSection(uid, fix.adoptedBookId, section);
          changed = true;
        } catch (_) {}
      }
    }
    if (changed) {
      await _storage.saveBooks(allBooks);
      notifyListeners();
    }
  }

  List<SectionModel> _mergeSections(
    List<SectionModel> local,
    List<SectionModel> remote, {
    Set<String> pendingSectionDeletes = const <String>{},
  }) {
    final liveRemote = pendingSectionDeletes.isEmpty
        ? remote
        : remote.where((s) => !pendingSectionDeletes.contains(s.id)).toList();
    return mergeSectionsLww(local, liveRemote,
        onMergeDecision: _maybeRecordMerge);
  }

  /// Pure last-write-wins merge of two section lists, exposed for tests.
  /// Local sections win when their `updatedAt` is strictly later than the
  /// remote AND they're marked unsynced (i.e. they have unsent edits);
  /// otherwise the remote wins. Local-only sections (no remote match)
  /// are appended at the end.
  static List<SectionModel> mergeSectionsLww(
    List<SectionModel> local,
    List<SectionModel> remote, {
    void Function(SectionModel local, SectionModel remote, bool localWins)?
        onMergeDecision,
  }) {
    final localMap = {for (final s in local) s.id: s};
    final merged = <SectionModel>[];
    for (final remoteSection in remote) {
      final localSection = localMap.remove(remoteSection.id);
      if (localSection == null) {
        merged.add(remoteSection);
        continue;
      }
      final localWins =
          localSection.updatedAt.isAfter(remoteSection.updatedAt) &&
              !localSection.isSynced;
      onMergeDecision?.call(localSection, remoteSection, localWins);
      merged.add(localWins ? localSection : remoteSection);
    }
    merged.addAll(localMap.values);
    return merged;
  }

  /// Record a merge decision when the two sides actually disagree on
  /// content. Same-content "merges" are noise and would drown the log.
  void _maybeRecordMerge(
    SectionModel localSection,
    SectionModel remoteSection,
    bool localWins,
  ) {
    if (localSection.content == remoteSection.content) return;
    unawaited(_mergeLog.record(MergeLogEntry(
      sectionId: localSection.id,
      localUpdatedAt: localSection.updatedAt,
      remoteUpdatedAt: remoteSection.updatedAt,
      localLen: localSection.content.length,
      remoteLen: remoteSection.content.length,
      winner: localWins ? 'local' : 'remote',
    )));
  }

  /// Enqueue any locally-modified, unsynced sections so the drainer pushes
  /// them. Cheap to call repeatedly — duplicates would just produce extra
  /// PUTs (idempotent on the server side). For now we only enqueue if the
  /// outbox doesn't already have a same-target upsert pending.
  /// Promote books whose id is a legacy digit-only timestamp (the
  /// pre-fix `addNewBook` shape) to a proper UUIDv4 and queue an
  /// upsertWriting so the server actually registers them. Without this,
  /// any later upsertSection enqueued for the book hits 422 — the
  /// section routes validate writing_id as a UUID at the path level.
  ///
  /// Only migrates books that have NO upsertWriting already in the
  /// outbox; if one is queued, the existing remap-on-drain path will
  /// heal it without our help (and a parallel migration would create
  /// a duplicate server-side).
  Future<void> _migrateLegacyBookIds() async {
    final pendingWritings = <String>{};
    for (final op in _outbox.snapshot()) {
      if (op.kind == PendingOpKind.upsertWriting) {
        final id = op.payload['writingId'];
        if (id is String) pendingWritings.add(id);
      }
    }
    var changed = false;
    for (final book in allBooks) {
      if (!_isLegacyLocalBookId(book.id)) continue;
      if (pendingWritings.contains(book.id)) continue;
      final oldId = book.id;
      final newId = _uuid.v4();
      book.id = newId;
      // Sections need to be re-pushed under the new writing — the
      // server has no record of them yet. _syncUnsyncedSections, which
      // runs right after this, will pick up the unsynced flag and
      // enqueue them with the new writingId.
      for (final section in book.sections) {
        section.isSynced = false;
      }
      await _rewriteOutboxWritingId(oldId, newId);
      await _enqueue(PendingOp(
        kind: PendingOpKind.upsertWriting,
        payload: {
          'writingId': newId,
          'isNew': true,
          'fields': {
            'title': book.title,
            'description': book.description,
            'coverImagePath': book.coverImagePath,
            'writingType': book.writingType.index,
            'subtype': book.subtype,
            'author': book.author,
          },
        },
      ));
      changed = true;
      if (activeBook?.id == oldId) activeBook!.id = newId;
      if (_writingChannelKey == oldId) {
        _teardownWritingChannel();
        _subscribeToWritingChannel(newId);
      }
    }
    if (changed) {
      await _storage.saveBooks(allBooks);
    }
  }

  /// Replace every queued op's `writingId == oldId` with `newId`. Used
  /// when a legacy book id is promoted to a UUID so already-queued
  /// section/bookmark/project ops still target the right writing.
  Future<void> _rewriteOutboxWritingId(String oldId, String newId) async {
    await _outbox.rewriteAll((op) {
      final wid = op.payload['writingId'];
      if (wid is! String || wid != oldId) return op;
      return op.copyWith(payload: {...op.payload, 'writingId': newId});
    });
  }

  void _syncUnsyncedSections(String uid) async {
    final pendingTargets = <String>{
      for (final op in _outbox.snapshot())
        if (op.kind == PendingOpKind.upsertSection)
          '${op.payload['writingId']}/${op.payload['sectionId']}',
    };
    for (final book in allBooks) {
      for (final section in book.sections) {
        if (section.isSynced) continue;
        final key = '${book.id}/${section.id}';
        if (pendingTargets.contains(key)) continue;
        await _enqueue(PendingOp(
          kind: PendingOpKind.upsertSection,
          payload: {
            'writingId': book.id,
            'sectionId': section.id,
            'isNew': false,
            'fields': {
              'content': section.content,
              if (section.canvasData.isNotEmpty)
                'canvas_data': section.canvasData,
            },
          },
        ));
      }
    }
  }

  void setActiveBook(WritingModel book) {
    activeBook = book;
    allBooksSection = book.sections;
    _subscribeToWritingChannel(book.id);
    notifyListeners();
  }

  /// Open (or reopen) the SSE channel for [writingId] and route incoming
  /// mutations through the merge layer so a remote edit doesn't yank text
  /// from under the user's cursor. Cheap to call repeatedly — same target
  /// reuses the existing subscription.
  void _subscribeToWritingChannel(String writingId) {
    if (_writingChannelKey == writingId) return;
    _teardownWritingChannel();
    _writingChannelKey = writingId;
    final realtime = _auth.realtimeService;
    _writingChannelSub =
        realtime.writingChannel(writingId).listen(_onWritingChannelEvent);
  }

  void _teardownWritingChannel() {
    final prev = _writingChannelKey;
    _writingChannelSub?.cancel();
    _writingChannelSub = null;
    _writingChannelKey = null;
    if (prev != null) {
      unawaited(_auth.realtimeService.closeWritingChannel(prev));
    }
  }

  void _onWritingChannelEvent(Map<String, dynamic> event) {
    // Drop our own echoes — the local model already reflects the write.
    if (_auth.realtimeService.wasIssuedByMe(event['op_id']?.toString())) {
      return;
    }
    final type = event['type'];
    if (type is! String) return;
    switch (type) {
      case 'writing.updated':
        _onRemoteWritingUpdated(event['writing']);
        break;
      case 'writing.deleted':
        _onRemoteWritingDeleted(event['writing_id']?.toString());
        break;
      case 'section.created':
        _onRemoteSectionCreated(event);
        break;
      case 'section.updated':
        _onRemoteSectionUpdated(event['section']);
        break;
      case 'section.deleted':
        _onRemoteSectionDeleted(event);
        break;
    }
  }

  void _onRemoteWritingUpdated(dynamic raw) {
    if (raw is! Map) return;
    final json = Map<String, dynamic>.from(raw);
    final id = json['id']?.toString();
    if (id == null) return;
    WritingModel? book;
    for (final b in allBooks) {
      if (b.id == id) {
        book = b;
        break;
      }
    }
    if (book == null) return;
    book.title = (json['title'] as String?) ?? book.title;
    book.description = (json['description'] as String?) ?? book.description;
    book.coverImagePath =
        (json['cover_image_path'] as String?) ?? book.coverImagePath;
    final coverMeta = ImageMeta.tryFromJson(json['cover_image_meta']);
    if (coverMeta != null) book.coverImageMeta = coverMeta;
    final subtype = json['subtype'] as String?;
    if (subtype != null) book.subtype = subtype;
    _storage.saveBooks(allBooks);
    notifyListeners();
  }

  void _onRemoteWritingDeleted(String? id) {
    if (id == null) return;
    final before = allBooks.length;
    allBooks.removeWhere((b) => b.id == id);
    // Even when the writing isn't in our local list (e.g. it was
    // authored on another device), the matching feed card may still be
    // sitting in this user's feed cache from an earlier hydrate. Prune
    // it unconditionally so a subsequent cold start doesn't paint a
    // tombstone — the server cascaded feed_items via the FK, so the
    // card is genuinely gone.
    _storage.removeCachedFeedItem(writingId: id);
    if (allBooks.length == before) return;
    if (activeBook?.id == id) {
      _teardownWritingChannel();
      if (allBooks.isNotEmpty) {
        setActiveBook(allBooks.first);
      } else {
        activeBook = null;
        activeSection = null;
        allBooksSection = [];
      }
    }
    _storage.saveBooks(allBooks);
    notifyListeners();
  }

  void _onRemoteSectionCreated(Map<String, dynamic> event) {
    final raw = event['section'];
    if (raw is! Map) return;
    final book = activeBook;
    if (book == null) return;
    final sectionJson = Map<String, dynamic>.from(raw);
    if (sectionJson['writing_id']?.toString() != book.id) return;
    final id = sectionJson['id']?.toString();
    if (id == null) return;
    if (book.sections.any((s) => s.id == id)) return;
    book.sections.add(_remoteSectionFromJson(sectionJson));
    allBooksSection = book.sections;
    _storage.saveBooks(allBooks);
    notifyListeners();
  }

  void _onRemoteSectionUpdated(dynamic raw) {
    if (raw is! Map) return;
    final book = activeBook;
    if (book == null) return;
    final sectionJson = Map<String, dynamic>.from(raw);
    if (sectionJson['writing_id']?.toString() != book.id) return;
    final remote = _remoteSectionFromJson(sectionJson);
    final idx = book.sections.indexWhere((s) => s.id == remote.id);
    if (idx < 0) {
      book.sections.add(remote);
      allBooksSection = book.sections;
      _storage.saveBooks(allBooks);
      notifyListeners();
      return;
    }
    final local = book.sections[idx];
    final isActive = activeSection?.id == remote.id;
    // Don't yank text from under the cursor: if the live editor has an
    // unsaved buffer, treat it as the local content (with "now" updatedAt)
    // so local always wins and the user sees a "your edit was merged" toast
    // rather than losing keystrokes.
    if (isActive) {
      final live = dumpData();
      if (live != _lastSavedContent) {
        unawaited(_mergeLog.record(MergeLogEntry(
          sectionId: remote.id,
          localUpdatedAt: DateTime.now(),
          remoteUpdatedAt: remote.updatedAt,
          localLen: live.length,
          remoteLen: remote.content.length,
          winner: 'local',
        )));
        return;
      }
    }
    final localWins =
        local.updatedAt.isAfter(remote.updatedAt) && !local.isSynced;
    _maybeRecordMerge(local, remote, localWins);
    if (localWins) return;
    // Preserve fields the remote doesn't carry (canvas data, color, plus
    // any binder metadata the server omits in this echo). Remote takes
    // precedence when it does carry the field.
    final merged = SectionModel(
      id: remote.id,
      title: remote.title,
      content: remote.content,
      canvasData: remote.canvasData.isEmpty ? local.canvasData : remote.canvasData,
      sectionColor: remote.sectionColor,
      isSynced: true,
      createdAt: local.createdAt,
      updatedAt: remote.updatedAt,
      parentId: remote.parentId ?? local.parentId,
      order: remote.order != 0 ? remote.order : local.order,
      kind: remote.kind != SectionKind.chapter ? remote.kind : local.kind,
      synopsis: remote.synopsis.isNotEmpty ? remote.synopsis : local.synopsis,
      notes: remote.notes.isNotEmpty ? remote.notes : local.notes,
      labelColor: remote.labelColor ?? local.labelColor,
      keywords: remote.keywords.isNotEmpty ? remote.keywords : local.keywords,
      includeInPublish: remote.includeInPublish,
      footnotes:
          remote.footnotes.isNotEmpty ? remote.footnotes : local.footnotes,
    );
    book.sections[idx] = merged;
    allBooksSection = book.sections;
    if (isActive) {
      activeSection = merged;
      if (_scrivenningsSession == null) {
        initEditor();
      }
    }
    // Refresh scrivenings controllers (focused or not) so a remote
    // edit lands in the live multi-section view too.
    _scrivenningsSession?.refreshSectionContent(merged);
    _storage.saveBooks(allBooks);
    notifyListeners();
  }

  void _onRemoteSectionDeleted(Map<String, dynamic> event) {
    final book = activeBook;
    if (book == null) return;
    final id = event['section_id']?.toString();
    if (id == null) return;
    final before = book.sections.length;
    book.sections.removeWhere((s) => s.id == id);
    if (book.sections.length == before) return;
    allBooksSection = book.sections;
    // Drop any per-section controller whose section just disappeared
    // remotely. Defer disposal so we don't await inside this synchronous
    // event handler — the session swallows in-flight typing state safely.
    final session = _scrivenningsSession;
    if (session != null) {
      unawaited(session.unregister(id));
    }
    if (activeSection?.id == id) {
      if (book.sections.isNotEmpty) {
        activeSection = book.sections.first;
        if (session == null) initEditor();
      } else {
        activeSection = null;
        controller = QuillController.basic();
      }
    }
    _storage.saveBooks(allBooks);
    notifyListeners();
  }

  /// Decode a section payload as broadcast by the writings router. Local
  /// canvasData isn't included by the server — preserved by the merge
  /// path above when applicable.
  SectionModel _remoteSectionFromJson(Map<String, dynamic> json) {
    return SectionModel(
      id: json['id']?.toString() ?? '',
      title: (json['title'] as String?) ?? '',
      content: _encodeRemoteContent(json['content']),
      canvasData: _encodeRemoteContent(json['canvas_data']),
      sectionColor:
          Color((json['section_color'] as num?)?.toInt() ?? 0xFF1982C4),
      isSynced: true,
      updatedAt:
          DateTime.tryParse(json['updated_at']?.toString() ?? '') ??
              DateTime.now(),
      parentId: json['parent_id'] as String?,
      order: (json['sort_order'] as num?)?.toInt() ?? 0,
      kind: SectionKindCodec.fromCode(json['kind'] as String?),
      synopsis: (json['synopsis'] as String?) ?? '',
      notes: _encodeRemoteContent(json['notes']),
      labelColor: (json['label_color'] as num?)?.toInt(),
      keywords: (json['keywords'] is List)
          ? (json['keywords'] as List).whereType<String>().toList()
          : <String>[],
      includeInPublish: json['include_in_publish'] is bool
          ? json['include_in_publish'] as bool
          : true,
      footnotes: _decodeRemoteFootnotes(json['footnotes']),
    );
  }

  static List<FootnoteModel> _decodeRemoteFootnotes(dynamic raw) {
    if (raw is! List) return <FootnoteModel>[];
    final out = <FootnoteModel>[];
    for (final entry in raw) {
      if (entry is Map) {
        try {
          out.add(FootnoteModel.fromJson(entry.cast<String, dynamic>()));
        } catch (_) {}
      }
    }
    return out;
  }

  static String _encodeRemoteContent(dynamic value) {
    if (value == null) return '';
    if (value is String) return value;
    return jsonEncode(value);
  }

  Future<void> addNewBook() async {
    if (titleController.text.trim().isEmpty) {
      throw Exception("Title cannot be empty");
    }
    if (subtype.trim().isEmpty) throw Exception("Please select a format");
    // Server validates writing_id / section_id as UUIDs on every section
    // route — generate them client-side as UUIDv4 so a queued upsertSection
    // can land even if the user creates the book offline (or while
    // logged out) and edits a section before the upsertWriting drains.
    final bookId = _uuid.v4();
    final manuscriptId = _folderUuid(bookId, SectionKind.folder);
    final researchId = _folderUuid(bookId, SectionKind.research);
    final trashId = _folderUuid(bookId, SectionKind.trash);
    final firstChapterId = _uuid.v4();
    final newBook = WritingModel(
      author: _auth.currentUser?.name ?? "Unknown Author",
      coverImagePath: "",
      id: bookId,
      title: titleController.text,
      description: descriptionController.text,
      writingType: type,
      subtype: subtype,
      sections: [
        SectionModel(
          id: manuscriptId,
          title: 'Manuscript',
          content: '',
          kind: SectionKind.folder,
          order: 0,
          sectionColor: sectionColors[0],
          includeInPublish: true,
        ),
        SectionModel(
          id: researchId,
          title: 'Research',
          content: '',
          kind: SectionKind.research,
          order: 1,
          sectionColor: sectionColors[3],
          includeInPublish: false,
        ),
        SectionModel(
          id: trashId,
          title: 'Trash',
          content: '',
          kind: SectionKind.trash,
          order: 2,
          sectionColor: sectionColors[1],
          includeInPublish: false,
        ),
        SectionModel(
          id: firstChapterId,
          title: 'Untitled Section',
          content: jsonEncode([
            {"insert": "\n"},
          ]),
          sectionColor: sectionColors[0],
          parentId: manuscriptId,
          order: 0,
          kind: SectionKind.chapter,
          includeInPublish: true,
        ),
      ],
    );
    titleController.clear();
    descriptionController.clear();
    type = WritingType.personal;
    subtype = "";

    allBooks.add(newBook);
    activeBook = newBook;
    allBooksSection = newBook.sections;

    await _storage.saveBooks(allBooks);

    if (_userId != null) {
      // Queue create-writing first; the drainer rewrites the queued
      // create-section's writingId once the server returns the canonical
      // id, so order matters here.
      await _enqueue(PendingOp(
        kind: PendingOpKind.upsertWriting,
        payload: {
          'writingId': newBook.id,
          'isNew': true,
          'fields': {
            'title': newBook.title,
            'description': newBook.description,
            'coverImagePath': newBook.coverImagePath,
            'writingType': newBook.writingType.index,
            'subtype': newBook.subtype,
            'author': newBook.author,
          },
        },
      ));
      for (final section in newBook.sections) {
        await _enqueue(PendingOp(
          kind: PendingOpKind.upsertSection,
          payload: {
            'writingId': newBook.id,
            'sectionId': section.id,
            'isNew': true,
            'fields': {
              'title': section.title,
              'content': section.content,
              'canvas_data': section.canvasData,
              'section_color': section.sectionColor.toARGB32(),
              if (section.parentId != null) 'parent_id': section.parentId,
              'sort_order': section.order,
              'kind': section.kind.code,
              'include_in_publish': section.includeInPublish,
            },
          },
        ));
      }
    }
    // First chapter is the natural place to drop the user — folder rows
    // aren't editable.
    final firstChapter = newBook.sections.firstWhere(
      (s) => s.id == firstChapterId,
      orElse: () => newBook.sections.first,
    );
    setActiveSection(firstChapter);
    notifyListeners();
  }

  /// Idempotent: ensures every book has the three top-level folders
  /// (Manuscript, Research, Trash), reparents orphan top-level
  /// chapters/scenes under Manuscript, and migrates any pre-existing
  /// folder whose id is not a UUID (legacy `${book.id}-manuscript`
  /// shape) into a deterministic UUIDv5. The legacy id was rejected
  /// server-side as not-a-UUID, so chapters under those folders never
  /// synced; the migration also rewrites the offending outbox ops to
  /// point at the new ids and marks the touched sections unsynced so
  /// the next drain creates them server-side.
  Future<void> _ensureBinderFolders() async {
    final renames = <_FolderRename>[];
    var changed = false;
    for (final book in allBooks) {
      final result = _ensureFoldersForBook(book);
      changed = result.changed || changed;
      renames.addAll(result.renames);
    }
    if (renames.isNotEmpty) {
      await _migrateOutboxForRenames(renames);
    }
    if (changed) {
      await _storage.saveBooks(allBooks);
      // Anything we marked unsynced (renamed folders + their direct
      // children whose parent_id we rewrote) needs an upsert so the
      // server creates the folder and links children properly. The
      // outbox is per-user; only enqueue once we know there's a uid.
      if (_userId != null) {
        for (final r in renames) {
          await _enqueueRenameUpserts(r);
        }
      }
    }
  }

  // RFC4122 / RFC9562 UUID layout. Used to detect legacy folder ids
  // that the server (which does strict UUID validation on `section_id`)
  // would otherwise reject with HTTP 422.
  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  // Project-private namespace UUID for binder folder ids. Pinned here
  // forever — every client MUST use the same namespace so two devices
  // bootstrapping the same legacy book produce identical folder UUIDs
  // (otherwise we'd duplicate folders on first cross-device sync).
  static const String _folderNamespace =
      '9e7c8d2a-4b5f-4a3e-9c1d-8a7b6f5e4d3c';
  static const Uuid _uuid = Uuid();

  /// Deterministic UUIDv5 for the binder folder of [kind] inside [bookId].
  /// Same input always returns the same UUID so concurrent migrations on
  /// different devices converge instead of producing duplicates.
  static String _folderUuid(String bookId, SectionKind kind) {
    return _uuid.v5(_folderNamespace, '$bookId/${kind.code}');
  }

  static bool _looksLikeUuid(String id) => _uuidPattern.hasMatch(id);

  _EnsureFoldersResult _ensureFoldersForBook(WritingModel book) {
    SectionModel? findFolder(SectionKind kind) {
      for (final s in book.sections) {
        if (s.parentId == null && s.kind == kind) return s;
      }
      return null;
    }

    final renames = <_FolderRename>[];
    var changed = false;

    // Step 1: rename any existing top-level folder whose id isn't a
    // UUID. This is the migration arm — bookId-manuscript / -research /
    // -trash get rewritten in place and every child's parent_id
    // follows.
    SectionModel? migrate(SectionModel folder) {
      if (_looksLikeUuid(folder.id)) return folder;
      final newId = _folderUuid(book.id, folder.kind);
      if (newId == folder.id) return folder;
      final oldId = folder.id;
      folder.id = newId;
      folder.isSynced = false;
      // Rewrite every child's parentId so the binder hierarchy survives.
      // Also mark them unsynced so the parent-id change propagates to
      // the server on the next drain.
      final movedChildIds = <String>[];
      for (final s in book.sections) {
        if (s.parentId == oldId) {
          s.parentId = newId;
          s.isSynced = false;
          movedChildIds.add(s.id);
        }
      }
      renames.add(_FolderRename(
        bookId: book.id,
        oldId: oldId,
        newId: newId,
        movedChildIds: movedChildIds,
      ));
      changed = true;
      return folder;
    }

    SectionModel? manuscript = findFolder(SectionKind.folder);
    if (manuscript != null) manuscript = migrate(manuscript);
    final research = findFolder(SectionKind.research);
    if (research != null) migrate(research);
    final trash = findFolder(SectionKind.trash);
    if (trash != null) migrate(trash);

    // Step 2: create any missing folder with a fresh deterministic UUID.
    if (manuscript == null) {
      manuscript = SectionModel(
        id: _folderUuid(book.id, SectionKind.folder),
        title: 'Manuscript',
        content: '',
        kind: SectionKind.folder,
        order: 0,
        sectionColor: sectionColors[0],
        includeInPublish: true,
      );
      book.sections.add(manuscript);
      changed = true;
    }
    if (findFolder(SectionKind.research) == null) {
      book.sections.add(SectionModel(
        id: _folderUuid(book.id, SectionKind.research),
        title: 'Research',
        content: '',
        kind: SectionKind.research,
        order: 1,
        sectionColor: sectionColors[3],
        includeInPublish: false,
      ));
      changed = true;
    }
    if (findFolder(SectionKind.trash) == null) {
      book.sections.add(SectionModel(
        id: _folderUuid(book.id, SectionKind.trash),
        title: 'Trash',
        content: '',
        kind: SectionKind.trash,
        order: 2,
        sectionColor: sectionColors[1],
        includeInPublish: false,
      ));
      changed = true;
    }

    // Step 3: adopt orphan top-level chapters/scenes into the Manuscript
    // folder so legacy flat writings keep all their existing chapters
    // visible.
    var nextOrder = 0;
    for (final s in book.sections) {
      if (s.id == manuscript.id) continue;
      if (s.parentId == null &&
          s.kind != SectionKind.folder &&
          s.kind != SectionKind.research &&
          s.kind != SectionKind.trash &&
          s.kind != SectionKind.act) {
        s.parentId = manuscript.id;
        s.order = nextOrder++;
        changed = true;
      }
    }
    return _EnsureFoldersResult(changed: changed, renames: renames);
  }

  /// Drop any outbox op that references a renamed folder id. Those ops
  /// were created when the section_id was the legacy `bookId-kind`
  /// string — the server already rejected them with HTTP 422, and the
  /// `_enqueueRenameUpserts` call below will queue a fresh isNew=true
  /// upsert under the new UUID so the folder actually lands.
  Future<void> _migrateOutboxForRenames(List<_FolderRename> renames) async {
    if (renames.isEmpty) return;
    final oldIds = {for (final r in renames) r.oldId};
    final ops = _outbox.snapshot();
    for (final op in ops) {
      final sectionId = op.payload['sectionId'];
      if (sectionId is String && oldIds.contains(sectionId)) {
        await _outbox.remove(op.id);
      }
    }
  }

  /// Queue upserts for a freshly-renamed folder + every child whose
  /// parent_id we rewrote. Marked `isNew: true` because the legacy id
  /// was never accepted server-side, so this UUID is genuinely new.
  Future<void> _enqueueRenameUpserts(_FolderRename rename) async {
    final book = allBooks.firstWhere(
      (b) => b.id == rename.bookId,
      orElse: () => WritingModel(
        id: '',
        title: '',
        sections: const [],
        author: '',
        description: '',
        coverImagePath: '',
        writingType: WritingType.freestyle,
        subtype: 'freestyle',
      ),
    );
    if (book.id.isEmpty) return;
    SectionModel? folder;
    for (final s in book.sections) {
      if (s.id == rename.newId) {
        folder = s;
        break;
      }
    }
    if (folder == null) return;
    await _enqueue(PendingOp(
      kind: PendingOpKind.upsertSection,
      payload: {
        'writingId': book.id,
        'sectionId': folder.id,
        'isNew': true,
        'fields': {
          'title': folder.title,
          'content': folder.content,
          'canvas_data': folder.canvasData,
          'section_color': folder.sectionColor.toARGB32(),
          'sort_order': folder.order,
          'kind': folder.kind.code,
          'synopsis': folder.synopsis,
          'notes': folder.notes,
          'keywords': folder.keywords,
          'include_in_publish': folder.includeInPublish,
        },
      },
    ));
    // Each child's parent_id changed; surface that to the server too.
    for (final childId in rename.movedChildIds) {
      await _enqueue(PendingOp(
        kind: PendingOpKind.upsertSection,
        payload: {
          'writingId': book.id,
          'sectionId': childId,
          'isNew': false,
          'fields': {'parent_id': rename.newId},
        },
      ));
    }
  }

  Future<String> updateBookCoverImage(WritingModel book, Uint8List bytes) async {
    final uid = _userId;
    if (uid == null) throw Exception("User not logged in");
    // The upload itself is online-only — there's no useful offline shape for
    // a binary blob upload (we don't want to buffer raw bytes in Hive). The
    // metadata update that follows IS queued so it survives a crash.
    final result = await _storageService.uploadCoverImage(uid, book.id, bytes);
    book.coverImagePath = result.url;
    book.coverImageMeta = result.meta;
    await _storage.saveBooks(allBooks);
    await _enqueue(PendingOp(
      kind: PendingOpKind.upsertWriting,
      payload: {
        'writingId': book.id,
        'isNew': false,
        'fields': {
          'coverImagePath': result.url,
          if (result.meta != null) 'coverImageMeta': result.meta!.toJson(),
        },
      },
    ));
    notifyListeners();
    return result.url;
  }

  Future<void> deleteBook(WritingModel book) async {
    AnalyticsService.instance.track(
      'post_deleted',
      action: 'click',
      entityType: 'writing',
      entityId: book.id,
    );
    allBooks.remove(book);
    if (activeBook?.id == book.id) {
      if (allBooks.isNotEmpty) {
        setActiveBook(allBooks.first);
      } else {
        activeBook = null;
        activeSection = null;
        allBooksSection = [];
      }
    }

    await _storage.saveBooks(allBooks);
    // The server cascades the matching feed_items row via the
    // writings -> feed_items FK (migration 20260502_04). Mirror that
    // cascade in the local feed cache so a hydrate-from-cache cold
    // start doesn't paint a card whose reader will 404 on open.
    await _storage.removeCachedFeedItem(writingId: book.id);
    if (_userId != null) {
      await _enqueue(PendingOp(
        kind: PendingOpKind.deleteWriting,
        payload: {'writingId': book.id},
      ));
    }
    notifyListeners();
  }

  Future<void> renameBook(String newTitle) async {
    if (activeBook == null) return;
    await renameBookById(activeBook!, newTitle);
  }

  Future<void> renameBookById(WritingModel book, String newTitle) async {
    book.title = newTitle;
    await _storage.saveBooks(allBooks);
    if (_userId != null) {
      await _enqueue(PendingOp(
        kind: PendingOpKind.upsertWriting,
        payload: {
          'writingId': book.id,
          'isNew': false,
          'fields': {'title': newTitle},
        },
      ));
    }
    notifyListeners();
  }

  void loadSection(WritingModel book) async {
    sectionLoadingData = true;
    notifyListeners();

    for (var b in allBooks) {
      if (b.id == book.id) {
        activeBook = b;
        allBooksSection = b.sections;
        break;
      }
    }
    if (activeBook != null) {
      _subscribeToWritingChannel(activeBook!.id);
    }
    await Future.delayed(const Duration(milliseconds: 300));
    sectionLoadingData = false;
    notifyListeners();
  }

  void setActiveSection(SectionModel section) {
    activeSection = section;
    saveStatus = "";
    notifyListeners();
  }

  String getPreviewText(String content) {
    if (content.trim().isEmpty) return "";
    try {
      var myJSON = jsonDecode(content);
      var doc = Document.fromJson(myJSON);
      String plainText = doc.toPlainText().replaceAll('\n', ' ').trim();
      return plainText.isEmpty ? "Empty document" : plainText;
    } catch (e) {
      return content.replaceAll('\n', ' ').trim();
    }
  }

  void addSection(
    String title, {
    bool autoSelect = true,
    String? parentId,
    SectionKind kind = SectionKind.chapter,
  }) {
    if (activeBook == null) return;
    // Default to nesting under Manuscript so new chapters land in the
    // publishable folder, not as orphans at the top level.
    final effectiveParentId = parentId ?? _defaultManuscriptId();
    final siblings = activeBook!.sections
        .where((s) => s.parentId == effectiveParentId)
        .toList();
    final newSection = SectionModel(
      id: _uuid.v4(),
      title: title,
      content: jsonEncode([
        {"insert": "\n"},
      ]),
      sectionColor:
          sectionColors[activeBook!.sections.length % sectionColors.length],
      parentId: effectiveParentId,
      order: siblings.length,
      kind: kind,
      includeInPublish: _isWithinManuscript(effectiveParentId),
    );

    activeBook!.sections.insert(0, newSection);
    allBooksSection = activeBook!.sections;

    _persistSectionAdd(newSection);
    if (autoSelect) {
      forceSaveImmediately();
      setActiveSection(newSection);
      initEditor();
    } else {
      notifyListeners();
    }
  }

  String? _defaultManuscriptId() {
    if (activeBook == null) return null;
    for (final s in activeBook!.sections) {
      if (s.parentId == null && s.kind == SectionKind.folder) return s.id;
    }
    return null;
  }

  bool _isWithinManuscript(String? parentId) {
    if (activeBook == null || parentId == null) return true;
    var current = parentId;
    final byId = {for (final s in activeBook!.sections) s.id: s};
    final visited = <String>{};
    while (true) {
      if (!visited.add(current)) return false;
      final node = byId[current];
      if (node == null) return false;
      if (node.kind == SectionKind.research || node.kind == SectionKind.trash) {
        return false;
      }
      if (node.parentId == null) return node.kind == SectionKind.folder;
      current = node.parentId!;
    }
  }

  /// Move [section] to live under [newParentId] at the given index among
  /// siblings, rewriting `order` densely. Drag-reorder + drag-between-
  /// folders both call this.
  Future<void> moveSection(
    SectionModel section, {
    required String? newParentId,
    required int newIndex,
  }) async {
    if (activeBook == null) return;
    final book = activeBook!;
    section.parentId = newParentId;
    final newWithinPublishable = _isWithinManuscript(newParentId);
    section.includeInPublish = newWithinPublishable;
    // Renumber siblings under the new parent so `order` is dense and
    // dragging always produces a stable result.
    final siblings = book.sections
        .where((s) => s.id != section.id && s.parentId == newParentId)
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    final clampedIndex = newIndex.clamp(0, siblings.length).toInt();
    siblings.insert(clampedIndex, section);
    for (var i = 0; i < siblings.length; i++) {
      siblings[i].order = i;
    }
    section.updatedAt = DateTime.now();
    await _storage.saveBooks(allBooks);
    notifyListeners();
    if (_userId != null) {
      // Persist the move for the dragged section + every renumbered
      // sibling whose order changed. Each is a metadata-only PUT.
      for (final s in siblings) {
        await _enqueue(PendingOp(
          kind: PendingOpKind.upsertSection,
          payload: {
            'writingId': book.id,
            'sectionId': s.id,
            'isNew': false,
            'fields': {
              if (s.id == section.id) 'parent_id': s.parentId,
              'sort_order': s.order,
              if (s.id == section.id)
                'include_in_publish': s.includeInPublish,
            },
          },
        ));
      }
    }
  }

  /// Update one or more metadata fields on [section] in memory + persist.
  /// `fields` keys are the server-side names (e.g. `synopsis`, `notes`,
  /// `label_color`, `keywords`, `include_in_publish`).
  Future<void> updateSectionFields(
    SectionModel section,
    Map<String, dynamic> fields,
  ) async {
    if (fields.containsKey('synopsis')) {
      section.synopsis = fields['synopsis'] as String? ?? '';
    }
    if (fields.containsKey('notes')) {
      section.notes = fields['notes'] as String? ?? '';
    }
    if (fields.containsKey('label_color')) {
      section.labelColor = (fields['label_color'] as num?)?.toInt();
    }
    if (fields.containsKey('keywords')) {
      final raw = fields['keywords'];
      section.keywords = (raw is List)
          ? raw.whereType<String>().toList()
          : <String>[];
    }
    if (fields.containsKey('include_in_publish')) {
      section.includeInPublish = fields['include_in_publish'] as bool? ?? true;
    }
    if (fields.containsKey('kind')) {
      section.kind = SectionKindCodec.fromCode(fields['kind'] as String?);
    }
    if (fields.containsKey('footnotes')) {
      final raw = fields['footnotes'];
      if (raw is List<FootnoteModel>) {
        section.footnotes = List<FootnoteModel>.from(raw);
      } else if (raw is List) {
        section.footnotes = [
          for (final entry in raw)
            if (entry is FootnoteModel)
              entry
            else if (entry is Map)
              FootnoteModel.fromJson(entry.cast<String, dynamic>()),
        ];
      }
      // Outbox payloads round-trip through JSON; normalize footnote
      // models to plain maps so the drainer / Hive codec doesn't choke
      // on a non-encodable List<FootnoteModel>.
      fields['footnotes'] =
          section.footnotes.map((f) => f.toJson()).toList();
    }
    await persistSectionMetadata(section, fields);
    notifyListeners();
  }

  Future<void> _persistSectionAdd(SectionModel section) async {
    await _storage.saveBooks(allBooks);
    if (_userId != null && activeBook != null) {
      await _enqueue(PendingOp(
        kind: PendingOpKind.upsertSection,
        payload: {
          'writingId': activeBook!.id,
          'sectionId': section.id,
          'isNew': true,
          'fields': {
            'title': section.title,
            'content': section.content,
            'canvas_data': section.canvasData,
            'section_color': section.sectionColor.toARGB32(),
            if (section.parentId != null) 'parent_id': section.parentId,
            'sort_order': section.order,
            'kind': section.kind.code,
            'synopsis': section.synopsis,
            'notes': section.notes,
            if (section.labelColor != null) 'label_color': section.labelColor,
            'keywords': section.keywords,
            'include_in_publish': section.includeInPublish,
            'footnotes':
                section.footnotes.map((f) => f.toJson()).toList(),
          },
        },
      ));
    }
  }

  /// Patch a section's binder metadata locally + queue the same delta
  /// for the server. Used by the binder for parent/order changes,
  /// label assignment, keyword edits, synopsis/notes edits, etc.
  Future<void> persistSectionMetadata(
    SectionModel section,
    Map<String, dynamic> fields, {
    bool save = true,
  }) async {
    section.updatedAt = DateTime.now();
    if (save) {
      await _storage.saveBooks(allBooks);
    }
    if (_userId != null && activeBook != null) {
      await _enqueue(PendingOp(
        kind: PendingOpKind.upsertSection,
        payload: {
          'writingId': activeBook!.id,
          'sectionId': section.id,
          'isNew': false,
          'fields': fields,
        },
      ));
    }
  }

  /// Patch project-level fields on the active book (target word count,
  /// deadline, label palette).
  Future<void> persistProjectFields(Map<String, dynamic> fields) async {
    if (activeBook == null) return;
    await _storage.saveBooks(allBooks);
    if (_userId != null) {
      await _enqueue(PendingOp(
        kind: PendingOpKind.updateWritingProject,
        payload: {
          'writingId': activeBook!.id,
          'fields': fields,
        },
      ));
    }
    notifyListeners();
  }

  void addSectionToActiveBook(String title) {
    addSection(title, autoSelect: false);
  }

  Future<void> renameSection(SectionModel section, String newTitle) async {
    section.title = newTitle;
    await _storage.saveBooks(allBooks);
    if (_userId != null && activeBook != null) {
      await _enqueue(PendingOp(
        kind: PendingOpKind.upsertSection,
        payload: {
          'writingId': activeBook!.id,
          'sectionId': section.id,
          'isNew': false,
          'fields': {'title': newTitle},
        },
      ));
    }
    notifyListeners();
  }

  /// Soft-delete: move the section under the Trash folder. Permanent
  /// deletion happens from inside the Trash folder via [purgeSection].
  /// Sections that are *already* under Trash skip the move and are
  /// purged immediately so the user can clear Trash item-by-item.
  Future<void> deleteSection(SectionModel section) async {
    if (activeBook == null) return;
    final book = activeBook!;
    String? trashId;
    for (final s in book.sections) {
      if (s.parentId == null && s.kind == SectionKind.trash) {
        trashId = s.id;
        break;
      }
    }
    final alreadyInTrash = trashId != null && _isAncestor(book, trashId, section);
    if (trashId != null && !alreadyInTrash) {
      await moveSection(section,
          newParentId: trashId, newIndex: 1 << 30);
      return;
    }
    await purgeSection(section);
  }

  /// Permanent delete — used from Trash and from the soft-delete fallback
  /// when no Trash folder exists (defensive).
  Future<void> purgeSection(SectionModel section) async {
    if (activeBook == null) return;
    final writingId = activeBook!.id;
    final descendants = _collectDescendants(activeBook!, section.id);
    final allIds = {section.id, ...descendants};
    // If a scrivenings session is open, drop any controllers for purged
    // sections so they don't keep firing autosave for content that no
    // longer exists in the model.
    final session = _scrivenningsSession;
    if (session != null) {
      for (final id in allIds) {
        await session.unregister(id);
      }
    }
    activeBook!.sections.removeWhere((c) => allIds.contains(c.id));
    allBooksSection = activeBook!.sections;

    if (activeSection != null && allIds.contains(activeSection!.id)) {
      final firstChapter = activeBook!.sections
          .where((s) => s.kind == SectionKind.chapter || s.kind == SectionKind.scene)
          .toList()
        ..sort((a, b) => a.order.compareTo(b.order));
      if (firstChapter.isNotEmpty) {
        activeSection = firstChapter.first;
        initEditor();
      } else {
        activeSection = null;
        controller = QuillController.basic();
      }
    }

    await _storage.saveBooks(allBooks);
    if (_userId != null) {
      for (final id in allIds) {
        await _enqueue(PendingOp(
          kind: PendingOpKind.deleteSection,
          payload: {'writingId': writingId, 'sectionId': id},
        ));
      }
    }
    notifyListeners();
  }

  bool _isAncestor(WritingModel book, String ancestorId, SectionModel section) {
    var current = section.parentId;
    final byId = {for (final s in book.sections) s.id: s};
    final visited = <String>{};
    while (current != null) {
      if (current == ancestorId) return true;
      if (!visited.add(current)) return false;
      current = byId[current]?.parentId;
    }
    return false;
  }

  Set<String> _collectDescendants(WritingModel book, String parentId) {
    final result = <String>{};
    final stack = <String>[parentId];
    while (stack.isNotEmpty) {
      final current = stack.removeLast();
      for (final s in book.sections) {
        if (s.parentId == current && result.add(s.id)) {
          stack.add(s.id);
        }
      }
    }
    return result;
  }

  // ==========================================
  // EDITOR LOGIC
  // ==========================================
  void initEditor() {
    if (activeSection == null) return;
    try {
      String jsonString = activeSection!.content;
      if (jsonString.trim().isEmpty) {
        controller = QuillController.basic();
      } else {
        var myJSON = jsonDecode(jsonString);
        controller = QuillController(
          document: Document.fromJson(myJSON),
          selection: const TextSelection.collapsed(offset: 0),
        );
      }
    } catch (e) {
      controller = QuillController(
        document: Document()..insert(0, '${activeSection!.content}\n'),
        selection: const TextSelection.collapsed(offset: 0),
      );
    }

    _lastSavedContent = dumpData();
    _lastSyncedContent = _lastSavedContent;
    _needsFirestoreSync = false;
    _docSubscription?.cancel();
    _docSubscription = controller.document.changes.listen((event) {
      // Decoration-only mutations (spell-check underlines) compose with
      // ChangeSource.silent. They must not flip the typing/save state.
      if (event.source == ChangeSource.silent) return;
      _maybeSmartSubstitute(event);
      _maybeTypingHaptic(event);
      _onUserTyped();
    });
    _startPeriodicSync();
  }

  void _startPeriodicSync() {
    _periodicSyncTimer?.cancel();
    _periodicSyncTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      _syncToFirestore();
    });
  }

  void _stopPeriodicSync() {
    _periodicSyncTimer?.cancel();
    _periodicSyncTimer = null;
  }

  /// Hot-path haptic emitter. Fires only at sentence and paragraph
  /// boundaries — keystroke-level haptics get tiring fast, but a soft
  /// beat at the end of each thought makes typing feel rhythmic. Coalesced
  /// to one event per ~120ms so paste/IME bursts can't machine-gun.
  void _maybeTypingHaptic(DocChange event) {
    if (!typingHapticsEnabled || !_hapticsAvailable) return;
    String? inserted;
    for (final op in event.change.toList()) {
      if (op.isInsert && op.data is String) {
        inserted = op.data as String;
      }
    }
    if (inserted == null || inserted.isEmpty) return;
    final now = DateTime.now();
    if (now.difference(_lastHapticAt).inMilliseconds < 120) return;
    if (inserted.contains('\n')) {
      _lastHapticAt = now;
      HapticFeedback.lightImpact();
      return;
    }
    final last = inserted[inserted.length - 1];
    if (last == '.' || last == '!' || last == '?') {
      _lastHapticAt = now;
      HapticFeedback.selectionClick();
    }
  }

  void setTypingHapticsEnabled(bool value) {
    if (typingHapticsEnabled == value) return;
    typingHapticsEnabled = value;
    notifyListeners();
  }

  /// Apply a smart-punctuation rule if the just-emitted change was a
  /// single-character user insertion that matches one of the rules in
  /// [SmartSubstitutions]. The synthetic replace re-enters the same
  /// listener — `_applyingSmartSubstitution` short-circuits the recursion.
  void _maybeSmartSubstitute(DocChange event) {
    if (!_smartPunctuationLoaded || !smartPunctuationEnabled) return;
    if (_applyingSmartSubstitution) return;
    if (event.source != ChangeSource.local) return;

    int retain = 0;
    String? inserted;
    int? insertOffset;
    for (final op in event.change.toList()) {
      if (op.isRetain) {
        retain += (op.value as int? ?? 0);
      } else if (op.isInsert) {
        if (op.data is! String) return;
        if (inserted != null) return; // only act on a single insert op
        inserted = op.data as String;
        insertOffset = retain;
        retain += inserted.length;
      } else if (op.isDelete) {
        return; // mixed insert/delete — skip
      }
    }
    if (inserted == null || insertOffset == null) return;

    final textAfter = controller.document.toPlainText();
    final sub = SmartSubstitutions.compute(
      textAfter: textAfter,
      insertOffset: insertOffset,
      inserted: inserted,
    );
    if (sub == null) return;

    _applyingSmartSubstitution = true;
    try {
      controller.replaceText(
        sub.start,
        sub.length,
        sub.replacement,
        TextSelection.collapsed(offset: sub.cursorAfter),
      );
    } finally {
      _applyingSmartSubstitution = false;
    }
  }

  Future<void> setSmartPunctuationEnabled(bool value) async {
    if (smartPunctuationEnabled == value) return;
    smartPunctuationEnabled = value;
    _smartPunctuationLoaded = true;
    await SmartSubstitutions.saveEnabled(value);
    notifyListeners();
  }

  void _onUserTyped() {
    // Keystroke hot path. Do NOT call notifyListeners() here — that would
    // rebuild every Consumer<EditorProvider> in the editor tree on the
    // first keystroke of every typing burst. The status chip listens to
    // [syncStatusListenable] directly, so a notifier flip is enough.
    if (!_typing) {
      _typing = true;
      saveStatus = "Typing...";
      _recomputeSyncStatus();
    }
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(seconds: 3), () {
      _saveToLocal();
    });
  }

  /// Save to local storage immediately. Fast, offline-safe.
  Future<void> _saveToLocal() async {
    if (activeSection == null || activeBook == null) return;
    final currentContent = dumpData();
    if (currentContent == _lastSavedContent) {
      if (saveStatus != "Saved") {
        _typing = false;
        saveStatus = "Saved";
        _recomputeSyncStatus();
      }
      return;
    }
    _saving = true;
    _recomputeSyncStatus();
    try {
      activeSection!.content = currentContent;
      activeSection!.updatedAt = DateTime.now();
      activeSection!.isSynced = false;
      await _storage.saveBooks(allBooks);
      _lastSavedContent = currentContent;
      _needsFirestoreSync = true;
    } finally {
      _saving = false;
      _typing = false;
      saveStatus = "Saved";
      _recomputeSyncStatus();
      // Section list previews and similar consumers should refresh after a
      // save tick (every ~3s while typing) — much less noisy than fanning
      // out on every keystroke.
      notifyListeners();
    }
  }

  /// Enqueue the active section's pending content as an outbox upsert.
  /// Returns immediately — the drainer pushes asynchronously and the
  /// connectivity listener kicks it again when the link is back.
  Future<void> _syncToFirestore() async {
    if (!_needsFirestoreSync) return;
    if (activeSection == null || activeBook == null) return;
    final content = activeSection!.content;
    final canvasData = activeSection!.canvasData;
    if (content == _lastSyncedContent && canvasData.isEmpty) {
      _needsFirestoreSync = false;
      return;
    }
    if (_userId == null) return;
    await _enqueue(PendingOp(
      kind: PendingOpKind.upsertSection,
      payload: {
        'writingId': activeBook!.id,
        'sectionId': activeSection!.id,
        'isNew': false,
        'fields': {
          'content': content,
          if (canvasData.isNotEmpty) 'canvas_data': canvasData,
        },
      },
    ));
    _lastSyncedContent = content;
    _needsFirestoreSync = false;
    // The op is durable; treat the local section as "queued" for the
    // purpose of the merge logic — actual server-acked state flips via
    // the drainer's success path (which doesn't need to write back here
    // because the merge logic on next loadBooks honours updatedAt).
    activeSection!.isSynced = false;
    await _storage.saveBooks(allBooks);
  }

  /// Called on back press / page exit. Saves local immediately, then syncs.
  void forceSaveImmediately() {
    _autoSaveTimer?.cancel();
    _stopPeriodicSync();
    // Flush any in-flight per-section autosaves first — pause / back-button
    // can fire while scrivenings is open and we don't want a 3-second
    // debounce window to swallow the user's last keystrokes.
    final session = _scrivenningsSession;
    if (session != null) {
      unawaited(session.flushAll());
    }
    if (activeSection == null || activeBook == null) return;
    final currentContent = dumpData();
    if (currentContent != _lastSavedContent ||
        !activeSection!.isSynced) {
      activeSection!.content = currentContent;
      activeSection!.updatedAt = DateTime.now();
      activeSection!.isSynced = false;
      _storage.saveBooks(allBooks);
      _lastSavedContent = currentContent;
      _needsFirestoreSync = true;
    }
    if (_needsFirestoreSync) {
      _syncToFirestore();
    }
    saveStatus = "Saved";
    _typing = false;
    _saving = false;
    _recomputeSyncStatus();
    notifyListeners();
  }

  String dumpData() {
    final clean = stripSpellCheckErrors(controller.document.toDelta());
    return jsonEncode(clean.toJson());
  }

  // ==========================================
  // SCRIVENINGS (multi-section live editing)
  // ==========================================

  /// Switch the editor into Scrivenings mode: every publishable section
  /// becomes independently editable in a continuous scroll. The single-
  /// section [controller] is stashed so we can restore it on exit, and
  /// the doc-changes listener is paused so it doesn't double-fire with
  /// the per-section listeners owned by the session.
  ///
  /// No-op if a session is already running or there is no active book.
  void enterScrivenningsMode() {
    if (_scrivenningsSession != null) return;
    if (activeBook == null) return;

    // Flush any pending single-section autosave before we hand over.
    if (_autoSaveTimer?.isActive ?? false) {
      _autoSaveTimer!.cancel();
      _saveToLocal();
    }
    _docSubscription?.cancel();
    _docSubscription = null;

    _draftControllerStash = controller;
    _draftSectionIdStash = activeSection?.id;

    _scrivenningsSession = ScrivenningsSession(
      book: activeBook!,
      onSectionPersist: _persistScrivenningsSection,
      onFocusChanged: _onScrivenningsFocusChanged,
      onTypingStateChanged: _onScrivenningsTypingChanged,
      smartSubstitutionsEnabled: () =>
          _smartPunctuationLoaded && smartPunctuationEnabled,
      typingHapticsEnabled: () => typingHapticsEnabled,
    );
    notifyListeners();
  }

  /// Exit Scrivenings mode: flush every per-section autosave, dispose
  /// per-section controllers, and restore the stashed single-section
  /// controller so Draft view picks up exactly where it left off.
  Future<void> exitScrivenningsMode() async {
    final session = _scrivenningsSession;
    if (session == null) return;
    await session.flushAll();
    await session.dispose();
    _scrivenningsSession = null;

    // Restore (or rebuild) the single-section controller. If the stashed
    // controller is still alive and points to the same section, keep it
    // — that preserves cursor / undo / scroll across the round-trip.
    final stashed = _draftControllerStash;
    final stashedId = _draftSectionIdStash;
    _draftControllerStash = null;
    _draftSectionIdStash = null;
    if (stashed != null && activeSection != null && stashedId == activeSection!.id) {
      controller = stashed;
      _lastSavedContent = dumpData();
      _lastSyncedContent = _lastSavedContent;
      _needsFirestoreSync = false;
      _docSubscription?.cancel();
      _docSubscription = controller.document.changes.listen((event) {
        if (event.source == ChangeSource.silent) return;
        _maybeSmartSubstitute(event);
        _maybeTypingHaptic(event);
        _onUserTyped();
      });
      _startPeriodicSync();
    } else {
      stashed?.dispose();
      initEditor();
    }
    notifyListeners();
  }

  /// Persist callback handed to [ScrivenningsSession]. Mirrors the
  /// single-section autosave path: write the new content into the in-
  /// memory model + local storage, then enqueue an outbox upsertSection
  /// so the drainer pushes when online.
  Future<void> _persistScrivenningsSection(
    SectionModel section,
    String contentJson,
  ) async {
    if (activeBook == null) return;
    if (section.content == contentJson) return;
    section.content = contentJson;
    section.updatedAt = DateTime.now();
    section.isSynced = false;
    await _storage.saveBooks(allBooks);
    if (_userId != null) {
      await _enqueue(PendingOp(
        kind: PendingOpKind.upsertSection,
        payload: {
          'writingId': activeBook!.id,
          'sectionId': section.id,
          'isNew': false,
          'fields': {
            'content': contentJson,
            if (section.canvasData.isNotEmpty)
              'canvas_data': section.canvasData,
          },
        },
      ));
    }
    saveStatus = 'Saved';
    notifyListeners();
  }

  /// Focus callback. Promote the focused section to `activeSection` and
  /// retarget [controller] to its per-section QuillController so
  /// `provider.controller` — read by toolbar, find/replace, floating
  /// bars, spell-check, slash menu, version history — points at the
  /// right document.
  void _onScrivenningsFocusChanged(SectionModel section) {
    final session = _scrivenningsSession;
    if (session == null) return;
    final focused = session.focusedController;
    if (focused == null) return;
    activeSection = section;
    controller = focused;
    _recomputeSyncStatus();
    notifyListeners();
  }

  void _onScrivenningsTypingChanged(bool typing) {
    if (_typing == typing) return;
    _typing = typing;
    saveStatus = typing ? 'Typing...' : 'Saved';
    _recomputeSyncStatus();
    if (!typing) notifyListeners();
  }

  /// Save canvas data for the active section and trigger sync.
  void saveCanvasData(String data) {
    if (activeSection == null || activeBook == null) return;
    activeSection!.canvasData = data;
    activeSection!.updatedAt = DateTime.now();
    activeSection!.isSynced = false;
    _needsFirestoreSync = true;
    _storage.saveBooks(allBooks);
    notifyListeners();
  }

  /// Check if a book already has a published Space on the feed.
  Future<FeedItemModel?> getExistingSpace(String bookId) {
    return _dataService.getExistingSpace(bookId);
  }

  /// Publish a cover (book) with selected sections to the public feed.
  ///
  /// `publishedSectionIds` is the author's curation set — the section
  /// IDs they ticked in the publish dialog. Backend bulk-flips
  /// `Section.is_published` to match (ids in list become True, omitted
  /// ids become False). Defaults to the IDs of `sections` so legacy
  /// callers that pass a pre-filtered list keep working.
  Future<void> publishCover(
    WritingModel book,
    List<SectionModel> sections, {
    List<String> tags = const [],
    String? descriptionOverride,
    bool isDraft = false,
    bool isPrivate = false,
    List<String>? publishedSectionIds,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception("User not logged in");

    await _dataService.publishCover(
      book,
      sections,
      user,
      tags: tags,
      descriptionOverride: descriptionOverride,
      isDraft: isDraft,
      isPrivate: isPrivate,
      publishedSectionIds: publishedSectionIds,
    );
  }

  /// Reset editor in-memory state on logout. The user's books and the
  /// outbox live in per-user Hive slots and are intentionally left on disk
  /// — both resume on next sign-in as that same user. Wiping the persisted
  /// books here would defeat the sandbox.
  void clearData() {
    _autoSaveTimer?.cancel();
    _stopPeriodicSync();
    _docSubscription?.cancel();
    _teardownWritingChannel();
    allBooks = [];
    activeBook = null;
    activeSection = null;
    allBooksSection = [];
    showSectionsList = false;
    saveStatus = "";
    _lastSavedContent = "";
    _lastSyncedContent = "";
    _needsFirestoreSync = false;
    _typing = false;
    _saving = false;
    _recomputeSyncStatus();
    controller = QuillController.basic();
    notifyListeners();
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _periodicSyncTimer?.cancel();
    _docSubscription?.cancel();
    _connectivitySub?.cancel();
    _remapSub?.cancel();
    _ackSub?.cancel();
    _writingChannelSub?.cancel();
    _outbox.pendingCount.removeListener(_onSyncCounterChanged);
    _drainer.failedCount.removeListener(_onSyncCounterChanged);
    _syncStatusNotifier.dispose();
    controller.dispose();
    super.dispose();
  }
}

/// Coarse-grained sync state used by the editor's status chip.
enum SyncStatus { idle, typing, saving, offline, syncing, error }

class _GhostFix {
  _GhostFix({required this.adoptedBookId, required this.ghostSectionIds});
  final String adoptedBookId;
  final List<String> ghostSectionIds;
}

/// One legacy → UUID rename pass for a single binder folder. Captured
/// so the post-walk code can drop dead outbox ops and queue fresh
/// upserts in one place.
class _FolderRename {
  _FolderRename({
    required this.bookId,
    required this.oldId,
    required this.newId,
    required this.movedChildIds,
  });
  final String bookId;
  final String oldId;
  final String newId;
  final List<String> movedChildIds;
}

class _EnsureFoldersResult {
  _EnsureFoldersResult({required this.changed, required this.renames});
  final bool changed;
  final List<_FolderRename> renames;
}
