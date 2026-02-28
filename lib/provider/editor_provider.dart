import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:writer/models/writing_model.dart';
import 'package:writer/models/section_model.dart';

// Your existing classes

class EditorProvider extends ChangeNotifier {
  EditorProvider() {
    loadBooks();
  }

  List<WritingModel> allBooks = [];
  List<SectionModel> allBooksSection = [];

  WritingModel? activeBook; // <--- ADDED: Track the active book
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
    Colors.red,
    Colors.blue,
    Colors.green,
    Colors.orange,
    Colors.purple,
    Colors.teal,
    Colors.amber,
    Colors.cyanAccent,
  ];

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

  void loadBooks() async {
    bookLoadingData = true;
    allBooks = [];
    await Future.delayed(const Duration(milliseconds: 400));
    bookLoadingData = false;
    notifyListeners();
  }

  void setActiveBook(WritingModel book) {
    activeBook = book;
    allBooksSection = book.sections;
    notifyListeners();
  }

  void addNewBook() {
    if (titleController.text.trim().isEmpty) {
      throw Exception("Title cannot be empty");
    }
    if (subtype.trim().isEmpty) throw Exception("Please select a subtype");
    final newBook = WritingModel(
      author: "Unknown Author",
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
          content: "",
          sectionColor: sectionColors[0],
        ),
      ],
    );
    titleController.clear();
    descriptionController.clear();

    allBooks.add(newBook);
    allBooks = allBooks..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    activeBook = newBook;
    allBooksSection = newBook.sections;
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
  }

  String getPreviewText(String content) {
    if (content.trim().isEmpty) return "";
    try {
      // Try to parse the delta JSON
      var myJSON = jsonDecode(content);
      var doc = Document.fromJson(myJSON);
      String plainText = doc.toPlainText().replaceAll('\n', ' ').trim();
      return plainText.isEmpty ? "" : plainText;
    } catch (e) {
      // If it fails (e.g. it's already plain text), return it directly
      return content.replaceAll('\n', ' ').trim();
    }
  }

  void renameBook(String newTitle) {
    if (activeBook != null) {
      activeBook!.title = newTitle;
      notifyListeners();
    }
  }

  void deleteActiveBook() {
    if (activeBook != null) {
      allBooks.removeWhere((b) => b.id == activeBook!.id);
      activeBook = null;
      allBooksSection = [];
      notifyListeners();
    }
  }

  void addSection(String title) {
    if (activeBook != null) {
      final newSection = SectionModel(
        id: DateTime.now().millisecondsSinceEpoch.toString(), // Unique ID
        title: title,
        content: "",
        sectionColor:
            sectionColors[activeBook!.sections.length %
                sectionColors.length], // Cycle colors
      );
      activeBook!.sections.add(newSection);
      allBooksSection = activeBook!.sections;
      notifyListeners();
    }
  }

  void deleteBook(WritingModel book) {
    allBooks.removeWhere((b) => b.id == book.id);
    // If we deleted the currently selected book, clear the section list
    if (activeBook?.id == book.id) {
      activeBook = null;
      allBooksSection = [];
    }
    notifyListeners();
  }

  // --- section OPERATIONS ---
  void addSectionToActiveBook(String title) {
    if (activeBook != null) {
      final newSection = SectionModel(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        title: title,
        content: "",
        sectionColor:
            sectionColors[activeBook!.sections.length %
                sectionColors.length], // Cycle colors
      );
      activeBook!.sections.add(newSection);
      allBooksSection = activeBook!.sections;
      notifyListeners();
    }
  }

  void renameSection(SectionModel section, String newTitle) {
    section.title = newTitle;
    notifyListeners();
  }

  void deleteSection(SectionModel section) {
    if (activeBook != null) {
      activeBook!.sections.removeWhere((c) => c.id == section.id);
      allBooksSection = activeBook!.sections;
      notifyListeners();
    }
  }

  // ==========================================
  // ORIGINAL EDITOR LOGIC
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
    notifyListeners();
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

  void _performAutoSave() {
    if (activeSection == null) return;
    saveStatus = "Saving...";
    notifyListeners();
    activeSection!.content = dumpData();
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
    final stringified = jsonEncode(deltaJson);
    return stringified;
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _docSubscription?.cancel();
    controller.dispose();
    super.dispose();
  }
}
