import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/provider/editor_provider.dart';

/// Scrivener-style "scrivenings" mode: every publishable chapter / scene
/// in the active book rendered as one continuous read-only scroll with
/// section title dividers between them.
///
/// v1 is read-only by design. Live multi-section editing would require
/// either N independent QuillControllers (heavy provider state) or a
/// single controller with offset bookkeeping that maps cursor positions
/// back to originating sections. Both are deferred. The "Edit" button
/// on each section header switches the editor back to Draft view
/// focused on that section, which is adequate for the "see it all
/// together, jump in to fix one spot" workflow Scrivener users want.
///
/// Same renderer shape as `secondary_pane.dart` (read-only Quill per
/// section). Folders / Research / Trash are filtered out so the writer
/// only sees the manuscript content readers will see.
class ScrivenningsView extends StatelessWidget {
  const ScrivenningsView({super.key, required this.onJumpToSection});

  /// Switch the surrounding editor back to Draft mode focused on the
  /// given section. Wired by the parent so this widget stays decoupled
  /// from the editor's view-mode state machine.
  final void Function(SectionModel section) onJumpToSection;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = theme.textTheme.bodyMedium?.color ?? Colors.black;
    final mutedColor = textColor.withValues(alpha: 0.55);
    final dividerColor = textColor.withValues(alpha: 0.08);

    return Consumer<EditorProvider>(
      builder: (context, provider, _) {
        final book = provider.activeBook;
        if (book == null) return const SizedBox.shrink();
        final sections = _publishableSections(book);
        if (sections.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                'Add a chapter or scene to start writing.',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: mutedColor,
                ),
              ),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          itemCount: sections.length,
          separatorBuilder: (_, _) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Divider(color: dividerColor, height: 1),
          ),
          itemBuilder: (context, index) {
            final section = sections[index];
            return _ScrivenningsSection(
              section: section,
              isDark: isDark,
              textColor: textColor,
              mutedColor: mutedColor,
              onEdit: () => onJumpToSection(section),
            );
          },
        );
      },
    );
  }

  /// Manuscript order: every chapter / scene with `includeInPublish ==
  /// true`, sorted by `order`. Mirrors `publish_page._publishableSections`
  /// so the writer's preview matches what readers will see.
  List<SectionModel> _publishableSections(WritingModel book) {
    return book.sections
        .where((s) =>
            s.kind != SectionKind.folder &&
            s.kind != SectionKind.research &&
            s.kind != SectionKind.trash &&
            s.kind != SectionKind.act &&
            s.includeInPublish)
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));
  }
}

class _ScrivenningsSection extends StatefulWidget {
  const _ScrivenningsSection({
    required this.section,
    required this.isDark,
    required this.textColor,
    required this.mutedColor,
    required this.onEdit,
  });

  final SectionModel section;
  final bool isDark;
  final Color textColor;
  final Color mutedColor;
  final VoidCallback onEdit;

  @override
  State<_ScrivenningsSection> createState() => _ScrivenningsSectionState();
}

class _ScrivenningsSectionState extends State<_ScrivenningsSection> {
  QuillController? _controller;
  String? _renderedContent;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureController();
  }

  @override
  void didUpdateWidget(covariant _ScrivenningsSection old) {
    super.didUpdateWidget(old);
    if (old.section.id != widget.section.id ||
        old.section.content != widget.section.content) {
      _ensureController(force: true);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  /// Build (or rebuild) the read-only QuillController for this section.
  /// Rebuild only when `content` actually changed to avoid losing the
  /// scroll offset on every parent rebuild.
  void _ensureController({bool force = false}) {
    if (!force && _renderedContent == widget.section.content) return;
    _controller?.dispose();
    final raw = widget.section.content;
    if (raw.trim().isEmpty) {
      _controller = QuillController(
        document: Document()..insert(0, ''),
        readOnly: true,
        selection: const TextSelection.collapsed(offset: 0),
      );
    } else {
      try {
        final ops = jsonDecode(raw);
        _controller = QuillController(
          document: ops is List ? Document.fromJson(ops) : Document(),
          readOnly: true,
          selection: const TextSelection.collapsed(offset: 0),
        );
      } catch (_) {
        _controller = QuillController(
          document: Document()..insert(0, raw),
          readOnly: true,
          selection: const TextSelection.collapsed(offset: 0),
        );
      }
    }
    _renderedContent = raw;
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                widget.section.title.trim().isEmpty
                    ? 'Untitled'
                    : widget.section.title,
                style: GoogleFonts.inter(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: widget.textColor,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Edit this section',
              icon: Icon(
                CupertinoIcons.pencil,
                size: 16,
                color: widget.mutedColor,
              ),
              onPressed: widget.onEdit,
              splashRadius: 18,
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (widget.section.synopsis.trim().isNotEmpty) ...[
          Text(
            widget.section.synopsis,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontStyle: FontStyle.italic,
              color: widget.mutedColor,
            ),
          ),
          const SizedBox(height: 12),
        ] else
          const SizedBox(height: 8),
        QuillEditor.basic(
          controller: controller,
          config: const QuillEditorConfig(
            padding: EdgeInsets.zero,
            scrollable: false,
            autoFocus: false,
            expands: false,
            showCursor: false,
          ),
        ),
      ],
    );
  }
}
