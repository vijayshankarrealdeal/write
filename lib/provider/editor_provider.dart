import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:writer/models/writing_model.dart';
import 'package:writer/models/section_model.dart';
import 'package:writer/provider/auth_provider.dart';
import 'package:writer/services/firestore_service.dart';
import 'package:writer/services/storage_service.dart';

class EditorProvider extends ChangeNotifier {
  final StorageService _storage;
  final AuthProvider _auth;
  final FirestoreService _firestore = FirestoreService();

  EditorProvider(this._storage, this._auth) {
    loadBooks();
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

  Future<void> loadBooks() async {
    bookLoadingData = true;
    notifyListeners();

    final localBooks = _storage.getBooks();
    final uid = _userId;
    if (uid != null) {
      try {
        final remoteBooks = await _firestore.getWritings(uid);
        allBooks = _mergeBooks(localBooks, remoteBooks);
        await _storage.saveBooks(allBooks);
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
    final localMap = {for (final b in local) b.id: b};
    final merged = <WritingModel>[];

    for (final remoteBook in remote) {
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
            await _firestore.updateSectionContent(
              uid, book.id, section.id, section.content,
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
          content: jsonEncode([{"insert": "\n"}]),
          sectionColor: sectionColors[0],
        ),
      ],
    );
    titleController.clear();
    descriptionController.clear();

    allBooks.add(newBook);
    activeBook = newBook;
    allBooksSection = newBook.sections;

    final uid = _userId;
    if (uid != null) {
      try {
        await _firestore.createWriting(uid, newBook);
      } catch (e) {
        await _storage.saveBooks(allBooks);
        rethrow;
      }
    } else {
      await _storage.saveBooks(allBooks);
    }
    notifyListeners();
  }

  Future<void> deleteBook(WritingModel book) async {
    allBooks.remove(book);
    if (activeBook == book) {
      activeBook = null;
      allBooksSection = [];
    }

    final uid = _userId;
    if (uid != null) {
      try {
        await _firestore.deleteWriting(uid, book.id);
      } catch (e) {
        await _storage.saveBooks(allBooks);
        rethrow;
      }
    } else {
      await _storage.saveBooks(allBooks);
    }
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
        await _firestore.updateWritingMetadata(uid, book.id, title: newTitle);
      } catch (e) {
        await _storage.saveBooks(allBooks);
        rethrow;
      }
    } else {
      await _storage.saveBooks(allBooks);
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
      content: jsonEncode([{"insert": "\n"}]),
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
        await _firestore.addSection(uid, activeBook!.id, section);
      } catch (e) {
        await _storage.saveBooks(allBooks);
      }
    } else {
      await _storage.saveBooks(allBooks);
    }
    notifyListeners();
  }

  void addSectionToActiveBook(String title) {
    addSection(title, autoSelect: false);
  }

  Future<void> renameSection(SectionModel section, String newTitle) async {
    section.title = newTitle;

    final uid = _userId;
    if (uid != null && activeBook != null) {
      try {
        await _firestore.renameSection(uid, activeBook!.id, section.id, newTitle);
      } catch (e) {
        await _storage.saveBooks(allBooks);
      }
    } else {
      await _storage.saveBooks(allBooks);
    }
    notifyListeners();
  }

  Future<void> deleteSection(SectionModel section) async {
    if (activeBook == null) return;
    activeBook!.sections.removeWhere((c) => c.id == section.id);
    allBooksSection = activeBook!.sections;
    if (activeSection?.id == section.id) {
      activeSection = null;
    }

    final uid = _userId;
    if (uid != null) {
      try {
        await _firestore.deleteSection(uid, activeBook!.id, section.id);
      } catch (e) {
        await _storage.saveBooks(allBooks);
      }
    } else {
      await _storage.saveBooks(allBooks);
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
    if (content == _lastSyncedContent) {
      _needsFirestoreSync = false;
      return;
    }
    final uid = _userId;
    if (uid == null) return;
    try {
      await _firestore.updateSectionContent(
        uid,
        activeBook!.id,
        activeSection!.id,
        content,
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
    if (currentContent != _lastSavedContent) {
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
    controller.dispose();
    super.dispose();
  }
}
