import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/provider/editor_provider.dart';

/// Corkboard. Each card represents a chapter or scene under the
/// currently-focused folder. Synopsis is rendered front-and-center.
/// Drag-reorder rewrites `order`.
class CardsView extends StatelessWidget {
  const CardsView({super.key, this.searchQuery = ''});

  final String searchQuery;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Consumer<EditorProvider>(
      builder: (context, provider, _) {
        final book = provider.activeBook;
        if (book == null) return const SizedBox.shrink();
        final cards = _focusedChildren(book, provider.activeSection);
        if (cards.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                'No chapters or scenes here yet. Add one in the binder.',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: theme.textTheme.bodyMedium?.color
                      ?.withValues(alpha: 0.55),
                ),
              ),
            ),
          );
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final cardWidth = width >= 1100
                ? 260.0
                : width >= 720
                    ? 240.0
                    : 200.0;
            final crossCount = (width / (cardWidth + 16)).floor().clamp(1, 6);
            return GridView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: cards.length,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossCount,
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
                childAspectRatio: 0.78,
              ),
              itemBuilder: (context, index) {
                final section = cards[index];
                if (!_matchesQuery(section)) {
                  return Opacity(
                    opacity: 0.25,
                    child: _CorkCard(
                      section: section,
                      isDark: isDark,
                      onTap: () => _open(provider, section),
                      onDragAccepted: (_) {},
                      isActive: false,
                    ),
                  );
                }
                return DragTarget<SectionModel>(
                  onAcceptWithDetails: (details) {
                    final dragged = details.data;
                    if (dragged.id == section.id) return;
                    provider.moveSection(
                      dragged,
                      newParentId: section.parentId,
                      newIndex: index,
                    );
                  },
                  builder: (context, candidate, _) {
                    final highlighted = candidate.isNotEmpty;
                    return LongPressDraggable<SectionModel>(
                      data: section,
                      delay: const Duration(milliseconds: 220),
                      feedback: Material(
                        color: Colors.transparent,
                        child: SizedBox(
                          width: cardWidth,
                          child: _CorkCard(
                            section: section,
                            isDark: isDark,
                            onTap: () {},
                            onDragAccepted: (_) {},
                            isActive: false,
                            elevated: true,
                          ),
                        ),
                      ),
                      childWhenDragging: const SizedBox.shrink(),
                      child: _CorkCard(
                        section: section,
                        isDark: isDark,
                        onTap: () => _open(provider, section),
                        onDragAccepted: (s) => provider.moveSection(s,
                            newParentId: section.parentId, newIndex: index),
                        isActive: provider.activeSection?.id == section.id,
                        highlighted: highlighted,
                      ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  bool _matchesQuery(SectionModel section) {
    if (searchQuery.isEmpty) return true;
    final q = searchQuery.toLowerCase();
    if (section.title.toLowerCase().contains(q)) return true;
    if (section.synopsis.toLowerCase().contains(q)) return true;
    for (final k in section.keywords) {
      if (k.toLowerCase().contains(q)) return true;
    }
    return false;
  }

  void _open(EditorProvider provider, SectionModel section) {
    if (section.kind == SectionKind.folder) return;
    provider.forceSaveImmediately();
    provider.setActiveSection(section);
    provider.initEditor();
  }

  /// Cards under the current focus context: the active folder if one is
  /// selected, otherwise every chapter/scene anywhere in the binder.
  List<SectionModel> _focusedChildren(
      WritingModel book, SectionModel? active) {
    String? focusId;
    if (active != null) {
      if (active.kind == SectionKind.folder ||
          active.kind == SectionKind.act ||
          active.kind == SectionKind.research) {
        focusId = active.id;
      } else {
        focusId = active.parentId;
      }
    }
    if (focusId == null) {
      // Manuscript folder if it exists, else everything publishable.
      for (final s in book.sections) {
        if (s.parentId == null && s.kind == SectionKind.folder) {
          focusId = s.id;
          break;
        }
      }
    }
    final result = book.sections
        .where((s) =>
            s.parentId == focusId &&
            s.kind != SectionKind.folder &&
            s.kind != SectionKind.research &&
            s.kind != SectionKind.trash &&
            s.kind != SectionKind.act)
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    return result;
  }
}

class _CorkCard extends StatelessWidget {
  const _CorkCard({
    required this.section,
    required this.isDark,
    required this.onTap,
    required this.onDragAccepted,
    required this.isActive,
    this.elevated = false,
    this.highlighted = false,
  });

  final SectionModel section;
  final bool isDark;
  final VoidCallback onTap;
  final ValueChanged<SectionModel> onDragAccepted;
  final bool isActive;
  final bool elevated;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textColor = theme.textTheme.bodyMedium?.color ?? Colors.black;
    final tint = section.labelColor != null
        ? Color(section.labelColor!).withValues(alpha: isDark ? 0.18 : 0.10)
        : (isDark
            ? const Color(0xFF1A1A1A)
            : const Color(0xFFFEFCF7));
    final border = isActive
        ? Colors.blueAccent
        : highlighted
            ? Colors.blueAccent.withValues(alpha: 0.5)
            : (isDark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.08));
    return Material(
      color: tint,
      elevation: elevated ? 8 : 0,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: border, width: isActive ? 1.4 : 0.8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    section.kind == SectionKind.scene
                        ? CupertinoIcons.doc
                        : CupertinoIcons.doc_text,
                    size: 13,
                    color: textColor.withValues(alpha: 0.5),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      section.title.isEmpty ? 'Untitled' : section.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: textColor,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (section.keywords.isNotEmpty)
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final k in section.keywords.take(3))
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: textColor.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          k,
                          style: GoogleFonts.inter(
                            fontSize: 9,
                            color: textColor.withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                  ],
                ),
              const SizedBox(height: 8),
              Expanded(
                child: Text(
                  section.synopsis.isEmpty
                      ? 'No synopsis yet — open the inspector to add one.'
                      : section.synopsis,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    height: 1.4,
                    color: textColor.withValues(
                        alpha: section.synopsis.isEmpty ? 0.4 : 0.85),
                    fontStyle: section.synopsis.isEmpty
                        ? FontStyle.italic
                        : FontStyle.normal,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
