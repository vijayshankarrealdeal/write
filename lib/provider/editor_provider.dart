import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

class EditorProvider extends ChangeNotifier {
  EditorProvider() {
    load();
  }

  // Start with loading as true
  bool loadingData = true;

  late QuillController controller;

  void load() async {
    loadingData = true;

    try {
      String jsonString = '';

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
      print("Error loading document: $e");
      controller = QuillController.basic();
    }

    loadingData = false;
    notifyListeners();
  }

  void dumpData() {
    final deltaJson = controller.document.toDelta().toJson();
    final stringified = jsonEncode(deltaJson);
    print(stringified);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }
}
