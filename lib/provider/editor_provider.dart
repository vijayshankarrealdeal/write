import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/services/api/api_data_service.dart';
import 'package:inkspacex/services/api/api_storage_service.dart';
import 'package:inkspacex/services/connectivity_service.dart';
import 'package:inkspacex/services/storage_service.dart';

class EditorProvider extends ChangeNotifier {
  final StorageService _storage;
  final AuthProvider _auth;
  final ConnectivityService _connectivity;
  ApiDataService get _dataService => _auth.dataService;
  ApiStorageService get _storageService => _auth.storageService;

  EditorProvider(this._storage, this._auth, this._connectivity) {
    loadBooks();
    _connectivitySub = _connectivity.onChange.listen((online) {
      if (online && _needsFirestoreSync) {
        _syncToFirestore();
      }
    });
  }

  StreamSubscription<bool>? _connectivitySub;

  bool get _isOnline => _connectivity.isOnlineNow;

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
    final localMap = {for (final s in local) s.id: s};
    final merged = <SectionModel>[];

    for (final remoteSection in remote) {
      final localSection = localMap.remove(remoteSection.id);
      if (localSection == null) {
        merged.add(remoteSection);
        continue;
      }
      // Keep whichever was updated more recently
      if (localSection.updatedAt.isAfter(remoteSection.updatedAt) &&
          !localSection.isSynced) {
        merged.add(localSection);
      } else {
        merged.add(remoteSection);
      }
    }
    // Local-only sections (created offline)
    merged.addAll(localMap.values);
    return merged;
  }

  /// Push any unsynced local sections to Firestore in background.
  void _syncUnsyncedSections(String uid) async {
    for (final book in allBooks) {
      for (final section in book.sections) {
        if (!section.isSynced) {
          try {
            await _dataService.updateSectionContent(
              uid,
              book.id,
              section.id,
              section.content,
              canvasData: section.canvasData,
            );
            section.isSynced = true;
          } catch (_) {
            // Will retry next load
          }
        }
      }
    }
    await _storage.saveBooks(allBooks);
  }

  void setActiveBook(WritingModel book) {
    activeBook = book;
    allBooksSection = book.sections;
    notifyListeners();
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

    final uid = _userId;
    if (uid != null) {
      try {
        await _dataService.createWriting(uid, newBook);
      } catch (e) {
        await _storage.saveBooks(allBooks);
        rethrow;
      }
    }
    await _storage.saveBooks(allBooks);
    notifyListeners();
  }

  Future<String> updateBookCoverImage(WritingModel book, Uint8List bytes) async {
    final uid = _userId;
    if (uid == null) throw Exception("User not logged in");
    final url = await _storageService.uploadCoverImage(uid, book.id, bytes);
    book.coverImagePath = url;
    await _storage.saveBooks(allBooks);
    final writeUid = _userId;
    if (writeUid != null) {
      await _dataService.updateWritingMetadata(writeUid, book.id, coverImagePath: url);
    }
    notifyListeners();
    return url;
  }

  Future<void> deleteBook(WritingModel book) async {
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

    final uid = _userId;
    if (uid != null) {
      try {
        await _dataService.deleteWriting(uid, book.id);
      } catch (e) {
        await _storage.saveBooks(allBooks);
        rethrow;
      }
    }
    await _storage.saveBooks(allBooks);
    notifyListeners();
  }

  Future<void> renameBook(String newTitle) async {
    if (activeBook == null) return;
    await renameBookById(activeBook!, newTitle);
  }

  Future<void> renameBookById(WritingModel book, String newTitle) async {
    book.title = newTitle;

    final uid = _userId;
    if (uid != null) {
      try {
        await _dataService.updateWritingMetadata(uid, book.id, title: newTitle);
      } catch (e) {
        await _storage.saveBooks(allBooks);
        rethrow;
      }
    }
    await _storage.saveBooks(allBooks);
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
    final uid = _userId;
    if (uid != null && activeBook != null) {
      try {
        await _dataService.addSection(uid, activeBook!.id, section);
      } catch (_) {}
    }
    await _storage.saveBooks(allBooks);
  }

  void addSectionToActiveBook(String title) {
    addSection(title, autoSelect: false);
  }

  Future<void> renameSection(SectionModel section, String newTitle) async {
    section.title = newTitle;

    final uid = _userId;
    if (uid != null && activeBook != null) {
      try {
        await _dataService.renameSection(
          uid,
          activeBook!.id,
          section.id,
          newTitle,
        );
      } catch (_) {}
    }
    await _storage.saveBooks(allBooks);
    notifyListeners();
  }

  Future<void> deleteSection(SectionModel section) async {
    if (activeBook == null) return;
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

    final uid = _userId;
    if (uid != null) {
      try {
        await _dataService.deleteSection(uid, activeBook!.id, section.id);
      } catch (_) {}
    }
    await _storage.saveBooks(allBooks);
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
    if (saveStatus != "Typing...") {
      saveStatus = "Typing...";
      notifyListeners();
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
        saveStatus = "Saved";
        notifyListeners();
      }
      return;
    }
    activeSection!.content = currentContent;
    activeSection!.updatedAt = DateTime.now();
    activeSection!.isSynced = false;
    await _storage.saveBooks(allBooks);
    _lastSavedContent = currentContent;
    _needsFirestoreSync = true;
    saveStatus = "Saved";
    notifyListeners();
  }

  /// Sync to Firestore in background. Skips if nothing changed since last sync.
  Future<void> _syncToFirestore() async {
    if (!_needsFirestoreSync) return;
    if (activeSection == null || activeBook == null) return;
    final content = activeSection!.content;
    final canvasData = activeSection!.canvasData;
    if (content == _lastSyncedContent && canvasData.isEmpty) {
      _needsFirestoreSync = false;
      return;
    }
    final uid = _userId;
    if (uid == null) return;
    // Offline: leave _needsFirestoreSync set so the connectivity listener
    // (and the next periodic tick) retries when the link returns.
    if (!_isOnline) return;
    try {
      await _dataService.updateSectionContent(
        uid,
        activeBook!.id,
        activeSection!.id,
        content,
        canvasData: canvasData,
      );
      _lastSyncedContent = content;
      activeSection!.isSynced = true;
      _needsFirestoreSync = false;
      await _storage.saveBooks(allBooks);
    } catch (_) {
      // Will retry on next periodic tick or on exit
    }
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
    notifyListeners();
  }

  String dumpData() {
    final deltaJson = controller.document.toDelta().toJson();
    return jsonEncode(deltaJson);
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

  /// Reset all editor state on logout so stale data doesn't linger.
  void clearData() {
    _autoSaveTimer?.cancel();
    _stopPeriodicSync();
    _docSubscription?.cancel();
    allBooks = [];
    activeBook = null;
    activeSection = null;
    allBooksSection = [];
    showSectionsList = false;
    saveStatus = "";
    _lastSavedContent = "";
    _lastSyncedContent = "";
    _needsFirestoreSync = false;
    controller = QuillController.basic();
    _storage.clearBooks();
    notifyListeners();
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _periodicSyncTimer?.cancel();
    _docSubscription?.cancel();
    _connectivitySub?.cancel();
    controller.dispose();
    super.dispose();
  }
}

class _GhostFix {
  _GhostFix({required this.adoptedBookId, required this.ghostSectionIds});
  final String adoptedBookId;
  final List<String> ghostSectionIds;
}
