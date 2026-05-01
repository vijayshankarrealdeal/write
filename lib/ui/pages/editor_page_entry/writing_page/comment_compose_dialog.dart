import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class CommentComposeDialog extends StatefulWidget {
  const CommentComposeDialog({
    super.key,
    required this.anchoredText,
    required this.isDark,
  });

  final String anchoredText;
  final bool isDark;

  @override
  State<CommentComposeDialog> createState() => _CommentComposeDialogState();
}

class _CommentComposeDialogState extends State<CommentComposeDialog> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final fg = isDark ? Colors.white : const Color(0xFF1A1A1F);
    final mutedFg = fg.withValues(alpha: 0.55);
    final bg = isDark ? const Color(0xFF1F2126) : Colors.white;
    final snippetBg = isDark
        ? Colors.white.withValues(alpha: 0.05)
        : Colors.black.withValues(alpha: 0.04);
    final preview = widget.anchoredText.length > 140
        ? '${widget.anchoredText.substring(0, 140)}…'
        : widget.anchoredText;

    return Dialog(
      backgroundColor: bg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Add comment',
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: snippetBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border(
                    left: BorderSide(
                        color: const Color(0xFFFFC857), width: 3),
                  ),
                ),
                child: Text(
                  preview,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: mutedFg,
                    fontStyle: FontStyle.italic,
                    height: 1.35,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _ctrl,
                focusNode: _focus,
                maxLines: 4,
                minLines: 3,
                style: GoogleFonts.inter(fontSize: 13, color: fg),
                decoration: InputDecoration(
                  hintText: 'Your comment…',
                  hintStyle:
                      GoogleFonts.inter(fontSize: 13, color: mutedFg),
                  filled: true,
                  fillColor: snippetBg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                ),
                onSubmitted: (v) {
                  if (v.trim().isNotEmpty) Navigator.pop(context, v);
                },
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text('Cancel',
                        style: GoogleFonts.inter(
                            fontSize: 13, color: mutedFg)),
                  ),
                  const SizedBox(width: 4),
                  ElevatedButton(
                    onPressed: () {
                      final body = _ctrl.text.trim();
                      if (body.isEmpty) return;
                      Navigator.pop(context, body);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4A6CF7),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                    ),
                    child: Text(
                      'Comment',
                      style: GoogleFonts.inter(
                          fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
