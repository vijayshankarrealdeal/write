import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:inkspacex/models/footnote_model.dart';
import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/ui/editor/footnote_embed_builder.dart';

/// A list-of-footnotes panel mounted inside the [SectionInspector].
///
/// The active section's footnotes drive the visible numbering: position
/// in this list ⇒ position in the prose. Editing a body, deleting an
/// entry, or dragging to reorder all funnel through [onChanged] which
/// the host wires to `EditorProvider.updateSectionFields(section, {
/// 'footnotes': next })`.
class FootnotesPanel extends StatefulWidget {
  const FootnotesPanel({
    super.key,
    required this.section,
    required this.isDark,
    required this.textColor,
    required this.borderColor,
    required this.onChanged,
    this.onJumpToMarker,
  });

  final SectionModel section;
  final bool isDark;
  final Color textColor;
  final Color borderColor;
  final void Function(List<FootnoteModel> next) onChanged;
  // Optional: if the host can scroll the editor to the inline marker for
  // a given footnote id, it can wire it here. Tapping a footnote row
  // then puts the caret next to the corresponding ¹.
  final void Function(String footnoteId)? onJumpToMarker;

  @override
  State<FootnotesPanel> createState() => _FootnotesPanelState();
}

class _FootnotesPanelState extends State<FootnotesPanel> {
  // One TextEditingController per footnote id. We hold them across
  // rebuilds so the focused field doesn't lose its caret on every
  // keystroke / reorder. Cleaned up when the corresponding footnote is
  // deleted or the panel disposes.
  final Map<String, TextEditingController> _controllers = {};
  // Track the section we last hydrated for so a section switch wipes
  // the per-id controllers (new section, new footnote ids).
  String? _trackedSectionId;

  @override
  void didUpdateWidget(covariant FootnotesPanel old) {
    super.didUpdateWidget(old);
    _hydrate();
  }

  @override
  void initState() {
    super.initState();
    _hydrate();
  }

  void _hydrate() {
    if (_trackedSectionId != widget.section.id) {
      for (final c in _controllers.values) {
        c.dispose();
      }
      _controllers.clear();
      _trackedSectionId = widget.section.id;
    }
    final liveIds = <String>{};
    for (final f in widget.section.footnotes) {
      liveIds.add(f.id);
      final existing = _controllers[f.id];
      if (existing == null) {
        _controllers[f.id] = TextEditingController(text: f.text);
      } else if (existing.text != f.text && !_isFocused(f.id)) {
        // Don't yank text from under the cursor: only sync external
        // changes (e.g. realtime push) into the field when it isn't
        // currently focused for editing.
        existing.text = f.text;
      }
    }
    final stale = _controllers.keys.where((k) => !liveIds.contains(k)).toList();
    for (final id in stale) {
      _controllers.remove(id)?.dispose();
    }
  }

  bool _isFocused(String id) {
    final c = _controllers[id];
    if (c == null) return false;
    return _focusedControllers.contains(c);
  }

  // We use FocusNode-per-row to know which TextEditingController has
  // focus without pulling a global FocusManager — keeps the helper
  // self-contained.
  final Set<TextEditingController> _focusedControllers = <TextEditingController>{};

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onTextChanged(String id, String value) {
    final next = List<FootnoteModel>.from(widget.section.footnotes);
    final idx = next.indexWhere((f) => f.id == id);
    if (idx < 0) return;
    next[idx] = next[idx].copyWith(text: value);
    widget.onChanged(next);
  }

  void _delete(String id) {
    final next = [for (final f in widget.section.footnotes) if (f.id != id) f];
    widget.onChanged(next);
  }

  void _reorder(int oldIndex, int newIndex) {
    final next = List<FootnoteModel>.from(widget.section.footnotes);
    if (oldIndex < newIndex) newIndex -= 1;
    if (oldIndex < 0 ||
        oldIndex >= next.length ||
        newIndex < 0 ||
        newIndex >= next.length) {
      return;
    }
    final item = next.removeAt(oldIndex);
    next.insert(newIndex, item);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final mutedFg = widget.textColor.withValues(alpha: 0.55);
    final footnotes = widget.section.footnotes;
    if (footnotes.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          'No footnotes in this section yet. Place the cursor in the prose '
          'and tap the footnote button in the toolbar to insert one.',
          style: GoogleFonts.inter(
            fontSize: 12,
            color: mutedFg,
            height: 1.45,
          ),
        ),
      );
    }
    return ReorderableListView.builder(
      shrinkWrap: true,
      buildDefaultDragHandles: false,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: footnotes.length,
      onReorder: _reorder,
      itemBuilder: (context, i) {
        final f = footnotes[i];
        final n = i + 1;
        final controller = _controllers[f.id]!;
        return _FootnoteRow(
          key: ValueKey('fn-row-${f.id}'),
          index: n,
          controller: controller,
          mutedFg: mutedFg,
          textColor: widget.textColor,
          borderColor: widget.borderColor,
          isDark: widget.isDark,
          onChanged: (v) => _onTextChanged(f.id, v),
          onDelete: () => _delete(f.id),
          onJump: widget.onJumpToMarker == null
              ? null
              : () => widget.onJumpToMarker!(f.id),
          onFocusChange: (focused) {
            if (focused) {
              _focusedControllers.add(controller);
            } else {
              _focusedControllers.remove(controller);
            }
          },
          rowIndex: i,
        );
      },
    );
  }
}

class _FootnoteRow extends StatelessWidget {
  const _FootnoteRow({
    super.key,
    required this.index,
    required this.controller,
    required this.mutedFg,
    required this.textColor,
    required this.borderColor,
    required this.isDark,
    required this.onChanged,
    required this.onDelete,
    required this.onFocusChange,
    required this.rowIndex,
    this.onJump,
  });

  final int index;
  final TextEditingController controller;
  final Color mutedFg;
  final Color textColor;
  final Color borderColor;
  final bool isDark;
  final ValueChanged<String> onChanged;
  final VoidCallback onDelete;
  final VoidCallback? onJump;
  final ValueChanged<bool> onFocusChange;
  final int rowIndex;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.04)
              : Colors.black.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: borderColor.withValues(alpha: 0.4)),
        ),
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ReorderableDragStartListener(
              index: rowIndex,
              child: Padding(
                padding: const EdgeInsets.only(top: 4, right: 4),
                child: Icon(
                  CupertinoIcons.line_horizontal_3,
                  size: 14,
                  color: mutedFg,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6, right: 6),
              child: Text(
                toSuperscript(index),
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                ),
              ),
            ),
            Expanded(
              child: Focus(
                onFocusChange: onFocusChange,
                child: TextField(
                  controller: controller,
                  minLines: 1,
                  maxLines: 6,
                  onChanged: onChanged,
                  style: GoogleFonts.inter(
                    fontSize: 12.5,
                    height: 1.4,
                    color: textColor,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Footnote text…',
                    hintStyle: GoogleFonts.inter(
                      fontSize: 12,
                      color: mutedFg.withValues(alpha: 0.6),
                    ),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onJump != null)
                  IconButton(
                    tooltip: 'Jump to marker',
                    icon: Icon(CupertinoIcons.arrow_turn_up_left,
                        size: 14, color: mutedFg),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                    onPressed: onJump,
                  ),
                IconButton(
                  tooltip: 'Delete footnote',
                  icon: Icon(CupertinoIcons.trash,
                      size: 14, color: Colors.redAccent.withValues(alpha: 0.85)),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: onDelete,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
