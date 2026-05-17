import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:inkspacex/models/library_book_model.dart';

/// Small coloured pill that names a book's reading-state at a glance.
///
/// Used in:
///   * the Library page's grid cards (top-right corner overlay)
///   * the feed card "more" sheet to confirm what bucket a book is in
///
/// Hex codes intentionally mirror `app/badges.py` so a user who's seen
/// the Reader-tier chip on a profile reads the same colour vocabulary
/// here: green = achievement (Reader badge / Finished book), blue =
/// depth (Bookworm / Saved), amber = motion (Sage / Reading).
class BookLabelChip extends StatelessWidget {
  final BookLabel label;
  final bool compact;

  const BookLabelChip({
    super.key,
    required this.label,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = BookLabelStyle.color[label] ?? const Color(0xFF94A3B8);
    final text = BookLabelStyle.shortLabel[label] ?? '';

    if (compact) {
      // Pure dot — for dense lists where text would crowd the row.
      return Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.45), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            text,
            style: GoogleFonts.inter(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: color,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}
