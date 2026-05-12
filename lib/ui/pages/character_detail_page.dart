import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/models/book_character_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/ui/widgets/app_network_image.dart';
import 'package:inkspacex/ui/widgets/app_spinner.dart';

/// Full-bleed character page reached by tapping a cast-strip avatar
/// on the book detail page.
///
/// Renders the larger portrait (when available) plus the scout's
/// one-line appearance description and the character's name. Pushed
/// with the [BookCharacterModel] as `extra` so the page paints
/// instantly from the strip's payload — the page re-fetches the
/// detail by id in the background to pick up any later edits or to
/// hydrate when the user landed via deep link.
class CharacterDetailPage extends StatefulWidget {
  const CharacterDetailPage({
    super.key,
    required this.characterId,
    this.initial,
  });

  final String characterId;
  final BookCharacterModel? initial;

  @override
  State<CharacterDetailPage> createState() => _CharacterDetailPageState();
}

class _CharacterDetailPageState extends State<CharacterDetailPage> {
  BookCharacterModel? _character;
  bool _loadingMore = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _character = widget.initial;
    // Even with `initial` we re-fetch to pick up any server-side
    // refresh (regenerated portrait, edited appearance) without making
    // the user pull-to-refresh.
    _refetch();
  }

  Future<void> _refetch() async {
    if (!mounted) return;
    setState(() => _loadingMore = _character == null);
    try {
      final fresh = await context
          .read<AuthProvider>()
          .dataService
          .getCharacter(widget.characterId);
      if (!mounted) return;
      setState(() {
        if (fresh != null) _character = fresh;
        _loadingMore = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        if (_character == null) _error = e;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF0E0E12) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF111111);
    final subtleColor = isDark
        ? Colors.white.withValues(alpha: 0.65)
        : Colors.black.withValues(alpha: 0.65);

    final character = _character;
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: IconThemeData(color: textColor),
        title: Text(
          character?.name ?? 'Character',
          style: GoogleFonts.playfairDisplay(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: textColor,
          ),
        ),
      ),
      body: character == null
          ? Center(
              child: _loadingMore
                  ? const AppSpinner(size: 24)
                  : Text(
                      _error == null
                          ? 'Character not found'
                          : 'Failed to load character',
                      style: GoogleFonts.inter(color: subtleColor),
                    ),
            )
          : _buildBody(context, character, textColor, subtleColor, isDark),
    );
  }

  Widget _buildBody(
    BuildContext context,
    BookCharacterModel character,
    Color textColor,
    Color subtleColor,
    bool isDark,
  ) {
    final mediaWidth = MediaQuery.sizeOf(context).width;
    // Hero portrait targets ~80% of viewport width on phones, capped
    // for tablets so it doesn't dominate the page.
    final portraitWidth = mediaWidth.clamp(280.0, 520.0) * 0.86;
    final portraitHeight = portraitWidth * 1.4; // matches 1024x1536 aspect

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      children: [
        if (character.imageUrl != null && character.imageUrl!.isNotEmpty)
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: AppNetworkImage(
                url: character.imageUrl,
                meta: character.imageMeta,
                width: portraitWidth,
                height: portraitHeight,
                fit: BoxFit.cover,
              ),
            ),
          )
        else
          // No portrait — paint a tasteful initials placeholder so the
          // page doesn't look empty for books whose pipeline run
          // didn't generate sheets.
          Center(
            child: Container(
              width: portraitWidth,
              height: portraitHeight,
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.06)
                    : Colors.black.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(20),
              ),
              alignment: Alignment.center,
              child: Text(
                _initials(character.name),
                style: GoogleFonts.playfairDisplay(
                  fontSize: 64,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                ),
              ),
            ),
          ),
        const SizedBox(height: 22),
        Text(
          character.name,
          style: GoogleFonts.playfairDisplay(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            color: textColor,
            letterSpacing: -0.4,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 14),
        Text(
          character.appearance,
          style: GoogleFonts.inter(
            fontSize: 15.5,
            height: 1.6,
            color: subtleColor,
          ),
          textAlign: TextAlign.center,
        ),
        if (_loadingMore) ...[
          const SizedBox(height: 24),
          const Center(child: AppSpinner(size: 16)),
        ],
      ],
    );
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    if (parts.isEmpty) return '?';
    final letters = parts.take(2).map((p) => p[0].toUpperCase()).join();
    return letters.isEmpty ? '?' : letters;
  }
}
