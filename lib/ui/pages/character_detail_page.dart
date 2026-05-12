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
/// Renders the portrait as a framed gallery piece — bronze outer
/// frame, cream mat, the painting inside, and a brass-style plaque
/// underneath bearing the character's name. The scout's one-line
/// appearance sits below the frame as caption text.
///
/// Pushed with the [BookCharacterModel] as `extra` so the page
/// paints instantly from the strip's payload; the page re-fetches by
/// id in the background to pick up any later edits or hydrate when
/// the user landed via deep link.
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
    // Wall colour — a touch warmer than the rest of the app so the
    // gallery has its own atmosphere.
    final wallColor =
        isDark ? const Color(0xFF0B0B10) : const Color(0xFFF6F1E8);
    final textColor = isDark ? Colors.white : const Color(0xFF1A1612);
    final subtleColor = isDark
        ? Colors.white.withValues(alpha: 0.65)
        : const Color(0xFF6B5E4E);

    final character = _character;
    return Scaffold(
      backgroundColor: wallColor,
      appBar: AppBar(
        backgroundColor: wallColor,
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
    // Web breathes — cap the inner content so the frame doesn't
    // stretch across a 1920-px window. On phones we get the full
    // width minus padding.
    final contentWidth = mediaWidth < 720
        ? mediaWidth - 24
        : (mediaWidth * 0.55).clamp(440.0, 620.0);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 40),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: contentWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 12),
              _GalleryFrame(
                character: character,
                isDark: isDark,
                textColor: textColor,
              ),
              const SizedBox(height: 28),
              // Appearance caption below the frame — italic, sized like
              // a museum placard's secondary line. The frame's plaque
              // already shows the name, so we don't repeat it here on
              // wide screens.
              Text(
                character.appearance,
                style: GoogleFonts.inter(
                  fontSize: 14.5,
                  height: 1.65,
                  fontStyle: FontStyle.italic,
                  color: subtleColor,
                ),
                textAlign: TextAlign.center,
              ),
              if (_loadingMore) ...[
                const SizedBox(height: 20),
                const AppSpinner(size: 16),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Bronze-frame + cream-mat composition for the character portrait.
/// Two nested Containers with carefully picked colours: a layered
/// gradient on the outer band reads as polished metal, the mat is
/// soft warm white, and a small brass plaque sits at the bottom of
/// the mat with the character's name engraved. Falls back to an
/// initials medallion when no portrait was generated.
class _GalleryFrame extends StatelessWidget {
  const _GalleryFrame({
    required this.character,
    required this.isDark,
    required this.textColor,
  });

  final BookCharacterModel character;
  final bool isDark;
  final Color textColor;

  // Frame palette — chosen for both light + dark walls.
  static const _frameOuter = Color(0xFF3A2A18); // deep walnut shadow
  static const _frameMid = Color(0xFF8C6A2E);   // antique brass
  static const _frameHilite = Color(0xFFD9B26B); // gilt highlight
  static const _mat = Color(0xFFEFE6D3);        // warm cream mat
  static const _matShadow = Color(0xFFC9BBA0);  // inner mat shadow

  @override
  Widget build(BuildContext context) {
    final hasImage =
        character.imageUrl != null && character.imageUrl!.isNotEmpty;
    return DecoratedBox(
      // Soft wall shadow under the frame so it visually hangs.
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.55 : 0.20),
            blurRadius: 30,
            offset: const Offset(0, 16),
            spreadRadius: -6,
          ),
        ],
      ),
      child: Container(
        // Outer frame — three-stop gradient mimics polished brass.
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [_frameHilite, _frameMid, _frameOuter],
            stops: [0.0, 0.55, 1.0],
          ),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _frameOuter, width: 1.2),
        ),
        padding: const EdgeInsets.all(14), // bronze band thickness
        child: Container(
          // Inset bevel between bronze and mat — a thin dark line
          // gives the metal an edge.
          decoration: BoxDecoration(
            color: _frameOuter,
            borderRadius: BorderRadius.circular(2),
          ),
          padding: const EdgeInsets.all(2),
          child: Container(
            // Cream mat board.
            decoration: BoxDecoration(
              color: _mat,
              borderRadius: BorderRadius.circular(2),
              boxShadow: const [
                // Tiny inner shadow lip — sells the layered paperboard look.
                BoxShadow(
                  color: _matShadow,
                  blurRadius: 4,
                  spreadRadius: -2,
                  offset: Offset(0, 1),
                ),
              ],
            ),
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 14),
            child: Column(
              children: [
                AspectRatio(
                  aspectRatio: 1024 / 1536, // matches the portrait gen size
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: hasImage
                        ? AppNetworkImage(
                            url: character.imageUrl,
                            meta: character.imageMeta,
                            fit: BoxFit.cover,
                          )
                        : _initialsMedallion(character),
                  ),
                ),
                const SizedBox(height: 16),
                _BrassPlaque(name: character.name),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _initialsMedallion(BookCharacterModel character) {
    final parts =
        character.name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    final initials = parts.isEmpty
        ? '?'
        : parts.take(2).map((p) => p[0].toUpperCase()).join();
    return Container(
      color: const Color(0xFFE5D9BF),
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            initials,
            style: GoogleFonts.playfairDisplay(
              fontSize: 64,
              fontWeight: FontWeight.w700,
              color: _frameOuter,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'PORTRAIT PENDING',
            style: GoogleFonts.inter(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.6,
              color: _frameMid,
            ),
          ),
        ],
      ),
    );
  }
}

class _BrassPlaque extends StatelessWidget {
  const _BrassPlaque({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFFB3892F),
            Color(0xFF8C6A2E),
            Color(0xFF5B431A),
          ],
          stops: [0.0, 0.5, 1.0],
        ),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(
          color: const Color(0xFF3A2A18),
          width: 0.8,
        ),
      ),
      child: Text(
        name.toUpperCase(),
        style: GoogleFonts.cormorantGaramond(
          fontSize: 17,
          fontWeight: FontWeight.w700,
          letterSpacing: 2.4,
          color: const Color(0xFFF6E8C4),
        ),
      ),
    );
  }
}
