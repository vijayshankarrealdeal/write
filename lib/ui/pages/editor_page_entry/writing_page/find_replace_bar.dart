import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:google_fonts/google_fonts.dart';

class FindReplaceBar extends StatefulWidget {
  const FindReplaceBar({
    super.key,
    required this.controller,
    required this.isDark,
    required this.textColor,
    required this.borderColor,
    required this.bgColor,
    required this.onClose,
  });

  final QuillController controller;
  final bool isDark;
  final Color textColor;
  final Color borderColor;
  final Color bgColor;
  final VoidCallback onClose;

  @override
  State<FindReplaceBar> createState() => _FindReplaceBarState();
}

class _FindReplaceBarState extends State<FindReplaceBar> {
  final _findCtrl = TextEditingController();
  final _replaceCtrl = TextEditingController();
  final _findFocus = FocusNode();
  bool _showReplace = false;
  bool _caseSensitive = false;
  bool _wholeWord = false;
  List<int> _matches = const [];
  int _index = -1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _findFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _findCtrl.dispose();
    _replaceCtrl.dispose();
    _findFocus.dispose();
    super.dispose();
  }

  void _recompute() {
    final query = _findCtrl.text;
    if (query.isEmpty) {
      setState(() {
        _matches = const [];
        _index = -1;
      });
      return;
    }
    final found = widget.controller.document.search(
      query,
      caseSensitive: _caseSensitive,
      wholeWord: _wholeWord,
    );
    setState(() {
      _matches = found;
      _index = found.isEmpty ? -1 : 0;
    });
    if (_index >= 0) _select(_index);
  }

  void _select(int i) {
    if (i < 0 || i >= _matches.length) return;
    final start = _matches[i];
    final len = _findCtrl.text.length;
    widget.controller.updateSelection(
      TextSelection(baseOffset: start, extentOffset: start + len),
      ChangeSource.local,
    );
  }

  void _next() {
    if (_matches.isEmpty) return;
    setState(() => _index = (_index + 1) % _matches.length);
    _select(_index);
  }

  void _prev() {
    if (_matches.isEmpty) return;
    setState(() => _index = (_index - 1 + _matches.length) % _matches.length);
    _select(_index);
  }

  void _replaceOne() {
    if (_index < 0 || _matches.isEmpty) return;
    final start = _matches[_index];
    final len = _findCtrl.text.length;
    final repl = _replaceCtrl.text;
    widget.controller.replaceText(
      start,
      len,
      repl,
      TextSelection.collapsed(offset: start + repl.length),
    );
    _recompute();
  }

  void _replaceAll() {
    if (_matches.isEmpty) return;
    final len = _findCtrl.text.length;
    final repl = _replaceCtrl.text;
    // Replace from end to start so earlier offsets stay valid.
    for (var i = _matches.length - 1; i >= 0; i--) {
      widget.controller.replaceText(_matches[i], len, repl, null);
    }
    _recompute();
  }

  @override
  Widget build(BuildContext context) {
    final mutedColor = widget.textColor.withValues(alpha: 0.55);
    final fieldFill = widget.isDark
        ? Colors.white.withValues(alpha: 0.05)
        : Colors.black.withValues(alpha: 0.03);
    final countText = _matches.isEmpty
        ? (_findCtrl.text.isEmpty ? '' : 'No results')
        : '${_index + 1} of ${_matches.length}';

    Widget field({
      required TextEditingController controller,
      required String hint,
      required FocusNode? focus,
      ValueChanged<String>? onSubmitted,
    }) {
      return Container(
        height: 32,
        decoration: BoxDecoration(
          color: fieldFill,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: widget.textColor.withValues(alpha: 0.12),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: TextField(
          controller: controller,
          focusNode: focus,
          textAlignVertical: TextAlignVertical.center,
          onChanged: (_) {
            if (controller == _findCtrl) _recompute();
          },
          onSubmitted: onSubmitted,
          decoration: InputDecoration(
            border: InputBorder.none,
            isDense: true,
            contentPadding: EdgeInsets.zero,
            hintText: hint,
            hintStyle: GoogleFonts.inter(
              fontSize: 13,
              color: mutedColor,
              height: 1.2,
            ),
          ),
          style: GoogleFonts.inter(
            fontSize: 13,
            color: widget.textColor,
            height: 1.2,
          ),
        ),
      );
    }

    Widget iconBtn({
      required IconData icon,
      required String tooltip,
      VoidCallback? onTap,
      bool active = false,
    }) {
      return Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: onTap,
          child: Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active
                  ? widget.textColor.withValues(alpha: 0.08)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(
              icon,
              size: 17,
              color: onTap == null
                  ? widget.textColor.withValues(alpha: 0.25)
                  : widget.textColor.withValues(alpha: 0.85),
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: widget.bgColor,
        border: Border(
          bottom: BorderSide(color: widget.borderColor),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              iconBtn(
                icon: _showReplace
                    ? CupertinoIcons.chevron_down
                    : CupertinoIcons.chevron_right,
                tooltip:
                    _showReplace ? 'Hide replace' : 'Show replace',
                onTap: () =>
                    setState(() => _showReplace = !_showReplace),
              ),
              const SizedBox(width: 4),
              SizedBox(
                width: 240,
                child: field(
                  controller: _findCtrl,
                  hint: 'Find',
                  focus: _findFocus,
                  onSubmitted: (_) => _next(),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                countText,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: mutedColor,
                ),
              ),
              const Spacer(),
              iconBtn(
                icon: Icons.text_fields,
                tooltip: 'Match case',
                active: _caseSensitive,
                onTap: () {
                  setState(() => _caseSensitive = !_caseSensitive);
                  _recompute();
                },
              ),
              iconBtn(
                icon: Icons.abc,
                tooltip: 'Match whole word',
                active: _wholeWord,
                onTap: () {
                  setState(() => _wholeWord = !_wholeWord);
                  _recompute();
                },
              ),
              iconBtn(
                icon: CupertinoIcons.chevron_up,
                tooltip: 'Previous match',
                onTap: _matches.isEmpty ? null : _prev,
              ),
              iconBtn(
                icon: CupertinoIcons.chevron_down,
                tooltip: 'Next match',
                onTap: _matches.isEmpty ? null : _next,
              ),
              iconBtn(
                icon: CupertinoIcons.xmark,
                tooltip: 'Close (Esc)',
                onTap: widget.onClose,
              ),
            ],
          ),
          if (_showReplace) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const SizedBox(width: 34),
                SizedBox(
                  width: 240,
                  child: field(
                    controller: _replaceCtrl,
                    hint: 'Replace with',
                    focus: null,
                    onSubmitted: (_) => _replaceOne(),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _matches.isEmpty ? null : _replaceOne,
                  child: Text(
                    'Replace',
                    style: GoogleFonts.inter(fontSize: 12),
                  ),
                ),
                TextButton(
                  onPressed: _matches.isEmpty ? null : _replaceAll,
                  child: Text(
                    'Replace All',
                    style: GoogleFonts.inter(fontSize: 12),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
