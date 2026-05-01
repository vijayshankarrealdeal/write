import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// One renderable segment of a paragraph diff. Either an [equalText] run
/// that's identical between original and edited, or an [_Edit] that pairs a
/// (possibly null) removed run with a (possibly null) added run. Edits are
/// the user's tap targets — accepting/rejecting toggles between using the
/// added text or the removed text.
class _Segment {
  final String? equalText;
  final String? removed;
  final String? added;

  const _Segment.equal(String text)
      : equalText = text,
        removed = null,
        added = null;

  const _Segment.edit({this.removed, this.added}) : equalText = null;

  bool get isEdit => equalText == null;
}

/// Group flat diff spans into [_Segment]s. Consecutive (removed, added)
/// pairs become a single edit so the UI treats "X → Y" as one tap target
/// instead of two.
List<_Segment> _groupSegments(List<_DiffSpan> spans) {
  final out = <_Segment>[];
  int i = 0;
  while (i < spans.length) {
    final s = spans[i];
    if (s.type == _DiffType.equal) {
      out.add(_Segment.equal(s.text));
      i++;
      continue;
    }
    String? removed;
    String? added;
    if (s.type == _DiffType.removed) {
      removed = s.text;
      i++;
      if (i < spans.length && spans[i].type == _DiffType.added) {
        added = spans[i].text;
        i++;
      }
    } else {
      added = s.text;
      i++;
    }
    out.add(_Segment.edit(removed: removed, added: added));
  }
  return out;
}

// ─── Block style helpers ───

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

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
      },
      child: Focus(
        autofocus: true,
        child: Container(
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

// ─── AI Assist Panel (on-canvas) ───

enum _AIMode { transform, feedback }

/// Pair of original + edited paragraph at the same index. Either side may
/// be null when the AI added or removed a paragraph relative to the source.
class _Pair {
  final DeltaParagraph? original;
  final DeltaParagraph? edited;
  const _Pair(this.original, this.edited);
}

/// Resolved typography + container styling for one block, mirroring the
/// QuillEditor's `customStyles` so the panel renders look like the editor.
class _BlockStyle {
  final TextStyle textStyle;
  final EdgeInsets padding;
  final BoxDecoration? decoration;
  final EdgeInsets innerPadding;
  const _BlockStyle({
    required this.textStyle,
    required this.padding,
    this.decoration,
    this.innerPadding = EdgeInsets.zero,
  });
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

  /// Paper color of the editor — the panel uses this as its own background so
  /// the diff appears to live directly on the editor canvas.
  final Color backgroundColor;

  /// When true, paragraph typography uses the larger focus-mode size (matches
  /// the QuillEditor's behavior so the on-canvas diff doesn't reflow visually).
  final bool focusMode;

  /// Horizontal padding to apply around the diff content. Mirrors the editor
  /// card's left/right padding so paragraph wraps line up with what the user
  /// will see post-Apply.
  final EdgeInsets contentPadding;

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
    required this.focusMode,
    required this.contentPadding,
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
  // Segments and per-edit accept flags, parallel to _pairs.
  // _pairSegments[i] is the diff segments of pair i.
  // _editAccepts[i] is one bool per edit segment in that pair (true = accept).
  List<List<_Segment>> _pairSegments = const [];
  List<List<bool>> _editAccepts = const [];

  // Feedback (advice) result
  String? _feedbackText;

  Future<void> _runTransform(String actionId) async {
    setState(() {
      _loading = true;
      _error = null;
      _editResult = null;
      _pairs = const [];
      _pairSegments = const [];
      _editAccepts = const [];
      _feedbackText = null;
      _mode = _AIMode.transform;
    });
    try {
      final result =
          await widget.gemini.textEditDelta(actionId, widget.sourceDelta);
      if (!mounted) return;
      final pairs = _buildPairs(result);
      final segments = pairs
          .map((p) =>
              _groupSegments(_computeWordDiff(p.original?.text ?? '', p.edited?.text ?? '')))
          .toList(growable: false);
      final accepts = segments
          .map((segs) =>
              List<bool>.filled(segs.where((s) => s.isEdit).length, true))
          .toList(growable: false);
      setState(() {
        _editResult = result;
        _pairs = pairs;
        _pairSegments = segments;
        _editAccepts = accepts;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toggleEdit(int pairIdx, int editIdx) {
    setState(() {
      _editAccepts[pairIdx][editIdx] = !_editAccepts[pairIdx][editIdx];
    });
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

  /// Build the final Delta ops from per-edit selections. When every edit in a
  /// paragraph is accepted (or rejected), emit the source paragraph verbatim
  /// so per-run formatting (font/bold/color) survives intact. For mixed
  /// paragraphs we have to compose plain text from segments and attach only
  /// the paragraph's block attributes — per-word inline formatting is lost.
  List<dynamic> _composeMergedDelta() {
    final ops = <Map<String, dynamic>>[];
    for (var i = 0; i < _pairs.length; i++) {
      final pair = _pairs[i];
      final accepts = _editAccepts[i];
      final segs = _pairSegments[i];

      final allAccepted = accepts.every((a) => a);
      final allRejected = accepts.every((a) => !a);

      if (allAccepted) {
        if (pair.edited != null) _emitParagraph(ops, pair.edited!);
        // Pure-add paragraph + accepted: already emitted.
        // Pure-remove paragraph + accepted: skip — nothing to emit.
        continue;
      }
      if (allRejected) {
        if (pair.original != null) _emitParagraph(ops, pair.original!);
        // Pure-add rejected: skip. Pure-remove rejected: original emitted.
        continue;
      }

      // Mixed: compose plain text by walking segments. Inline runs lost.
      final buf = StringBuffer();
      int editIdx = 0;
      for (final seg in segs) {
        if (!seg.isEdit) {
          buf.write(seg.equalText);
          continue;
        }
        final accepted = accepts[editIdx++];
        if (accepted) {
          if (seg.added != null) buf.write(seg.added);
        } else {
          if (seg.removed != null) buf.write(seg.removed);
        }
      }
      final text = buf.toString();
      if (text.isNotEmpty) ops.add({'insert': text});

      final blockAttrs =
          (pair.edited ?? pair.original)?.blockAttrs ?? const {};
      final nl = <String, dynamic>{'insert': '\n'};
      if (blockAttrs.isNotEmpty) {
        nl['attributes'] = Map<String, dynamic>.from(blockAttrs);
      }
      ops.add(nl);
    }
    if (ops.isEmpty) ops.add({'insert': '\n'});
    return ops;
  }

  void _emitParagraph(List<Map<String, dynamic>> ops, DeltaParagraph p) {
    if (p.runs.isNotEmpty) {
      for (final run in p.runs) {
        if (run.text.isEmpty) continue;
        final op = <String, dynamic>{'insert': run.text};
        if (run.attrs.isNotEmpty) {
          op['attributes'] = Map<String, dynamic>.from(run.attrs);
        }
        ops.add(op);
      }
    } else if (p.text.isNotEmpty) {
      ops.add({'insert': p.text});
    }
    final nl = <String, dynamic>{'insert': '\n'};
    if (p.blockAttrs.isNotEmpty) {
      nl['attributes'] = Map<String, dynamic>.from(p.blockAttrs);
    }
    ops.add(nl);
  }

  // Colors used by the inline diff and floating action bar. Picked once per
  // build instead of recomputed inside every block widget.
  Color get _addedColor =>
      widget.isDark ? const Color(0xFF6BCB77) : const Color(0xFF28A745);
  Color get _removedColor =>
      widget.isDark ? const Color(0xFFFF6B6B) : const Color(0xFFDC3545);
  Color get _addedBg =>
      const Color(0xFF28A745).withValues(alpha: widget.isDark ? 0.18 : 0.12);
  Color get _removedBg =>
      const Color(0xFFDC3545).withValues(alpha: widget.isDark ? 0.18 : 0.12);

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
      },
      child: Focus(
        autofocus: true,
        child: Container(
      color: widget.backgroundColor,
      child: Stack(
        children: [
          Positioned.fill(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                widget.contentPadding.left,
                widget.contentPadding.top,
                widget.contentPadding.right,
                // Reserve space below the diff so the floating action bar
                // never covers the last paragraph.
                widget.contentPadding.bottom + 96,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _topBreadcrumb(),
                  const SizedBox(height: 8),
                  if (_loading) _loadingRow(),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    _errorBanner(_error!),
                  ],
                  if (_editResult != null &&
                      !_loading &&
                      _mode == _AIMode.transform)
                    ..._diffBlocks(),
                  if (_feedbackText != null &&
                      !_loading &&
                      _mode == _AIMode.feedback)
                    _feedbackBlock(_feedbackText!),
                ],
              ),
            ),
          ),
          // Floating action bar — sits over the canvas like the editor's
          // other floating chrome (format bar, side actions pill).
          if (!_loading && (_editResult != null || _feedbackText != null))
            Positioned(
              left: 0,
              right: 0,
              bottom: 24,
              child: Center(child: _floatingActionBar()),
            ),
        ],
      ),
        ),
      ),
    );
  }

  // ─── Top breadcrumb (minimal header) ───

  Widget _topBreadcrumb() {
    final accentColor = widget.isDark
        ? const Color(0xFF93B4F5)
        : const Color(0xFF5B8DEF);
    return Row(
      children: [
        Icon(CupertinoIcons.wand_stars, size: 14, color: accentColor),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            '${widget.action.label} • ${widget.hasSelection ? 'Selection' : 'Document'}',
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: widget.mutedColor,
              letterSpacing: 0.4,
            ),
          ),
        ),
        const Spacer(),
        GestureDetector(
          onTap: widget.onClose,
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: widget.textColor.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(CupertinoIcons.xmark,
                size: 12, color: widget.mutedColor),
          ),
        ),
      ],
    );
  }

  Widget _loadingRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Row(
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
    );
  }

  // ─── Inline diff blocks (rendered as if part of the editor) ───

  List<Widget> _diffBlocks() {
    return List.generate(_pairs.length, (i) {
      // ValueKey on (pairIdx, edit count) so a fresh _DiffBlock state is
      // created when the user runs a new transform (segments may differ).
      final segs = _pairSegments[i];
      final editCount = _editAccepts[i].length;
      return _DiffBlock(
        key: ValueKey('aipair-$i-$editCount'),
        pair: _pairs[i],
        segments: segs,
        accepts: _editAccepts[i],
        onToggleEdit: (editIdx) => _toggleEdit(i, editIdx),
        textColor: widget.textColor,
        mutedColor: widget.mutedColor,
        isDark: widget.isDark,
        focusMode: widget.focusMode,
        addedColor: _addedColor,
        removedColor: _removedColor,
        addedBg: _addedBg,
        removedBg: _removedBg,
      );
    });
  }

  Widget _feedbackBlock(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: SelectableText(
        text,
        style: GoogleFonts.inter(
          fontSize: widget.focusMode ? 18 : 17,
          height: widget.focusMode ? 1.9 : 1.7,
          color: widget.textColor.withValues(alpha: 0.9),
        ),
      ),
    );
  }

  // ─── Floating action bar ───

  Widget _floatingActionBar() {
    final hasTransformResult = _editResult != null;
    final barColor = widget.isDark
        ? const Color(0xFF1C1C1E)
        : Colors.white;
    final borderColor = widget.isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.08);

    return Container(
      decoration: BoxDecoration(
        color: barColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: widget.isDark ? 0.5 : 0.12),
            blurRadius: 24,
            spreadRadius: -6,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _barButton(
            icon: CupertinoIcons.arrow_left,
            label: 'Try another',
            color: widget.mutedColor,
            onTap: widget.onClose,
          ),
          if (hasTransformResult) ...[
            _barDivider(),
            _barButton(
              icon: CupertinoIcons.xmark,
              label: 'Decline',
              color: _removedColor,
              onTap: widget.onClose,
            ),
            const SizedBox(width: 4),
            _barButton(
              icon: CupertinoIcons.checkmark_alt,
              label: 'Apply',
              color: Colors.white,
              filled: true,
              fillColor: const Color(0xFF28A745),
              onTap: () {
                widget.onApply(_composeMergedDelta());
                widget.onClose();
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _barButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
    bool filled = false,
    Color? fillColor,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: filled ? fillColor : null,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _barDivider() {
    return Container(
      width: 1,
      height: 18,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: widget.isDark
          ? Colors.white.withValues(alpha: 0.08)
          : Colors.black.withValues(alpha: 0.08),
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

// ─── One paragraph, rendered inline using editor typography ───

/// Diff block matching the QuillEditor's `customStyles` so the on-canvas
/// preview lines up with what the document looks like post-Apply.
///
/// Each edit (a removed/added pair) is its own tap target. Tapping toggles
/// between accepted (red strikethrough on removed, green highlight on added)
/// and rejected (original text shown plain, suggestion grayed out and struck
/// through). Equal text is non-tappable.
class _DiffBlock extends StatefulWidget {
  final _Pair pair;
  final List<_Segment> segments;
  final List<bool> accepts;
  final void Function(int editIdx) onToggleEdit;
  final Color textColor;
  final Color mutedColor;
  final bool isDark;
  final bool focusMode;
  final Color addedColor;
  final Color removedColor;
  final Color addedBg;
  final Color removedBg;

  const _DiffBlock({
    super.key,
    required this.pair,
    required this.segments,
    required this.accepts,
    required this.onToggleEdit,
    required this.textColor,
    required this.mutedColor,
    required this.isDark,
    required this.focusMode,
    required this.addedColor,
    required this.removedColor,
    required this.addedBg,
    required this.removedBg,
  });

  @override
  State<_DiffBlock> createState() => _DiffBlockState();
}

class _DiffBlockState extends State<_DiffBlock> {
  // One recognizer per edit index. Created lazily, lives until widget
  // disposal — the recognizer's onTap closure is stable since it dereferences
  // `widget.onToggleEdit` at call time, so we never need to recreate them.
  final Map<int, TapGestureRecognizer> _recognizers = {};

  @override
  void dispose() {
    for (final r in _recognizers.values) {
      r.dispose();
    }
    super.dispose();
  }

  TapGestureRecognizer _recognizerFor(int editIdx) {
    return _recognizers.putIfAbsent(editIdx, () {
      return TapGestureRecognizer()
        ..onTap = () => widget.onToggleEdit(editIdx);
    });
  }

  @override
  Widget build(BuildContext context) {
    final orig = widget.pair.original;
    final edited = widget.pair.edited;

    // Block style is keyed off whichever side exists. For pure adds/removes
    // we fall back to the surviving side; for normal edits both have the
    // same block attrs in practice.
    final blockAttrs =
        (edited ?? orig)?.blockAttrs ?? const <String, dynamic>{};
    final block = _editorBlockStyle(
      Map<String, dynamic>.from(blockAttrs),
      textColor: widget.textColor,
      isDark: widget.isDark,
      focusMode: widget.focusMode,
    );

    // Inline attrs from the longest run on the surviving side. Approximates
    // per-run styling (font/bold/color); the actual document gets exact
    // per-run formatting via _composeMergedDelta on Apply (whole-paragraph
    // accept/reject only — mixed paragraphs lose inline runs).
    final baselineRuns = (edited ?? orig)?.runs ?? const <TextRun>[];
    final inline = _longestRunAttrs(baselineRuns);
    final styledBase = _inlineStyleOf(
      Map<String, dynamic>.from(inline),
      block.textStyle,
    );

    final rejectedTint = widget.textColor.withValues(alpha: 0.35);

    final inlineSpans = <InlineSpan>[];
    int editIdx = 0;
    for (final seg in widget.segments) {
      if (!seg.isEdit) {
        inlineSpans.add(TextSpan(text: seg.equalText));
        continue;
      }
      final eIdx = editIdx++;
      final accepted = widget.accepts[eIdx];
      final recognizer = _recognizerFor(eIdx);

      if (seg.removed != null) {
        inlineSpans.add(TextSpan(
          text: seg.removed,
          recognizer: recognizer,
          style: accepted
              // Accepted: removed text struck through in red.
              ? TextStyle(
                  color: widget.removedColor,
                  decoration: TextDecoration.lineThrough,
                  decorationColor: widget.removedColor,
                  backgroundColor: widget.removedBg,
                )
              // Rejected: original text shown plain (no special styling so
              // it reads like part of the document).
              : null,
        ));
      }
      if (seg.added != null) {
        inlineSpans.add(TextSpan(
          text: seg.added,
          recognizer: recognizer,
          style: accepted
              // Accepted: added text highlighted green.
              ? TextStyle(
                  color: widget.addedColor,
                  backgroundColor: widget.addedBg,
                )
              // Rejected: suggestion still visible but muted + struck through
              // so the user knows what was proposed and can re-tap to accept.
              : TextStyle(
                  color: rejectedTint,
                  decoration: TextDecoration.lineThrough,
                  decorationColor: rejectedTint,
                ),
        ));
      }
    }

    Widget content = RichText(text: TextSpan(style: styledBase, children: inlineSpans));

    if (block.decoration != null) {
      content = Container(
        decoration: block.decoration,
        padding: block.innerPadding,
        child: content,
      );
    }

    return Padding(
      padding: block.padding,
      child: content,
    );
  }
}

/// Mirror of the QuillEditor's `customStyles` block lookup, kept in sync with
/// [editor_page_entry.dart]'s `customStyles:` so on-canvas diff typography
/// matches the editor 1:1. Update both together when changing styles.
_BlockStyle _editorBlockStyle(
  Map<String, dynamic> blockAttrs, {
  required Color textColor,
  required bool isDark,
  required bool focusMode,
}) {
  if (blockAttrs.containsKey('header')) {
    final v = blockAttrs['header'];
    if (v == 1) {
      return _BlockStyle(
        textStyle: GoogleFonts.inter(
            fontSize: 32,
            fontWeight: FontWeight.w700,
            height: 1.3,
            color: textColor),
        padding: const EdgeInsets.fromLTRB(0, 20, 0, 10),
      );
    }
    if (v == 2) {
      return _BlockStyle(
        textStyle: GoogleFonts.inter(
            fontSize: 26,
            fontWeight: FontWeight.w600,
            height: 1.35,
            color: textColor),
        padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
      );
    }
    if (v == 3) {
      return _BlockStyle(
        textStyle: GoogleFonts.inter(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            height: 1.4,
            color: textColor),
        padding: const EdgeInsets.fromLTRB(0, 14, 0, 6),
      );
    }
  }
  if (blockAttrs['blockquote'] == true) {
    return _BlockStyle(
      textStyle: GoogleFonts.inter(
          fontSize: 17,
          fontStyle: FontStyle.italic,
          height: 1.6,
          color: textColor.withValues(alpha: 0.7)),
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: textColor.withValues(alpha: 0.2),
            width: 3,
          ),
        ),
      ),
      innerPadding: const EdgeInsets.only(left: 12),
    );
  }
  if (blockAttrs['code-block'] == true) {
    return _BlockStyle(
      textStyle: GoogleFonts.jetBrainsMono(
          fontSize: 14, height: 1.5, color: textColor.withValues(alpha: 0.85)),
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(8),
      ),
      innerPadding: const EdgeInsets.all(12),
    );
  }
  return _BlockStyle(
    textStyle: GoogleFonts.inter(
      fontSize: focusMode ? 18 : 17,
      height: focusMode ? 1.9 : 1.7,
      color: textColor.withValues(alpha: 0.9),
    ),
    padding: const EdgeInsets.only(top: 10),
  );
}
