import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';

/// Warm every PNG + SVG used by the auth screens into memory before the
/// user navigates there. Call once at app startup (e.g. from main() after
/// runApp, or from the splash screen's initState).
///
/// Subsequent renders of [AuthScaffold] paint instantly because Flutter's
/// image cache and flutter_svg's bytes cache have already done the work.
Future<void> precacheAuthAssets(BuildContext context) async {
  const pngs = [
    'assets/doodles/feather.png',
    'assets/doodles/arrow.png',
    'assets/doodles/lightning.png',
    'assets/doodles/flower.png',
  ];
  const svgs = [
    'assets/scribbles/wavy.svg',
    'assets/scribbles/zigzag.svg',
    'assets/scribbles/burst.svg',
    'assets/scribbles/loop.svg',
  ];

  // Decode PNGs at the same target width used at render time so we hit the
  // cache key precisely, then no second decode happens later.
  await Future.wait([
    for (final p in pngs)
      precacheImage(
        ResizeImage(AssetImage(p), width: 480),
        context,
      ),
    // SvgAssetLoader caches the parsed VectorGraphic on first decode.
    for (final s in svgs) SvgAssetLoader(s).loadBytes(null),
  ]);
}

// Suppress "unused import" if Flutter ever dead-code-eliminates the bundle
// reference; rootBundle is used implicitly by the asset providers above.
// ignore: unused_element
final _keepBundle = rootBundle;

/// Auth page chrome inspired by the InkSpaceX landing page:
///
/// - Whole page is one composition on a cream paper background.
/// - Scribbles are scattered at the page corners (not inside any container).
/// - Left:  brutalist white card with thick ink border + offset shadow,
///          slight tilt for character.
/// - Right: a hand-drawn "writing scene" — the feather is the centerpiece
///          and smaller doodles (flower, lightning, arrow, stars) orbit it
///          like notes pinned to a corkboard. No panel, no border — they
///          float on the page, then a single hand-written caption sits
///          under them.
class AuthScaffold extends StatelessWidget {
  final String title;
  final String subtitle;
  final String heroCaption;
  final Widget formChild;

  const AuthScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.heroCaption,
    required this.formChild,
  });

  static const double _kBreakpoint = 920;

  // ── Palette ─────────────────────────────────────────────
  // Page background in light mode: a faint white — barely-there warm tint,
  // reads as white with paper character.
  static const _cream = Color(0xFFFAFAF6);
  static const _ink = Color(0xFF111111);
  static const _accentOrange = Color(0xFFFF5A3C);
  // Stark blue that pops against the black page in dark mode and reads as
  // a clear accent in light mode too.
  static const _accentBlue = Color(0xFF3B82F6);

  static const _darkPage = Color(0xFF121212);
  static const _darkPaper = Color(0xFF191919);
  static const _darkInk = Color(0xFFF1F5F9);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pageBg = isDark ? _darkPage : _cream;
    final inkColor = isDark ? _darkInk : _ink;
    final paperColor = isDark ? _darkPaper : Colors.white;

    return Scaffold(
      backgroundColor: pageBg,
      body: Stack(
        children: [
          // Faded dotted-paper background that bleeds from the top
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _DottedPaperPainter(
                  dotColor: inkColor.withOpacity(isDark ? 0.06 : 0.13),
                ),
              ),
            ),
          ),

          // Decide narrow vs. wide once and use it for both the corner
          // scribbles (shrink/hide on mobile) and the body layout.
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= _kBreakpoint;
              return Stack(
                children: [
                  ..._cornerScribbles(inkColor, isDark, wide: wide),
                  SafeArea(
                    child: wide
                        ? _wideLayout(context, inkColor, paperColor)
                        : _narrowLayout(context, inkColor, paperColor),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  // ── Page-corner scribbles (decoration) ─────────────────
  List<Widget> _cornerScribbles(Color inkColor, bool isDark,
      {required bool wide}) {
    final orange = _accentOrange.withOpacity(isDark ? 0.65 : 0.85);
    final blue = _accentBlue.withOpacity(isDark ? 0.65 : 0.85);
    final ghostInk = inkColor.withOpacity(isDark ? 0.18 : 0.55);

    if (!wide) {
      // Mobile: keep just two small accents up top so the page has a touch
      // of personality without the corner scribbles bleeding into the form.
      return [
        Positioned(
          top: -8,
          left: -10,
          child: _scribble('assets/scribbles/wavy.svg',
              size: 70, color: blue, rotate: -0.18),
        ),
        Positioned(
          top: 14,
          right: -6,
          child: _scribble('assets/scribbles/zigzag.svg',
              size: 70, color: orange, rotate: 0.30),
        ),
      ];
    }

    return [
      Positioned(
        top: -12,
        left: 16,
        child: _scribble('assets/scribbles/wavy.svg',
            size: 110, color: blue, rotate: -0.18),
      ),
      Positioned(
        top: 60,
        right: 28,
        child: _scribble('assets/scribbles/zigzag.svg',
            size: 130, color: orange, rotate: 0.30),
      ),
      Positioned(
        bottom: 40,
        left: 36,
        child: _scribble('assets/scribbles/burst.svg',
            size: 90, color: orange, rotate: -0.35),
      ),
      Positioned(
        bottom: -16,
        right: 60,
        child: _scribble('assets/scribbles/loop.svg',
            size: 100, color: ghostInk, rotate: 0.22),
      ),
    ];
  }

  Widget _scribble(String asset,
      {required double size, required Color color, double rotate = 0}) {
    return IgnorePointer(
      child: Transform.rotate(
        angle: rotate,
        child: SizedBox(
          width: size,
          height: size,
          child: SvgPicture.asset(
            asset,
            colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
          ),
        ),
      ),
    );
  }

  // ── Wide (desktop / tablet) ────────────────────────────
  Widget _wideLayout(BuildContext context, Color inkColor, Color paperColor) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1180),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(48, 24, 48, 24),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Hero column on the LEFT (no card, just the composition)
              Expanded(
                flex: 6,
                child: _HeroComposition(
                  inkColor: inkColor,
                  caption: heroCaption,
                ),
              ),
              const SizedBox(width: 64),
              // Form column on the RIGHT
              Expanded(
                flex: 5,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: _formCard(context, inkColor, paperColor),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Narrow (mobile) ─────────────────────────────────────
  Widget _narrowLayout(BuildContext context, Color inkColor, Color paperColor) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 28, 18, 28),
          child: ConstrainedBox(
            // Make the scroll view at least as tall as its viewport so the
            // form can vertically center instead of leaving a giant black
            // void underneath.
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: _formCard(
                  context,
                  inkColor,
                  paperColor,
                  compact: true,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ── Brutalist form card ────────────────────────────────
  Widget _formCard(
    BuildContext context,
    Color inkColor,
    Color paperColor, {
    bool compact = false,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final card = Container(
      decoration: BoxDecoration(
        color: paperColor,
        borderRadius: BorderRadius.circular(compact ? 18 : 20),
        border: Border.all(color: inkColor, width: compact ? 2.0 : 2.5),
        boxShadow: [
          BoxShadow(
            color: inkColor,
            offset: Offset(compact ? 5 : 7, compact ? 5 : 7),
            blurRadius: 0,
          ),
        ],
      ),
      padding: compact
          ? const EdgeInsets.fromLTRB(22, 24, 22, 22)
          : const EdgeInsets.fromLTRB(32, 34, 32, 30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: GoogleFonts.playfairDisplay(
              fontSize: compact ? 28 : 34,
              fontWeight: FontWeight.w800,
              color: inkColor,
              height: 1.05,
              letterSpacing: -0.6,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: GoogleFonts.caveat(
              fontSize: compact ? 18 : 20,
              color: inkColor.withOpacity(isDark ? 0.7 : 0.65),
              height: 1.25,
              fontWeight: FontWeight.w500,
            ),
          ),
          SizedBox(height: compact ? 20 : 24),
          formChild,
        ],
      ),
    );

    // Tilt only on the wide layout — on mobile a tilted card looks broken
    // because the offset shadow rides off the screen.
    if (compact) return card;
    return Transform.rotate(angle: -0.012, child: card);
  }
}

// ── The hero "writing scene" ────────────────────────────
//
// Composes the feather as the centerpiece + smaller doodles orbiting it.
// Lays out on a fixed-aspect canvas so the relative positions stay stable
// across viewports, scaling as one unit.
class _HeroComposition extends StatelessWidget {
  final Color inkColor;
  final String caption;

  const _HeroComposition({
    required this.inkColor,
    required this.caption,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tint = inkColor.withOpacity(isDark ? 0.92 : 0.92);
    final accent = AuthScaffold._accentOrange;
    final purple = AuthScaffold._accentBlue;

    return AspectRatio(
      aspectRatio: 5 / 6,
      child: LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          final h = c.maxHeight;

          // Anchor positions in fractions of width/height so the layout
          // scales proportionally on any viewport.
          Widget at({
            required double left,
            required double top,
            required double width,
            required Widget child,
          }) {
            return Positioned(
              left: left * w,
              top: top * h,
              width: width * w,
              child: child,
            );
          }

          return Stack(
            clipBehavior: Clip.none,
            children: [
              // Soft background tint behind the centerpiece — gives the eye
              // a focal point without resorting to a hard-edged panel.
              // Uses a neutral dark-grey (#191919) so it reads as a subtle
              // shadow on the page, not a colored halo.
              Positioned(
                left: 0.10 * w,
                top: 0.06 * h,
                child: IgnorePointer(
                  child: Container(
                    width: 0.78 * w,
                    height: 0.62 * h,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          const Color(0xFF191919).withOpacity(isDark ? 0.55 : 0.06),
                          const Color(0xFF191919).withOpacity(0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // ── Floating doodles around the feather ──
              // Top-left: flower
              at(
                left: 0.04,
                top: 0.06,
                width: 0.18,
                child: Transform.rotate(
                  angle: -0.20,
                  child: _doodle('assets/doodles/flower.png', accent),
                ),
              ),

              // Top-right: lightning bolt
              at(
                left: 0.78,
                top: 0.04,
                width: 0.16,
                child: Transform.rotate(
                  angle: 0.18,
                  child: _doodle('assets/doodles/lightning.png', tint),
                ),
              ),

              // Mid-left: hand-drawn sparkle cluster (CustomPaint — no asset
              // bundle dependency, so it always renders even on hot-reload).
              at(
                left: 0.02,
                top: 0.36,
                width: 0.20,
                child: Transform.rotate(
                  angle: -0.10,
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: CustomPaint(painter: _SparklesPainter(color: purple)),
                  ),
                ),
              ),

              // Bottom-right: arrow pointing up at the feather
              at(
                left: 0.72,
                top: 0.46,
                width: 0.26,
                child: Transform.rotate(
                  angle: -0.85,
                  child: _doodle('assets/doodles/arrow.png', accent),
                ),
              ),

              // ── Centerpiece: feather, tilted ──
              Positioned(
                left: 0.18 * w,
                top: 0.10 * h,
                width: 0.62 * w,
                height: 0.60 * h,
                child: Transform.rotate(
                  angle: -0.18,
                  child: _doodle('assets/doodles/feather.png', tint),
                ),
              ),

              // ── Hand-written caption beneath the scene ──
              Positioned(
                left: 0,
                right: 0,
                bottom: 0.04 * h,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      Text(
                        caption,
                        textAlign: TextAlign.center,
                        style: GoogleFonts.playfairDisplay(
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                          color: inkColor,
                          height: 1.05,
                          letterSpacing: -0.4,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                      const SizedBox(height: 4),
                      // Hand-drawn underline using a scribble SVG
                      SizedBox(
                        height: 14,
                        width: 0.42 * w,
                        child: SvgPicture.asset(
                          'assets/scribbles/wavy.svg',
                          fit: BoxFit.fitWidth,
                          colorFilter: ColorFilter.mode(accent, BlendMode.srcIn),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _doodle(String asset, Color color) {
    // Source PNGs are 1500-2500px wide but the doodles only render at
    // ~150-300px on screen. cacheWidth tells Flutter to decode at the
    // smaller size, cutting decode time and image-cache footprint by ~10×
    // — so the scene paints instantly instead of streaming in piece by
    // piece on first build.
    return RepaintBoundary(
      child: ColorFiltered(
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
        child: Image.asset(
          asset,
          fit: BoxFit.contain,
          cacheWidth: 480,
          gaplessPlayback: true,
        ),
      ),
    );
  }
}

// ── Background painter ────────────────────────────────────

/// A small cluster of hand-drawn 4-pointed sparkles. Pure CustomPaint so it
/// renders without any asset-bundle dependency.
class _SparklesPainter extends CustomPainter {
  final Color color;
  _SparklesPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    // (cx fraction, cy fraction, radius fraction)
    const sparkles = <List<double>>[
      [0.30, 0.30, 0.22],
      [0.70, 0.55, 0.16],
      [0.20, 0.80, 0.12],
    ];
    for (final s in sparkles) {
      final cx = s[0] * size.width;
      final cy = s[1] * size.height;
      final r = s[2] * size.width;
      _drawSparkle(canvas, paint, Offset(cx, cy), r);
    }
  }

  // 4-pointed star: two crossed concave diamonds.
  void _drawSparkle(Canvas canvas, Paint paint, Offset c, double r) {
    final waist = r * 0.18;
    final path = Path()
      ..moveTo(c.dx, c.dy - r)
      ..quadraticBezierTo(c.dx + waist, c.dy - waist, c.dx + r, c.dy)
      ..quadraticBezierTo(c.dx + waist, c.dy + waist, c.dx, c.dy + r)
      ..quadraticBezierTo(c.dx - waist, c.dy + waist, c.dx - r, c.dy)
      ..quadraticBezierTo(c.dx - waist, c.dy - waist, c.dx, c.dy - r)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SparklesPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _DottedPaperPainter extends CustomPainter {
  final Color dotColor;
  _DottedPaperPainter({required this.dotColor});

  @override
  void paint(Canvas canvas, Size size) {
    const spacing = 22.0;
    const radius = 1.1;
    final paint = Paint();
    final maxY = size.height * 0.78;
    for (double y = 0; y < maxY; y += spacing) {
      final fade = 1.0 - (y / maxY);
      paint.color = dotColor.withOpacity(dotColor.opacity * fade);
      for (double x = 0; x < size.width; x += spacing) {
        canvas.drawCircle(Offset(x, y), radius, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DottedPaperPainter oldDelegate) =>
      oldDelegate.dotColor != dotColor;
}

// ─────────────────────────────────────────────────────────
// Shared form primitives.
// ─────────────────────────────────────────────────────────

class AuthField extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final String label;
  final String? hint;
  final IconData icon;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final Widget? suffix;

  const AuthField({
    super.key,
    required this.controller,
    this.focusNode,
    required this.label,
    this.hint,
    required this.icon,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
    this.suffix,
  });

  @override
  State<AuthField> createState() => _AuthFieldState();
}

class _AuthFieldState extends State<AuthField> {
  late FocusNode _focusNode;
  bool _ownsFocusNode = false;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    if (widget.focusNode != null) {
      _focusNode = widget.focusNode!;
    } else {
      _focusNode = FocusNode();
      _ownsFocusNode = true;
    }
    _focusNode.addListener(_handleFocus);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocus);
    if (_ownsFocusNode) _focusNode.dispose();
    super.dispose();
  }

  void _handleFocus() {
    if (mounted) setState(() => _focused = _focusNode.hasFocus);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ink = isDark ? AuthScaffold._darkInk : AuthScaffold._ink;
    final fill = isDark ? const Color(0xFF0F0F0F) : AuthScaffold._cream;
    final subtle = ink.withOpacity(0.55);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            widget.label.toUpperCase(),
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: ink.withOpacity(0.7),
              letterSpacing: 1.0,
            ),
          ),
        ),
        Material(
          color: fill,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: ink,
                width: _focused ? 2.0 : 1.4,
              ),
            ),
            child: TextField(
              controller: widget.controller,
              focusNode: _focusNode,
              obscureText: widget.obscureText,
              keyboardType: widget.keyboardType,
              textInputAction: widget.textInputAction,
              onSubmitted: widget.onSubmitted,
              style: GoogleFonts.inter(
                color: ink,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
              cursorColor: ink,
              decoration: InputDecoration(
                isDense: true,
                hintText: widget.hint,
                hintStyle: GoogleFonts.inter(
                  color: subtle.withOpacity(0.55),
                  fontSize: 15,
                  fontWeight: FontWeight.w400,
                ),
                prefixIcon: Padding(
                  padding: const EdgeInsets.only(left: 14, right: 10),
                  child: Icon(widget.icon, size: 18, color: subtle),
                ),
                prefixIconConstraints:
                    const BoxConstraints(minWidth: 0, minHeight: 0),
                suffixIcon: widget.suffix != null
                    ? Padding(
                        padding: const EdgeInsets.only(right: 14),
                        child: widget.suffix,
                      )
                    : null,
                suffixIconConstraints:
                    const BoxConstraints(minWidth: 0, minHeight: 0),
                filled: false,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class AuthPrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool loading;

  const AuthPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? AuthScaffold._darkInk : AuthScaffold._ink;
    final fg = isDark ? AuthScaffold._darkPage : AuthScaffold._cream;
    final shadow = isDark ? AuthScaffold._darkInk : AuthScaffold._ink;
    final disabled = onPressed == null || loading;

    return SizedBox(
      height: 52,
      child: GestureDetector(
        onTap: disabled ? null : onPressed,
        child: Container(
          decoration: BoxDecoration(
            color: disabled ? bg.withOpacity(0.4) : bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AuthScaffold._ink, width: 2),
            boxShadow: disabled
                ? const []
                : [
                    BoxShadow(
                      color: shadow,
                      offset: const Offset(4, 4),
                      blurRadius: 0,
                    ),
                  ],
          ),
          alignment: Alignment.center,
          child: loading
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    valueColor: AlwaysStoppedAnimation(fg),
                  ),
                )
              : Text(
                  label,
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: fg,
                    letterSpacing: 0.3,
                  ),
                ),
        ),
      ),
    );
  }
}

class AuthSecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool loading;
  final Widget? leading;

  const AuthSecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
    this.leading,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ink = isDark ? AuthScaffold._darkInk : AuthScaffold._ink;
    final fill = isDark ? const Color(0xFF0F0F0F) : Colors.white;
    final disabled = onPressed == null || loading;

    return SizedBox(
      height: 52,
      child: GestureDetector(
        onTap: disabled ? null : onPressed,
        child: Container(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: ink, width: 2),
            boxShadow: disabled
                ? const []
                : [
                    BoxShadow(
                      color: ink,
                      offset: const Offset(4, 4),
                      blurRadius: 0,
                    ),
                  ],
          ),
          alignment: Alignment.center,
          child: loading
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    valueColor: AlwaysStoppedAnimation(ink),
                  ),
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (leading != null) ...[
                      leading!,
                      const SizedBox(width: 12),
                    ],
                    Text(
                      label,
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: ink,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class AuthDivider extends StatelessWidget {
  const AuthDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ink = isDark ? AuthScaffold._darkInk : AuthScaffold._ink;
    return Row(
      children: [
        Expanded(child: Divider(color: ink.withOpacity(0.20), height: 1)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Text(
            'or',
            style: GoogleFonts.caveat(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: ink.withOpacity(0.55),
            ),
          ),
        ),
        Expanded(child: Divider(color: ink.withOpacity(0.20), height: 1)),
      ],
    );
  }
}
