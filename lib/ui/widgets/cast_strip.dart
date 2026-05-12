import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/models/book_character_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/ui/widgets/app_network_image.dart';
import 'package:inkspacex/ui/widgets/app_spinner.dart';

/// "Cast" strip rendered above the chapter list on the book detail
/// page. Each entry is a circular portrait + name; tapping opens the
/// character detail page.
///
/// Lazy-loads the cast from `/api/feed/{id}/characters`. Renders
/// nothing when the book has no cast (essays, landscape travelogues),
/// so the parent can drop this widget in unconditionally — it'll just
/// be a zero-height SizedBox in that case.
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
      // First paint: keep the strip's height stable so the chapter list
      // doesn't jump when the cast lands.
      return SizedBox(
        height: 132,
        child: Center(
          child: AppSpinner(size: 18, color: widget.subtleColor),
        ),
      );
    }
    final cast = _cast ?? const <BookCharacterModel>[];
    if (cast.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              widget.horizontalPadding,
              4,
              widget.horizontalPadding,
              10,
            ),
            child: Row(
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
                const Spacer(),
                Text(
                  '${cast.length} ${cast.length == 1 ? "character" : "characters"}',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: widget.subtleColor,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 116,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(
                horizontal: widget.horizontalPadding,
              ),
              itemCount: cast.length,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
              itemBuilder: (context, index) {
                final character = cast[index];
                return _CastAvatar(
                  character: character,
                  textColor: widget.textColor,
                  subtleColor: widget.subtleColor,
                  isDark: widget.isDark,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CastAvatar extends StatelessWidget {
  const _CastAvatar({
    required this.character,
    required this.textColor,
    required this.subtleColor,
    required this.isDark,
  });

  final BookCharacterModel character;
  final Color textColor;
  final Color subtleColor;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    const avatarSize = 76.0;
    final hasImage = character.imageUrl != null && character.imageUrl!.isNotEmpty;
    final placeholderColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => context.push(
        '/character/${character.id}',
        extra: character,
      ),
      child: SizedBox(
        width: 96,
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
                      )
                    : Container(
                        color: placeholderColor,
                        alignment: Alignment.center,
                        child: Text(
                          _initials(character.name),
                          style: GoogleFonts.playfairDisplay(
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                            color: textColor,
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              character.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                height: 1.2,
                color: textColor,
              ),
            ),
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
