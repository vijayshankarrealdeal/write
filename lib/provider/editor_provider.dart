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
  StreamSubscription? _docSubscription;
  String saveStatus = "";

  Future<void> loadBooks() async {
    bookLoadingData = true;
    notifyListeners();

    final uid = _userId;
    if (uid != null) {
      try {
        allBooks = await _firestore.getWritings(uid);
        await _storage.saveBooks(allBooks);
      } catch (e) {
        allBooks = _storage.getBooks();
      }
    } else {
      allBooks = _storage.getBooks();
    }

    // Auto-select first project when we have books but none selected
    if (allBooks.isNotEmpty && activeBook == null) {
      setActiveBook(allBooks.first);
    }
    bookLoadingData = false;
    notifyListeners();
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

    _docSubscription?.cancel();
    _docSubscription = controller.document.changes.listen((event) {
      _onUserTyped();
    });
  }

  void _onUserTyped() {
    if (saveStatus != "Typing...") {
      saveStatus = "Typing...";
      notifyListeners();
    }
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(milliseconds: 1000), () {
      _performAutoSave();
    });
  }

  Future<void> _performAutoSave() async {
    if (activeSection == null || activeBook == null) return;
    saveStatus = "Saving...";
    notifyListeners();
    activeSection!.content = dumpData();

    try {
      final uid = _userId;
      if (uid != null) {
        await _firestore.updateSectionContent(
          uid,
          activeBook!.id,
          activeSection!.id,
          activeSection!.content,
        );
      } else {
        await _storage.saveBooks(allBooks);
      }
    } catch (e) {
      await _storage.saveBooks(allBooks);
    }
    saveStatus = "Saved";
    notifyListeners();
  }

  void forceSaveImmediately() {
    _autoSaveTimer?.cancel();
    if (saveStatus == "Typing..." || saveStatus == "Saving...") {
      _performAutoSave();
    }
  }

  String dumpData() {
    final deltaJson = controller.document.toDelta().toJson();
    return jsonEncode(deltaJson);
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _docSubscription?.cancel();
    controller.dispose();
    super.dispose();
  }
}
