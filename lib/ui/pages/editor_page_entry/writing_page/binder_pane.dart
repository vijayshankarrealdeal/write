import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/provider/editor_provider.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/project_settings_dialog.dart';

/// Scrivener-class binder. Tree of `WritingModel.sections` grouped by
/// `parentId`, ordered by `order`. Each row is tappable, draggable, and
/// has a right-click / long-press context menu with rename / delete /
/// label / new-child actions.
///
/// Folder rows (Manuscript / Research / Trash) are non-editable shells:
/// they expand and accept drops, but selecting one does not load any
/// content into the editor.
class BinderPane extends StatefulWidget {
  const BinderPane({
    super.key,
    this.onItemTap,
  });

  /// Called after a leaf row is selected. The mobile bottom-sheet uses
  /// this to dismiss itself once the user picks a section.
  final VoidCallback? onItemTap;

  @override
  State<BinderPane> createState() => _BinderPaneState();
}

class _BinderPaneState extends State<BinderPane> {
  final Set<String> _expanded = <String>{};
  // Folders we've already auto-expanded once. Tracked separately from
  // `_expanded` so a user-collapse of a folder isn't stomped back to
  // expanded on the next rebuild.
  final Set<String> _seenFolderIds = <String>{};
  // Track pending state during drop so the row can flash.
  String? _hoverParentId;
  int? _hoverIndex;
  String _searchQuery = '';
  int? _labelFilter;
  // Which row currently has its inline action bar expanded. At most one
  // at a time so the binder doesn't bloat vertically.
  String? _actionsFor;
  late final TextEditingController _searchCtrl;

  @override
  void initState() {
    super.initState();
    _searchCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Parse the raw input. Supports `keyword:foo` (filters by keyword),
  /// otherwise treats the input as a free-text title/synopsis search.
  String _effectiveQuery() {
    final raw = _searchQuery.trim();
    if (raw.toLowerCase().startsWith('keyword:')) {
      return raw.substring('keyword:'.length).trim();
    }
    return raw;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = theme.textTheme.bodyMedium?.color ?? Colors.black;
    return Consumer<EditorProvider>(
      builder: (context, provider, _) {
        final book = provider.activeBook;
        if (book == null) {
          return const SizedBox.shrink();
        }
        final tree = _buildVisibleTree(book);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _BinderHeader(
              book: book,
              isDark: isDark,
              textColor: textColor,
              onAddChapter: () => _addChapter(provider),
            ),
            _BinderSearchBar(
              controller: _searchCtrl,
              isDark: isDark,
              textColor: textColor,
              labelFilter: _labelFilter,
              onSearchChanged: (v) => setState(() => _searchQuery = v),
              onLabelFilterChanged: (v) => setState(() => _labelFilter = v),
              labelPalette: book.labelNames,
            ),
            Expanded(
              child: tree.isEmpty
                  ? Center(
                      child: Text(
                        _effectiveQuery().isEmpty
                            ? 'No sections yet'
                            : 'No matches',
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          color: textColor.withValues(alpha: 0.4),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      itemCount: tree.length,
                      itemBuilder: (context, idx) {
                        final node = tree[idx];
                        return _BinderRow(
                          key: ValueKey(node.section.id),
                          node: node,
                          isActive: provider.activeSection?.id == node.section.id,
                          isExpanded: _expanded.contains(node.section.id),
                          actionsExpanded: _actionsFor == node.section.id,
                          isDark: isDark,
                          textColor: textColor,
                          isHoverTarget: _hoverParentId == node.section.id &&
                              _hoverIndex == null,
                          onTap: () => _selectSection(provider, node.section),
                          onToggleExpand: () => setState(() {
                            if (!_expanded.add(node.section.id)) {
                              _expanded.remove(node.section.id);
                            }
                          }),
                          onToggleActions: () => setState(() {
                            _actionsFor = _actionsFor == node.section.id
                                ? null
                                : node.section.id;
                          }),
                          onAddChild: node.section.kind == SectionKind.folder ||
                                  node.section.kind == SectionKind.act ||
                                  node.section.kind == SectionKind.research ||
                                  node.section.kind == SectionKind.chapter
                              ? () => _addChild(provider, node.section)
                              : null,
                          onRename: () => _rename(provider, node.section),
                          onDelete: () => _delete(provider, node.section),
                          onSetLabel: (color) =>
                              _setLabel(provider, node.section, color),
                          onAcceptDrop: (dragged, position) =>
                              _handleDrop(provider, dragged, node, position),
                          onHoverChange: (parentId, index) {
                            if (parentId == null && index == null) {
                              if (_hoverParentId != null || _hoverIndex != null) {
                                setState(() {
                                  _hoverParentId = null;
                                  _hoverIndex = null;
                                });
                              }
                              return;
                            }
                            if (_hoverParentId != parentId ||
                                _hoverIndex != index) {
                              setState(() {
                                _hoverParentId = parentId;
                                _hoverIndex = index;
                              });
                            }
                          },
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  List<_BinderNode> _buildVisibleTree(WritingModel book) {
    // Index children by parentId so we can do a quick depth-first walk.
    final byParent = <String?, List<SectionModel>>{};
    for (final s in book.sections) {
      byParent.putIfAbsent(s.parentId, () => <SectionModel>[]).add(s);
    }
    for (final list in byParent.values) {
      list.sort((a, b) => a.order.compareTo(b.order));
    }
    // Default folders to expanded the first time we lay them out so the
    // rail isn't a wall of collapsed top-level rows on a fresh open.
    // Chapters stay collapsed by default — Scrivener convention.
    for (final s in book.sections) {
      if (_seenFolderIds.contains(s.id)) continue;
      final isFolder = s.kind == SectionKind.folder ||
          s.kind == SectionKind.act ||
          s.kind == SectionKind.research ||
          s.kind == SectionKind.trash;
      if (isFolder) {
        _seenFolderIds.add(s.id);
        _expanded.add(s.id);
      }
    }
    final result = <_BinderNode>[];
    final searchOrFilterActive =
        _effectiveQuery().isNotEmpty || _labelFilter != null;
    void walk(String? parentId, int depth) {
      final kids = byParent[parentId] ?? const <SectionModel>[];
      for (final k in kids) {
        final isFolder = k.kind == SectionKind.folder ||
            k.kind == SectionKind.act ||
            k.kind == SectionKind.research ||
            k.kind == SectionKind.trash;
        final hasChildren = (byParent[k.id]?.isNotEmpty ?? false);
        // While searching/filtering, force-walk every subtree so a deep
        // match keeps its ancestors on screen. Otherwise honor the user's
        // explicit expanded/collapsed state per row.
        final shouldExpand =
            searchOrFilterActive || _expanded.contains(k.id);
        if (!_matches(k)) {
          // Even if the node is filtered out, we still descend if its
          // subtree might contain a match. Add the parent only if a
          // descendant match was added.
          final saved = result.length;
          if (shouldExpand) {
            walk(k.id, depth + 1);
          }
          if (result.length > saved) {
            result.insert(
                saved,
                _BinderNode(
                  section: k,
                  depth: depth,
                  isFolder: isFolder,
                  hasChildren: hasChildren,
                ));
          }
          continue;
        }
        result.add(_BinderNode(
          section: k,
          depth: depth,
          isFolder: isFolder,
          hasChildren: hasChildren,
        ));
        if (shouldExpand) {
          walk(k.id, depth + 1);
        }
      }
    }
    walk(null, 0);
    return result;
  }

  bool _matches(SectionModel s) {
    if (_labelFilter != null && s.labelColor != _labelFilter) {
      return false;
    }
    if (_effectiveQuery().isEmpty) return true;
    final q = _effectiveQuery().toLowerCase();
    if (s.title.toLowerCase().contains(q)) return true;
    for (final k in s.keywords) {
      if (k.toLowerCase().contains(q)) return true;
    }
    if (s.synopsis.toLowerCase().contains(q)) return true;
    return false;
  }

  void _selectSection(EditorProvider provider, SectionModel section) {
    final isFolder = section.kind == SectionKind.folder ||
        section.kind == SectionKind.act ||
        section.kind == SectionKind.research ||
        section.kind == SectionKind.trash;
    if (isFolder) {
      setState(() {
        if (!_expanded.add(section.id)) {
          _expanded.remove(section.id);
        }
      });
      return;
    }
    if (provider.activeSection?.id == section.id) return;
    provider.forceSaveImmediately();
    provider.setActiveSection(section);
    provider.initEditor();
    widget.onItemTap?.call();
  }

  Future<void> _addChapter(EditorProvider provider) async {
    final title = await _promptText(
      context,
      'New chapter',
      'Untitled chapter',
    );
    if (title == null || title.trim().isEmpty) return;
    provider.addSection(title.trim(), kind: SectionKind.chapter);
  }

  Future<void> _addChild(EditorProvider provider, SectionModel parent) async {
    final defaultKind = parent.kind == SectionKind.chapter
        ? SectionKind.scene
        : SectionKind.chapter;
    final title = await _promptText(
      context,
      defaultKind == SectionKind.scene ? 'New scene' : 'New chapter',
      defaultKind == SectionKind.scene ? 'Untitled scene' : 'Untitled chapter',
    );
    if (title == null || title.trim().isEmpty) return;
    setState(() => _expanded.add(parent.id));
    provider.addSection(
      title.trim(),
      parentId: parent.id,
      kind: defaultKind,
    );
  }

  Future<void> _rename(EditorProvider provider, SectionModel section) async {
    final renamed = await _promptText(
      context,
      'Rename',
      section.title,
      initial: section.title,
    );
    if (renamed == null || renamed.trim().isEmpty) return;
    await provider.renameSection(section, renamed.trim());
  }

  Future<void> _delete(EditorProvider provider, SectionModel section) async {
    if (section.kind == SectionKind.folder ||
        section.kind == SectionKind.research ||
        section.kind == SectionKind.trash) {
      // Top-level scaffolding folders are not deletable.
      return;
    }
    final isInTrash = provider.activeBook != null &&
        _isUnderTrash(provider.activeBook!, section);
    final action = isInTrash ? 'Delete permanently' : 'Move to Trash';
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialogCtx) => CupertinoAlertDialog(
        title: const Text('Delete'),
        content: Text('$action "${section.title}"?'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: Text(action),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await provider.deleteSection(section);
  }

  bool _isUnderTrash(WritingModel book, SectionModel section) {
    final byId = {for (final s in book.sections) s.id: s};
    var current = section.parentId;
    while (current != null) {
      final node = byId[current];
      if (node == null) return false;
      if (node.kind == SectionKind.trash) return true;
      current = node.parentId;
    }
    return false;
  }

  Future<void> _setLabel(
    EditorProvider provider,
    SectionModel section,
    int? color,
  ) async {
    await provider.updateSectionFields(section, {'label_color': color});
  }

  Future<void> _handleDrop(
    EditorProvider provider,
    SectionModel dragged,
    _BinderNode target,
    _DropPosition position,
  ) async {
    if (dragged.id == target.section.id) return;
    setState(() {
      _hoverParentId = null;
      _hoverIndex = null;
    });
    String? newParentId;
    int newIndex;
    if (position == _DropPosition.into && target.isFolder) {
      newParentId = target.section.id;
      newIndex = 1 << 30;
      setState(() => _expanded.add(target.section.id));
    } else {
      newParentId = target.section.parentId;
      final siblings = (provider.activeBook?.sections ?? const <SectionModel>[])
          .where((s) => s.id != dragged.id && s.parentId == newParentId)
          .toList()
        ..sort((a, b) => a.order.compareTo(b.order));
      final targetIdx = siblings.indexWhere((s) => s.id == target.section.id);
      newIndex = position == _DropPosition.before ? targetIdx : targetIdx + 1;
      if (newIndex < 0) newIndex = 0;
    }
    await provider.moveSection(
      dragged,
      newParentId: newParentId,
      newIndex: newIndex,
    );
  }
}

Future<String?> _promptText(
  BuildContext context,
  String title,
  String hint, {
  String initial = '',
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showCupertinoDialog<String>(
    context: context,
    builder: (dialogCtx) => CupertinoAlertDialog(
      title: Text(title),
      content: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: CupertinoTextField(
          controller: controller,
          autofocus: true,
          placeholder: hint,
          onSubmitted: (v) => Navigator.pop(dialogCtx, v),
        ),
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(dialogCtx),
          child: const Text('Cancel'),
        ),
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(dialogCtx, controller.text),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  return result;
}

enum _DropPosition { before, after, into }

class _BinderNode {
  _BinderNode({
    required this.section,
    required this.depth,
    required this.isFolder,
    required this.hasChildren,
  });
  final SectionModel section;
  final int depth;
  final bool isFolder;
  final bool hasChildren;
}

class _BinderHeader extends StatelessWidget {
  const _BinderHeader({
    required this.book,
    required this.isDark,
    required this.textColor,
    required this.onAddChapter,
  });

  final WritingModel book;
  final bool isDark;
  final Color textColor;
  final VoidCallback onAddChapter;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              book.title.isEmpty ? 'Untitled' : book.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: textColor.withValues(alpha: 0.65),
                letterSpacing: 0.4,
              ),
            ),
          ),
          IconButton(
            tooltip: 'New chapter',
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            icon: Icon(CupertinoIcons.plus, color: textColor.withValues(alpha: 0.65)),
            onPressed: onAddChapter,
          ),
          Builder(
            builder: (ctx) => IconButton(
              tooltip: 'Project settings',
              visualDensity: VisualDensity.compact,
              iconSize: 14,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 28, height: 28),
              icon: Icon(CupertinoIcons.settings,
                  color: textColor.withValues(alpha: 0.55)),
              onPressed: () => ProjectSettingsDialog.show(ctx),
            ),
          ),
        ],
      ),
    );
  }
}

class _BinderRow extends StatelessWidget {
  const _BinderRow({
    super.key,
    required this.node,
    required this.isActive,
    required this.isExpanded,
    required this.actionsExpanded,
    required this.isDark,
    required this.textColor,
    required this.isHoverTarget,
    required this.onTap,
    required this.onToggleExpand,
    required this.onToggleActions,
    required this.onRename,
    required this.onDelete,
    required this.onSetLabel,
    required this.onAcceptDrop,
    required this.onHoverChange,
    this.onAddChild,
  });

  final _BinderNode node;
  final bool isActive;
  final bool isExpanded;
  final bool actionsExpanded;
  final bool isDark;
  final Color textColor;
  final bool isHoverTarget;
  final VoidCallback onTap;
  final VoidCallback onToggleExpand;
  final VoidCallback onToggleActions;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final ValueChanged<int?> onSetLabel;
  final void Function(SectionModel dragged, _DropPosition position) onAcceptDrop;
  final void Function(String? parentId, int? index) onHoverChange;
  final VoidCallback? onAddChild;

  @override
  Widget build(BuildContext context) {
    final section = node.section;
    final indent = 8 + node.depth * 14.0;
    final accent = isDark
        ? Colors.white.withValues(alpha: 0.07)
        : Colors.black.withValues(alpha: 0.05);
    final labelColor =
        section.labelColor != null ? Color(section.labelColor!) : null;
    return Padding(
      padding: EdgeInsets.only(left: indent, right: 6, top: 1, bottom: 1),
      child: DragTarget<SectionModel>(
        onWillAcceptWithDetails: (_) {
          onHoverChange(section.id, null);
          return true;
        },
        onLeave: (_) => onHoverChange(null, null),
        onAcceptWithDetails: (details) {
          onAcceptDrop(details.data,
              node.isFolder ? _DropPosition.into : _DropPosition.after);
        },
        builder: (context, candidate, _) {
          final highlight =
              candidate.isNotEmpty ? accent.withAlpha(120) : Colors.transparent;
          return LongPressDraggable<SectionModel>(
            data: section,
            delay: const Duration(milliseconds: 280),
            feedback: Material(
              color: Colors.transparent,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF1E1E1E)
                      : Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Text(
                  section.title.isEmpty ? 'Untitled' : section.title,
                  style: GoogleFonts.inter(fontSize: 12, color: textColor),
                ),
              ),
            ),
            childWhenDragging: Opacity(
              opacity: 0.4,
              child: _BinderRowSurface(
                section: section,
                isActive: false,
                isExpanded: isExpanded,
                isDark: isDark,
                textColor: textColor,
                node: node,
                labelColor: labelColor,
                background: Colors.transparent,
              ),
            ),
            child: GestureDetector(
              onSecondaryTap: onToggleActions,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Stack(
                    children: [
                      _BinderRowSurface(
                        section: section,
                        isActive: isActive,
                        isExpanded: isExpanded,
                        isDark: isDark,
                        textColor: textColor,
                        node: node,
                        labelColor: labelColor,
                        background: highlight,
                        actionsOpen: actionsExpanded,
                        onTap: onTap,
                        onToggleExpand: onToggleExpand,
                        onMoreTap: onToggleActions,
                      ),
                      if (isHoverTarget)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: Container(
                            height: 2,
                            color: Colors.blueAccent.withValues(alpha: 0.5),
                          ),
                        ),
                    ],
                  ),
                  if (actionsExpanded)
                    _InlineActionBar(
                      isDark: isDark,
                      textColor: textColor,
                      depth: node.depth,
                      canAddChild: onAddChild != null,
                      canDelete: section.kind != SectionKind.folder &&
                          section.kind != SectionKind.research &&
                          section.kind != SectionKind.trash,
                      onAddChild: () {
                        onToggleActions();
                        onAddChild?.call();
                      },
                      onRename: () {
                        onToggleActions();
                        onRename();
                      },
                      onSetLabel: () => _showLabelPicker(context),
                      onDelete: () {
                        onToggleActions();
                        onDelete();
                      },
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showLabelPicker(BuildContext context) async {
    final color = await _pickLabelColor(context);
    if (color == null) return;
    onSetLabel(color == 0 ? null : color);
    onToggleActions();
  }
}

/// Inline action bar that drops in below a binder row when its `⋯` is
/// tapped. Sits where a popup menu used to live — this version stays
/// inside the rail so the click feedback is local to the row.
class _InlineActionBar extends StatelessWidget {
  const _InlineActionBar({
    required this.isDark,
    required this.textColor,
    required this.depth,
    required this.canAddChild,
    required this.canDelete,
    required this.onAddChild,
    required this.onRename,
    required this.onSetLabel,
    required this.onDelete,
  });

  final bool isDark;
  final Color textColor;
  final int depth;
  final bool canAddChild;
  final bool canDelete;
  final VoidCallback onAddChild;
  final VoidCallback onRename;
  final VoidCallback onSetLabel;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final indent = 8 + depth * 14.0 + 18; // align under the row title
    final fillColor = isDark
        ? Colors.white.withValues(alpha: 0.04)
        : Colors.black.withValues(alpha: 0.025);
    return Padding(
      padding: EdgeInsets.fromLTRB(indent, 2, 8, 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        decoration: BoxDecoration(
          color: fillColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Wrap(
          spacing: 2,
          runSpacing: 2,
          children: [
            if (canAddChild)
              _action(
                icon: CupertinoIcons.plus,
                label: 'Add inside',
                onTap: onAddChild,
              ),
            _action(
              icon: CupertinoIcons.pencil,
              label: 'Rename',
              onTap: onRename,
            ),
            _action(
              icon: CupertinoIcons.tag,
              label: 'Label',
              onTap: onSetLabel,
            ),
            if (canDelete)
              _action(
                icon: CupertinoIcons.trash,
                label: 'Delete',
                onTap: onDelete,
                danger: true,
              ),
          ],
        ),
      ),
    );
  }

  Widget _action({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    final color = danger ? Colors.redAccent : textColor.withValues(alpha: 0.8);
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 5),
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<int?> _pickLabelColor(BuildContext context) async {
  const palette = <int>[
    0xFFE53935, // red
    0xFFFB8C00, // orange
    0xFFFFB300, // amber
    0xFF43A047, // green
    0xFF1E88E5, // blue
    0xFF8E24AA, // purple
    0xFF6D4C41, // brown
    0xFF546E7A, // slate
  ];
  return showCupertinoDialog<int>(
    context: context,
    builder: (dialogCtx) => CupertinoAlertDialog(
      title: const Text('Pick label'),
      content: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          alignment: WrapAlignment.center,
          children: [
            for (final color in palette)
              GestureDetector(
                onTap: () => Navigator.pop(dialogCtx, color),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: Color(color),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            GestureDetector(
              onTap: () => Navigator.pop(dialogCtx, 0),
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.grey),
                ),
                child: const Icon(CupertinoIcons.clear, size: 14),
              ),
            ),
          ],
        ),
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(dialogCtx),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
}

class _BinderRowSurface extends StatelessWidget {
  const _BinderRowSurface({
    required this.section,
    required this.isActive,
    required this.isExpanded,
    required this.isDark,
    required this.textColor,
    required this.node,
    required this.labelColor,
    required this.background,
    this.actionsOpen = false,
    this.onTap,
    this.onToggleExpand,
    this.onMoreTap,
  });

  final SectionModel section;
  final bool isActive;
  final bool isExpanded;
  final bool isDark;
  final Color textColor;
  final _BinderNode node;
  final Color? labelColor;
  final Color background;
  final bool actionsOpen;
  final VoidCallback? onTap;
  final VoidCallback? onToggleExpand;
  final VoidCallback? onMoreTap;

  @override
  Widget build(BuildContext context) {
    final accentBg = isActive
        ? (isDark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.black.withValues(alpha: 0.05))
        : Colors.transparent;
    final tintedBg = labelColor?.withValues(alpha: isDark ? 0.18 : 0.10) ??
        Colors.transparent;
    final iconColor = textColor.withValues(alpha: 0.55);
    return Material(
      color: background == Colors.transparent ? accentBg : background,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: tintedBg,
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          child: Row(
            children: [
              if (node.hasChildren)
                GestureDetector(
                  onTap: onToggleExpand,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Icon(
                      isExpanded
                          ? CupertinoIcons.chevron_down
                          : CupertinoIcons.chevron_right,
                      size: 11,
                      color: iconColor,
                    ),
                  ),
                )
              else
                const SizedBox(width: 14),
              const SizedBox(width: 4),
              Icon(
                _kindIcon(section.kind),
                size: 13,
                color: iconColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  section.title.isEmpty ? 'Untitled' : section.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 12.5,
                    fontWeight:
                        isActive ? FontWeight.w600 : FontWeight.w500,
                    color: textColor.withValues(alpha: isActive ? 1.0 : 0.85),
                  ),
                ),
              ),
              if (section.keywords.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Icon(CupertinoIcons.tag_fill,
                      size: 9, color: iconColor),
                ),
              if (onMoreTap != null)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 14,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints.tightFor(width: 22, height: 22),
                  icon: Icon(
                    actionsOpen
                        ? CupertinoIcons.chevron_up
                        : CupertinoIcons.ellipsis,
                    size: 13,
                    color: actionsOpen
                        ? textColor.withValues(alpha: 0.95)
                        : iconColor,
                  ),
                  onPressed: onMoreTap,
                ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _kindIcon(SectionKind kind) {
    switch (kind) {
      case SectionKind.folder:
        return CupertinoIcons.book;
      case SectionKind.act:
        return CupertinoIcons.square_stack;
      case SectionKind.chapter:
        return CupertinoIcons.doc_text;
      case SectionKind.scene:
        return CupertinoIcons.doc;
      case SectionKind.research:
        return CupertinoIcons.lightbulb;
      case SectionKind.trash:
        return CupertinoIcons.trash;
    }
  }
}

/// Suppress unused-import lint for HapticFeedback when running on web —
/// it's referenced by long-press feedback in some flavors but kept here
/// so future haptics are a one-liner.
// ignore: unused_element
void _kBinderHapticTouch() => HapticFeedback.selectionClick();

class _BinderSearchBar extends StatelessWidget {
  const _BinderSearchBar({
    required this.controller,
    required this.isDark,
    required this.textColor,
    required this.labelFilter,
    required this.onSearchChanged,
    required this.onLabelFilterChanged,
    required this.labelPalette,
  });

  final TextEditingController controller;
  final bool isDark;
  final Color textColor;
  final int? labelFilter;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<int?> onLabelFilterChanged;
  final Map<int, String> labelPalette;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 28,
            child: TextField(
              controller: controller,
              onChanged: onSearchChanged,
              style: GoogleFonts.inter(fontSize: 11, color: textColor),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 4),
                hintText: 'Filter (keyword:Daisy)',
                hintStyle: GoogleFonts.inter(
                  fontSize: 11,
                  color: textColor.withValues(alpha: 0.35),
                ),
                prefixIcon: Icon(
                  CupertinoIcons.search,
                  size: 12,
                  color: textColor.withValues(alpha: 0.45),
                ),
                prefixIconConstraints:
                    const BoxConstraints.tightFor(width: 24, height: 28),
                filled: true,
                fillColor: isDark
                    ? Colors.white.withValues(alpha: 0.04)
                    : Colors.black.withValues(alpha: 0.03),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          if (labelPalette.isNotEmpty) ...[
            const SizedBox(height: 6),
            SizedBox(
              height: 22,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: _filterChip(
                      'all',
                      null,
                      selected: labelFilter == null,
                    ),
                  ),
                  for (final entry in labelPalette.entries)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: _filterChip(
                        entry.value,
                        entry.key,
                        selected: labelFilter == entry.key,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _filterChip(String label, int? color, {required bool selected}) {
    final dot = color != null ? Color(color) : Colors.transparent;
    return GestureDetector(
      onTap: () => onLabelFilterChanged(color),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: selected
              ? (isDark
                  ? Colors.white.withValues(alpha: 0.1)
                  : Colors.black.withValues(alpha: 0.08))
              : Colors.transparent,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
              color: textColor.withValues(alpha: 0.18), width: 0.6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (color != null) ...[
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
              ),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 10,
                color: textColor.withValues(alpha: selected ? 1 : 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
