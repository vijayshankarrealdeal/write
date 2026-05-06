import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/provider/editor_provider.dart';

/// Right-rail panel: synopsis (drives corkboard + outline), free-form
/// notes (the "graveyard for cut text"), and per-section keywords.
///
/// Distinct from `AnnotationsPanel` (anchored, threaded comments).
///
/// On desktop the same widget renders as a 300-wide left-bordered side
/// rail; on mobile it's mounted in a draggable bottom sheet via
/// [SectionInspector.asSheet] which removes the fixed width and the
/// left border.
class SectionInspector extends StatefulWidget {
  const SectionInspector({
    super.key,
    required this.isDark,
    required this.textColor,
    required this.borderColor,
    required this.surfaceColor,
    required this.onClose,
    this.asSheet = false,
  });

  final bool isDark;
  final Color textColor;
  final Color borderColor;
  final Color surfaceColor;
  final VoidCallback onClose;
  final bool asSheet;

  @override
  State<SectionInspector> createState() => _SectionInspectorState();
}

class _SectionInspectorState extends State<SectionInspector> {
  String? _trackedSectionId;
  late final TextEditingController _synopsisCtrl;
  late final TextEditingController _notesCtrl;
  late final TextEditingController _keywordCtrl;

  @override
  void initState() {
    super.initState();
    _synopsisCtrl = TextEditingController();
    _notesCtrl = TextEditingController();
    _keywordCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _synopsisCtrl.dispose();
    _notesCtrl.dispose();
    _keywordCtrl.dispose();
    super.dispose();
  }

  void _syncFromSection(SectionModel section) {
    if (_trackedSectionId == section.id) return;
    _trackedSectionId = section.id;
    _synopsisCtrl.text = section.synopsis;
    _notesCtrl.text = section.notes;
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<EditorProvider>(
      builder: (context, provider, _) {
        final section = provider.activeSection;
        if (section == null) {
          return _shell(child: _placeholder('Open a section to inspect it.'));
        }
        if (section.kind == SectionKind.folder ||
            section.kind == SectionKind.research ||
            section.kind == SectionKind.trash ||
            section.kind == SectionKind.act) {
          return _shell(
              child: _placeholder(
                  'Inspector is for chapters and scenes only.'));
        }
        _syncFromSection(section);
        return _shell(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(section),
              const Divider(height: 1),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                  children: [
                    _label('Synopsis'),
                    const SizedBox(height: 6),
                    _multilineField(
                      controller: _synopsisCtrl,
                      hint:
                          'A sentence or two — what happens in this scene?',
                      minLines: 2,
                      maxLines: 5,
                      onChanged: (value) =>
                          provider.updateSectionFields(section, {
                        'synopsis': value,
                      }),
                    ),
                    const SizedBox(height: 18),
                    _label('Keywords'),
                    const SizedBox(height: 6),
                    _keywordsRow(provider, section),
                    const SizedBox(height: 18),
                    _label('Notes'),
                    const SizedBox(height: 6),
                    _multilineField(
                      controller: _notesCtrl,
                      hint:
                          'Scratchpad — cut text, ideas, anything you don\'t '
                          'want to lose. Author-side only.',
                      minLines: 6,
                      maxLines: 14,
                      onChanged: (value) =>
                          provider.updateSectionFields(section, {
                        'notes': value,
                      }),
                    ),
                    const SizedBox(height: 18),
                    _label('Publish gate'),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Include in published artifact',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: widget.textColor
                                  .withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                        Switch.adaptive(
                          value: section.includeInPublish,
                          onChanged: (v) => provider
                              .updateSectionFields(section, {
                            'include_in_publish': v,
                          }),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _shell({required Widget child}) {
    if (widget.asSheet) {
      return Container(
        decoration: BoxDecoration(
          color: widget.surfaceColor,
        ),
        child: child,
      );
    }
    return Container(
      width: 300,
      decoration: BoxDecoration(
        color: widget.surfaceColor.withValues(alpha: 0.55),
        border: Border(left: BorderSide(color: widget.borderColor)),
      ),
      child: child,
    );
  }

  Widget _placeholder(String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
            fontSize: 12,
            color: widget.textColor.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }

  Widget _header(SectionModel section) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 6, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'INSPECTOR',
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    color: widget.textColor.withValues(alpha: 0.45),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  section.title.isEmpty ? 'Untitled' : section.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: widget.textColor,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(CupertinoIcons.xmark,
                size: 16, color: widget.textColor.withValues(alpha: 0.6)),
            onPressed: widget.onClose,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _label(String text) {
    return Text(
      text,
      style: GoogleFonts.inter(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
        color: widget.textColor.withValues(alpha: 0.55),
      ),
    );
  }

  Widget _multilineField({
    required TextEditingController controller,
    required String hint,
    required int minLines,
    required int maxLines,
    required ValueChanged<String> onChanged,
  }) {
    return TextField(
      controller: controller,
      minLines: minLines,
      maxLines: maxLines,
      onChanged: onChanged,
      style: GoogleFonts.inter(
        fontSize: 13,
        height: 1.45,
        color: widget.textColor,
      ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: GoogleFonts.inter(
          fontSize: 12,
          color: widget.textColor.withValues(alpha: 0.35),
        ),
        filled: true,
        fillColor: widget.isDark
            ? Colors.white.withValues(alpha: 0.04)
            : Colors.black.withValues(alpha: 0.03),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(
            color: widget.borderColor.withValues(alpha: 0.4),
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(
            color: widget.borderColor.withValues(alpha: 0.4),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Colors.blueAccent, width: 1.2),
        ),
      ),
    );
  }

  Widget _keywordsRow(EditorProvider provider, SectionModel section) {
    final book = provider.activeBook;
    final suggestions = <String>{};
    if (book != null) {
      for (final s in book.sections) {
        suggestions.addAll(s.keywords);
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final k in section.keywords)
              InputChip(
                label: Text(k, style: GoogleFonts.inter(fontSize: 11)),
                onDeleted: () {
                  final next = List<String>.from(section.keywords)..remove(k);
                  provider.updateSectionFields(section, {'keywords': next});
                },
              ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _keywordCtrl,
                style: GoogleFonts.inter(fontSize: 12),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Add keyword (e.g. Daisy, POV: Nick)',
                  hintStyle: GoogleFonts.inter(
                    fontSize: 11,
                    color: widget.textColor.withValues(alpha: 0.3),
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                onSubmitted: (v) => _commitKeyword(provider, section, v),
              ),
            ),
            IconButton(
              icon: const Icon(CupertinoIcons.plus, size: 14),
              onPressed: () =>
                  _commitKeyword(provider, section, _keywordCtrl.text),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        if (suggestions.isNotEmpty) ...[
          const SizedBox(height: 4),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final s in suggestions
                  .where((s) => !section.keywords.contains(s))
                  .take(8))
                ActionChip(
                  label: Text(s, style: GoogleFonts.inter(fontSize: 10)),
                  onPressed: () => _commitKeyword(provider, section, s),
                ),
            ],
          ),
        ],
      ],
    );
  }

  void _commitKeyword(
    EditorProvider provider,
    SectionModel section,
    String value,
  ) {
    final v = value.trim();
    if (v.isEmpty) return;
    if (section.keywords.contains(v)) return;
    final next = List<String>.from(section.keywords)..add(v);
    provider.updateSectionFields(section, {'keywords': next});
    _keywordCtrl.clear();
  }
}
