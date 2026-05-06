import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/provider/editor_provider.dart';

/// Sortable, inline-editable spreadsheet of every chapter/scene.
/// Columns: title · synopsis · wordcount · keywords · label · publish.
/// Editing the synopsis cell or toggling include-in-publish writes back
/// through `EditorProvider.updateSectionFields`.
class OutlineView extends StatefulWidget {
  const OutlineView({super.key, this.searchQuery = ''});

  final String searchQuery;

  @override
  State<OutlineView> createState() => _OutlineViewState();
}

enum _OutlineColumn { order, title, synopsis, words, label, retention }

class _OutlineViewState extends State<OutlineView> {
  _OutlineColumn _sortColumn = _OutlineColumn.order;
  bool _ascending = true;

  // Reading-retention overlay. Fetched once per opened book (and when the
  // user explicitly refreshes); cached in state so sort/scroll doesn't
  // trigger a network round trip. `_retentionBookId` guards against a
  // stale response landing after the user opens a different writing.
  String? _retentionBookId;
  int _totalReaders = 0;
  int _completedReaders = 0;
  Map<String, int> _stalled = const {};
  bool _retentionLoading = false;

  Future<void> _ensureRetention(String writingId) async {
    if (_retentionBookId == writingId || _retentionLoading) return;
    _retentionLoading = true;
    final api = context.read<AuthProvider>().dataService;
    final result = await api.getSectionRetention(writingId);
    if (!mounted) return;
    setState(() {
      _retentionBookId = writingId;
      _totalReaders = result.total;
      _completedReaders = result.completed;
      _stalled = result.stalled;
      _retentionLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = theme.textTheme.bodyMedium?.color ?? Colors.black;
    return Consumer<EditorProvider>(
      builder: (context, provider, _) {
        final book = provider.activeBook;
        if (book == null) return const SizedBox.shrink();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _ensureRetention(book.id);
        });
        final rows = _rowsFor(book);
        if (rows.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'No sections to outline yet.',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: textColor.withValues(alpha: 0.5),
                ),
              ),
            ),
          );
        }
        final hasRetention = _totalReaders > 0;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (hasRetention) _retentionSummary(textColor, isDark),
            _headerRow(isDark, textColor, hasRetention),
            const SizedBox(height: 4),
            for (final s in rows) _OutlineRow(
              section: s,
              isDark: isDark,
              textColor: textColor,
              isActive: provider.activeSection?.id == s.id,
              stalledCount: _stalled[s.id] ?? 0,
              totalReaders: _totalReaders,
              showRetention: hasRetention,
              onOpen: () {
                if (s.kind == SectionKind.folder) return;
                provider.forceSaveImmediately();
                provider.setActiveSection(s);
                provider.initEditor();
              },
              onSynopsisChanged: (value) =>
                  provider.updateSectionFields(s, {'synopsis': value}),
              onPublishToggle: (v) => provider
                  .updateSectionFields(s, {'include_in_publish': v}),
              onLabelChanged: (color) => provider
                  .updateSectionFields(s, {'label_color': color}),
            ),
          ],
        );
      },
    );
  }

  Widget _retentionSummary(Color textColor, bool isDark) {
    final stalledTotal = _stalled.values.fold<int>(0, (a, b) => a + b);
    final completedPct = _totalReaders == 0
        ? 0.0
        : (_completedReaders / _totalReaders) * 100;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(
            CupertinoIcons.eye,
            size: 12,
            color: textColor.withValues(alpha: 0.55),
          ),
          const SizedBox(width: 6),
          Text(
            '$_totalReaders ${_totalReaders == 1 ? 'reader' : 'readers'}'
            ' · $_completedReaders finished'
            ' (${completedPct.toStringAsFixed(0)}%)'
            ' · $stalledTotal in progress',
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: textColor.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _headerRow(bool isDark, Color textColor, bool hasRetention) {
    Widget cell(String text, _OutlineColumn col, double flex) {
      final active = _sortColumn == col;
      return Expanded(
        flex: (flex * 100).round(),
        child: InkWell(
          onTap: () => setState(() {
            if (_sortColumn == col) {
              _ascending = !_ascending;
            } else {
              _sortColumn = col;
              _ascending = true;
            }
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                Text(
                  text,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: textColor.withValues(alpha: active ? 1 : 0.55),
                  ),
                ),
                if (active) ...[
                  const SizedBox(width: 4),
                  Icon(
                    _ascending
                        ? CupertinoIcons.chevron_up
                        : CupertinoIcons.chevron_down,
                    size: 10,
                    color: textColor.withValues(alpha: 0.65),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
              color: textColor.withValues(alpha: 0.12), width: 0.6),
        ),
      ),
      child: Row(
        children: [
          cell('TITLE', _OutlineColumn.title, 1.6),
          cell('SYNOPSIS', _OutlineColumn.synopsis, 2.4),
          cell('WORDS', _OutlineColumn.words, 0.6),
          cell('LABEL', _OutlineColumn.label, 0.7),
          if (hasRetention) cell('RETENTION', _OutlineColumn.retention, 0.9),
          const SizedBox(width: 96, child: SizedBox.shrink()),
        ],
      ),
    );
  }

  List<SectionModel> _rowsFor(WritingModel book) {
    final list = book.sections
        .where((s) =>
            s.kind != SectionKind.folder &&
            s.kind != SectionKind.research &&
            s.kind != SectionKind.trash &&
            s.kind != SectionKind.act)
        .where((s) {
      final q = widget.searchQuery.trim().toLowerCase();
      if (q.isEmpty) return true;
      if (s.title.toLowerCase().contains(q)) return true;
      if (s.synopsis.toLowerCase().contains(q)) return true;
      for (final k in s.keywords) {
        if (k.toLowerCase().contains(q)) return true;
      }
      return false;
    }).toList();
    int comparator(SectionModel a, SectionModel b) {
      switch (_sortColumn) {
        case _OutlineColumn.order:
          return a.order.compareTo(b.order);
        case _OutlineColumn.title:
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        case _OutlineColumn.synopsis:
          return a.synopsis.length.compareTo(b.synopsis.length);
        case _OutlineColumn.words:
          return _wordCount(a).compareTo(_wordCount(b));
        case _OutlineColumn.label:
          final av = a.labelColor ?? -1;
          final bv = b.labelColor ?? -1;
          return av.compareTo(bv);
        case _OutlineColumn.retention:
          return (_stalled[a.id] ?? 0).compareTo(_stalled[b.id] ?? 0);
      }
    }
    list.sort(comparator);
    if (!_ascending) {
      return list.reversed.toList();
    }
    return list;
  }
}

int _wordCount(SectionModel section) {
  final raw = section.content;
  if (raw.trim().isEmpty) return 0;
  try {
    final ops = jsonDecode(raw);
    if (ops is List) {
      final doc = Document.fromJson(ops);
      final plain = doc.toPlainText().trim();
      if (plain.isEmpty) return 0;
      return plain.split(RegExp(r'\s+')).length;
    }
  } catch (_) {}
  return raw.split(RegExp(r'\s+')).length;
}

class _OutlineRow extends StatefulWidget {
  const _OutlineRow({
    required this.section,
    required this.isDark,
    required this.textColor,
    required this.isActive,
    required this.stalledCount,
    required this.totalReaders,
    required this.showRetention,
    required this.onOpen,
    required this.onSynopsisChanged,
    required this.onPublishToggle,
    required this.onLabelChanged,
  });

  final SectionModel section;
  final bool isDark;
  final Color textColor;
  final bool isActive;
  final int stalledCount;
  final int totalReaders;
  final bool showRetention;
  final VoidCallback onOpen;
  final ValueChanged<String> onSynopsisChanged;
  final ValueChanged<bool> onPublishToggle;
  final ValueChanged<int?> onLabelChanged;

  @override
  State<_OutlineRow> createState() => _OutlineRowState();
}

class _OutlineRowState extends State<_OutlineRow> {
  late final TextEditingController _synopsisCtrl;

  @override
  void initState() {
    super.initState();
    _synopsisCtrl = TextEditingController(text: widget.section.synopsis);
  }

  @override
  void didUpdateWidget(covariant _OutlineRow old) {
    super.didUpdateWidget(old);
    if (old.section.id != widget.section.id ||
        widget.section.synopsis != _synopsisCtrl.text) {
      _synopsisCtrl.text = widget.section.synopsis;
    }
  }

  @override
  void dispose() {
    _synopsisCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.section;
    final wc = _wordCount(s);
    final labelColor =
        s.labelColor != null ? Color(s.labelColor!) : null;
    return Container(
      decoration: BoxDecoration(
        color: widget.isActive
            ? (widget.isDark
                ? Colors.white.withValues(alpha: 0.05)
                : Colors.black.withValues(alpha: 0.03))
            : Colors.transparent,
        border: Border(
          bottom: BorderSide(
              color: widget.textColor.withValues(alpha: 0.06), width: 0.4),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 160,
            child: InkWell(
              onTap: widget.onOpen,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      s.kind == SectionKind.scene
                          ? CupertinoIcons.doc
                          : CupertinoIcons.doc_text,
                      size: 12,
                      color: widget.textColor.withValues(alpha: 0.55),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        s.title.isEmpty ? 'Untitled' : s.title,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                          fontSize: 12.5,
                          fontWeight: widget.isActive
                              ? FontWeight.w600
                              : FontWeight.w500,
                          color: widget.textColor,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            flex: 240,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: TextField(
                controller: _synopsisCtrl,
                onChanged: widget.onSynopsisChanged,
                style: GoogleFonts.inter(fontSize: 12),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  isDense: true,
                  hintText: '—',
                ),
              ),
            ),
          ),
          Expanded(
            flex: 60,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                wc.toString(),
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: widget.textColor.withValues(alpha: 0.7),
                ),
              ),
            ),
          ),
          Expanded(
            flex: 70,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: GestureDetector(
                onTap: () async {
                  final picked = await _quickPickColor(context);
                  if (picked == null) return;
                  widget.onLabelChanged(picked == 0 ? null : picked);
                },
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: labelColor ?? Colors.transparent,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: widget.textColor.withValues(alpha: 0.25),
                      width: 0.8,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (widget.showRetention)
            Expanded(
              flex: 90,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: _RetentionCell(
                  stalled: widget.stalledCount,
                  total: widget.totalReaders,
                  textColor: widget.textColor,
                ),
              ),
            ),
          SizedBox(
            width: 96,
            child: Row(
              children: [
                Switch.adaptive(
                  value: s.includeInPublish,
                  onChanged: widget.onPublishToggle,
                ),
                Text(
                  'pub',
                  style: GoogleFonts.inter(
                    fontSize: 9,
                    color: widget.textColor.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<int?> _quickPickColor(BuildContext context) async {
    const palette = <int>[
      0xFFE53935,
      0xFFFB8C00,
      0xFFFFB300,
      0xFF43A047,
      0xFF1E88E5,
      0xFF8E24AA,
    ];
    return showDialog<int>(
      context: context,
      builder: (dialogCtx) => SimpleDialog(
        title: const Text('Pick label'),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in palette)
                  GestureDetector(
                    onTap: () => Navigator.pop(dialogCtx, c),
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        color: Color(c),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                GestureDetector(
                  onTap: () => Navigator.pop(dialogCtx, 0),
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.grey),
                    ),
                    child: const Icon(CupertinoIcons.clear, size: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Per-section retention pill. Shows the count and percentage of readers
/// stalled at this section out of the total who started the writing —
/// "5 readers (12%)". Tinted red when the share is high (likely a
/// drop-off cliff), green when low (most readers passed through).
class _RetentionCell extends StatelessWidget {
  const _RetentionCell({
    required this.stalled,
    required this.total,
    required this.textColor,
  });

  final int stalled;
  final int total;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    if (total == 0) {
      return Text(
        '—',
        style: GoogleFonts.inter(
          fontSize: 11,
          color: textColor.withValues(alpha: 0.4),
        ),
      );
    }
    final pct = (stalled / total) * 100;
    final tint = _tintFor(pct);
    return Tooltip(
      message: stalled == 0
          ? 'No readers currently stalled here'
          : '$stalled of $total readers last seen at this section',
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: tint.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: tint,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              stalled == 0 ? '0' : '$stalled · ${pct.toStringAsFixed(0)}%',
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: textColor.withValues(alpha: 0.85),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Threshold tuned so a section holding >25% of in-progress readers
  /// goes red (likely an attrition cliff), <10% stays green, and
  /// anything in between is amber. These are heuristics; the absolute
  /// numbers always show alongside the tint so the author can decide.
  static Color _tintFor(double pct) {
    if (pct >= 25) return const Color(0xFFE53935);
    if (pct >= 10) return const Color(0xFFFB8C00);
    return const Color(0xFF43A047);
  }
}
