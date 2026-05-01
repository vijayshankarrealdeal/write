import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:inkspacex/services/gemini_service.dart';
import 'package:inkspacex/ui/widgets/app_spinner.dart';

// ─── Word-level diff ───

enum _DiffType { equal, added, removed }

class _DiffSpan {
  final _DiffType type;
  final String text;
  const _DiffSpan(this.type, this.text);
}

/// Myers-style word diff via LCS, then collapse runs by type.
List<_DiffSpan> _computeWordDiff(String oldText, String newText) {
  final oldWords = _tokenize(oldText);
  final newWords = _tokenize(newText);

  final m = oldWords.length;
  final n = newWords.length;
  final dp = List.generate(m + 1, (_) => List.filled(n + 1, 0));
  for (int i = 1; i <= m; i++) {
    for (int j = 1; j <= n; j++) {
      if (oldWords[i - 1] == newWords[j - 1]) {
        dp[i][j] = dp[i - 1][j - 1] + 1;
      } else {
        dp[i][j] = math.max(dp[i - 1][j], dp[i][j - 1]);
      }
    }
  }

  final spans = <_DiffSpan>[];
  int i = m, j = n;
  final temp = <_DiffSpan>[];
  while (i > 0 || j > 0) {
    if (i > 0 && j > 0 && oldWords[i - 1] == newWords[j - 1]) {
      temp.add(_DiffSpan(_DiffType.equal, oldWords[i - 1]));
      i--;
      j--;
    } else if (j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j])) {
      temp.add(_DiffSpan(_DiffType.added, newWords[j - 1]));
      j--;
    } else {
      temp.add(_DiffSpan(_DiffType.removed, oldWords[i - 1]));
      i--;
    }
  }

  for (final s in temp.reversed) {
    if (spans.isNotEmpty && spans.last.type == s.type) {
      spans[spans.length - 1] =
          _DiffSpan(s.type, '${spans.last.text}${s.text}');
    } else {
      spans.add(s);
    }
  }
  return spans;
}

List<String> _tokenize(String text) {
  final tokens = <String>[];
  final re = RegExp(r'\S+\s*|\s+');
  for (final m in re.allMatches(text)) {
    tokens.add(m.group(0)!);
  }
  return tokens;
}

// ─── Block label helpers ───

String? _blockLabel(Map<String, dynamic> blockAttrs) {
  if (blockAttrs.containsKey('header')) {
    final v = blockAttrs['header'];
    if (v is int) return 'H$v';
  }
  if (blockAttrs['blockquote'] == true) return 'Quote';
  if (blockAttrs['code-block'] == true) return 'Code';
  final list = blockAttrs['list'];
  if (list == 'ordered') return '1. List';
  if (list == 'bullet') return '• List';
  if (list == 'checked' || list == 'unchecked') return '☐ List';
  return null;
}

Color? _parseColor(dynamic v) {
  if (v is! String) return null;
  var s = v.trim();
  if (s.startsWith('#')) s = s.substring(1);
  if (s.length == 6) s = 'FF$s';
  if (s.length != 8) return null;
  final n = int.tryParse(s, radix: 16);
  return n == null ? null : Color(n);
}

/// Pick the attrs of the longest run in a paragraph. Used purely for the
/// visual baseline of the diff card — the merged Delta we apply uses each
/// run's exact attrs, so this is just a display approximation.
Map<String, dynamic> _longestRunAttrs(List<TextRun> runs) {
  if (runs.isEmpty) return const {};
  var best = runs.first;
  for (final r in runs) {
    if (r.text.length > best.text.length) best = r;
  }
  return best.attrs;
}

TextStyle _inlineStyleOf(
    Map<String, dynamic> attrs, TextStyle base) {
  var style = base;
  if (attrs['bold'] == true) style = style.copyWith(fontWeight: FontWeight.w700);
  if (attrs['italic'] == true) style = style.copyWith(fontStyle: FontStyle.italic);
  final decos = <TextDecoration>[];
  if (attrs['underline'] == true) decos.add(TextDecoration.underline);
  if (attrs['strike'] == true) decos.add(TextDecoration.lineThrough);
  if (decos.isNotEmpty) {
    style = style.copyWith(decoration: TextDecoration.combine(decos));
  }
  final color = _parseColor(attrs['color']);
  if (color != null) style = style.copyWith(color: color);
  final bg = _parseColor(attrs['background']);
  if (bg != null) style = style.copyWith(backgroundColor: bg);
  return style;
}

// ─── AI Assist actions ───

enum AIActionKind { transform, feedback }

/// One AI action the user can pick from the bottom-sheet picker. The
/// resulting action is then handed off to [AIAssistPanel] which renders the
/// loading + diff (or feedback) over the editor.
class AIAction {
  final String label;
  final IconData? icon;
  final AIActionKind kind;
  /// For transforms, the backend action key (e.g. `'tighten'`). For feedback,
  /// the dispatch key consumed by [AIAssistPanel] (`'critique'`, etc.).
  final String id;
  const AIAction({
    required this.label,
    required this.icon,
    required this.kind,
    required this.id,
  });
}

const List<MapEntry<String, List<AIAction>>> _aiActionGroups = [
  MapEntry('SHARPEN', [
    AIAction(
        label: 'Tighten',
        icon: CupertinoIcons.bolt,
        kind: AIActionKind.transform,
        id: 'tighten'),
    AIAction(
        label: 'Sharpen opening',
        icon: CupertinoIcons.text_alignleft,
        kind: AIActionKind.transform,
        id: 'sharpen_opening'),
    AIAction(
        label: 'Lift the thesis',
        icon: CupertinoIcons.arrow_up_circle,
        kind: AIActionKind.transform,
        id: 'lift_thesis'),
    AIAction(
        label: 'Cut throat-clearing',
        icon: CupertinoIcons.scissors,
        kind: AIActionKind.transform,
        id: 'cut_throat_clearing'),
    AIAction(
        label: 'Pick up where I left off',
        icon: CupertinoIcons.arrow_right_circle,
        kind: AIActionKind.transform,
        id: 'continue_writing'),
  ]),
  MapEntry('REFRAME', [
    AIAction(
        label: 'For a beginner',
        icon: null,
        kind: AIActionKind.transform,
        id: 'for_beginner'),
    AIAction(
        label: 'For an expert',
        icon: null,
        kind: AIActionKind.transform,
        id: 'for_expert'),
    AIAction(
        label: 'Add an example',
        icon: null,
        kind: AIActionKind.transform,
        id: 'add_example'),
    AIAction(
        label: 'Steel-man the other side',
        icon: null,
        kind: AIActionKind.transform,
        id: 'steel_man'),
  ]),
  MapEntry('FEEDBACK', [
    AIAction(
        label: 'Critique honestly',
        icon: CupertinoIcons.chat_bubble_text,
        kind: AIActionKind.feedback,
        id: 'critique'),
    AIAction(
        label: "What's missing?",
        icon: CupertinoIcons.question_circle,
        kind: AIActionKind.feedback,
        id: 'whats_missing'),
    AIAction(
        label: 'Three new openings',
        icon: CupertinoIcons.list_number,
        kind: AIActionKind.feedback,
        id: 'three_openings'),
  ]),
];

// ─── AI Action Picker (bottom sheet) ───

/// Compact picker shown in a modal bottom sheet. When the user taps a chip
/// it pops the route with the selected [AIAction]; the editor then opens the
/// inline [AIAssistPanel] overlay to actually run it.
class AIActionPicker extends StatelessWidget {
  final bool hasSelection;
  final bool isDark;
  final Color textColor;
  final Color mutedColor;
  final Color surfaceColor;
  final Color backgroundColor;

  const AIActionPicker({
    super.key,
    required this.hasSelection,
    required this.isDark,
    required this.textColor,
    required this.mutedColor,
    required this.surfaceColor,
    required this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final accentColor =
        isDark ? const Color(0xFF93B4F5) : const Color(0xFF5B8DEF);

    return Container(
      color: backgroundColor,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(CupertinoIcons.wand_stars,
                    size: 20, color: accentColor),
                const SizedBox(width: 10),
                Text(
                  'AI Assist',
                  style: GoogleFonts.inter(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: textColor,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: textColor.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(CupertinoIcons.xmark,
                        size: 14, color: mutedColor),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              hasSelection
                  ? 'Working with selected text'
                  : 'Working with full document',
              style: GoogleFonts.inter(fontSize: 12, color: mutedColor),
            ),
            const SizedBox(height: 16),
            for (var i = 0; i < _aiActionGroups.length; i++) ...[
              if (i > 0) const SizedBox(height: 14),
              Text(
                _aiActionGroups[i].key,
                style: GoogleFonts.inter(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: mutedColor,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final action in _aiActionGroups[i].value)
                    _PickerChip(
                      action: action,
                      isDark: isDark,
                      textColor: textColor,
                      mutedColor: mutedColor,
                      surfaceColor: surfaceColor,
                      onTap: () => Navigator.of(context).pop(action),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PickerChip extends StatelessWidget {
  final AIAction action;
  final bool isDark;
  final Color textColor;
  final Color mutedColor;
  final Color surfaceColor;
  final VoidCallback onTap;

  const _PickerChip({
    required this.action,
    required this.isDark,
    required this.textColor,
    required this.mutedColor,
    required this.surfaceColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: surfaceColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.black.withValues(alpha: 0.06),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (action.icon != null) ...[
              Icon(action.icon, size: 14, color: mutedColor),
              const SizedBox(width: 7),
            ],
            Text(
              action.label,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: textColor.withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── AI Assist Panel (inline) ───

enum _AIMode { transform, feedback }

/// Pair of original + edited paragraph at the same index. Either side may
/// be null when the AI added or removed a paragraph relative to the source.
class _Pair {
  final DeltaParagraph? original;
  final DeltaParagraph? edited;
  const _Pair(this.original, this.edited);
}

class AIAssistPanel extends StatefulWidget {
  final GeminiService gemini;

  /// The action the user picked from [AIActionPicker]. The panel runs this on
  /// mount; chip selection lives in the picker, not here.
  final AIAction action;

  /// Quill Delta ops representing the editable scope (full doc or selection).
  /// Sent verbatim to the backend; the backend handles text extraction.
  final List<dynamic> sourceDelta;

  /// Plain-text fallback used by the feedback actions (critique, etc.) since
  /// they're advice-only and don't go through the delta endpoint.
  final String plainText;

  final bool hasSelection;
  final bool isDark;
  final Color textColor;
  final Color mutedColor;
  final Color surfaceColor;

  /// Background of the panel itself (matches the editor card's paper color).
  final Color backgroundColor;

  /// Called with the merged Delta ops the caller should apply to the document.
  final ValueChanged<List<dynamic>> onApply;

  /// Called when the user dismisses the panel (Decline / close / Try another).
  final VoidCallback onClose;

  const AIAssistPanel({
    super.key,
    required this.gemini,
    required this.action,
    required this.sourceDelta,
    required this.plainText,
    required this.hasSelection,
    required this.isDark,
    required this.textColor,
    required this.mutedColor,
    required this.surfaceColor,
    required this.backgroundColor,
    required this.onApply,
    required this.onClose,
  });

  @override
  State<AIAssistPanel> createState() => _AIAssistPanelState();
}

class _AIAssistPanelState extends State<AIAssistPanel> {
  bool _loading = false;
  String? _error;
  late _AIMode _mode = widget.action.kind == AIActionKind.transform
      ? _AIMode.transform
      : _AIMode.feedback;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _runAction();
    });
  }

  void _runAction() {
    final a = widget.action;
    if (a.kind == AIActionKind.transform) {
      _runTransform(a.id);
    } else {
      _runFeedback(a.id);
    }
  }

  // Transform results
  DeltaEditResult? _editResult;
  List<_Pair> _pairs = const [];
  // Per-pair toggle: true = use edited, false = keep original.
  List<bool> _accept = const [];

  // Feedback (advice) result
  String? _feedbackText;

  Future<void> _runTransform(String actionId) async {
    setState(() {
      _loading = true;
      _error = null;
      _editResult = null;
      _pairs = const [];
      _accept = const [];
      _feedbackText = null;
      _mode = _AIMode.transform;
    });
    try {
      final result =
          await widget.gemini.textEditDelta(actionId, widget.sourceDelta);
      if (!mounted) return;
      final pairs = _buildPairs(result);
      setState(() {
        _editResult = result;
        _pairs = pairs;
        _accept = List<bool>.filled(pairs.length, true);
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _runFeedback(String actionId) async {
    setState(() {
      _loading = true;
      _error = null;
      _editResult = null;
      _feedbackText = null;
      _mode = _AIMode.feedback;
    });
    try {
      final g = widget.gemini;
      final Future<String> task;
      switch (actionId) {
        case 'critique':
          task = g.critique(widget.plainText);
          break;
        case 'whats_missing':
          task = g.whatsMissing(widget.plainText);
          break;
        case 'three_openings':
          task = g.threeOpenings(widget.plainText);
          break;
        default:
          throw StateError('Unknown feedback action: $actionId');
      }
      final result = await task;
      if (mounted) setState(() => _feedbackText = result);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<_Pair> _buildPairs(DeltaEditResult r) {
    final n = math.max(r.original.length, r.edited.length);
    return List.generate(n, (i) {
      return _Pair(
        i < r.original.length ? r.original[i] : null,
        i < r.edited.length ? r.edited[i] : null,
      );
    });
  }

  /// Build the final Delta ops from per-pair selections. Emits one op per
  /// run so per-word formatting (font/bold/color) survives intact.
  List<dynamic> _composeMergedDelta() {
    final ops = <Map<String, dynamic>>[];
    for (var i = 0; i < _pairs.length; i++) {
      final pair = _pairs[i];
      final useEdited = _accept[i];
      final chosen = useEdited ? pair.edited : pair.original;
      if (chosen == null) continue;

      if (chosen.runs.isNotEmpty) {
        for (final run in chosen.runs) {
          if (run.text.isEmpty) continue;
          final op = <String, dynamic>{'insert': run.text};
          if (run.attrs.isNotEmpty) {
            op['attributes'] = Map<String, dynamic>.from(run.attrs);
          }
          ops.add(op);
        }
      } else if (chosen.text.isNotEmpty) {
        ops.add({'insert': chosen.text});
      }

      final nl = <String, dynamic>{'insert': '\n'};
      if (chosen.blockAttrs.isNotEmpty) {
        nl['attributes'] = Map<String, dynamic>.from(chosen.blockAttrs);
      }
      ops.add(nl);
    }
    if (ops.isEmpty) ops.add({'insert': '\n'});
    return ops;
  }

  @override
  Widget build(BuildContext context) {
    final accentColor = widget.isDark
        ? const Color(0xFF93B4F5)
        : const Color(0xFF5B8DEF);

    return Container(
      color: widget.backgroundColor,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _header(accentColor),
            const SizedBox(height: 4),
            Text(
              widget.hasSelection
                  ? 'Working with selected text'
                  : 'Working with full document',
              style: GoogleFonts.inter(
                  fontSize: 12, color: widget.mutedColor),
            ),
            const SizedBox(height: 16),
            if (_loading) ...[
              const SizedBox(height: 20),
              Row(
                children: [
                  const AppSpinner(size: 16),
                  const SizedBox(width: 10),
                  Text(
                    '${widget.action.label}...',
                    style: GoogleFonts.inter(
                        fontSize: 13, color: widget.mutedColor),
                  ),
                ],
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              _errorBanner(_error!),
            ],
            if (_editResult != null &&
                !_loading &&
                _mode == _AIMode.transform) ...[
              _diffLegend(),
              const SizedBox(height: 12),
              ..._pairCards(),
              const SizedBox(height: 16),
              _applyRow(),
            ],
            if (_feedbackText != null &&
                !_loading &&
                _mode == _AIMode.feedback) ...[
              _feedbackCard(_feedbackText!),
              const SizedBox(height: 16),
              _tryAnotherButton(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _header(Color accentColor) {
    return Row(
      children: [
        Icon(CupertinoIcons.wand_stars, size: 20, color: accentColor),
        const SizedBox(width: 10),
        Text(
          'AI Assist',
          style: GoogleFonts.inter(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: widget.textColor,
          ),
        ),
        const Spacer(),
        if ((_editResult != null || _feedbackText != null) && !_loading) ...[
          GestureDetector(
            onTap: widget.onClose,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(CupertinoIcons.arrow_left,
                    size: 14, color: widget.mutedColor),
                const SizedBox(width: 4),
                Text(
                  'Try another',
                  style: GoogleFonts.inter(
                      fontSize: 12, color: widget.mutedColor),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
        ],
        GestureDetector(
          onTap: widget.onClose,
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: widget.textColor.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(CupertinoIcons.xmark,
                size: 14, color: widget.mutedColor),
          ),
        ),
      ],
    );
  }

  Widget _diffLegend() {
    return Row(
      children: [
        _legendDot(const Color(0xFFDC3545), 'Removed'),
        const SizedBox(width: 16),
        _legendDot(const Color(0xFF28A745), 'Added'),
        const Spacer(),
        Text(
          '${_accept.where((b) => b).length}/${_pairs.length} accepted',
          style: GoogleFonts.inter(fontSize: 11, color: widget.mutedColor),
        ),
      ],
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 6),
        Text(label,
            style: GoogleFonts.inter(
                fontSize: 11, color: widget.mutedColor)),
      ],
    );
  }

  List<Widget> _pairCards() {
    return List.generate(_pairs.length, (i) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: _PairCard(
          index: i,
          pair: _pairs[i],
          accepted: _accept[i],
          isDark: widget.isDark,
          textColor: widget.textColor,
          mutedColor: widget.mutedColor,
          surfaceColor: widget.surfaceColor,
          onToggle: (v) => setState(() => _accept[i] = v),
        ),
      );
    });
  }

  Widget _applyRow() {
    final hasAcceptedEdit = () {
      for (var i = 0; i < _pairs.length; i++) {
        if (_accept[i] && _pairs[i].edited != null) return true;
      }
      return false;
    }();
    return Row(
      children: [
        Expanded(
          child: CupertinoButton(
            padding: const EdgeInsets.symmetric(vertical: 12),
            color: const Color(0xFF28A745),
            borderRadius: BorderRadius.circular(10),
            onPressed: hasAcceptedEdit
                ? () {
                    widget.onApply(_composeMergedDelta());
                    widget.onClose();
                  }
                : null,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(CupertinoIcons.checkmark_alt,
                    size: 16, color: Colors.white),
                const SizedBox(width: 8),
                Text(
                  'Apply Selection',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        CupertinoButton(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          borderRadius: BorderRadius.circular(10),
          color: widget.isDark
              ? const Color(0xFFDC3545).withValues(alpha: 0.15)
              : const Color(0xFFDC3545).withValues(alpha: 0.08),
          onPressed: widget.onClose,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(CupertinoIcons.xmark,
                  size: 14,
                  color: widget.isDark
                      ? const Color(0xFFFF6B6B)
                      : const Color(0xFFDC3545)),
              const SizedBox(width: 6),
              Text(
                'Decline',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: widget.isDark
                      ? const Color(0xFFFF6B6B)
                      : const Color(0xFFDC3545),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _feedbackCard(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: widget.surfaceColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: widget.isDark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.06),
        ),
      ),
      child: SelectableText(
        text,
        style: GoogleFonts.inter(
          fontSize: 14,
          height: 1.7,
          color: widget.textColor.withValues(alpha: 0.9),
        ),
      ),
    );
  }

  Widget _tryAnotherButton() {
    return CupertinoButton(
      padding: const EdgeInsets.symmetric(vertical: 12),
      borderRadius: BorderRadius.circular(10),
      color: widget.surfaceColor,
      onPressed: widget.onClose,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(CupertinoIcons.arrow_left, size: 14, color: widget.mutedColor),
          const SizedBox(width: 8),
          Text(
            'Try another',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: widget.textColor.withValues(alpha: 0.85),
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorBanner(String error) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.red.withValues(alpha: 0.15)),
      ),
      child: Row(
        children: [
          const Icon(CupertinoIcons.exclamationmark_triangle,
              size: 16, color: Colors.redAccent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              error,
              style: GoogleFonts.inter(
                  fontSize: 13, color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
  }

}

// ─── One paragraph pair card ───

class _PairCard extends StatelessWidget {
  final int index;
  final _Pair pair;
  final bool accepted;
  final bool isDark;
  final Color textColor;
  final Color mutedColor;
  final Color surfaceColor;
  final ValueChanged<bool> onToggle;

  const _PairCard({
    required this.index,
    required this.pair,
    required this.accepted,
    required this.isDark,
    required this.textColor,
    required this.mutedColor,
    required this.surfaceColor,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final orig = pair.original;
    final edited = pair.edited;

    final origText = orig?.text ?? '';
    final editText = edited?.text ?? '';
    final spans = _computeWordDiff(origText, editText);

    final base = GoogleFonts.inter(
      fontSize: 14,
      height: 1.6,
      color: textColor.withValues(alpha: 0.85),
    );

    // Pull inline attrs from the longest run of whichever side is the
    // visual baseline. The diff overlay can't render per-run formatting
    // (red/green strikethrough has to win), so we approximate with the
    // dominant run's style. The actual document gets exact per-run
    // formatting via _composeMergedDelta.
    final baselineRuns = (accepted ? edited : orig)?.runs ?? const <TextRun>[];
    final inline = _longestRunAttrs(baselineRuns);
    final styledBase = _inlineStyleOf(Map<String, dynamic>.from(inline), base);

    final block = (accepted ? edited : orig)?.blockAttrs ?? const {};
    final blockLabel = _blockLabel(Map<String, dynamic>.from(block));

    final addedColor = isDark ? const Color(0xFF6BCB77) : const Color(0xFF28A745);
    final removedColor = isDark ? const Color(0xFFFF6B6B) : const Color(0xFFDC3545);

    final addedBg = const Color(0xFF28A745).withValues(alpha: isDark ? 0.16 : 0.10);
    final removedBg = const Color(0xFFDC3545).withValues(alpha: isDark ? 0.16 : 0.10);

    final isPureAdd = orig == null && edited != null;
    final isPureRemove = orig != null && edited == null;

    return Opacity(
      opacity: accepted ? 1.0 : 0.55,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: surfaceColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.black.withValues(alpha: 0.06),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: textColor.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '#${index + 1}',
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: mutedColor,
                    ),
                  ),
                ),
                if (blockLabel != null) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF5B8DEF).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      blockLabel,
                      style: GoogleFonts.inter(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF5B8DEF),
                      ),
                    ),
                  ),
                ],
                if (isPureAdd) ...[
                  const SizedBox(width: 6),
                  _tag('Added paragraph', addedColor, addedBg),
                ] else if (isPureRemove) ...[
                  const SizedBox(width: 6),
                  _tag('Removed paragraph', removedColor, removedBg),
                ],
                const Spacer(),
                _AcceptToggle(
                  value: accepted,
                  onChanged: onToggle,
                  isDark: isDark,
                  mutedColor: mutedColor,
                ),
              ],
            ),
            const SizedBox(height: 10),
            RichText(
              text: TextSpan(
                style: styledBase,
                children: spans.map((s) {
                  switch (s.type) {
                    case _DiffType.removed:
                      return TextSpan(
                        text: s.text,
                        style: TextStyle(
                          color: removedColor,
                          decoration: TextDecoration.lineThrough,
                          decorationColor: removedColor,
                          backgroundColor: removedBg,
                        ),
                      );
                    case _DiffType.added:
                      return TextSpan(
                        text: s.text,
                        style: TextStyle(
                          color: addedColor,
                          backgroundColor: addedBg,
                        ),
                      );
                    case _DiffType.equal:
                      return TextSpan(text: s.text);
                  }
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tag(String label, Color color, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _AcceptToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool isDark;
  final Color mutedColor;

  const _AcceptToggle({
    required this.value,
    required this.onChanged,
    required this.isDark,
    required this.mutedColor,
  });

  @override
  Widget build(BuildContext context) {
    final active = value;
    final activeColor = const Color(0xFF28A745);
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active
              ? activeColor.withValues(alpha: 0.15)
              : (isDark
                  ? Colors.white.withValues(alpha: 0.05)
                  : Colors.black.withValues(alpha: 0.05)),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: active
                ? activeColor.withValues(alpha: 0.4)
                : (isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.black.withValues(alpha: 0.08)),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              active ? CupertinoIcons.checkmark_alt : CupertinoIcons.minus,
              size: 12,
              color: active ? activeColor : mutedColor,
            ),
            const SizedBox(width: 4),
            Text(
              active ? 'Use rewrite' : 'Keep original',
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: active ? activeColor : mutedColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
