import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/models/image_meta.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/services/analytics_service.dart';
import 'package:inkspacex/services/api/api_data_service.dart';
import 'package:inkspacex/services/api/api_storage_service.dart';
import 'package:inkspacex/services/connectivity_service.dart';
import 'package:inkspacex/services/spell_check_decoration.dart';
import 'package:inkspacex/services/storage_service.dart';
import 'package:inkspacex/services/sync/merge_log.dart';
import 'package:inkspacex/services/sync/outbox.dart';
import 'package:inkspacex/services/sync/outbox_drainer.dart';
import 'package:inkspacex/services/sync/pending_op.dart';

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
  WritingType type = WritingType.personal;
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
        _syncUnsyncedSections(uid);
      } catch (e) {
        allBooks = localBooks;
      }
    } else {
      allBooks = localBooks;
    }

    if (allBooks.isNotEmpty && activeBook == null) {
      setActiveBook(allBooks.first);
    }
    bookLoadingData = false;
    notifyListeners();
  }

  /// Merge local and remote books. For each section present in both,
  /// keep whichever has the later updatedAt timestamp.
  List<WritingModel> _mergeBooks(
    List<WritingModel> local,
    List<WritingModel> remote,
  ) {
    // Detect "ghost" duplicates produced by an old createWriting bug:
    // a local book kept its client-generated timestamp ID instead of the
    // server's UUID, so subsequent fetches saw the same book under both
    // IDs. Pair each legacy local book with a same-title remote book that
    // only contains untouched default sections, then promote the local
    // book to the server's UUID so it dedupes by ID from now on.
    final remoteByTitle = <String, List<WritingModel>>{};
    for (final r in remote) {
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
        remote.where((r) => !claimedRemoteIds.contains(r.id)).toList();

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
    List<SectionModel> remote,
  ) {
    return mergeSectionsLww(local, remote, onMergeDecision: _maybeRecordMerge);
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
    // Preserve fields the remote doesn't carry (canvas data, color).
    final merged = SectionModel(
      id: remote.id,
      title: remote.title,
      content: remote.content,
      canvasData: remote.canvasData.isEmpty ? local.canvasData : remote.canvasData,
      sectionColor: remote.sectionColor,
      isSynced: true,
      createdAt: local.createdAt,
      updatedAt: remote.updatedAt,
    );
    book.sections[idx] = merged;
    allBooksSection = book.sections;
    if (isActive) {
      activeSection = merged;
      initEditor();
    }
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
    if (activeSection?.id == id) {
      if (book.sections.isNotEmpty) {
        activeSection = book.sections.first;
        initEditor();
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
    );
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
    final newBook = WritingModel(
      author: _auth.currentUser?.name ?? "Unknown Author",
      coverImagePath: "",
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: titleController.text,
      description: descriptionController.text,
      writingType: type,
      subtype: subtype,
      sections: [
        SectionModel(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          title: "Untitled Section",
          content: jsonEncode([
            {"insert": "\n"},
          ]),
          sectionColor: sectionColors[0],
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
            },
          },
        ));
      }
    }
    notifyListeners();
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

  void addSection(String title, {bool autoSelect = true}) {
    if (activeBook == null) return;
    final newSection = SectionModel(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: title,
      content: jsonEncode([
        {"insert": "\n"},
      ]),
      sectionColor:
          sectionColors[activeBook!.sections.length % sectionColors.length],
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
          },
        },
      ));
    }
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

  Future<void> deleteSection(SectionModel section) async {
    if (activeBook == null) return;
    final writingId = activeBook!.id;
    activeBook!.sections.removeWhere((c) => c.id == section.id);
    allBooksSection = activeBook!.sections;

    if (activeSection?.id == section.id) {
      if (allBooksSection.isNotEmpty) {
        activeSection = allBooksSection.first;
        initEditor();
      } else {
        activeSection = null;
        controller = QuillController.basic();
      }
    }

    await _storage.saveBooks(allBooks);
    if (_userId != null) {
      await _enqueue(PendingOp(
        kind: PendingOpKind.deleteSection,
        payload: {'writingId': writingId, 'sectionId': section.id},
      ));
    }
    notifyListeners();
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
    activeSection!.content = currentContent;
    activeSection!.updatedAt = DateTime.now();
    activeSection!.isSynced = false;
    await _storage.saveBooks(allBooks);
    _lastSavedContent = currentContent;
    _needsFirestoreSync = true;
    _saving = false;
    _typing = false;
    saveStatus = "Saved";
    _recomputeSyncStatus();
    // Section list previews and similar consumers should refresh after a
    // save tick (every ~3s while typing) — much less noisy than fanning
    // out on every keystroke.
    notifyListeners();
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
  Future<void> publishCover(
    WritingModel book,
    List<SectionModel> sections, {
    List<String> tags = const [],
    String? descriptionOverride,
    bool isDraft = false,
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
