import 'package:flutter/foundation.dart';
import 'package:inkspacex/services/api/api_client.dart';

/// One formatted run inside a paragraph — a contiguous span of text that
/// shares the same inline attributes (bold, font, color, etc.).
class TextRun {
  final String text;
  final Map<String, dynamic> attrs;

  const TextRun({required this.text, this.attrs = const {}});

  factory TextRun.fromJson(Map<String, dynamic> json) => TextRun(
        text: json['text'] as String? ?? '',
        attrs: Map<String, dynamic>.from((json['attrs'] as Map?) ?? const {}),
      );
}

/// One paragraph from a Delta — plain text plus block-level attrs and the
/// list of formatted runs that make up the inline content.
class DeltaParagraph {
  final String text;
  final Map<String, dynamic> blockAttrs;
  final List<TextRun> runs;

  const DeltaParagraph({
    required this.text,
    this.blockAttrs = const {},
    this.runs = const [],
  });

  factory DeltaParagraph.fromJson(Map<String, dynamic> json) => DeltaParagraph(
        text: json['text'] as String? ?? '',
        blockAttrs: Map<String, dynamic>.from(
            (json['block_attrs'] as Map?) ?? const {}),
        runs: ((json['runs'] as List?) ?? const [])
            .map((e) => TextRun.fromJson(e as Map<String, dynamic>))
            .toList(),
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

  /// Scrivener-class name generator. The constraints are sent as a
  /// natural-language paragraph the model reads, not a structured form,
  /// so the surface stays a single text endpoint. Returns one name per
  /// line, ready to drop into a list view.
  Future<List<String>> generateNames({
    String? gender,
    String? origin,
    String? era,
    String? alliteration,
    String? surname,
    int count = 5,
  }) async {
    final lines = <String>[
      'Count: $count',
      if (gender != null && gender.isNotEmpty) 'Gender: $gender',
      if (origin != null && origin.isNotEmpty) 'Origin: $origin',
      if (era != null && era.isNotEmpty) 'Era: $era',
      if (alliteration != null && alliteration.isNotEmpty)
        'Alliteration on letter: $alliteration',
      if (surname != null && surname.isNotEmpty) 'Surname constraint: $surname',
    ];
    final raw = await _textEdit('generate_names', lines.join('\n'));
    return raw
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
  }

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
