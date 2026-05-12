import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
/// frame, cream mat, painting inside, brass plaque underneath. The
/// scout's appearance description sits below the frame as italic
/// caption text.
///
/// When the caller passes a `cast` list via GoRouter `extra`, the
/// page wraps the frame in a vertical `PageView` so the reader can
/// swipe up/down to walk through the rest of the book's cast without
/// returning to the book detail page. Single-character pushes (deep
/// links / older callers) still work — the page degrades to one
/// non-scrollable frame.
///
/// `extra` shape (preferred):
///   `({List<BookCharacterModel> cast, int index})`
/// Fallback shapes (backward compat):
///   - `BookCharacterModel` (single character, no swipe)
///   - `null` (deep link — fetch by id, no swipe)
class CharacterDetailPage extends StatefulWidget {
  const CharacterDetailPage({
    super.key,
    required this.characterId,
    this.initial,
    this.cast,
    this.initialIndex = 0,
  });

  final String characterId;
  final BookCharacterModel? initial;
  final List<BookCharacterModel>? cast;
  final int initialIndex;

  @override
  State<CharacterDetailPage> createState() => _CharacterDetailPageState();
}

class _CharacterDetailPageState extends State<CharacterDetailPage> {
  /// The cast we render. Always non-empty in the swipeable case; in
  /// the deep-link fallback this starts empty and we fall back to a
  /// single-character fetch-by-id.
  late final List<BookCharacterModel> _items;
  late final PageController _controller;
  int _currentIndex = 0;
  bool _loadingCurrent = false;
  Object? _error;

  bool get _canSwipe => _items.length > 1;

  @override
  void initState() {
    super.initState();
    if (widget.cast != null && widget.cast!.isNotEmpty) {
      _items = List.of(widget.cast!);
      _currentIndex = widget.initialIndex.clamp(0, _items.length - 1);
    } else if (widget.initial != null) {
      _items = [widget.initial!];
      _currentIndex = 0;
    } else {
      _items = <BookCharacterModel>[];
      _currentIndex = 0;
    }
    _controller = PageController(initialPage: _currentIndex);
    _refetchAt(_currentIndex);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Refresh a single character from the server and fold the result
  /// back into `_items` so swiping back to it later uses the latest
  /// portrait/appearance without another network call.
  Future<void> _refetchAt(int index) async {
    if (!mounted) return;
    final targetId = index >= 0 && index < _items.length
        ? _items[index].id
        : widget.characterId;
    if (targetId.isEmpty) return;
    setState(() {
      _loadingCurrent = _items.isEmpty || index == _currentIndex;
    });
    try {
      final fresh = await context
          .read<AuthProvider>()
          .dataService
          .getCharacter(targetId);
      if (!mounted) return;
      setState(() {
        _loadingCurrent = false;
        _error = null;
        if (fresh == null) return;
        if (_items.isEmpty) {
          _items.add(fresh);
        } else if (index >= 0 && index < _items.length) {
          _items[index] = fresh;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingCurrent = false;
        if (_items.isEmpty) _error = e;
      });
    }
  }

  void _onPageChanged(int index) {
    setState(() => _currentIndex = index);
    // Quietly refresh the newly-shown character. The page paints
    // instantly from the cached BookCharacterModel that came in via
    // `extra`; this just folds in any server-side updates.
    _refetchAt(index);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final wallColor =
        isDark ? const Color(0xFF0B0B10) : const Color(0xFFF6F1E8);
    final textColor = isDark ? Colors.white : const Color(0xFF1A1612);
    final subtleColor = isDark
        ? Colors.white.withValues(alpha: 0.65)
        : const Color(0xFF6B5E4E);

    final current = _items.isNotEmpty && _currentIndex < _items.length
        ? _items[_currentIndex]
        : null;

    return Scaffold(
      backgroundColor: wallColor,
      appBar: AppBar(
        backgroundColor: wallColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: IconThemeData(color: textColor),
        title: Text(
          current?.name ?? 'Character',
          style: GoogleFonts.playfairDisplay(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: textColor,
          ),
        ),
        actions: [
          if (_canSwipe)
            // Tiny "n / N" indicator so readers know there's a cast
            // to swipe through.
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  '${_currentIndex + 1} / ${_items.length}',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: subtleColor,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: current == null
          ? Center(
              child: _loadingCurrent
                  ? const AppSpinner(size: 24)
                  : Text(
                      _error == null
                          ? 'Character not found'
                          : 'Failed to load character',
                      style: GoogleFonts.inter(color: subtleColor),
                    ),
            )
          : Focus(
              autofocus: true,
              onKeyEvent: (node, event) {
                if (!_canSwipe || event is! KeyDownEvent) {
                  return KeyEventResult.ignored;
                }
                if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
                    event.logicalKey == LogicalKeyboardKey.arrowRight ||
                    event.logicalKey == LogicalKeyboardKey.pageDown) {
                  _goNext();
                  return KeyEventResult.handled;
                }
                if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
                    event.logicalKey == LogicalKeyboardKey.arrowLeft ||
                    event.logicalKey == LogicalKeyboardKey.pageUp) {
                  _goPrev();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: _buildSwipeableBody(
                context,
                textColor: textColor,
                subtleColor: subtleColor,
                isDark: isDark,
              ),
            ),
    );
  }

  void _goNext() {
    if (_currentIndex >= _items.length - 1) return;
    _controller.animateToPage(
      _currentIndex + 1,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  void _goPrev() {
    if (_currentIndex <= 0) return;
    _controller.animateToPage(
      _currentIndex - 1,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  Widget _buildSwipeableBody(
    BuildContext context, {
    required Color textColor,
    required Color subtleColor,
    required bool isDark,
  }) {
    final pageView = PageView.builder(
      controller: _controller,
      // Vertical swipe — matches the "scroll up/down for next" pattern
      // readers expect from gallery / story UIs.
      scrollDirection: Axis.vertical,
      itemCount: _items.length,
      physics: _canSwipe
          ? const PageScrollPhysics()
          : const NeverScrollableScrollPhysics(),
      onPageChanged: _onPageChanged,
      itemBuilder: (context, index) {
        final character = _items[index];
        return _CharacterFrameView(
          character: character,
          textColor: textColor,
          subtleColor: subtleColor,
          isDark: isDark,
          showSwipeHint: _canSwipe && index == 0 && !kIsWeb,
          loading: _loadingCurrent && index == _currentIndex,
        );
      },
    );

    // On web (mouse-driven), the inner SingleChildScrollView competes
    // with the PageView for the scroll wheel — plaque + caption end up
    // below the fold without a way to reach them. Overlay clickable
    // chevron buttons on the left + right edges so navigation doesn't
    // depend on a scroll gesture.
    if (!_canSwipe || !kIsWeb) return pageView;
    final canPrev = _currentIndex > 0;
    final canNext = _currentIndex < _items.length - 1;
    return Stack(
      children: [
        Positioned.fill(child: pageView),
        if (canPrev)
          Positioned(
            left: 24,
            top: 0,
            bottom: 0,
            child: Center(
              child: _NavButton(
                icon: Icons.keyboard_arrow_up,
                tooltip: 'Previous character',
                isDark: isDark,
                onTap: _goPrev,
              ),
            ),
          ),
        if (canNext)
          Positioned(
            right: 24,
            top: 0,
            bottom: 0,
            child: Center(
              child: _NavButton(
                icon: Icons.keyboard_arrow_down,
                tooltip: 'Next character',
                isDark: isDark,
                onTap: _goNext,
              ),
            ),
          ),
      ],
    );
  }
}

/// Circular chevron button used on web to advance between characters
/// without relying on the mouse-wheel-vs-PageView fight.
class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.icon,
    required this.tooltip,
    required this.isDark,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool isDark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Buttons need to read clearly against the page's warm-wall
    // background — semi-transparent dark/light overlay was almost
    // invisible at distance. Use the bronze/gold frame palette so
    // they feel like they belong to the gallery instead of a generic
    // chrome control.
    const ringFill = Color(0xFFD9B26B); // gilt — same as the frame highlight
    const iconColor = Color(0xFF1A1210); // dark walnut — high contrast
    final shadow = isDark
        ? Colors.black.withValues(alpha: 0.55)
        : Colors.black.withValues(alpha: 0.18);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [ringFill, Color(0xFF8C6A2E)],
              ),
              shape: BoxShape.circle,
              border: Border.all(
                color: const Color(0xFF3A2A18),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: shadow,
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Icon(icon, size: 28, color: iconColor),
          ),
        ),
      ),
    );
  }
}

/// One page in the vertical PageView — gallery frame + caption + the
/// optional swipe hint at the bottom of the first item.
class _CharacterFrameView extends StatelessWidget {
  const _CharacterFrameView({
    required this.character,
    required this.textColor,
    required this.subtleColor,
    required this.isDark,
    required this.showSwipeHint,
    required this.loading,
  });

  final BookCharacterModel character;
  final Color textColor;
  final Color subtleColor;
  final bool isDark;
  final bool showSwipeHint;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 720;
        // Vertical overhead: frame padding (top+bottom) + plaque +
        // gap + caption + hint + outer page padding. Reserve more
        // than seems strictly needed so the frame never bumps the
        // edge of the viewport on web zoom / different DPRs.
        const verticalOverhead = 260.0;
        final availableForFrameImage =
            (constraints.maxHeight - verticalOverhead).clamp(280.0, 900.0);
        // Image width = imageHeight × (1024/1536) = imageHeight × 0.667.
        // Then clamp so the frame doesn't get absurdly small on phones
        // (where width is the binding constraint) or huge on ultra-wide
        // desktop windows.
        final widthFromHeight = availableForFrameImage * (1024 / 1536);
        final contentWidth = isNarrow
            ? constraints.maxWidth - 24
            : widthFromHeight.clamp(280.0, 420.0);

        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: contentWidth),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _GalleryFrame(
                    character: character,
                    isDark: isDark,
                    textColor: textColor,
                  ),
                  const SizedBox(height: 14),
                  Text(
                    character.displayDescription,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 13.5,
                      height: 1.5,
                      color: subtleColor,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  if (loading) ...[
                    const SizedBox(height: 10),
                    const AppSpinner(size: 14),
                  ],
                  if (showSwipeHint) ...[
                    const SizedBox(height: 12),
                    _SwipeHint(subtleColor: subtleColor),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Bronze-frame + cream-mat composition for the character portrait.
class _GalleryFrame extends StatelessWidget {
  const _GalleryFrame({
    required this.character,
    required this.isDark,
    required this.textColor,
  });

  final BookCharacterModel character;
  final bool isDark;
  final Color textColor;

  static const _frameOuter = Color(0xFF3A2A18);
  static const _frameMid = Color(0xFF8C6A2E);
  static const _frameHilite = Color(0xFFD9B26B);
  static const _mat = Color(0xFFEFE6D3);
  static const _matShadow = Color(0xFFC9BBA0);

  @override
  Widget build(BuildContext context) {
    final hasImage =
        character.imageUrl != null && character.imageUrl!.isNotEmpty;
    return DecoratedBox(
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
        padding: const EdgeInsets.all(14),
        child: Container(
          decoration: BoxDecoration(
            color: _frameOuter,
            borderRadius: BorderRadius.circular(2),
          ),
          padding: const EdgeInsets.all(2),
          child: Container(
            decoration: BoxDecoration(
              color: _mat,
              borderRadius: BorderRadius.circular(2),
              boxShadow: const [
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
                  aspectRatio: 1024 / 1536,
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

/// Tiny "swipe up for next" hint shown under the first character's
/// caption. Only appears on the first page so we don't pester the
/// reader on every swipe.
class _SwipeHint extends StatelessWidget {
  const _SwipeHint({required this.subtleColor});

  final Color subtleColor;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(Icons.keyboard_arrow_up, color: subtleColor, size: 22),
        const SizedBox(height: 2),
        Text(
          'SWIPE FOR NEXT',
          style: GoogleFonts.inter(
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.8,
            color: subtleColor,
          ),
        ),
      ],
    );
  }
}
