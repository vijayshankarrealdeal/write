import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:inkspacex/services/gemini_service.dart';

// ─── Word-level diff ───

enum _DiffType { equal, added, removed }

class _DiffSpan {
  final _DiffType type;
  final String text;
  const _DiffSpan(this.type, this.text);
}

/// Myers-style word diff. Splits on word boundaries, computes LCS,
/// then produces a list of equal / added / removed spans.
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

// ─── AI Bottom Sheet with Diff View ───

class AIBottomSheet extends StatefulWidget {
  final GeminiService gemini;
  final String text;
  final bool hasSelection;
  final bool isDark;
  final Color textColor;
  final Color mutedColor;
  final Color surfaceColor;
  final ValueChanged<String> onApply;

  const AIBottomSheet({
    super.key,
    required this.gemini,
    required this.text,
    required this.hasSelection,
    required this.isDark,
    required this.textColor,
    required this.mutedColor,
    required this.surfaceColor,
    required this.onApply,
  });

  @override
  State<AIBottomSheet> createState() => _AIBottomSheetState();
}

// Transform actions return replacement text → show diff + Accept/Decline.
// Feedback actions return advice → show as a card, no diff, no apply.
enum _AIMode { transform, feedback }

class _AIBottomSheetState extends State<AIBottomSheet> {
  bool _loading = false;
  String? _result;
  String? _error;
  String _activeAction = '';
  List<_DiffSpan>? _diffSpans;
  _AIMode _mode = _AIMode.transform;

  Future<void> _run(
    String label,
    Future<String> Function() action, {
    _AIMode mode = _AIMode.transform,
  }) async {
    setState(() {
      _loading = true;
      _error = null;
      _result = null;
      _diffSpans = null;
      _activeAction = label;
      _mode = mode;
    });
    try {
      final result = await action();
      if (mounted) {
        setState(() {
          _result = result;
          _diffSpans = mode == _AIMode.transform
              ? _computeWordDiff(widget.text, result)
              : null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
            () => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _reset() {
    setState(() {
      _result = null;
      _diffSpans = null;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final accentColor = widget.isDark
        ? const Color(0xFF93B4F5)
        : const Color(0xFF5B8DEF);

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(top: 8, bottom: 12),
                decoration: BoxDecoration(
                  color: widget.textColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
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
                            color: widget.textColor,
                          ),
                        ),
                        const Spacer(),
                        if (_result != null && !_loading)
                          GestureDetector(
                            onTap: _reset,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(CupertinoIcons.arrow_left,
                                    size: 14, color: widget.mutedColor),
                                const SizedBox(width: 4),
                                Text(
                                  'Try another',
                                  style: GoogleFonts.inter(
                                    fontSize: 12,
                                    color: widget.mutedColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.hasSelection
                          ? 'Working with selected text'
                          : 'Working with full document',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: widget.mutedColor,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (_result == null || _loading) ...[
                      _sectionLabel('SHARPEN'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _aiChip(
                              'Tighten',
                              CupertinoIcons.bolt,
                              () => _run('Tighten',
                                  () => widget.gemini.tighten(widget.text))),
                          _aiChip(
                              'Sharpen opening',
                              CupertinoIcons.text_alignleft,
                              () => _run(
                                  'Sharpen opening',
                                  () => widget.gemini
                                      .sharpenOpening(widget.text))),
                          _aiChip(
                              'Lift the thesis',
                              CupertinoIcons.arrow_up_circle,
                              () => _run(
                                  'Lift the thesis',
                                  () =>
                                      widget.gemini.liftThesis(widget.text))),
                          _aiChip(
                              'Cut throat-clearing',
                              CupertinoIcons.scissors,
                              () => _run(
                                  'Cut throat-clearing',
                                  () => widget.gemini
                                      .cutThroatClearing(widget.text))),
                          _aiChip(
                              'Pick up where I left off',
                              CupertinoIcons.arrow_right_circle,
                              () => _run(
                                  'Pick up where I left off',
                                  () => widget.gemini
                                      .continueWriting(widget.text))),
                        ],
                      ),
                      const SizedBox(height: 14),
                      _sectionLabel('REFRAME'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _aiChip(
                              'For a beginner',
                              null,
                              () => _run(
                                  'For a beginner',
                                  () =>
                                      widget.gemini.forBeginner(widget.text))),
                          _aiChip(
                              'For an expert',
                              null,
                              () => _run('For an expert',
                                  () => widget.gemini.forExpert(widget.text))),
                          _aiChip(
                              'Add an example',
                              null,
                              () => _run('Add an example',
                                  () => widget.gemini.addExample(widget.text))),
                          _aiChip(
                              'Steel-man the other side',
                              null,
                              () => _run('Steel-man the other side',
                                  () => widget.gemini.steelMan(widget.text))),
                        ],
                      ),
                      const SizedBox(height: 14),
                      _sectionLabel('FEEDBACK'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _aiChip(
                              'Critique honestly',
                              CupertinoIcons.chat_bubble_text,
                              () => _run(
                                  'Critique honestly',
                                  () => widget.gemini.critique(widget.text),
                                  mode: _AIMode.feedback)),
                          _aiChip(
                              "What's missing?",
                              CupertinoIcons.question_circle,
                              () => _run(
                                  "What's missing?",
                                  () =>
                                      widget.gemini.whatsMissing(widget.text),
                                  mode: _AIMode.feedback)),
                          _aiChip(
                              'Three new openings',
                              CupertinoIcons.list_number,
                              () => _run(
                                  'Three new openings',
                                  () =>
                                      widget.gemini.threeOpenings(widget.text),
                                  mode: _AIMode.feedback)),
                        ],
                      ),
                      if (_loading) ...[
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            const CupertinoActivityIndicator(radius: 8),
                            const SizedBox(width: 10),
                            Text(
                              '$_activeAction...',
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                color: widget.mutedColor,
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color: Colors.red.withValues(alpha: 0.15)),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                  CupertinoIcons.exclamationmark_triangle,
                                  size: 16,
                                  color: Colors.redAccent),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _error!,
                                  style: GoogleFonts.inter(
                                    fontSize: 13,
                                    color: Colors.redAccent,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                    if (_result != null &&
                        !_loading &&
                        _mode == _AIMode.transform &&
                        _diffSpans != null) ...[
                      Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: const Color(0xFFDC3545)
                                  .withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text('Removed',
                              style: GoogleFonts.inter(
                                  fontSize: 11, color: widget.mutedColor)),
                          const SizedBox(width: 16),
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: const Color(0xFF28A745)
                                  .withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text('Added',
                              style: GoogleFonts.inter(
                                  fontSize: 11, color: widget.mutedColor)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Container(
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
                        child: RichText(
                          text: TextSpan(
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              height: 1.7,
                              color:
                                  widget.textColor.withValues(alpha: 0.85),
                            ),
                            children: _diffSpans!.map((span) {
                              switch (span.type) {
                                case _DiffType.removed:
                                  return TextSpan(
                                    text: span.text,
                                    style: TextStyle(
                                      color: widget.isDark
                                          ? const Color(0xFFFF6B6B)
                                          : const Color(0xFFDC3545),
                                      decoration:
                                          TextDecoration.lineThrough,
                                      decorationColor: widget.isDark
                                          ? const Color(0xFFFF6B6B)
                                          : const Color(0xFFDC3545),
                                      backgroundColor: widget.isDark
                                          ? const Color(0xFFDC3545)
                                              .withValues(alpha: 0.12)
                                          : const Color(0xFFDC3545)
                                              .withValues(alpha: 0.08),
                                    ),
                                  );
                                case _DiffType.added:
                                  return TextSpan(
                                    text: span.text,
                                    style: TextStyle(
                                      color: widget.isDark
                                          ? const Color(0xFF6BCB77)
                                          : const Color(0xFF28A745),
                                      backgroundColor: widget.isDark
                                          ? const Color(0xFF28A745)
                                              .withValues(alpha: 0.12)
                                          : const Color(0xFF28A745)
                                              .withValues(alpha: 0.08),
                                    ),
                                  );
                                case _DiffType.equal:
                                  return TextSpan(text: span.text);
                              }
                            }).toList(),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: CupertinoButton(
                              padding: const EdgeInsets.symmetric(
                                  vertical: 12),
                              color: const Color(0xFF28A745),
                              borderRadius: BorderRadius.circular(10),
                              onPressed: () => widget.onApply(_result!),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.center,
                                children: [
                                  const Icon(
                                      CupertinoIcons.checkmark_alt,
                                      size: 16,
                                      color: Colors.white),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Accept Changes',
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
                            padding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 12),
                            borderRadius: BorderRadius.circular(10),
                            color: widget.isDark
                                ? const Color(0xFFDC3545)
                                    .withValues(alpha: 0.15)
                                : const Color(0xFFDC3545)
                                    .withValues(alpha: 0.08),
                            onPressed: () => setState(() {
                              _result = null;
                              _diffSpans = null;
                            }),
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
                      ),
                    ],
                    if (_result != null &&
                        !_loading &&
                        _mode == _AIMode.feedback) ...[
                      Container(
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
                          _result!,
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            height: 1.7,
                            color: widget.textColor.withValues(alpha: 0.9),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      CupertinoButton(
                        padding:
                            const EdgeInsets.symmetric(vertical: 12),
                        borderRadius: BorderRadius.circular(10),
                        color: widget.surfaceColor,
                        onPressed: _reset,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(CupertinoIcons.arrow_left,
                                size: 14, color: widget.mutedColor),
                            const SizedBox(width: 8),
                            Text(
                              'Try another',
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: widget.textColor
                                    .withValues(alpha: 0.85),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) => Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: widget.mutedColor,
          letterSpacing: 1,
        ),
      );

  Widget _aiChip(String label, IconData? icon, VoidCallback onTap) {
    final isActive = _loading && _activeAction == label;
    return GestureDetector(
      onTap: _loading ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: isActive
              ? (widget.isDark
                  ? const Color(0xFF5B8DEF).withValues(alpha: 0.15)
                  : const Color(0xFF5B8DEF).withValues(alpha: 0.08))
              : widget.surfaceColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isActive
                ? const Color(0xFF5B8DEF).withValues(alpha: 0.3)
                : (widget.isDark
                    ? Colors.white.withValues(alpha: 0.06)
                    : Colors.black.withValues(alpha: 0.06)),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: widget.mutedColor),
              const SizedBox(width: 7),
            ],
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: widget.textColor.withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
