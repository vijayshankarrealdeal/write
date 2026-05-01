import 'package:flutter/foundation.dart';
import 'package:inkspacex/services/api/api_client.dart';

/// One paragraph from a Delta — text plus block/inline formatting.
class DeltaParagraph {
  final String text;
  final Map<String, dynamic> blockAttrs;
  final Map<String, dynamic> inlineAttrs;

  const DeltaParagraph({
    required this.text,
    this.blockAttrs = const {},
    this.inlineAttrs = const {},
  });

  factory DeltaParagraph.fromJson(Map<String, dynamic> json) => DeltaParagraph(
        text: json['text'] as String? ?? '',
        blockAttrs: Map<String, dynamic>.from(
            (json['block_attrs'] as Map?) ?? const {}),
        inlineAttrs: Map<String, dynamic>.from(
            (json['inline_attrs'] as Map?) ?? const {}),
      );
}

/// Result of a delta-aware AI edit: original and rewritten paragraphs,
/// already aligned by index.
class DeltaEditResult {
  final List<DeltaParagraph> original;
  final List<DeltaParagraph> edited;

  const DeltaEditResult({required this.original, required this.edited});

  factory DeltaEditResult.fromJson(Map<String, dynamic> json) => DeltaEditResult(
        original: ((json['original_paragraphs'] as List?) ?? const [])
            .map((e) => DeltaParagraph.fromJson(e as Map<String, dynamic>))
            .toList(),
        edited: ((json['edited_paragraphs'] as List?) ?? const [])
            .map((e) => DeltaParagraph.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

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

  /// Delta-aware text edit. Sends the document's Delta to the backend, which
  /// extracts text, runs the action, and re-projects formatting paragraph-by-
  /// paragraph. Returns both sides so the UI can render a per-paragraph diff
  /// and let the user accept/decline each one.
  Future<DeltaEditResult> textEditDelta(
    String action,
    List<dynamic> deltaOps, {
    String? tone,
  }) async {
    _ensureInit();
    debugPrint('🟡 TextEditDelta ($action): calling /api/ai/text-edit-delta');
    final response = await _apiClient!.post('/api/ai/text-edit-delta', data: {
      'action': action,
      'delta': deltaOps,
      if (tone != null) 'tone': tone,
    });
    final data = response.data as Map<String, dynamic>;
    return DeltaEditResult.fromJson(data);
  }

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
