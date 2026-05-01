import 'package:flutter/material.dart';

// ── Functional page ruler (Docs-style) ──
//
// Sits above the page card. The two blue triangles are draggable —
// pan horizontally to change the page's left and right text margins
// in real time. The page card padding tracks these values, and they
// persist across reloads via SharedPreferences.
//
// Hidden in focus mode where chrome fights the distraction-free goal.
class RulerBar extends StatelessWidget {
  const RulerBar({
    super.key,
    required this.isDark,
    required this.leftMargin,
    required this.rightMargin,
    required this.onChanged,
  });

  final bool isDark;
  final double leftMargin;
  final double rightMargin;
  final void Function(double left, double right) onChanged;

  static const double height = 22;
  static const double _minMargin = 12;
  // Keep at least this much usable text width regardless of margin pull.
  static const double _minTextWidth = 200;
  // Triangle visual size + extra hit padding for usability.
  static const double _handleHitWidth = 26;

  @override
  Widget build(BuildContext context) {
    final tickColor = isDark
        ? Colors.white.withValues(alpha: 0.18)
        : Colors.black.withValues(alpha: 0.30);
    final numberColor = isDark
        ? Colors.white.withValues(alpha: 0.40)
        : Colors.black.withValues(alpha: 0.55);
    final marginColor = isDark
        ? const Color(0xFF93B4F5)
        : const Color(0xFF4A6CF7);

    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          final width = constraints.maxWidth;

          double clampLeft(double v) {
            final maxLeft = width - rightMargin - _minTextWidth;
            return v.clamp(_minMargin, maxLeft.clamp(_minMargin, double.infinity));
          }

          double clampRight(double v) {
            final maxRight = width - leftMargin - _minTextWidth;
            return v.clamp(_minMargin, maxRight.clamp(_minMargin, double.infinity));
          }

          return Stack(
            clipBehavior: Clip.none,
            children: [
              // Ticks + numbers (background paint).
              Positioned.fill(
                child: CustomPaint(
                  painter: _RulerPainter(
                    tickColor: tickColor,
                    numberColor: numberColor,
                  ),
                ),
              ),
              // Left margin handle.
              Positioned(
                left: leftMargin - _handleHitWidth / 2,
                top: 0,
                bottom: 0,
                width: _handleHitWidth,
                child: _MarginHandle(
                  color: marginColor,
                  onPanUpdate: (delta) =>
                      onChanged(clampLeft(leftMargin + delta), rightMargin),
                ),
              ),
              // Right margin handle.
              Positioned(
                right: rightMargin - _handleHitWidth / 2,
                top: 0,
                bottom: 0,
                width: _handleHitWidth,
                child: _MarginHandle(
                  color: marginColor,
                  onPanUpdate: (delta) =>
                      onChanged(leftMargin, clampRight(rightMargin - delta)),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _MarginHandle extends StatefulWidget {
  const _MarginHandle({
    required this.color,
    required this.onPanUpdate,
  });

  final Color color;
  final void Function(double deltaDx) onPanUpdate;

  @override
  State<_MarginHandle> createState() => _MarginHandleState();
}

class _MarginHandleState extends State<_MarginHandle> {
  bool _hover = false;
  bool _drag = false;

  @override
  Widget build(BuildContext context) {
    final active = _hover || _drag;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => setState(() => _drag = true),
        onPanEnd: (_) => setState(() => _drag = false),
        onPanCancel: () => setState(() => _drag = false),
        onPanUpdate: (d) => widget.onPanUpdate(d.delta.dx),
        child: Center(
          child: CustomPaint(
            size: const Size(14, RulerBar.height),
            painter: _MarginTrianglePainter(
              color: widget.color,
              active: active,
            ),
          ),
        ),
      ),
    );
  }
}

class _MarginTrianglePainter extends CustomPainter {
  _MarginTrianglePainter({required this.color, required this.active});

  final Color color;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final baseY = size.height - 6;
    final paint = Paint()
      ..color = color.withValues(alpha: active ? 1.0 : 0.85);
    final path = Path()
      ..moveTo(cx - 6, baseY - 3)
      ..lineTo(cx + 6, baseY - 3)
      ..lineTo(cx, baseY + 4)
      ..close();
    canvas.drawPath(path, paint);

    // Subtle highlight ring while hovering / dragging.
    if (active) {
      final ringPaint = Paint()
        ..color = color.withValues(alpha: 0.18)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(cx, baseY), 9, ringPaint);
    }
  }

  @override
  bool shouldRepaint(_MarginTrianglePainter old) =>
      old.color != color || old.active != active;
}

class _RulerPainter extends CustomPainter {
  _RulerPainter({
    required this.tickColor,
    required this.numberColor,
  });

  final Color tickColor;
  final Color numberColor;

  // Visual scale: one "unit" on the ruler is 80 px.
  static const double _unit = 80;

  @override
  void paint(Canvas canvas, Size size) {
    final tickPaint = Paint()
      ..color = tickColor
      ..strokeWidth = 1;

    final baseY = size.height - 6;
    final majorTickH = 6.0;
    final minorTickH = 3.0;

    final minorStep = _unit / 4;
    for (double x = 0; x <= size.width; x += minorStep) {
      final isMajor = ((x / _unit) - (x ~/ _unit)).abs() < 0.001;
      final h = isMajor ? majorTickH : minorTickH;
      canvas.drawLine(
        Offset(x, baseY - h),
        Offset(x, baseY),
        tickPaint,
      );
    }

    for (double x = _unit; x < size.width; x += _unit) {
      final n = (x / _unit).round();
      final tp = TextPainter(
        text: TextSpan(
          text: '$n',
          style: TextStyle(
            color: numberColor,
            fontSize: 9,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas,
          Offset(x - tp.width / 2, baseY - majorTickH - tp.height - 1));
    }
  }

  @override
  bool shouldRepaint(_RulerPainter old) =>
      old.tickColor != tickColor || old.numberColor != numberColor;
}
