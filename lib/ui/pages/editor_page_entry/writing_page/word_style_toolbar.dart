import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'editor_constants.dart';
import 'grow_shrink_button.dart';
import 'toolbar_widgets.dart';

class WordStyleToolbar extends StatefulWidget {
  const WordStyleToolbar({
    super.key,
    required this.controller,
    required this.isDark,
    required this.textColor,
    required this.onToggleFindReplace,
    required this.findReplaceOpen,
  });

  final QuillController controller;
  final bool isDark;
  final Color textColor;
  final VoidCallback onToggleFindReplace;
  final bool findReplaceOpen;

  @override
  State<WordStyleToolbar> createState() => _WordStyleToolbarState();
}

class _WordStyleToolbarState extends State<WordStyleToolbar> {
  static const double _defaultSize = 12;

  // Cached last-valid selection — popups (font picker, font-size menu,
  // heading menu, colour swatch, link dialog) all steal focus, after
  // which `controller.selection` can come back invalid. formatSelection
  // is a no-op on an invalid selection, which is the bug where picking
  // a font / size / colour seems to do nothing on an empty doc.
  // We snapshot the last good selection here and restore it before
  // applying any format that runs after a popup.
  TextSelection? _lastValidSelection;

  // The user's most recent inline-style pick. flutter_quill clears its
  // toggledStyle whenever the selection changes, so without us caching
  // the pick here, picking a font / colour / mark and then clicking into
  // the writing area would silently revert the toolbar and the next
  // typed character. We keep the picks here and re-arm toggledStyle on
  // every selection change. Sticky behaviour: a pending value persists
  // until the user picks a different value or hits "clear formatting"
  // — typing or deleting alone does NOT clear it. This matches what the
  // user expects: switch to font B → type → delete → keep typing → all
  // still in font B until they explicitly switch again.
  //
  // Paragraph-break exception: _pendingColor / _pendingBackground are
  // cleared on Enter (see _onSelectionChanged). Heading size comes from
  // the h1/h2/h3 block style and never carries to the next paragraph;
  // letting an explicit colour pick carry while size resets felt
  // inconsistent (orange body text under a body-sized cursor). On Enter
  // we now reset colour/background so a fresh paragraph starts clean —
  // the user can re-pick if they want orange to continue.
  String? _pendingFont;
  double? _pendingSize;
  String? _pendingColor;       // hex including leading '#'
  String? _pendingBackground;  // hex including leading '#'
  // Inline marks (bold / italic / underline / strikeThrough / inlineCode):
  // attribute key -> desired on/off state. Absent key = no preference,
  // toolbar reflects the doc.
  final Map<String, bool> _pendingInline = {};
  bool _reapplyingPending = false;
  int _prevDocLength = 0;

  @override
  void initState() {
    super.initState();
    _prevDocLength = widget.controller.document.length;
    widget.controller.addListener(_onSelectionChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onSelectionChanged);
    super.dispose();
  }

  bool get _hasAnyPending =>
      _pendingFont != null ||
      _pendingSize != null ||
      _pendingColor != null ||
      _pendingBackground != null ||
      _pendingInline.isNotEmpty;

  void _onSelectionChanged() {
    if (_reapplyingPending) return;
    final sel = widget.controller.selection;
    if (sel.isValid) _lastValidSelection = sel;

    // Paragraph-break detection: doc grew (insert) and the caret now sits
    // immediately after a '\n'. That's Enter (or paste with a newline).
    // Drop sticky colour/background so the new paragraph starts clean —
    // matches heading size, which never carries because it's a block attr.
    final docLen = widget.controller.document.length;
    if (sel.isValid &&
        sel.isCollapsed &&
        docLen > _prevDocLength &&
        (_pendingColor != null || _pendingBackground != null)) {
      final caret = sel.baseOffset;
      if (caret > 0) {
        final text = widget.controller.document.toPlainText();
        if (caret <= text.length && text[caret - 1] == '\n') {
          _pendingColor = null;
          _pendingBackground = null;
        }
      }
    }
    _prevDocLength = docLen;

    if (sel.isValid && sel.isCollapsed && _hasAnyPending) {
      _reapplyPending();
    }

    if (mounted) setState(() {});
  }

  // Map an inline-mark attribute key to its base Attribute instance.
  Attribute? _inlineAttrByKey(String key) {
    if (key == Attribute.bold.key) return Attribute.bold;
    if (key == Attribute.italic.key) return Attribute.italic;
    if (key == Attribute.underline.key) return Attribute.underline;
    if (key == Attribute.strikeThrough.key) return Attribute.strikeThrough;
    if (key == Attribute.inlineCode.key) return Attribute.inlineCode;
    return null;
  }

  void _reapplyPending() {
    final attrs = widget.controller.getSelectionStyle().attributes;

    // For value-bearing attrs, mismatch = pending differs from current.
    // For mark attrs, mismatch = pending on/off differs from presence.
    final fontVal = attrs[Attribute.font.key]?.value;
    final sizeVal = attrs[Attribute.size.key]?.value?.toString();
    final colorVal = attrs[Attribute.color.key]?.value;
    final backgroundVal = attrs[Attribute.background.key]?.value;

    final needFont = _pendingFont != null && fontVal != _pendingFont;
    final needSize = _pendingSize != null &&
        sizeVal != _pendingSize!.toStringAsFixed(0);
    final needColor = _pendingColor != null && colorVal != _pendingColor;
    final needBackground =
        _pendingBackground != null && backgroundVal != _pendingBackground;

    final inlineMismatches = <(String, bool)>[];
    for (final entry in _pendingInline.entries) {
      final has = attrs.containsKey(entry.key);
      if (entry.value != has) {
        inlineMismatches.add((entry.key, entry.value));
      }
    }

    if (!needFont &&
        !needSize &&
        !needColor &&
        !needBackground &&
        inlineMismatches.isEmpty) {
      return;
    }

    _reapplyingPending = true;
    try {
      if (needFont) {
        widget.controller.formatSelection(
          Attribute.fromKeyValue(Attribute.font.key, _pendingFont!)!,
        );
      }
      if (needSize) {
        widget.controller.formatSelection(
          Attribute.fromKeyValue(
              Attribute.size.key, _pendingSize!.toStringAsFixed(0))!,
        );
      }
      if (needColor) {
        widget.controller.formatSelection(ColorAttribute(_pendingColor!));
      }
      if (needBackground) {
        widget.controller
            .formatSelection(BackgroundAttribute(_pendingBackground!));
      }
      for (final (key, on) in inlineMismatches) {
        final attr = _inlineAttrByKey(key);
        if (attr == null) continue;
        widget.controller
            .formatSelection(on ? attr : Attribute.clone(attr, null));
      }
    } finally {
      _reapplyingPending = false;
    }
  }

  // Restore the last good selection if the current one was invalidated
  // by a popup stealing focus. Without this, formatSelection becomes a
  // no-op and the toggledStyle never lands on the next typed character.
  void _ensureSelection() {
    final sel = widget.controller.selection;
    if (!sel.isValid && _lastValidSelection != null) {
      widget.controller
          .updateSelection(_lastValidSelection!, ChangeSource.local);
    }
  }

  // Find the start and end of the line/paragraph containing `offset`.
  // Returns (start, length). Empty doc → (0, 0).
  (int, int) _currentLineRange(int offset) {
    final text = widget.controller.document.toPlainText();
    if (text.isEmpty) return (0, 0);
    final clamped = offset.clamp(0, text.length);
    var start = clamped;
    while (start > 0 && text[start - 1] != '\n') {
      start--;
    }
    var end = clamped;
    while (end < text.length && text[end] != '\n') {
      end++;
    }
    return (start, end - start);
  }

  // Apply an inline attribute. With a real selection: format that range.
  // With a collapsed caret on a *blank* line: format the empty line so
  // the toggled style sticks reliably (no visible retroactive change).
  // With a collapsed caret on a *non-empty* line: only arm the toggled
  // style — do NOT rewrite the existing line text. Rewriting felt like
  // "all changed??" to users who expected the picker to affect what
  // they type next, not what's already on screen.
  void _applyInlineWithFallback(Attribute attribute) {
    _ensureSelection();
    final sel = widget.controller.selection;
    if (sel.isValid && !sel.isCollapsed) {
      widget.controller.formatSelection(attribute);
      return;
    }
    final caret = sel.isValid ? sel.baseOffset : 0;
    final (start, len) = _currentLineRange(caret);
    final plain = widget.controller.document.toPlainText();
    final lineText =
        len > 0 ? plain.substring(start, start + len) : '';
    final lineIsBlank = lineText.trim().isEmpty;
    if (lineIsBlank && len > 0) {
      widget.controller.formatText(start, len, attribute);
    }
    widget.controller.formatSelection(attribute);
  }

  String get _currentFontFamily {
    final attr =
        widget.controller.getSelectionStyle().attributes[Attribute.font.key];
    if (attr?.value is String && (attr!.value as String).isNotEmpty) {
      return attr.value as String;
    }
    return _pendingFont ?? 'Inter';
  }

  double get _currentFontSize {
    final attr =
        widget.controller.getSelectionStyle().attributes[Attribute.size.key];
    final raw = attr?.value;
    if (raw != null) {
      final parsed = double.tryParse(raw.toString());
      if (parsed != null) return parsed;
    }
    return _pendingSize ?? _defaultSize;
  }

  void _setFontFamily(String family) {
    _pendingFont = family;
    _applyInlineWithFallback(
      Attribute.fromKeyValue(Attribute.font.key, family)!,
    );
    setState(() {});
  }

  void _setFontSize(double size) {
    _pendingSize = size;
    _applyInlineWithFallback(
      Attribute.fromKeyValue(Attribute.size.key, size.toStringAsFixed(0))!,
    );
    setState(() {});
  }

  void _stepFontSize(int direction) {
    final current = _currentFontSize;
    int idx = wordFontSizes.indexWhere((s) => s >= current);
    if (idx < 0) idx = wordFontSizes.length - 1;
    if (direction > 0) {
      if (wordFontSizes[idx] == current && idx < wordFontSizes.length - 1) {
        idx++;
      } else if (wordFontSizes[idx] < current &&
          idx < wordFontSizes.length - 1) {
        idx++;
      }
    } else {
      if (wordFontSizes[idx] >= current && idx > 0) idx--;
    }
    _setFontSize(wordFontSizes[idx]);
  }

  bool _isInlineActive(Attribute attr) {
    // Pending overrides the run at the caret so the button reflects the
    // user's armed pick, not what happens to be under the cursor.
    final pending = _pendingInline[attr.key];
    if (pending != null) return pending;
    return widget.controller
        .getSelectionStyle()
        .attributes
        .containsKey(attr.key);
  }

  void _toggleInline(Attribute attr) {
    _ensureSelection();
    final next = !_isInlineActive(attr);
    _pendingInline[attr.key] = next;
    widget.controller
        .formatSelection(next ? attr : Attribute.clone(attr, null));
    setState(() {});
  }

  String? _currentListValue() {
    final attr =
        widget.controller.getSelectionStyle().attributes[Attribute.list.key];
    return attr?.value as String?;
  }

  void _toggleList(String value) {
    final current = _currentListValue();
    widget.controller.formatSelection(
      current == value
          ? Attribute.clone(Attribute.list, null)
          : Attribute.fromKeyValue(Attribute.list.key, value),
    );
    setState(() {});
  }

  String? _currentAlignValue() {
    final attr =
        widget.controller.getSelectionStyle().attributes[Attribute.align.key];
    return attr?.value as String?;
  }

  void _setAlign(String value) {
    final current = _currentAlignValue();
    widget.controller.formatSelection(
      current == value
          ? Attribute.clone(Attribute.align, null)
          : Attribute.fromKeyValue(Attribute.align.key, value),
    );
    setState(() {});
  }

  int _currentIndentLevel() {
    final attr =
        widget.controller.getSelectionStyle().attributes[Attribute.indent.key];
    final value = attr?.value;
    if (value is int) return value;
    return 0;
  }

  void _stepIndent(int direction) {
    final level = _currentIndentLevel();
    final next = level + direction;
    if (next <= 0) {
      widget.controller
          .formatSelection(Attribute.clone(Attribute.indent, null));
    } else {
      widget.controller.formatSelection(Attribute.getIndentLevel(next));
    }
    setState(() {});
  }

  void _clearFormatting() {
    final selection = widget.controller.selection;
    if (!selection.isValid) return;
    final attrs =
        widget.controller.getSelectionStyle().attributes.values.toList();
    for (final a in attrs) {
      widget.controller.formatSelection(Attribute.clone(a, null));
    }
    // Drop every caret-armed pick so "clear formatting" is a true reset.
    _pendingFont = null;
    _pendingSize = null;
    _pendingColor = null;
    _pendingBackground = null;
    _pendingInline.clear();
    setState(() {});
  }

  // ── Heading / paragraph style ──
  String get _currentHeadingLabel {
    final attrs = widget.controller.getSelectionStyle().attributes;
    final h = attrs[Attribute.header.key]?.value;
    if (h == 1) return 'Heading 1';
    if (h == 2) return 'Heading 2';
    if (h == 3) return 'Heading 3';
    return 'Body';
  }

  void _applyHeading(int? level) {
    _ensureSelection();
    if (level == null) {
      widget.controller
          .formatSelection(Attribute.clone(Attribute.header, null));
    } else if (level == 1) {
      widget.controller.formatSelection(Attribute.h1);
    } else if (level == 2) {
      widget.controller.formatSelection(Attribute.h2);
    } else if (level == 3) {
      widget.controller.formatSelection(Attribute.h3);
    }
    setState(() {});
  }

  // ── Color / highlight ──
  Color? _currentColorOf(Attribute<String?> attr) {
    final raw =
        widget.controller.getSelectionStyle().attributes[attr.key]?.value;
    if (raw is String && raw.isNotEmpty) return _hexToColor(raw);
    // Fall back to the caret-armed pick so the swatch reflects what the
    // next typed character will inherit, mirroring Word's behaviour.
    final pending = attr.key == Attribute.color.key
        ? _pendingColor
        : _pendingBackground;
    if (pending != null) return _hexToColor(pending);
    return null;
  }

  void _applyColor(Attribute<String?> attr, Color? color) {
    final isText = attr.key == Attribute.color.key;
    if (color == null) {
      _ensureSelection();
      widget.controller.formatSelection(Attribute.clone(attr, null));
      if (isText) {
        _pendingColor = null;
      } else {
        _pendingBackground = null;
      }
    } else {
      final hex = '#${_colorToHex(color)}';
      final next = isText ? ColorAttribute(hex) : BackgroundAttribute(hex);
      _applyInlineWithFallback(next);
      // Remember the pick so a subsequent click into the editor doesn't
      // wipe it (flutter_quill clears toggledStyle on every selection
      // change). _onSelectionChanged re-applies via _reapplyPending.
      if (isText) {
        _pendingColor = hex;
      } else {
        _pendingBackground = hex;
      }
    }
    setState(() {});
  }

  // ── Script (sub/super) ──
  String? _currentScript() {
    final attr = widget.controller
        .getSelectionStyle()
        .attributes[Attribute.script.key];
    return attr?.value as String?;
  }

  void _toggleScript(ScriptAttributes value) {
    final current = _currentScript();
    final target = value.value;
    if (current == target) {
      widget.controller
          .formatSelection(Attribute.clone(Attribute.script, null));
    } else {
      widget.controller.formatSelection(ScriptAttribute(value));
    }
    setState(() {});
  }

  // ── Link ──
  Future<void> _openLinkDialog() async {
    final selStyle = widget.controller.getSelectionStyle();
    final existing =
        selStyle.attributes[Attribute.link.key]?.value as String?;
    final selection = widget.controller.selection;
    String selectedText = '';
    if (selection.isValid && !selection.isCollapsed) {
      final start = math.min(selection.baseOffset, selection.extentOffset);
      final end = math.max(selection.baseOffset, selection.extentOffset);
      selectedText =
          widget.controller.document.getPlainText(start, end - start);
    }

    final result = await showDialog<LinkDialogResult>(
      context: context,
      builder: (ctx) => LinkDialog(
        initialText: selectedText,
        initialUrl: existing ?? '',
        canRemove: existing != null,
        isDark: widget.isDark,
      ),
    );
    if (result == null) return;
    if (result.remove) {
      widget.controller
          .formatSelection(Attribute.clone(Attribute.link, null));
      setState(() {});
      return;
    }
    final url = result.url.trim();
    if (url.isEmpty) return;
    if (selection.isCollapsed) {
      final insertText =
          result.text.trim().isEmpty ? url : result.text;
      final start = selection.baseOffset.clamp(
          0, widget.controller.document.length);
      widget.controller.replaceText(
        start,
        0,
        insertText,
        TextSelection.collapsed(offset: start + insertText.length),
      );
      widget.controller
          .formatText(start, insertText.length, LinkAttribute(url));
    } else {
      widget.controller.formatSelection(LinkAttribute(url));
    }
    setState(() {});
  }

  bool get _hasLink {
    return widget.controller
        .getSelectionStyle()
        .attributes
        .containsKey(Attribute.link.key);
  }

  @override
  Widget build(BuildContext context) {
    // Dropdown chrome: in dark mode, sit just barely above the toolbar bg
    // instead of the old 0xFF2A2D33 high-contrast slab. The tint reads as
    // an affordance, not as a separate surface fighting with the toolbar.
    final borderColor = widget.isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.10);
    final fillColor = widget.isDark
        ? Colors.white.withValues(alpha: 0.04)
        : Colors.black.withValues(alpha: 0.025);
    final accentColor = widget.isDark
        ? const Color(0xFF93B4F5)
        : const Color(0xFF5B8DEF);
    final activeBg = widget.isDark
        ? Colors.white.withValues(alpha: 0.08)
        : const Color(0xFFE3EBFB);

    final listValue = _currentListValue();
    final alignValue = _currentAlignValue();

    final clusterBg = widget.isDark
        ? Colors.white.withValues(alpha: 0.05)
        : Colors.black.withValues(alpha: 0.04);

    Widget cluster(List<Widget> children) => Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          decoration: BoxDecoration(
            color: clusterBg,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: children),
        );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── History ──
            cluster([
              UndoRedoButton(
                controller: widget.controller,
                undo: true,
                textColor: widget.textColor,
              ),
              UndoRedoButton(
                controller: widget.controller,
                undo: false,
                textColor: widget.textColor,
              ),
            ]),

            // ── Text (heading + font + size) ──
            cluster([
              HeadingMenu(
                controller: widget.controller,
                current: _currentHeadingLabel,
                borderColor: borderColor,
                fillColor: fillColor,
                textColor: widget.textColor,
                onSelected: _applyHeading,
              ),
              const SizedBox(width: 6),
              FontFamilyDropdown(
                controller: widget.controller,
                current: _currentFontFamily,
                items: editorFonts,
                borderColor: borderColor,
                fillColor: fillColor,
                textColor: widget.textColor,
                isDark: widget.isDark,
                onSelected: _setFontFamily,
              ),
              const SizedBox(width: 6),
              FontSizeDropdown(
                controller: widget.controller,
                current: _currentFontSize,
                items: wordFontSizes,
                borderColor: borderColor,
                fillColor: fillColor,
                textColor: widget.textColor,
                onSelected: _setFontSize,
              ),
              const SizedBox(width: 4),
              GrowShrinkButton(
                grow: true,
                textColor: widget.textColor,
                onPressed: () => _stepFontSize(1),
              ),
              GrowShrinkButton(
                grow: false,
                textColor: widget.textColor,
                onPressed: () => _stepFontSize(-1),
              ),
            ]),

            // ── Style (inline marks + color + link) ──
            cluster([
              FormatToggleButton(
                icon: Icons.format_bold,
                tooltip: 'Bold',
                isActive: _isInlineActive(Attribute.bold),
                textColor: widget.textColor,
                activeBg: activeBg,
                activeColor: accentColor,
                onPressed: () => _toggleInline(Attribute.bold),
              ),
              FormatToggleButton(
                icon: Icons.format_italic,
                tooltip: 'Italic',
                isActive: _isInlineActive(Attribute.italic),
                textColor: widget.textColor,
                activeBg: activeBg,
                activeColor: accentColor,
                onPressed: () => _toggleInline(Attribute.italic),
              ),
              FormatToggleButton(
                icon: Icons.format_underline,
                tooltip: 'Underline',
                isActive: _isInlineActive(Attribute.underline),
                textColor: widget.textColor,
                activeBg: activeBg,
                activeColor: accentColor,
                onPressed: () => _toggleInline(Attribute.underline),
              ),
              FormatToggleButton(
                icon: Icons.format_strikethrough,
                tooltip: 'Strikethrough',
                isActive: _isInlineActive(Attribute.strikeThrough),
                textColor: widget.textColor,
                activeBg: activeBg,
                activeColor: accentColor,
                onPressed: () => _toggleInline(Attribute.strikeThrough),
              ),
              FormatToggleButton(
                icon: Icons.code,
                tooltip: 'Inline code',
                isActive: _isInlineActive(Attribute.inlineCode),
                textColor: widget.textColor,
                activeBg: activeBg,
                activeColor: accentColor,
                onPressed: () => _toggleInline(Attribute.inlineCode),
              ),
              FormatToggleButton(
                icon: Icons.subscript,
                tooltip: 'Subscript',
                isActive: _currentScript() == ScriptAttributes.sub.value,
                textColor: widget.textColor,
                activeBg: activeBg,
                activeColor: accentColor,
                onPressed: () => _toggleScript(ScriptAttributes.sub),
              ),
              FormatToggleButton(
                icon: Icons.superscript,
                tooltip: 'Superscript',
                isActive: _currentScript() == ScriptAttributes.sup.value,
                textColor: widget.textColor,
                activeBg: activeBg,
                activeColor: accentColor,
                onPressed: () => _toggleScript(ScriptAttributes.sup),
              ),
              ColorSwatchButton(
                controller: widget.controller,
                icon: Icons.format_color_text,
                tooltip: 'Text color',
                currentColor: _currentColorOf(Attribute.color),
                textColor: widget.textColor,
                isDark: widget.isDark,
                onSelected: (c) => _applyColor(Attribute.color, c),
              ),
              ColorSwatchButton(
                controller: widget.controller,
                icon: Icons.format_color_fill,
                tooltip: 'Highlight',
                currentColor: _currentColorOf(Attribute.background),
                textColor: widget.textColor,
                isDark: widget.isDark,
                onSelected: (c) => _applyColor(Attribute.background, c),
              ),
              FormatToggleButton(
                icon: Icons.link,
                tooltip: 'Insert link',
                isActive: _hasLink,
                textColor: widget.textColor,
                activeBg: activeBg,
                activeColor: accentColor,
                onPressed: _openLinkDialog,
              ),
            ]),

            // ── Lists & indent ──
            cluster([
              FormatToggleButton(
                icon: Icons.format_list_bulleted,
                tooltip: 'Bulleted list',
                isActive: listValue == 'bullet',
                textColor: widget.textColor,
                activeBg: activeBg,
                activeColor: accentColor,
                onPressed: () => _toggleList('bullet'),
              ),
              FormatToggleButton(
                icon: Icons.format_list_numbered,
                tooltip: 'Numbered list',
                isActive: listValue == 'ordered',
                textColor: widget.textColor,
                activeBg: activeBg,
                activeColor: accentColor,
                onPressed: () => _toggleList('ordered'),
              ),
              FormatToggleButton(
                icon: Icons.checklist,
                tooltip: 'Checklist',
                isActive: listValue == 'unchecked' || listValue == 'checked',
                textColor: widget.textColor,
                activeBg: activeBg,
                activeColor: accentColor,
                onPressed: () => _toggleList('unchecked'),
              ),
              FormatToggleButton(
                icon: Icons.format_indent_decrease,
                tooltip: 'Decrease indent',
                isActive: false,
                textColor: widget.textColor,
                activeBg: activeBg,
                activeColor: accentColor,
                onPressed: () => _stepIndent(-1),
              ),
              FormatToggleButton(
                icon: Icons.format_indent_increase,
                tooltip: 'Increase indent',
                isActive: false,
                textColor: widget.textColor,
                activeBg: activeBg,
                activeColor: accentColor,
                onPressed: () => _stepIndent(1),
              ),
            ]),

            // ── Align ──
            cluster([
              FormatToggleButton(
                icon: Icons.format_align_left,
                tooltip: 'Align left',
                isActive: alignValue == null || alignValue == 'left',
                textColor: widget.textColor,
                activeBg: activeBg,
                activeColor: accentColor,
                onPressed: () => _setAlign('left'),
              ),
              FormatToggleButton(
                icon: Icons.format_align_center,
                tooltip: 'Align center',
                isActive: alignValue == 'center',
                textColor: widget.textColor,
                activeBg: activeBg,
                activeColor: accentColor,
                onPressed: () => _setAlign('center'),
              ),
              FormatToggleButton(
                icon: Icons.format_align_right,
                tooltip: 'Align right',
                isActive: alignValue == 'right',
                textColor: widget.textColor,
                activeBg: activeBg,
                activeColor: accentColor,
                onPressed: () => _setAlign('right'),
              ),
              FormatToggleButton(
                icon: Icons.format_align_justify,
                tooltip: 'Justify',
                isActive: alignValue == 'justify',
                textColor: widget.textColor,
                activeBg: activeBg,
                activeColor: accentColor,
                onPressed: () => _setAlign('justify'),
              ),
            ]),

            // ── Block + find ──
            cluster([
              FormatToggleButton(
                icon: Icons.format_quote,
                tooltip: 'Quote',
                isActive: _isInlineActive(Attribute.blockQuote),
                textColor: widget.textColor,
                activeBg: activeBg,
                activeColor: accentColor,
                onPressed: () => _toggleInline(Attribute.blockQuote),
              ),
              FormatToggleButton(
                icon: Icons.format_clear,
                tooltip: 'Clear formatting',
                isActive: false,
                textColor: widget.textColor,
                activeBg: activeBg,
                activeColor: accentColor,
                onPressed: _clearFormatting,
              ),
              FormatToggleButton(
                icon: Icons.search,
                tooltip: 'Find & Replace (Ctrl+F)',
                isActive: widget.findReplaceOpen,
                textColor: widget.textColor,
                activeBg: activeBg,
                activeColor: accentColor,
                onPressed: widget.onToggleFindReplace,
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

// ── Hex / Color helpers (local copy of flutter_quill internals) ──
Color _hexToColor(String? hexString) {
  if (hexString == null) return Colors.black;
  final hex = hexString.replaceAll('#', '');
  if (!RegExp(r'^([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$').hasMatch(hex)) {
    return Colors.black;
  }
  final buffer = StringBuffer();
  if (hex.length == 6) buffer.write('ff');
  buffer.write(hex);
  return Color(int.tryParse(buffer.toString(), radix: 16) ?? 0xFF000000);
}

String _colorToHex(Color color) {
  int toInt(double x) => (x * 255.0).round() & 0xff;
  final a = toInt(color.a);
  final r = toInt(color.r);
  final g = toInt(color.g);
  final b = toInt(color.b);
  return '${a.toRadixString(16).padLeft(2, '0')}'
          '${r.toRadixString(16).padLeft(2, '0')}'
          '${g.toRadixString(16).padLeft(2, '0')}'
          '${b.toRadixString(16).padLeft(2, '0')}'
      .toUpperCase();
}
