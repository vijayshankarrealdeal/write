import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:inkspacex/provider/editor_provider.dart';

// ─── Focus Mode: Exit Button (hover-aware, with ESC hint) ───
class FocusExitButton extends StatefulWidget {
  final bool isDark;
  final VoidCallback onTap;

  const FocusExitButton({
    super.key,
    required this.isDark,
    required this.onTap,
  });

  @override
  State<FocusExitButton> createState() => _FocusExitButtonState();
}

class _FocusExitButtonState extends State<FocusExitButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final base = widget.isDark ? Colors.white : Colors.black;
    final fg = base.withValues(alpha: _hover ? 0.85 : 0.35);
    final bg = base.withValues(alpha: _hover ? 0.08 : 0.03);
    final keyBg = base.withValues(alpha: _hover ? 0.12 : 0.06);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding:
              const EdgeInsets.fromLTRB(10, 6, 6, 6),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(CupertinoIcons.eye, size: 13, color: fg),
              const SizedBox(width: 6),
              Text(
                'Exit Focus',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  color: fg,
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: keyBg,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'ESC',
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: fg,
                    letterSpacing: 0.5,
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

// ─── Focus Mode: Subtle Word Counter (live, bottom-center) ───
class FocusWordCounter extends StatelessWidget {
  final bool isDark;
  final int sessionStart;

  const FocusWordCounter({
    super.key,
    required this.isDark,
    required this.sessionStart,
  });

  @override
  Widget build(BuildContext context) {
    final base = isDark ? Colors.white : Colors.black;
    return Selector<EditorProvider, QuillController>(
      selector: (_, p) => p.controller,
      builder: (context, controller, _) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final text = controller.document.toPlainText().trim();
          final words = text.isEmpty ? 0 : text.split(RegExp(r'\s+')).length;
          final session = words - sessionStart;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$words',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  color: base.withValues(alpha: 0.32),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                ' words',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  color: base.withValues(alpha: 0.22),
                ),
              ),
              if (session > 0) ...[
                Text(
                  '   ·   ',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: base.withValues(alpha: 0.15),
                  ),
                ),
                Text(
                  '+$session',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: Colors.green.withValues(alpha: 0.5),
                    fontWeight: FontWeight.w500,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                Text(
                  ' session',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: base.withValues(alpha: 0.22),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
