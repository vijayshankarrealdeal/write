import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:inkspacex/ui/widgets/app_spinner.dart';

/// In-app cropper. Shows the picked image inside a fixed-aspect frame; user
/// pans + pinches; on confirm the framed region is rasterised to PNG.
///
/// Pass `circleOverlay: true` for avatar-style previews — the captured bytes
/// remain a square PNG (most upload pipelines expect that), but a circular
/// mask is drawn on top so the user sees the actual avatar shape while
/// adjusting.
class ImageCropPage extends StatefulWidget {
  final Uint8List imageBytes;
  final double aspectRatio;
  final bool circleOverlay;
  final String title;
  final String confirmLabel;

  const ImageCropPage({
    super.key,
    required this.imageBytes,
    this.aspectRatio = 21 / 9,
    this.circleOverlay = false,
    this.title = 'Adjust image',
    this.confirmLabel = 'Use this image',
  });

  @override
  State<ImageCropPage> createState() => _ImageCropPageState();
}

class _ImageCropPageState extends State<ImageCropPage> {
  final TransformationController _controller = TransformationController();
  final GlobalKey _frameKey = GlobalKey();
  ui.Image? _image;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    final codec = await ui.instantiateImageCodec(widget.imageBytes);
    final frame = await codec.getNextFrame();
    if (mounted) setState(() => _image = frame.image);
  }

  @override
  void dispose() {
    _controller.dispose();
    _image?.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final boundary =
          _frameKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (!mounted || byteData == null) return;
      Navigator.of(context).pop(byteData.buffer.asUint8List());
    } catch (_) {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _reset() {
    _controller.value = Matrix4.identity();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF0A0A0A) : const Color(0xFFFAFAFA);
    final textColor = isDark ? Colors.white : const Color(0xFF111111);
    final mutedColor = isDark
        ? Colors.white.withValues(alpha: 0.55)
        : Colors.black.withValues(alpha: 0.55);
    final btnFg = isDark ? Colors.black : Colors.white;

    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: SizedBox(
                height: 48,
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.06)
                              : Colors.black.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(CupertinoIcons.xmark,
                            size: 16, color: mutedColor),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Text(
                      widget.title,
                      style: GoogleFonts.playfairDisplay(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: textColor,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: _reset,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.06)
                              : Colors.black.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          'Reset',
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: textColor,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: _image == null
                      ? const SizedBox(
                          width: 28, height: 28, child: AppSpinner())
                      : LayoutBuilder(
                          builder: (ctx, c) {
                            final maxW = c.maxWidth;
                            final maxH = c.maxHeight;
                            double w = maxW;
                            double h = w / widget.aspectRatio;
                            if (h > maxH) {
                              h = maxH;
                              w = h * widget.aspectRatio;
                            }
                            final radius = widget.circleOverlay
                                ? w / 2
                                : 16.0;
                            return ClipRRect(
                              borderRadius: BorderRadius.circular(radius),
                              child: RepaintBoundary(
                                key: _frameKey,
                                child: SizedBox(
                                  width: w,
                                  height: h,
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      Container(color: Colors.black),
                                      InteractiveViewer(
                                        transformationController: _controller,
                                        minScale: 0.5,
                                        maxScale: 5.0,
                                        boundaryMargin: const EdgeInsets.all(
                                            double.infinity),
                                        clipBehavior: Clip.none,
                                        child: Image.memory(
                                          widget.imageBytes,
                                          fit: BoxFit.cover,
                                          width: w,
                                          height: h,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Text(
                'Drag to reposition · pinch to zoom',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: mutedColor,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: GestureDetector(
                onTap: _image == null || _saving ? null : _confirm,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: double.infinity,
                  height: 48,
                  decoration: BoxDecoration(
                    color: _image == null
                        ? (isDark
                            ? Colors.white.withValues(alpha: 0.1)
                            : Colors.black.withValues(alpha: 0.1))
                        : textColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Center(
                    child: _saving
                        ? AppSpinner(color: btnFg)
                        : Text(
                            widget.confirmLabel,
                            style: GoogleFonts.inter(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: btnFg,
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
