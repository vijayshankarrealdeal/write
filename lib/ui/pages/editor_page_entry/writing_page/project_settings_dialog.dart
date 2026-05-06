import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/provider/editor_provider.dart';
import 'package:inkspacex/services/daily_goal_service.dart';
import 'package:inkspacex/ui/pages/writing_history_page.dart';

/// Project Settings — Scrivener's "Color label meanings" + "Project
/// targets" rolled into one sheet. Writes back through
/// [EditorProvider.persistProjectFields] so changes propagate to the
/// outbox.
class ProjectSettingsDialog extends StatefulWidget {
  const ProjectSettingsDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF0E0E0E)
          : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => const Padding(
        padding: EdgeInsets.only(top: 12),
        child: ProjectSettingsDialog(),
      ),
    );
  }

  @override
  State<ProjectSettingsDialog> createState() => _ProjectSettingsDialogState();
}

class _ProjectSettingsDialogState extends State<ProjectSettingsDialog> {
  static const _palette = <int>[
    0xFFE53935,
    0xFFFB8C00,
    0xFFFFB300,
    0xFF43A047,
    0xFF1E88E5,
    0xFF8E24AA,
    0xFF6D4C41,
    0xFF546E7A,
  ];
  static const _meanings = <String>['status', 'pov', 'subplot', 'mood'];

  late TextEditingController _targetCtrl;
  DateTime? _deadline;
  // One TextEditingController per label color, kept in state so onChanged
  // → persistProjectFields → notifyListeners → rebuild doesn't recreate
  // the controller and reset the caret to offset 0 (typing "dead" came
  // out as "daed" because every keystroke rebuilt the field).
  final Map<int, TextEditingController> _labelCtrls = {};

  @override
  void initState() {
    super.initState();
    final book = context.read<EditorProvider>().activeBook;
    _targetCtrl = TextEditingController(
        text: book?.targetWordCount?.toString() ?? '');
    _deadline = book?.targetDeadline;
  }

  @override
  void dispose() {
    _targetCtrl.dispose();
    for (final c in _labelCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _ctrlFor(int colorInt, String currentValue) {
    final existing = _labelCtrls[colorInt];
    if (existing != null) return existing;
    final created = TextEditingController(text: currentValue);
    _labelCtrls[colorInt] = created;
    return created;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textColor = theme.textTheme.bodyMedium?.color ?? Colors.black;
    final mediaHeight = MediaQuery.sizeOf(context).height;
    return SizedBox(
      height: mediaHeight * 0.78,
      child: Consumer<EditorProvider>(
        builder: (context, provider, _) {
          final book = provider.activeBook;
          if (book == null) return const SizedBox.shrink();
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
            children: [
              _grabber(textColor),
              const SizedBox(height: 8),
              Text(
                'Project Settings',
                style: GoogleFonts.inter(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 14),
              _sectionTitle(textColor, 'MANUSCRIPT TARGET'),
              const SizedBox(height: 10),
              TextField(
                controller: _targetCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                ],
                decoration: InputDecoration(
                  labelText: 'Target word count',
                  hintText: '80000',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onChanged: (v) {
                  final parsed = v.isEmpty ? null : int.tryParse(v);
                  provider.activeBook?.targetWordCount = parsed;
                  provider.persistProjectFields(
                      {'target_word_count': parsed});
                },
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _deadline == null
                          ? 'No deadline'
                          : 'Deadline: '
                              '${_deadline!.year}-${_deadline!.month.toString().padLeft(2, '0')}-${_deadline!.day.toString().padLeft(2, '0')}',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        color: textColor.withValues(alpha: 0.75),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _deadline ??
                            DateTime.now().add(const Duration(days: 60)),
                        firstDate: DateTime.now(),
                        lastDate: DateTime.now().add(const Duration(days: 1825)),
                      );
                      if (picked == null) return;
                      setState(() => _deadline = picked);
                      provider.activeBook?.targetDeadline = picked;
                      provider.persistProjectFields(
                          {'target_deadline': picked.toIso8601String()});
                    },
                    child: const Text('Pick deadline'),
                  ),
                  if (_deadline != null)
                    IconButton(
                      icon: const Icon(CupertinoIcons.clear, size: 16),
                      onPressed: () {
                        setState(() => _deadline = null);
                        provider.activeBook?.targetDeadline = null;
                        provider.persistProjectFields(
                            {'target_deadline': null});
                      },
                    ),
                ],
              ),
              const SizedBox(height: 8),
              _recommendedDaily(book, textColor),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      theme.colorScheme.surface.withValues(alpha: 0.4),
                  foregroundColor: textColor,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => const WritingHistoryPage()),
                ),
                icon: const Icon(CupertinoIcons.chart_bar, size: 16),
                label: Text(
                  'Writing history',
                  style: GoogleFonts.inter(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: 18),
              _sectionTitle(textColor, 'COLOR LABEL MEANING'),
              const SizedBox(height: 6),
              Text(
                'What do colors mean on this project?',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: textColor.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final m in _meanings)
                    ChoiceChip(
                      label: Text(m,
                          style: GoogleFonts.inter(fontSize: 12)),
                      selected: book.labelMeaning == m,
                      onSelected: (_) {
                        book.labelMeaning = m;
                        provider.persistProjectFields(
                            {'label_meaning': m});
                      },
                    ),
                ],
              ),
              const SizedBox(height: 14),
              _sectionTitle(textColor, 'LABEL NAMES'),
              const SizedBox(height: 6),
              for (final colorInt in _palette)
                _labelRow(provider, book, colorInt, textColor),
            ],
          );
        },
      ),
    );
  }

  Widget _grabber(Color textColor) => Center(
        child: Container(
          margin: const EdgeInsets.only(top: 4),
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: textColor.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );

  Widget _recommendedDaily(WritingModel book, Color textColor) {
    final current = _manuscriptWordCount(book);
    final rec = DailyGoalService.recommendedDailyGoal(
      targetWordCount: book.targetWordCount,
      targetDeadline: book.targetDeadline,
      currentWordCount: current,
    );
    if (rec == null) return const SizedBox.shrink();
    final progress = (book.targetWordCount ?? 0) > 0
        ? (current / book.targetWordCount!).clamp(0.0, 1.0)
        : 0.0;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: textColor.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 36,
            height: 36,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: progress,
                  strokeWidth: 4,
                  backgroundColor: textColor.withValues(alpha: 0.08),
                  valueColor: const AlwaysStoppedAnimation(Colors.blueAccent),
                ),
                Text(
                  '${(progress * 100).toStringAsFixed(0)}%',
                  style: GoogleFonts.inter(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: textColor,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$current / ${book.targetWordCount} words',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                  ),
                ),
                Text(
                  rec == 0
                      ? 'Manuscript target reached.'
                      : 'Recommended today: $rec words',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: textColor.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  int _manuscriptWordCount(WritingModel book) {
    var total = 0;
    for (final s in book.sections) {
      if (!s.includeInPublish) continue;
      final raw = s.content.trim();
      if (raw.isEmpty) continue;
      // Cheap whitespace word count off the raw delta — close enough for
      // a target tracker that rounds to the hundred anyway.
      total += raw.split(RegExp(r'\s+')).length;
    }
    return total;
  }

  Widget _sectionTitle(Color textColor, String text) => Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.1,
          color: textColor.withValues(alpha: 0.55),
        ),
      );

  Widget _labelRow(
    EditorProvider provider,
    WritingModel book,
    int colorInt,
    Color textColor,
  ) {
    final ctrl = _ctrlFor(colorInt, book.labelNames[colorInt] ?? '');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 18,
            height: 18,
            decoration:
                BoxDecoration(color: Color(colorInt), shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: ctrl,
              decoration: InputDecoration(
                hintText: 'Name this color',
                hintStyle: GoogleFonts.inter(
                  fontSize: 12,
                  color: textColor.withValues(alpha: 0.4),
                ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              onChanged: (value) {
                final next = Map<int, String>.from(book.labelNames);
                if (value.trim().isEmpty) {
                  next.remove(colorInt);
                } else {
                  next[colorInt] = value;
                }
                book.labelNames = next;
                provider.persistProjectFields({
                  'label_names': {
                    for (final entry in next.entries)
                      entry.key.toString(): entry.value,
                  },
                });
              },
            ),
          ),
        ],
      ),
    );
  }
}
