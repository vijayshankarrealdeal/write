import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:inkspacex/services/font_history.dart';
import 'package:inkspacex/ui/editor/font_picker.dart';

class HeadingMenu extends StatelessWidget {
  const HeadingMenu({
    super.key,
    required this.controller,
    required this.current,
    required this.borderColor,
    required this.fillColor,
    required this.textColor,
    required this.onSelected,
  });

  final QuillController controller;
  final String current;
  final Color borderColor;
  final Color fillColor;
  final Color textColor;
  final ValueChanged<int?> onSelected;

  @override
  Widget build(BuildContext context) {
    final items = <(int?, String, double, FontWeight)>[
      (null, 'Body', 13, FontWeight.normal),
      (1, 'Heading 1', 20, FontWeight.w700),
      (2, 'Heading 2', 17, FontWeight.w700),
      (3, 'Heading 3', 14, FontWeight.w600),
    ];
    // Snapshot before the popup opens — same reason as ColorSwatchButton:
    // PopupMenuButton can collapse the controller's selection, which would
    // make Select-All → Heading apply to only the line under the cursor.
    TextSelection? snapshot;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => snapshot = controller.selection,
      child: PopupMenuButton<int?>(
        tooltip: 'Paragraph style',
        position: PopupMenuPosition.under,
        onSelected: (v) {
          final s = snapshot;
          if (s != null && s.isValid) {
            controller.updateSelection(s, ChangeSource.local);
          }
          onSelected(v);
        },
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        itemBuilder: (_) => items
            .map((it) => PopupMenuItem<int?>(
                  value: it.$1,
                  height: 38,
                  child: Text(
                    it.$2,
                    style: GoogleFonts.inter(
                      fontSize: it.$3,
                      fontWeight: it.$4,
                      color: textColor,
                    ),
                  ),
                ))
            .toList(),
        child: Container(
          height: 28,
          width: 110,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: fillColor,
            border: Border.all(color: borderColor),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  current,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: textColor),
                ),
              ),
              Icon(Icons.keyboard_arrow_down,
                  size: 16, color: textColor.withValues(alpha: 0.6)),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Undo / Redo ──
class UndoRedoButton extends StatefulWidget {
  const UndoRedoButton({
    super.key,
    required this.controller,
    required this.undo,
    required this.textColor,
  });

  final QuillController controller;
  final bool undo;
  final Color textColor;

  @override
  State<UndoRedoButton> createState() => _UndoRedoButtonState();
}

class _UndoRedoButtonState extends State<UndoRedoButton> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_listener);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_listener);
    super.dispose();
  }

  void _listener() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.undo
        ? widget.controller.hasUndo
        : widget.controller.hasRedo;
    return Tooltip(
      message: widget.undo ? 'Undo (Ctrl+Z)' : 'Redo (Ctrl+Y)',
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: enabled
            ? () {
                if (widget.undo) {
                  widget.controller.undo();
                } else {
                  widget.controller.redo();
                }
              }
            : null,
        child: Container(
          width: 30,
          height: 28,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          alignment: Alignment.center,
          child: Icon(
            widget.undo ? Icons.undo : Icons.redo,
            size: 17,
            color: widget.textColor.withValues(alpha: enabled ? 1 : 0.3),
          ),
        ),
      ),
    );
  }
}

// ── Color swatch picker (text color / highlight) ──
const List<Color> _swatchColors = <Color>[
  // Row 1 — neutrals
  Color(0xFF000000), Color(0xFF434343), Color(0xFF666666),
  Color(0xFF999999), Color(0xFFCCCCCC), Color(0xFFFFFFFF),
  // Row 2 — saturated
  Color(0xFFE53935), Color(0xFFFB8C00), Color(0xFFFDD835),
  Color(0xFF43A047), Color(0xFF1E88E5), Color(0xFF8E24AA),
  // Row 3 — pastels
  Color(0xFFFFCDD2), Color(0xFFFFE0B2), Color(0xFFFFF9C4),
  Color(0xFFC8E6C9), Color(0xFFBBDEFB), Color(0xFFE1BEE7),
];

class ColorSwatchButton extends StatelessWidget {
  const ColorSwatchButton({
    super.key,
    required this.controller,
    required this.icon,
    required this.tooltip,
    required this.currentColor,
    required this.textColor,
    required this.isDark,
    required this.onSelected,
  });

  final QuillController controller;
  final IconData icon;
  final String tooltip;
  final Color? currentColor;
  final Color textColor;
  final bool isDark;
  final ValueChanged<Color?> onSelected;

  @override
  Widget build(BuildContext context) {
    final indicator = currentColor ??
        (icon == Icons.format_color_text
            ? textColor
            : Colors.transparent);
    // Snapshot the selection on pointer-down — *before* the popup opens
    // and collapses controller.selection. Otherwise Select-All → pick
    // color falls back to current-line-only via _applyInlineWithFallback.
    TextSelection? snapshot;
    void restore() {
      final s = snapshot;
      if (s != null && s.isValid) {
        controller.updateSelection(s, ChangeSource.local);
      }
    }
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => snapshot = controller.selection,
      child: PopupMenuButton<int>(
        tooltip: tooltip,
        position: PopupMenuPosition.under,
        padding: EdgeInsets.zero,
        itemBuilder: (popupCtx) => [
          PopupMenuItem<int>(
            enabled: false,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: SizedBox(
              width: 188,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: () {
                      Navigator.pop(popupCtx);
                      restore();
                      onSelected(null);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          vertical: 6, horizontal: 4),
                      child: Row(
                        children: [
                          Icon(Icons.format_color_reset,
                              size: 16,
                              color: isDark ? Colors.white70 : Colors.black87),
                          const SizedBox(width: 8),
                          Text(
                            'Reset',
                            style: GoogleFonts.inter(
                              fontSize: 13,
                              color:
                                  isDark ? Colors.white70 : Colors.black87,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Divider(height: 10),
                  for (var row = 0; row < 3; row++)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          for (var col = 0; col < 6; col++)
                            GestureDetector(
                              onTap: () {
                                Navigator.pop(popupCtx);
                                restore();
                                onSelected(_swatchColors[row * 6 + col]);
                              },
                              child: Container(
                                width: 24,
                                height: 24,
                                margin: const EdgeInsets.all(2),
                                decoration: BoxDecoration(
                                  color: _swatchColors[row * 6 + col],
                                  borderRadius: BorderRadius.circular(3),
                                  border: Border.all(
                                      color: Colors.black.withValues(
                                          alpha: 0.15),
                                      width: 0.5),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
        child: SizedBox(
          width: 30,
          height: 28,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(icon, size: 17, color: textColor),
              Positioned(
                bottom: 3,
                left: 6,
                right: 6,
                child: Container(
                  height: 3,
                  decoration: BoxDecoration(
                    color: indicator,
                    borderRadius: BorderRadius.circular(1),
                    border: indicator == Colors.transparent
                        ? null
                        : Border.all(
                            color: Colors.black.withValues(alpha: 0.1),
                            width: 0.5),
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

// ── Insert / edit link dialog ──
class LinkDialogResult {
  const LinkDialogResult({
    required this.url,
    required this.text,
    required this.remove,
  });
  final String url;
  final String text;
  final bool remove;
}

class LinkDialog extends StatefulWidget {
  const LinkDialog({
    super.key,
    required this.initialText,
    required this.initialUrl,
    required this.canRemove,
    required this.isDark,
  });

  final String initialText;
  final String initialUrl;
  final bool canRemove;
  final bool isDark;

  @override
  State<LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<LinkDialog> {
  late final TextEditingController _urlCtrl;
  late final TextEditingController _textCtrl;

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController(text: widget.initialUrl);
    _textCtrl = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _textCtrl.dispose();
    super.dispose();
  }

  bool get _isValid {
    final v = _urlCtrl.text.trim();
    return v.isNotEmpty && Uri.tryParse(v) != null;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
      },
      child: AlertDialog(
      backgroundColor: isDark ? const Color(0xFF1C1C1E) : Colors.white,
      title: Text(
        widget.canRemove ? 'Edit Link' : 'Insert Link',
        style: GoogleFonts.inter(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: isDark ? Colors.white : Colors.black87,
        ),
      ),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _textCtrl,
              decoration: const InputDecoration(
                labelText: 'Text to display',
                isDense: true,
              ),
              style: GoogleFonts.inter(fontSize: 14),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _urlCtrl,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'URL',
                hintText: 'https://example.com',
                isDense: true,
              ),
              style: GoogleFonts.inter(fontSize: 14),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (_isValid) {
                  Navigator.pop(
                    context,
                    LinkDialogResult(
                      url: _urlCtrl.text,
                      text: _textCtrl.text,
                      remove: false,
                    ),
                  );
                }
              },
            ),
          ],
        ),
      ),
      actions: [
        if (widget.canRemove)
          TextButton(
            onPressed: () => Navigator.pop(
              context,
              const LinkDialogResult(url: '', text: '', remove: true),
            ),
            child: Text(
              'Remove',
              style: GoogleFonts.inter(color: Colors.redAccent),
            ),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'Cancel',
            style: GoogleFonts.inter(
              color: isDark ? Colors.white70 : Colors.black54,
            ),
          ),
        ),
        FilledButton(
          onPressed: _isValid
              ? () => Navigator.pop(
                    context,
                    LinkDialogResult(
                      url: _urlCtrl.text,
                      text: _textCtrl.text,
                      remove: false,
                    ),
                  )
              : null,
          child: Text(widget.canRemove ? 'Update' : 'Insert'),
        ),
      ],
      ),
    );
  }
}

class FormatToggleButton extends StatelessWidget {
  const FormatToggleButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.isActive,
    required this.textColor,
    required this.activeBg,
    required this.activeColor,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final bool isActive;
  final Color textColor;
  final Color activeBg;
  final Color activeColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onPressed,
        child: Container(
          width: 30,
          height: 28,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: isActive ? activeBg : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(
            icon,
            size: 17,
            color: isActive ? activeColor : textColor,
          ),
        ),
      ),
    );
  }
}

class FontFamilyDropdown extends StatelessWidget {
  const FontFamilyDropdown({
    super.key,
    required this.controller,
    required this.current,
    required this.items,
    required this.borderColor,
    required this.fillColor,
    required this.textColor,
    required this.isDark,
    required this.onSelected,
  });

  final QuillController controller;
  final String current;
  // Curated/popular fonts pinned at the top of the picker.
  final List<String> items;
  final Color borderColor;
  final Color fillColor;
  final Color textColor;
  final bool isDark;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    // Capture selection on pointer-down — *before* the dialog steals focus
    // and any focus listeners can clear controller.selection. Listener fires
    // ahead of InkWell.onTap, so by the time the picker opens we already
    // have a snapshot of where the cursor was.
    TextSelection? snapshot;
    return Tooltip(
      message: 'Font',
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => snapshot = controller.selection,
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () async {
            final picked = await showFontPicker(
              context,
              current: current,
              popular: items,
              isDark: isDark,
            );
            if (picked == null) return;
            if (snapshot != null && snapshot!.isValid) {
              controller.updateSelection(snapshot!, ChangeSource.local);
            }
            FontHistory.instance.add(picked);
            onSelected(picked);
          },
          child: Container(
            height: 28,
            width: 158,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: fillColor,
              border: Border.all(color: borderColor),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    current,
                    overflow: TextOverflow.ellipsis,
                    style: _safeFontStyle(current).copyWith(
                      fontSize: 13,
                      color: textColor,
                    ),
                  ),
                ),
                Icon(Icons.keyboard_arrow_down,
                    size: 16, color: textColor.withValues(alpha: 0.6)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  TextStyle _safeFontStyle(String name) {
    try {
      return GoogleFonts.getFont(name);
    } catch (_) {
      return const TextStyle();
    }
  }
}

class FontSizeDropdown extends StatelessWidget {
  const FontSizeDropdown({
    super.key,
    required this.controller,
    required this.current,
    required this.items,
    required this.borderColor,
    required this.fillColor,
    required this.textColor,
    required this.onSelected,
  });

  final QuillController controller;
  final double current;
  final List<double> items;
  final Color borderColor;
  final Color fillColor;
  final Color textColor;
  final ValueChanged<double> onSelected;

  @override
  Widget build(BuildContext context) {
    // Snapshot the selection on pointer-down — same fix as
    // ColorSwatchButton/HeadingMenu, so Select-All → font size doesn't
    // collapse to current-line-only via _applyInlineWithFallback.
    TextSelection? snapshot;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => snapshot = controller.selection,
      child: PopupMenuButton<double>(
        tooltip: 'Font size',
        position: PopupMenuPosition.under,
        onSelected: (v) {
          final s = snapshot;
          if (s != null && s.isValid) {
            controller.updateSelection(s, ChangeSource.local);
          }
          onSelected(v);
        },
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        itemBuilder: (_) => items
            .map((size) => PopupMenuItem<double>(
                  value: size,
                  height: 30,
                  child: Text(
                    size.toStringAsFixed(0),
                    style: const TextStyle(fontSize: 13),
                  ),
                ))
            .toList(),
        child: Container(
          height: 28,
          width: 54,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: fillColor,
            border: Border.all(color: borderColor),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  current.toStringAsFixed(0),
                  style: TextStyle(fontSize: 13, color: textColor),
                ),
              ),
              Icon(Icons.keyboard_arrow_down,
                  size: 16, color: textColor.withValues(alpha: 0.6)),
            ],
          ),
        ),
      ),
    );
  }
}
