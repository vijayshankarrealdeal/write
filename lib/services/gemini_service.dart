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
  // Sharpen — craft moves that return replacement text
  Future<String> tighten(String text) => _textEdit('tighten', text);
  Future<String> sharpenOpening(String text) =>
      _textEdit('sharpen_opening', text);
  Future<String> liftThesis(String text) => _textEdit('lift_thesis', text);
  Future<String> cutThroatClearing(String text) =>
      _textEdit('cut_throat_clearing', text);
  Future<String> continueWriting(String text) =>
      _textEdit('continue_writing', text);

  // Reframe — aim the same piece at a different reader
  Future<String> forBeginner(String text) => _textEdit('for_beginner', text);
  Future<String> forExpert(String text) => _textEdit('for_expert', text);
  Future<String> addExample(String text) => _textEdit('add_example', text);
  Future<String> steelMan(String text) => _textEdit('steel_man', text);

  // Feedback — read-only advice (caller should not apply as a replacement)
  Future<String> critique(String text) => _textEdit('critique', text);
  Future<String> whatsMissing(String text) =>
      _textEdit('whats_missing', text);
  Future<String> threeOpenings(String text) =>
      _textEdit('three_openings', text);

  // Legacy — kept for any non-panel caller that still uses it.
  Future<String> fixSpelling(String text) => _textEdit('fix_spelling', text);

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
