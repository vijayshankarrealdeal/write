import 'package:flutter/foundation.dart';
import 'package:inkspacex/services/api/api_client.dart';

/// Singleton service for AI text editing and canvas generation.
/// Calls the backend API which handles Azure OpenAI.
class GeminiService {
  static final GeminiService _instance = GeminiService._();
  factory GeminiService() => _instance;
  GeminiService._();

  ApiClient? _apiClient;

  void init(ApiClient apiClient) {
    _apiClient = apiClient;
  }

  bool get isConfigured => _apiClient != null;

  // ── AI Text Operations (via backend) ──

  Future<String> fixSpelling(String text) =>
      _textEdit('fix_spelling', text);

  Future<String> rewrite(String text) =>
      _textEdit('rewrite', text);

  Future<String> makeShorter(String text) =>
      _textEdit('make_shorter', text);

  Future<String> makeLonger(String text) =>
      _textEdit('make_longer', text);

  Future<String> changeTone(String text, String tone) =>
      _textEdit('change_tone', text, tone: tone);

  Future<String> continueWriting(String text) =>
      _textEdit('continue_writing', text);

  /// Generate a canvas layout via the backend.
  Future<String> generateCanvasLayout({
    required String prompt,
    String bookTitle = '',
    String sectionTitle = '',
    List<String> otherSectionTitles = const [],
    String writingPreview = '',
  }) async {
    _ensureInit();
    debugPrint('🟡 Canvas: calling backend /api/ai/canvas');

    final response = await _apiClient!.post('/api/ai/canvas', data: {
      'prompt': prompt,
      if (bookTitle.isNotEmpty) 'book_title': bookTitle,
      if (sectionTitle.isNotEmpty) 'section_title': sectionTitle,
      if (otherSectionTitles.isNotEmpty) 'other_section_titles': otherSectionTitles,
      if (writingPreview.isNotEmpty) 'writing_preview': writingPreview,
    });

    final layoutJson = response.data['layout_json'] as String;
    debugPrint('🟢 Canvas: Got ${layoutJson.length} chars response');
    return layoutJson;
  }

  // ── Internal ──

  Future<String> _textEdit(String action, String text, {String? tone}) async {
    _ensureInit();
    debugPrint('🟡 TextEdit ($action): calling backend /api/ai/text-edit');

    final response = await _apiClient!.post('/api/ai/text-edit', data: {
      'action': action,
      'text': text,
      if (tone != null) 'tone': tone,
    });

    final result = response.data['result'] as String;
    debugPrint('🟢 TextEdit ($action): Got ${result.length} chars response');
    return result;
  }

  void _ensureInit() {
    if (_apiClient == null) {
      throw StateError('GeminiService not initialized. Call init(apiClient) first.');
    }
  }
}
