import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:inkspacex/services/api/api_data_service.dart';

/// Tier chip — small accent pill that surfaces a reader/writer badge
/// next to a user's name. Compact mode (icon + label) renders in
/// search results and follower lists; full mode (icon + label + tap to
/// reveal next-tier progress) renders on the profile header.
class UserBadgeChip extends StatelessWidget {
  final UserBadge badge;
  final bool compact;
  final VoidCallback? onTap;
  const UserBadgeChip({
    super.key,
    required this.badge,
    this.compact = true,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = parseHex(badge.colorHex);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = color.withValues(alpha: isDark ? 0.16 : 0.10);
    final border = color.withValues(alpha: 0.45);
    final glyph = _iconFor(badge.icon);
    final pad = compact
        ? const EdgeInsets.symmetric(horizontal: 8, vertical: 3)
        : const EdgeInsets.symmetric(horizontal: 10, vertical: 5);
    final fontSize = compact ? 11.0 : 12.5;
    final iconSize = compact ? 11.0 : 13.0;
    final pill = Container(
      padding: pad,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(glyph, size: iconSize, color: color),
          const SizedBox(width: 5),
          Text(
            badge.label,
            style: GoogleFonts.inter(
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              color: color,
              height: 1.1,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return pill;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: pill,
    );
  }

  static Color parseHex(String hex) {
    var s = hex.replaceFirst('#', '');
    if (s.length == 6) s = 'FF$s';
    return Color(int.parse(s, radix: 16));
  }

  // Backend ships a small set of icon keys; new keys can be added
  // without a client update because unknowns fall back to a star.
  static IconData _iconFor(String key) {
    switch (key) {
      case 'feather':
        return CupertinoIcons.pencil_outline;
      case 'leaf':
        return CupertinoIcons.leaf_arrow_circlepath;
      case 'book':
        return CupertinoIcons.book;
      case 'quill':
        return CupertinoIcons.pencil_ellipsis_rectangle;
      case 'crown':
        return CupertinoIcons.star_circle_fill;
      case 'spark':
        return CupertinoIcons.sparkles;
      case 'bookmark':
        return CupertinoIcons.bookmark_fill;
      case 'books':
        return CupertinoIcons.collections;
      case 'graduation':
        return CupertinoIcons.book_solid;
      case 'owl':
        return CupertinoIcons.eye_solid;
      default:
        return CupertinoIcons.star_fill;
    }
  }
}

/// Bottom-sheet card that explains the badge and shows progress to the
/// next tier. Triggered from the profile-header chip — the goal is to
/// turn the badge from "label" into "ladder you can see climbing."
void showBadgeDetailSheet(
  BuildContext context, {
  required UserBadge badge,
  required bool isSelf,
}) {
  final color = UserBadgeChip.parseHex(badge.colorHex);
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final bg = isDark ? const Color(0xFF111114) : Colors.white;
  final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
  final subtle = textColor.withValues(alpha: 0.55);
  showModalBottomSheet(
    context: context,
    backgroundColor: bg,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              UserBadgeChip(badge: badge, compact: false),
              const SizedBox(width: 10),
              Text(
                badge.track == 'writer' ? 'Writer tier' : 'Reader tier',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: subtle,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            _flavor(badge),
            style: GoogleFonts.inter(
              fontSize: 14,
              color: textColor,
              height: 1.45,
            ),
          ),
          if (badge.nextLabel != null) ...[
            const SizedBox(height: 18),
            Text(
              isSelf
                  ? 'Next: ${badge.nextLabel}'
                  : '${badge.nextLabel} is the next rung',
              style: GoogleFonts.inter(
                fontSize: 13,
                color: subtle,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: (badge.nextProgress ?? 0).clamp(0.0, 1.0),
                minHeight: 6,
                backgroundColor: color.withValues(alpha: 0.12),
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

String _flavor(UserBadge b) {
  if (b.track == 'writer') {
    switch (b.slug) {
      case 'novice':
        return 'Just getting started — publish your first story to climb to Contributor.';
      case 'contributor':
        return 'You\'ve shipped your first piece. Keep writing, and earn likes from other readers to reach Storyteller.';
      case 'storyteller':
        return 'Five stories deep with real reader love. Author tier rewards consistency and a growing audience.';
      case 'author':
        return 'Established voice with a real following. Master tier is reserved for the most prolific, most-loved writers.';
      case 'master':
        return 'Top of the writing track. Your work moves the platform.';
    }
  } else {
    switch (b.slug) {
      case 'curious':
        return 'New to the library — finish your first read to become a Reader.';
      case 'reader':
        return 'You\'re building the reading habit. Highlight passages you love to deepen your craft.';
      case 'bookworm':
        return 'Reading deeply now. Scholar rewards range — across genres and authors.';
      case 'scholar':
        return 'Voracious. Sage is the apex — given to readers who shape what others discover.';
      case 'sage':
        return 'Top of the reading track. The library is yours.';
    }
  }
  return '';
}
