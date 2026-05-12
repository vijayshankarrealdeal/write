import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/models/book_character_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/ui/widgets/app_network_image.dart';
import 'package:inkspacex/ui/widgets/app_spinner.dart';

/// "Cast" strip rendered above the chapter list on the book detail
/// page. Designed for visual recognition: a compact row of overlapping
/// circular portraits with a "+N more" badge when the cast doesn't fit.
///
/// Lazy-loads via `/api/feed/{id}/characters`. Renders an empty
/// SizedBox when the book has no cast, so the parent can drop this
/// widget in unconditionally.
///
/// Interaction:
///  - Tap a portrait → push the character's detail page.
///  - Tap the "+N" badge or anywhere on the row → open a bottom sheet
///    listing the full cast with names + appearance previews.
class CastStrip extends StatefulWidget {
  const CastStrip({
    super.key,
    required this.feedItemId,
    required this.textColor,
    required this.subtleColor,
    required this.isDark,
    this.horizontalPadding = 20,
  });

  final String feedItemId;
  final Color textColor;
  final Color subtleColor;
  final bool isDark;
  final double horizontalPadding;

  @override
  State<CastStrip> createState() => _CastStripState();
}

class _CastStripState extends State<CastStrip> {
  static const int _maxVisibleAvatars = 5;
  static const double _avatarSize = 56;
  static const double _stride = 38; // overlap by (size - stride) px

  List<BookCharacterModel>? _cast;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    try {
      final cast = await context
          .read<AuthProvider>()
          .dataService
          .getFeedItemCharacters(widget.feedItemId);
      if (!mounted) return;
      setState(() {
        _cast = cast;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _cast = const [];
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      // Keep height stable on first paint so the chapter list doesn't
      // jump when the cast lands.
      return SizedBox(
        height: 100,
        child: Center(
          child: AppSpinner(size: 18, color: widget.subtleColor),
        ),
      );
    }
    final cast = _cast ?? const <BookCharacterModel>[];
    if (cast.isEmpty) return const SizedBox.shrink();

    // Compute the visible avatars vs the "+N more" slot.
    final fitsWithoutBadge = cast.length <= _maxVisibleAvatars;
    final visibleCount = fitsWithoutBadge ? cast.length : _maxVisibleAvatars - 1;
    final remaining = cast.length - visibleCount;
    final stackWidth = visibleCount * _stride
        + (remaining > 0 ? _stride : 0)
        + (_avatarSize - _stride);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        widget.horizontalPadding,
        12,
        widget.horizontalPadding,
        18,
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _openBottomSheet(cast),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Left: title + count
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Cast',
                    style: GoogleFonts.playfairDisplay(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: widget.textColor,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${cast.length} ${cast.length == 1 ? "character" : "characters"} · tap to view',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: widget.subtleColor,
                    ),
                  ),
                ],
              ),
            ),
            // Right: overlapping avatar stack
            SizedBox(
              width: stackWidth,
              height: _avatarSize,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  for (int i = 0; i < visibleCount; i++)
                    Positioned(
                      left: i * _stride,
                      top: 0,
                      child: _RingedAvatar(
                        character: cast[i],
                        size: _avatarSize,
                        ringColor: widget.isDark
                            ? const Color(0xFF0E0E12)
                            : Colors.white,
                        textColor: widget.textColor,
                        isDark: widget.isDark,
                        // Pass the full cast + the tapped index so the
                        // character page can render as a swipeable
                        // vertical PageView seeded on this character.
                        onTap: () => context.push(
                          '/character/${cast[i].id}',
                          extra: {'cast': cast, 'index': i},
                        ),
                      ),
                    ),
                  if (remaining > 0)
                    Positioned(
                      left: visibleCount * _stride,
                      top: 0,
                      child: _MoreBadge(
                        remaining: remaining,
                        size: _avatarSize,
                        ringColor: widget.isDark
                            ? const Color(0xFF0E0E12)
                            : Colors.white,
                        textColor: widget.textColor,
                        isDark: widget.isDark,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openBottomSheet(List<BookCharacterModel> cast) {
    final isDark = widget.isDark;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: isDark ? const Color(0xFF14141A) : Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => _CastListSheet(
        cast: cast,
        textColor: widget.textColor,
        subtleColor: widget.subtleColor,
        isDark: isDark,
      ),
    );
  }
}

/// One avatar in the overlapping stack — circular portrait with a
/// background-coloured ring so it visually "lifts" off the avatar to
/// its left.
class _RingedAvatar extends StatelessWidget {
  const _RingedAvatar({
    required this.character,
    required this.size,
    required this.ringColor,
    required this.textColor,
    required this.isDark,
    required this.onTap,
  });

  final BookCharacterModel character;
  final double size;
  final Color ringColor;
  final Color textColor;
  final bool isDark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hasImage =
        character.imageUrl != null && character.imageUrl!.isNotEmpty;
    final placeholderColor = isDark
        ? Colors.white.withValues(alpha: 0.10)
        : Colors.black.withValues(alpha: 0.06);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: ringColor,
          shape: BoxShape.circle,
          // Tiny 2px ring around the inner avatar matches the
          // page background so overlapping circles separate cleanly.
          border: Border.all(color: ringColor, width: 2),
        ),
        child: ClipOval(
          child: hasImage
              ? AppNetworkImage(
                  url: character.imageUrl,
                  meta: character.imageMeta,
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  // Portraits are head-to-knees full-body, so a centered
                  // circular crop lands on the torso. Anchor to top so
                  // the face fills the avatar.
                  alignment: Alignment.topCenter,
                )
              : Container(
                  color: placeholderColor,
                  alignment: Alignment.center,
                  child: Text(
                    _initials(character.name),
                    style: GoogleFonts.playfairDisplay(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: textColor,
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    if (parts.isEmpty) return '?';
    return parts.take(2).map((p) => p[0].toUpperCase()).join();
  }
}

class _MoreBadge extends StatelessWidget {
  const _MoreBadge({
    required this.remaining,
    required this.size,
    required this.ringColor,
    required this.textColor,
    required this.isDark,
  });

  final int remaining;
  final double size;
  final Color ringColor;
  final Color textColor;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final fill = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.05);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: ringColor,
        shape: BoxShape.circle,
        border: Border.all(color: ringColor, width: 2),
      ),
      child: Container(
        decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
        alignment: Alignment.center,
        child: Text(
          '+$remaining',
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: textColor,
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet that lists every character with their portrait, name,
/// and a one-line appearance preview. Reached by tapping the cast
/// strip or its "+N" badge.
class _CastListSheet extends StatelessWidget {
  const _CastListSheet({
    required this.cast,
    required this.textColor,
    required this.subtleColor,
    required this.isDark,
  });

  final List<BookCharacterModel> cast;
  final Color textColor;
  final Color subtleColor;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.72;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 10, 0, 6),
            child: Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.18)
                    : Colors.black.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 16),
            child: Row(
              children: [
                Text(
                  'Cast',
                  style: GoogleFonts.playfairDisplay(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: textColor,
                    letterSpacing: -0.3,
                  ),
                ),
                const Spacer(),
                Text(
                  '${cast.length}',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: subtleColor,
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              shrinkWrap: true,
              itemCount: cast.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final character = cast[index];
                return _CastListRow(
                  character: character,
                  textColor: textColor,
                  subtleColor: subtleColor,
                  isDark: isDark,
                  onTap: () {
                    Navigator.of(context).pop();
                    // Push with the full cast so the character page
                    // is swipeable from this entry point too.
                    context.push(
                      '/character/${character.id}',
                      extra: {'cast': cast, 'index': index},
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CastListRow extends StatelessWidget {
  const _CastListRow({
    required this.character,
    required this.textColor,
    required this.subtleColor,
    required this.isDark,
    required this.onTap,
  });

  final BookCharacterModel character;
  final Color textColor;
  final Color subtleColor;
  final bool isDark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const avatarSize = 52.0;
    final hasImage =
        character.imageUrl != null && character.imageUrl!.isNotEmpty;
    final placeholderColor = isDark
        ? Colors.white.withValues(alpha: 0.10)
        : Colors.black.withValues(alpha: 0.06);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            ClipOval(
              child: SizedBox(
                width: avatarSize,
                height: avatarSize,
                child: hasImage
                    ? AppNetworkImage(
                        url: character.imageUrl,
                        meta: character.imageMeta,
                        width: avatarSize,
                        height: avatarSize,
                        fit: BoxFit.cover,
                        alignment: Alignment.topCenter,
                      )
                    : Container(
                        color: placeholderColor,
                        alignment: Alignment.center,
                        child: Text(
                          _initials(character.name),
                          style: GoogleFonts.playfairDisplay(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: textColor,
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    character.name,
                    style: GoogleFonts.playfairDisplay(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    character.appearance,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 12.5,
                      height: 1.4,
                      color: subtleColor,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: subtleColor, size: 20),
          ],
        ),
      ),
    );
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    if (parts.isEmpty) return '?';
    return parts.take(2).map((p) => p[0].toUpperCase()).join();
  }
}
