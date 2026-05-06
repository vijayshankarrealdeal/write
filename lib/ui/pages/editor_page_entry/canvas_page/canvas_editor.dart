import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:inkspacex/models/canvas_element_model.dart';
import 'package:inkspacex/models/image_meta.dart';
import 'package:inkspacex/services/gemini_service.dart';
import 'package:inkspacex/ui/widgets/app_network_image.dart';
import 'package:inkspacex/ui/widgets/app_spinner.dart';

// Decoded image bytes cache for `data:image/...;base64,...` URIs used as
// canvas image elements and the canvas background. The build path
// re-evaluates these on every parent rebuild (e.g. selection change),
// and base64Decode of a phone photo is a multi-MB allocation we should
// not redo per frame. Capped to keep memory bounded.
final Map<String, Uint8List> _canvasDataUriBytesCache = {};
const int _canvasDataUriCacheMax = 32;

Uint8List? _decodeDataUriCached(String url) {
  final cached = _canvasDataUriBytesCache[url];
  if (cached != null) return cached;
  try {
    final commaIdx = url.indexOf(',');
    if (commaIdx == -1) return null;
    final bytes = base64Decode(url.substring(commaIdx + 1));
    if (_canvasDataUriBytesCache.length >= _canvasDataUriCacheMax) {
      _canvasDataUriBytesCache.remove(_canvasDataUriBytesCache.keys.first);
    }
    _canvasDataUriBytesCache[url] = bytes;
    return bytes;
  } catch (_) {
    return null;
  }
}

/// Free-form canvas editor for scrapbook / slam-book / creative layouts.
///
/// Allows placing images and text blocks anywhere on the page,
/// dragging, rotating, and resizing them. Think Pinterest board meets
/// scrapbook meets slam book.
class CanvasEditor extends StatefulWidget {
  final String initialData;
  final ValueChanged<String> onChanged;
  final bool isDark;
  final Future<String?> Function(Uint8List bytes)? onUploadImage;
  final String writingPreview; // plain text preview from Quill
  final String bookTitle;
  final String sectionTitle;
  final List<String> otherSectionTitles;

  const CanvasEditor({
    super.key,
    this.initialData = '',
    required this.onChanged,
    required this.isDark,
    this.onUploadImage,
    this.writingPreview = '',
    this.bookTitle = '',
    this.sectionTitle = '',
    this.otherSectionTitles = const [],
  });

  @override
  State<CanvasEditor> createState() => CanvasEditorState();
}

class CanvasEditorState extends State<CanvasEditor>
    with SingleTickerProviderStateMixin {
  /// Reference width used to convert legacy pixel positions to fractions.
  static const double _kRefWidth = 820.0;

  /// Gradient presets for canvas background (start, end).
  static const _bgGradientPresets = [
    // Warm
    (0xFFFFF8E1, 0xFFFCE4EC), // Cream → Pink
    (0xFFFFF3E0, 0xFFFBE9E7), // Light Orange → Light Red
    (0xFFFCE4EC, 0xFFF3E5F5), // Pink → Lavender
    (0xFFFBE9E7, 0xFFFFF8E1), // Peach → Cream
    // Cool
    (0xFFE3F2FD, 0xFFE8EAF6), // Sky Blue → Indigo
    (0xFFE8F5E9, 0xFFE0F2F1), // Mint → Teal
    (0xFFE0F2F1, 0xFFE3F2FD), // Teal → Sky Blue
    (0xFFEDE7F6, 0xFFE3F2FD), // Purple → Blue
    // Mixed
    (0xFFF3E5F5, 0xFFE8F5E9), // Lavender → Mint
    (0xFFE8EAF6, 0xFFFCE4EC), // Indigo → Pink
    (0xFFFFF8E1, 0xFFE8F5E9), // Cream → Mint
    (0xFFE3F2FD, 0xFFFFF8E1), // Blue → Cream
    // Dark
    (0xFF1A1A2E, 0xFF16213E), // Dark Navy
    (0xFF0F3460, 0xFF1A1A2E), // Deep Blue → Navy
    (0xFF2D132C, 0xFF1A1A2E), // Dark Purple → Navy
    (0xFF1B1B3A, 0xFF0F3460), // Dark → Blue
  ];

  List<CanvasElement> _elements = [];
  String? _selectedId;
  int _nextZIndex = 1;
  bool _imageUploading = false;
  bool _showWritingPreview = false;
  bool _aiGenerating = false;

  // ── Two-finger pinch tracking ──
  double _pinchBaseWidth = 0;
  double _pinchBaseHeight = 0;
  double _pinchBaseRotation = 0;
  int _bgColorValue = 0; // 0 = use default theme color
  String _bgImageUrl = '';
  int? _bgGradientStart;
  int? _bgGradientEnd;
  String _bgGradientDirection = 'top';
  final _gemini = GeminiService();
  late final AnimationController _shimmerController;

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
    _loadElements();
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    super.dispose();
  }

  void _loadElements() {
    if (widget.initialData.isEmpty) return;
    try {
      final decoded = jsonDecode(widget.initialData);
      int version = 1;
      if (decoded is List) {
        // Legacy v0: just elements array (always pixel-based)
        _elements = decoded.map((e) => CanvasElement.fromJson(e as Map<String, dynamic>)).toList();
      } else if (decoded is Map) {
        version = decoded['version'] ?? 1;
        _bgColorValue = decoded['bgColor'] ?? 0;
        _bgImageUrl = decoded['bgImageUrl'] ?? '';
        _bgGradientStart = decoded['bgGradientStart'];
        _bgGradientEnd = decoded['bgGradientEnd'];
        _bgGradientDirection = decoded['bgGradientDirection'] ?? 'top';
        final list = decoded['elements'] as List? ?? [];
        _elements = list.map((e) => CanvasElement.fromJson(e as Map<String, dynamic>)).toList();
      }
      if (_elements.isNotEmpty) {
        _nextZIndex = _elements.map((e) => e.zIndex).reduce(max) + 1;
      }
      // Migrate legacy pixel-based positions to fractions of canvas width
      if (version < 2 && _elements.isNotEmpty) {
        _migrateToFractions();
      }
    } catch (_) {}
  }

  /// Convert old absolute-pixel positions to fractions of [_kRefWidth].
  void _migrateToFractions() {
    for (final e in _elements) {
      e.x = e.x / _kRefWidth;
      e.y = e.y / _kRefWidth;
      e.width = e.width / _kRefWidth;
      e.height = e.height / _kRefWidth;
    }
    // Persist the migrated data on next frame
    Future.microtask(() => _emitChange());
  }

  void _emitChange() {
    widget.onChanged(jsonEncode({
      'version': 2, // fraction-based coordinates
      'bgColor': _bgColorValue,
      'bgImageUrl': _bgImageUrl,
      if (_bgGradientStart != null) 'bgGradientStart': _bgGradientStart,
      if (_bgGradientEnd != null) 'bgGradientEnd': _bgGradientEnd,
      if (_bgGradientStart != null) 'bgGradientDirection': _bgGradientDirection,
      'elements': _elements.map((e) => e.toJson()).toList(),
    }));
  }

  // ── Public API for parent to add images (with data-URI) ──

  void addImageElement(String imageUrl, {double? w, double? h}) {
    final element = CanvasElement(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: CanvasElementType.image,
      imageUrl: imageUrl,
      x: 0.05 + Random().nextDouble() * 0.1,
      y: 0.05 + Random().nextDouble() * 0.07,
      width: w ?? 0.35,
      height: h ?? 0.35,
      zIndex: _nextZIndex++,
    );
    setState(() {
      _elements.add(element);
      _selectedId = element.id;
    });
    _emitChange();
  }

  /// Replace a data-URI image with its uploaded URL.
  void replaceImageUrl(String oldUrl, String newUrl) {
    for (final e in _elements) {
      if (e.type == CanvasElementType.image && e.imageUrl == oldUrl) {
        e.imageUrl = newUrl;
        break;
      }
    }
    _emitChange();
  }

  // ── Element management ──

  void _addTextElement() {
    final isDark = widget.isDark;
    final element = CanvasElement(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: CanvasElementType.text,
      text: 'Tap to edit',
      x: 0.07 + Random().nextDouble() * 0.12,
      y: 0.07 + Random().nextDouble() * 0.1,
      width: 0.3,
      height: 0.1,
      fontFamily: 'Caveat',
      fontSize: 24,
      textColorValue: isDark ? 0xFFFFFFFF : 0xFF111111,
      bgColorValue: 0x00000000,
      zIndex: _nextZIndex++,
    );
    setState(() {
      _elements.add(element);
      _selectedId = element.id;
    });
    _emitChange();
  }

  Future<void> _pickAndAddImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;

    final bytes = await picked.readAsBytes();
    if (!mounted) return;

    // Store as data-URI for instant preview; upload deferred to screen exit
    final dataUri = 'data:image/jpeg;base64,${base64Encode(bytes)}';
    addImageElement(dataUri);
  }

  /// Upload all data-URI images to cloud storage. Call this before
  /// navigating away from the editor screen.
  Future<void> uploadPendingImages() async {
    if (widget.onUploadImage == null) return;

    final pendingElements = _elements
        .where((e) =>
            e.type == CanvasElementType.image &&
            e.imageUrl.startsWith('data:image'))
        .toList();

    if (pendingElements.isEmpty) return;

    if (mounted) setState(() => _imageUploading = true);

    for (final e in pendingElements) {
      try {
        final commaIdx = e.imageUrl.indexOf(',');
        final b64 = e.imageUrl.substring(commaIdx + 1);
        final bytes = Uint8List.fromList(base64Decode(b64));
        final url = await widget.onUploadImage!(bytes);
        if (url != null) {
          e.imageUrl = url;
        }
      } catch (_) {
        // stays as data-URI
      }
    }

    _emitChange();
    if (mounted) setState(() => _imageUploading = false);
  }

  void _deleteSelected() {
    if (_selectedId == null) return;
    setState(() {
      _elements.removeWhere((e) => e.id == _selectedId);
      _selectedId = null;
    });
    _emitChange();
  }

  void _bringToFront() {
    final e = _selected;
    if (e == null) return;
    e.zIndex = _nextZIndex++;
    setState(() {});
    _emitChange();
  }

  void _sendToBack() {
    final e = _selected;
    if (e == null) return;
    for (final el in _elements) {
      el.zIndex += 1;
    }
    e.zIndex = 0;
    setState(() {});
    _emitChange();
  }

  void _duplicateSelected() {
    final e = _selected;
    if (e == null) return;
    final copy = e.copyWith(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      x: e.x + 0.025,
      y: e.y + 0.025,
      zIndex: _nextZIndex++,
    );
    setState(() {
      _elements.add(copy);
      _selectedId = copy.id;
    });
    _emitChange();
  }

  CanvasElement? get _selected => _selectedId == null
      ? null
      : _elements.cast<CanvasElement?>().firstWhere(
          (e) => e?.id == _selectedId,
          orElse: () => null,
        );

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final bgColor = isDark ? const Color(0xFF0A0A0A) : const Color(0xFFFAFAFA);
    final textColor = isDark ? Colors.white : const Color(0xFF111111);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.06);

    final hasSelection = _selectedId != null;

    return Column(
      children: [
        // ── Canvas Toolbar ──
        _buildToolbar(
          isDark: isDark,
          bgColor: bgColor,
          textColor: textColor,
          borderColor: borderColor,
        ),

        // ── Canvas Area ──
        Expanded(
          child: GestureDetector(
            onTap: () => setState(() => _selectedId = null),
            behavior: HitTestBehavior.translucent,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isMobile = constraints.maxWidth < 600;
                final canvasWidget = ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: isMobile ? double.infinity : 820,
                  ),
                  child: AspectRatio(
                    aspectRatio: 3 / 4,
                    child: _buildCanvas(isDark: isDark, textColor: textColor),
                  ),
                );

                if (isMobile) {
                  // On mobile: fill width, scroll vertically if needed
                  return SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                    child: canvasWidget,
                  );
                }
                // On desktop: center with max width
                return Container(
                  color: bgColor,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.all(16),
                  child: canvasWidget,
                );
              },
            ),
          ),
        ),

        // ── Selection Bar (bottom) ──
        if (hasSelection)
          _buildSelectionBar(
            isDark: isDark,
            bgColor: bgColor,
            textColor: textColor,
            borderColor: borderColor,
          ),
      ],
    );
  }

  Widget _buildToolbar({
    required bool isDark,
    required Color bgColor,
    required Color textColor,
    required Color borderColor,
  }) {
    final mutedColor = textColor.withValues(alpha: 0.45);

    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _CanvasToolBtn(icon: CupertinoIcons.photo_fill, label: 'Image', color: textColor, onTap: _pickAndAddImage),
            _CanvasToolBtn(icon: CupertinoIcons.textbox, label: 'Text', color: textColor, onTap: _addTextElement),
            _CanvasToolBtn(icon: CupertinoIcons.smiley, label: 'Stickers', color: textColor, onTap: _showStickerPicker),
            _CanvasToolBtn(icon: CupertinoIcons.paintbrush_fill, label: 'BG', color: textColor, onTap: _showBackgroundPicker),
            if (!_aiGenerating)
              _CanvasToolBtn(icon: CupertinoIcons.wand_stars, label: 'AI', color: isDark ? const Color(0xFF5B8DEF) : const Color(0xFF4A6CF7), onTap: _showAIGenerateDialog),
            if (_elements.isNotEmpty || _bgColorValue != 0 || _bgImageUrl.isNotEmpty)
              _CanvasToolBtn(icon: CupertinoIcons.arrow_counterclockwise, label: 'Reset', color: textColor, onTap: _resetCanvas),
            if (widget.writingPreview.isNotEmpty)
              _CanvasToolBtn(
                icon: _showWritingPreview ? CupertinoIcons.eye_slash : CupertinoIcons.eye,
                label: 'Preview',
                color: _showWritingPreview ? (isDark ? const Color(0xFF5B8DEF) : const Color(0xFF4A6CF7)) : textColor,
                onTap: () => setState(() => _showWritingPreview = !_showWritingPreview),
              ),
            if (_imageUploading || _aiGenerating) ...[
              const SizedBox(width: 8),
              const AppSpinner(size: 14),
              const SizedBox(width: 6),
              Text(_aiGenerating ? 'Generating...' : 'Uploading', style: GoogleFonts.inter(fontSize: 11, color: mutedColor)),
            ],
          ],
        ),
      ),
    );
  }

  /// Bottom bar shown when an element is selected (mobile-friendly)
  Widget _buildSelectionBar({
    required bool isDark,
    required Color bgColor,
    required Color textColor,
    required Color borderColor,
  }) {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(top: BorderSide(color: borderColor)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _CanvasToolBtn(icon: CupertinoIcons.doc_on_doc, label: 'Duplicate', color: textColor, onTap: _duplicateSelected),
            _CanvasToolBtn(icon: CupertinoIcons.arrow_up_square, label: 'Front', color: textColor, onTap: _bringToFront),
            _CanvasToolBtn(icon: CupertinoIcons.arrow_down_square, label: 'Back', color: textColor, onTap: _sendToBack),
            _CanvasToolBtn(icon: CupertinoIcons.paintbrush, label: 'Color', color: textColor, onTap: _showElementColorPicker),
            _CanvasToolBtn(
              icon: (_selected?.hasBorder ?? false) ? Icons.border_all_rounded : Icons.border_clear_rounded,
              label: 'Border',
              color: (_selected?.hasBorder ?? false) ? (isDark ? const Color(0xFF5B8DEF) : const Color(0xFF4A6CF7)) : textColor,
              onTap: _showBorderPicker,
            ),
            _CanvasToolBtn(icon: CupertinoIcons.trash, label: 'Delete', color: Colors.redAccent, onTap: _deleteSelected),
          ],
        ),
      ),
    );
  }

  Widget _buildCanvas({required bool isDark, required Color textColor}) {
    final paperColor = _bgColorValue != 0 ? Color(_bgColorValue) : (isDark ? const Color(0xFF131315) : Colors.white);
    final paperBorder = isDark
        ? Colors.white.withValues(alpha: 0.05)
        : Colors.black.withValues(alpha: 0.06);
    final hasBgGradient = _bgGradientStart != null && _bgGradientEnd != null;
    final bgGradientAlign = _gradientAlignment(_bgGradientDirection);

    // Sort by zIndex
    final sorted = [..._elements]..sort((a, b) => a.zIndex.compareTo(b.zIndex));

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      decoration: BoxDecoration(
        color: hasBgGradient ? null : paperColor,
        gradient: hasBgGradient
            ? LinearGradient(
                begin: bgGradientAlign.$1,
                end: bgGradientAlign.$2,
                colors: [Color(_bgGradientStart!), Color(_bgGradientEnd!)],
              )
            : null,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: paperBorder),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final cw = constraints.maxWidth;
            final ch = constraints.maxHeight;

            Widget canvas = SizedBox(
              width: cw,
              height: ch,
              child: Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  // Background fill (for scrollable area)
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        color: hasBgGradient ? null : paperColor,
                        gradient: hasBgGradient
                            ? LinearGradient(
                                begin: bgGradientAlign.$1,
                                end: bgGradientAlign.$2,
                                colors: [Color(_bgGradientStart!), Color(_bgGradientEnd!)],
                              )
                            : null,
                      ),
                    ),
                  ),

                  // Background image
                  if (_bgImageUrl.isNotEmpty)
                    Positioned(
                      left: 0, right: 0, top: 0,
                      height: ch,
                      child: _bgImageUrl.startsWith('data:image')
                          ? () {
                              final bytes =
                                  _decodeDataUriCached(_bgImageUrl);
                              if (bytes == null) return const SizedBox();
                              return Image.memory(
                                bytes,
                                fit: BoxFit.cover,
                                gaplessPlayback: true,
                              );
                            }()
                          : AppNetworkImage(
                              url: _bgImageUrl,
                              meta: ImageMeta.fromInlineUrl(_bgImageUrl),
                              fit: BoxFit.cover,
                            ),
                    ),

                  // Background tap to deselect
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: () => setState(() => _selectedId = null),
                      behavior: HitTestBehavior.translucent,
                      child: const SizedBox.expand(),
                    ),
                  ),

                  // Elements
                  for (final e in sorted)
                    _buildElement(e, isDark: isDark, textColor: textColor, canvasWidth: cw, canvasHeight: ch),

                  // AI generating skeleton animation
                  if (_aiGenerating)
                    Positioned(
                      left: 0, right: 0, top: 0,
                      height: ch,
                      child: _buildGeneratingOverlay(isDark: isDark, textColor: textColor),
                    ),

                  // Empty state hint
                  if (_elements.isEmpty && !_aiGenerating)
                    Positioned(
                      left: 0, right: 0, top: 0, height: ch,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              CupertinoIcons.photo,
                              size: 48,
                              color: textColor.withValues(alpha: 0.12),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'Add images & text to create\nyour scrapbook page',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.inter(
                                fontSize: 15,
                                color: textColor.withValues(alpha: 0.25),
                                height: 1.5,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Use the toolbar above to get started',
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                color: textColor.withValues(alpha: 0.15),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // Writing preview overlay
                  if (_showWritingPreview && widget.writingPreview.isNotEmpty)
                    Positioned.fill(
                      child: Container(
                        color: (isDark ? Colors.black : Colors.white).withValues(alpha: 0.85),
                        padding: const EdgeInsets.all(24),
                        child: SingleChildScrollView(
                          child: Text(
                            widget.writingPreview,
                            style: GoogleFonts.inter(fontSize: 15, height: 1.7, color: isDark ? Colors.white70 : Colors.black87),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            );

            return SizedBox(
              width: cw,
              height: ch,
              child: canvas,
            );
          },
        ),
      ),
    );
  }

  Widget _buildGeneratingOverlay({required bool isDark, required Color textColor}) {
    final shimmerBase = isDark
        ? Colors.white.withValues(alpha: 0.04)
        : Colors.black.withValues(alpha: 0.04);
    final shimmerHighlight = isDark
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.black.withValues(alpha: 0.08);

    return AnimatedBuilder(
      animation: _shimmerController,
      builder: (context, child) {
        final t = _shimmerController.value;
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title skeleton
              _shimmerBlock(
                width: 0.6, height: 40, borderRadius: 8,
                base: shimmerBase, highlight: shimmerHighlight,
                phase: t, delay: 0.0,
              ),
              const SizedBox(height: 10),
              // Subtitle skeleton
              _shimmerBlock(
                width: 0.35, height: 16, borderRadius: 6,
                base: shimmerBase, highlight: shimmerHighlight,
                phase: t, delay: 0.1,
              ),
              const SizedBox(height: 24),
              // Two image placeholders side by side
              Row(
                children: [
                  Expanded(
                    child: _shimmerBlock(
                      height: 160, borderRadius: 12,
                      base: shimmerBase, highlight: shimmerHighlight,
                      phase: t, delay: 0.2,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _shimmerBlock(
                      height: 160, borderRadius: 12,
                      base: shimmerBase, highlight: shimmerHighlight,
                      phase: t, delay: 0.3,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              // Quote text skeleton
              _shimmerBlock(
                width: 0.7, height: 24, borderRadius: 6,
                base: shimmerBase, highlight: shimmerHighlight,
                phase: t, delay: 0.4,
              ),
              const SizedBox(height: 8),
              _shimmerBlock(
                width: 0.5, height: 24, borderRadius: 6,
                base: shimmerBase, highlight: shimmerHighlight,
                phase: t, delay: 0.45,
              ),
              const SizedBox(height: 24),
              // Body text lines
              _shimmerBlock(
                width: 0.8, height: 14, borderRadius: 4,
                base: shimmerBase, highlight: shimmerHighlight,
                phase: t, delay: 0.5,
              ),
              const SizedBox(height: 6),
              _shimmerBlock(
                width: 0.6, height: 14, borderRadius: 4,
                base: shimmerBase, highlight: shimmerHighlight,
                phase: t, delay: 0.55,
              ),
              const Spacer(),
              // Bottom label
              Center(
                child: Column(
                  children: [
                    const AppSpinner(),
                    const SizedBox(height: 12),
                    Text(
                      'Creating your layout...',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: textColor.withValues(alpha: 0.3),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  Widget _shimmerBlock({
    double? width,
    required double height,
    required double borderRadius,
    required Color base,
    required Color highlight,
    required double phase,
    required double delay,
  }) {
    // Each block pulses with a staggered delay
    final adjustedPhase = (phase + delay) % 1.0;
    // Smooth sine pulse: 0→1→0
    final pulse = (sin(adjustedPhase * pi * 2) + 1) / 2;
    final color = Color.lerp(base, highlight, pulse)!;

    return FractionallySizedBox(
      widthFactor: width,
      alignment: Alignment.centerLeft,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(borderRadius),
        ),
      ),
    );
  }

  Widget _buildElement(
    CanvasElement e, {
    required bool isDark,
    required Color textColor,
    required double canvasWidth,
    required double canvasHeight,
  }) {
    final isSelected = e.id == _selectedId;
    final accentColor = isDark
        ? const Color(0xFF5B8DEF)
        : const Color(0xFF4A6CF7);

    // x/width are fractions of canvasWidth, y/height are fractions of canvasHeight
    final pxX = e.x * canvasWidth;
    final pxY = e.y * canvasHeight;
    final pxW = e.width * canvasWidth;
    final pxH = e.height * canvasHeight;

    return Positioned(
      left: pxX,
      top: pxY,
      child: GestureDetector(
        onTap: () {
          setState(() => _selectedId = e.id);
        },
        onDoubleTap: e.type == CanvasElementType.text
            ? () => _showTextEditor(e)
            : null,
        onLongPress: isSelected ? () => _showTransformDialog(e) : null,
        onScaleStart: (d) {
          if (_selectedId != e.id) {
            setState(() => _selectedId = e.id);
          }
          // Save initial values for pinch-to-scale/rotate
          _pinchBaseWidth = e.width;
          _pinchBaseHeight = e.height;
          _pinchBaseRotation = e.rotation;
        },
        onScaleUpdate: (d) {
          if (_selectedId != e.id) {
            setState(() => _selectedId = e.id);
          }
          setState(() {
            if (d.pointerCount == 1) {
              // Single finger → move
              e.x += d.focalPointDelta.dx / canvasWidth;
              e.y += d.focalPointDelta.dy / canvasHeight;
            } else if (d.pointerCount >= 2) {
              // Two fingers → pinch to scale + rotate
              final scaleFactor = d.scale;
              if (e.type == CanvasElementType.image) {
                // Maintain aspect ratio for images
                final ratio = _pinchBaseHeight / _pinchBaseWidth;
                final newW = (_pinchBaseWidth * scaleFactor).clamp(0.07, 1.5);
                e.width = newW;
                e.height = (newW * ratio).clamp(0.07, 2.0);
              } else {
                e.width = (_pinchBaseWidth * scaleFactor).clamp(0.1, 1.5);
                e.height = (_pinchBaseHeight * scaleFactor).clamp(0.05, 2.0);
              }
              // Rotation from two-finger twist
              e.rotation = (_pinchBaseRotation + d.rotation).clamp(-pi, pi);
            }
          });
        },
        onScaleEnd: (_) => _emitChange(),
        child: Transform.rotate(
          angle: e.rotation,
          child: SizedBox(
            width: pxW,
            height: pxH,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // ── Content (clipped to bounds) ──
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(
                      e.type == CanvasElementType.text ? 8 : 6,
                    ),
                    child: _buildContent(e, isDark: isDark, textColor: textColor, canvasWidth: canvasWidth),
                  ),
                ),

                // ── Selection overlay ──
                if (isSelected) ...[
                  // Border
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: accentColor, width: 2),
                          borderRadius: BorderRadius.circular(
                            e.type == CanvasElementType.text ? 8 : 4,
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Resize handle (bottom-right)
                  Positioned(
                    right: -8,
                    bottom: -8,
                    child: GestureDetector(
                      onPanUpdate: (d) => _onResize(e, d, canvasWidth, canvasHeight),
                      onPanEnd: (_) => _emitChange(),
                      child: _handle(
                        accentColor,
                        CupertinoIcons.arrow_up_left_arrow_down_right,
                      ),
                    ),
                  ),

                  // Rotation handle (top-center)
                  Positioned(
                    left: pxW / 2 - 14,
                    top: -44,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        GestureDetector(
                          onPanUpdate: (d) => _onRotate(e, d),
                          onPanEnd: (_) => _emitChange(),
                          child: _handle(
                            accentColor,
                            CupertinoIcons.rotate_right,
                          ),
                        ),
                        Container(
                          width: 1,
                          height: 12,
                          color: accentColor.withValues(alpha: 0.4),
                        ),
                      ],
                    ),
                  ),

                  // Delete handle (top-right)
                  Positioned(
                    right: -14,
                    top: -14,
                    child: GestureDetector(
                      onTap: _deleteSelected,
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: Colors.redAccent,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.25),
                              blurRadius: 6,
                            ),
                          ],
                        ),
                        child: const Icon(
                          CupertinoIcons.xmark,
                          size: 13,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),

                  // Info badge (bottom-left — shows rotation degrees)
                  if (e.rotation.abs() > 0.01)
                    Positioned(
                      left: -8,
                      bottom: -8,
                      child: IgnorePointer(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: accentColor,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '${(e.rotation * 180 / pi).round()}°',
                            style: GoogleFonts.inter(
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(
    CanvasElement e, {
    required bool isDark,
    required Color textColor,
    required double canvasWidth,
  }) {
    if (e.type == CanvasElementType.image) {
      return _buildImageContent(e, isDark: isDark);
    }
    return _buildTextContent(e, isDark: isDark, textColor: textColor, canvasWidth: canvasWidth);
  }

  Widget _buildImageContent(CanvasElement e, {required bool isDark}) {
    // Empty imageUrl = placeholder for user to add their photo
    if (e.imageUrl.isEmpty) {
      // Determine if canvas bg is dark to pick contrasting placeholder colors
      final canvasBgColor = _bgColorValue != 0
          ? Color(_bgColorValue)
          : (isDark ? const Color(0xFF131315) : Colors.white);
      final bgLuminance = canvasBgColor.computeLuminance();
      final onDarkBg = bgLuminance < 0.4;

      return GestureDetector(
        onTap: () => _pickImageForElement(e),
        child: Container(
          decoration: BoxDecoration(
            color: onDarkBg
                ? Colors.white.withValues(alpha: 0.12)
                : Colors.black.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: onDarkBg
                  ? Colors.white.withValues(alpha: 0.3)
                  : Colors.black.withValues(alpha: 0.2),
              width: 2,
              strokeAlign: BorderSide.strokeAlignInside,
            ),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: onDarkBg
                        ? Colors.white.withValues(alpha: 0.15)
                        : Colors.black.withValues(alpha: 0.08),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    CupertinoIcons.camera_fill,
                    size: 24,
                    color: onDarkBg
                        ? Colors.white.withValues(alpha: 0.7)
                        : Colors.black.withValues(alpha: 0.4),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Tap to add photo',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: onDarkBg
                        ? Colors.white.withValues(alpha: 0.6)
                        : Colors.black.withValues(alpha: 0.4),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    Widget imageWidget;

    if (e.imageUrl.startsWith('data:image')) {
      final bytes = _decodeDataUriCached(e.imageUrl);
      imageWidget = bytes == null
          ? _errorPlaceholder(isDark)
          : Image.memory(
              bytes,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => _errorPlaceholder(isDark),
            );
    } else if (e.imageUrl.startsWith('http')) {
      imageWidget = AppNetworkImage(
        url: e.imageUrl,
        meta: ImageMeta.fromInlineUrl(e.imageUrl),
        fit: BoxFit.cover,
        errorWidget: _errorPlaceholder(isDark),
      );
    } else {
      imageWidget = _errorPlaceholder(isDark);
    }

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: e.hasBorder
            ? Border.all(color: Color(e.borderColorValue), width: 2)
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(e.hasBorder ? 4 : 6),
        child: imageWidget,
      ),
    );
  }

  /// Pick an image and assign it to a specific element (for placeholders).
  Future<void> _pickImageForElement(CanvasElement e) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;

    final bytes = await picked.readAsBytes();
    if (!mounted) return;

    final dataUri = 'data:image/jpeg;base64,${base64Encode(bytes)}';
    setState(() => e.imageUrl = dataUri);
    _emitChange();
  }

  Widget _buildTextContent(
    CanvasElement e, {
    required bool isDark,
    required Color textColor,
    required double canvasWidth,
  }) {
    // Scale font size proportionally so text looks the same on any screen
    final scale = canvasWidth / _kRefWidth;
    final scaledFontSize = e.fontSize * scale;

    TextStyle style;
    try {
      style = GoogleFonts.getFont(
        e.fontFamily,
        fontSize: scaledFontSize,
        color: Color(e.textColorValue),
        fontWeight: e.isBold ? FontWeight.bold : FontWeight.normal,
        fontStyle: e.isItalic ? FontStyle.italic : FontStyle.normal,
      );
    } catch (_) {
      style = TextStyle(
        fontFamily: e.fontFamily,
        fontSize: scaledFontSize,
        color: Color(e.textColorValue),
        fontWeight: e.isBold ? FontWeight.bold : FontWeight.normal,
        fontStyle: e.isItalic ? FontStyle.italic : FontStyle.normal,
      );
    }

    final align =
        {
          'left': TextAlign.left,
          'center': TextAlign.center,
          'right': TextAlign.right,
        }[e.textAlign] ??
        TextAlign.left;

    // Determine gradient alignment
    final gradientBeginEnd = _gradientAlignment(e.gradientDirection);
    final hasGradient = e.gradientStartColor != null && e.gradientEndColor != null;

    return Container(
      padding: EdgeInsets.all(12 * scale),
      decoration: BoxDecoration(
        color: hasGradient
            ? null
            : (e.bgColorValue == 0x00000000 ? null : Color(e.bgColorValue)),
        gradient: hasGradient
            ? LinearGradient(
                begin: gradientBeginEnd.$1,
                end: gradientBeginEnd.$2,
                colors: [
                  Color(e.gradientStartColor!),
                  Color(e.gradientEndColor!),
                ],
              )
            : null,
        borderRadius: BorderRadius.circular(8 * scale),
        border: e.hasBorder
            ? Border.all(
                color: Color(e.borderColorValue),
                width: 1.5,
              )
            : null,
      ),
      alignment: Alignment.topLeft,
      child: Text(
        e.text,
        style: style,
        textAlign: align,
        overflow: TextOverflow.fade,
      ),
    );
  }

  (Alignment, Alignment) _gradientAlignment(String direction) {
    switch (direction) {
      case 'top':
        return (Alignment.topCenter, Alignment.bottomCenter);
      case 'left':
        return (Alignment.centerLeft, Alignment.centerRight);
      case 'topRight':
        return (Alignment.topRight, Alignment.bottomLeft);
      case 'topLeft':
      default:
        return (Alignment.topLeft, Alignment.bottomRight);
    }
  }

  Widget _errorPlaceholder(bool isDark) {
    return Container(
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.04)
            : Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            CupertinoIcons.photo,
            color: isDark ? Colors.white24 : Colors.black26,
            size: 28,
          ),
          const SizedBox(height: 6),
          Text(
            'Image failed',
            style: TextStyle(
              color: isDark ? Colors.white30 : Colors.black26,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _handle(Color color, IconData icon) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Icon(icon, size: 17, color: Colors.white),
    );
  }

  // ── Resize ──

  void _onResize(CanvasElement e, DragUpdateDetails d, double canvasWidth, double canvasHeight) {
    setState(() {
      final dw = d.delta.dx / canvasWidth;
      final dh = d.delta.dy / canvasHeight;
      if (e.type == CanvasElementType.image) {
        // Maintain aspect ratio for images
        final ratio = e.height / e.width;
        final newW = (e.width + dw).clamp(0.07, 1.5);
        e.width = newW;
        e.height = (newW * ratio).clamp(0.07, 2.0);
      } else {
        // Free resize for text
        e.width = (e.width + dw).clamp(0.1, 1.5);
        e.height = (e.height + dh).clamp(0.05, 2.0);
      }
    });
  }

  // ── Rotate ──

  void _onRotate(CanvasElement e, DragUpdateDetails d) {
    setState(() {
      // Horizontal drag → rotation: ~1° per 2px
      e.rotation += d.delta.dx * 0.008;
      // Clamp to ±180°
      e.rotation = e.rotation.clamp(-pi, pi);
    });
  }

  // ── Transform dialog (long-press on selected element) ──

  void _showTransformDialog(CanvasElement e) {
    final isDark = widget.isDark;
    final sheetBg = isDark ? const Color(0xFF1C1C1E) : Colors.white;
    final labelColor = isDark ? Colors.white70 : Colors.black87;
    final accentColor = isDark
        ? const Color(0xFF5B8DEF)
        : const Color(0xFF4A6CF7);

    double tempRotation = e.rotation;
    double tempScale = 1.0; // 1.0 = current size

    showModalBottomSheet(
      context: context,
      backgroundColor: sheetBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final degrees = (tempRotation * 180 / pi).round();
            final scalePercent = (tempScale * 100).round();
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ── Drag handle ──
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white24 : Colors.black12,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 16),

                  Text(
                    'Transform',
                    style: GoogleFonts.inter(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: labelColor,
                    ),
                  ),
                  const SizedBox(height: 20),

                  // ── Rotation ──
                  Row(
                    children: [
                      Icon(CupertinoIcons.rotate_right,
                          size: 18, color: labelColor),
                      const SizedBox(width: 8),
                      Text(
                        'Rotation',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: labelColor,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '$degrees°',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: accentColor,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  SliderTheme(
                    data: SliderTheme.of(ctx).copyWith(
                      activeTrackColor: accentColor,
                      inactiveTrackColor: accentColor.withValues(alpha: 0.15),
                      thumbColor: accentColor,
                      overlayColor: accentColor.withValues(alpha: 0.12),
                      trackHeight: 4,
                    ),
                    child: Slider(
                      value: tempRotation,
                      min: -pi,
                      max: pi,
                      onChanged: (v) {
                        setSheetState(() => tempRotation = v);
                        setState(() {
                          e.rotation = v;
                        });
                      },
                      onChangeEnd: (_) => _emitChange(),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // ── Scale ──
                  Row(
                    children: [
                      Icon(CupertinoIcons.arrow_up_left_arrow_down_right,
                          size: 18, color: labelColor),
                      const SizedBox(width: 8),
                      Text(
                        'Scale',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: labelColor,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '$scalePercent%',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: accentColor,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  SliderTheme(
                    data: SliderTheme.of(ctx).copyWith(
                      activeTrackColor: accentColor,
                      inactiveTrackColor: accentColor.withValues(alpha: 0.15),
                      thumbColor: accentColor,
                      overlayColor: accentColor.withValues(alpha: 0.12),
                      trackHeight: 4,
                    ),
                    child: Slider(
                      value: tempScale,
                      min: 0.25,
                      max: 3.0,
                      onChanged: (v) {
                        setSheetState(() => tempScale = v);
                        setState(() {
                          if (e.type == CanvasElementType.image) {
                            final ratio = e.height / e.width;
                            final newW = (e.width / tempScale * v).clamp(0.07, 1.5);
                            e.width = newW;
                            e.height = (newW * ratio).clamp(0.07, 2.0);
                          } else {
                            final ratioW = v / tempScale;
                            e.width = (e.width * ratioW).clamp(0.1, 1.5);
                            e.height = (e.height * ratioW).clamp(0.05, 2.0);
                          }
                          tempScale = v;
                        });
                      },
                      onChangeEnd: (_) => _emitChange(),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // ── Action buttons ──
                  Row(
                    children: [
                      // Reset rotation
                      Expanded(
                        child: _transformActionButton(
                          icon: CupertinoIcons.rotate_left,
                          label: 'Reset Angle',
                          color: accentColor,
                          isDark: isDark,
                          onTap: () {
                            setSheetState(() => tempRotation = 0);
                            setState(() => e.rotation = 0);
                            _emitChange();
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Reset scale
                      Expanded(
                        child: _transformActionButton(
                          icon: CupertinoIcons.arrow_counterclockwise,
                          label: 'Reset Size',
                          color: accentColor,
                          isDark: isDark,
                          onTap: () {
                            setSheetState(() => tempScale = 1.0);
                            setState(() {
                              e.width = 0.27;
                              e.height = 0.27;
                            });
                            _emitChange();
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _transformActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required bool isDark,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Border picker ──

  void _showElementColorPicker() {
    final e = _selected;
    if (e == null) return;
    final isDark = widget.isDark;
    final textColor = isDark ? Colors.white : const Color(0xFF111111);

    final fillColors = [
      0, // transparent
      0xFFFFFFFF, 0xFFFFF8E1, 0xFFFFF3E0, 0xFFFBE9E7,
      0xFFFCE4EC, 0xFFF3E5F5, 0xFFE8F5E9, 0xFFE0F2F1,
      0xFFE3F2FD, 0xFFEDE7F6, 0xFFE8EAF6,
      0xFF000000, 0xFF1A1A2E, 0xFF111111, 0xFF2C2C2E,
      0xFFFF5252, 0xFFFF6D00, 0xFFFFAB00, 0xFF00C853,
      0xFF00B0FF, 0xFF651FFF, 0xFFD500F9, 0xFFFF1744,
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF0C0C0C) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 16), decoration: BoxDecoration(color: textColor.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(2)))),
            Text('Fill Color', style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w700, color: textColor)),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: fillColors.map((c) {
                final isActive = c == e.bgColorValue;
                final isTransparent = c == 0;
                return GestureDetector(
                  onTap: () {
                    setState(() => e.bgColorValue = c);
                    _emitChange();
                    Navigator.pop(ctx);
                  },
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: isTransparent
                          ? (isDark ? const Color(0xFF1A1A1A) : const Color(0xFFF0F0F0))
                          : Color(c),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isActive
                            ? (isDark ? Colors.white : const Color(0xFF111111))
                            : (c == 0xFFFFFFFF
                                ? Colors.black.withValues(alpha: 0.1)
                                : isDark
                                    ? Colors.white.withValues(alpha: 0.1)
                                    : Colors.black.withValues(alpha: 0.08)),
                        width: isActive ? 2.5 : 1,
                      ),
                    ),
                    child: isTransparent
                        ? Icon(CupertinoIcons.clear, size: 14, color: textColor.withValues(alpha: 0.3))
                        : null,
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  void _showBorderPicker() {
    final e = _selected;
    if (e == null) return;
    final isDark = widget.isDark;
    final textColor = isDark ? Colors.white : const Color(0xFF111111);

    final borderColors = [
      0xFFFFFFFF, 0xFF000000, 0xFF5B8DEF, 0xFFFF595E,
      0xFF1982C4, 0xFF8AC926, 0xFFFFCA3A, 0xFFFF6B6B,
      0xFFA855F7, 0xFF06B6D4, 0xFFE91E63, 0xFFFF9800,
      0xFF795548, 0xFF607D8B, 0xFF9E9E9E, 0xFF40FFFFFF,
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF0C0C0C) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: textColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Text(
                      'Border',
                      style: GoogleFonts.inter(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: textColor,
                      ),
                    ),
                    const Spacer(),
                    CupertinoSwitch(
                      value: e.hasBorder,
                      activeTrackColor: isDark
                          ? const Color(0xFF5B8DEF)
                          : CupertinoColors.activeBlue,
                      onChanged: (v) {
                        setState(() => e.hasBorder = v);
                        setSheetState(() {});
                        _emitChange();
                      },
                    ),
                  ],
                ),
                if (e.hasBorder) ...[
                  const SizedBox(height: 16),
                  Text(
                    'COLOR',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: textColor.withValues(alpha: 0.4),
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: borderColors.map((c) {
                      final isActive = c == e.borderColorValue;
                      return GestureDetector(
                        onTap: () {
                          setState(() => e.borderColorValue = c);
                          setSheetState(() {});
                          _emitChange();
                        },
                        child: Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: Color(c),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isActive
                                  ? (isDark ? Colors.white : Colors.black)
                                  : (isDark
                                      ? Colors.white.withValues(alpha: 0.1)
                                      : Colors.black.withValues(alpha: 0.08)),
                              width: isActive ? 2.5 : 1,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  // ── Background picker ──

  void _showBackgroundPicker() {
    final isDark = widget.isDark;
    final textColor = isDark ? Colors.white : const Color(0xFF111111);
    final bgColors = [
      0, // default / clear
      // Blacks & dark grays
      0xFF000000, 0xFF131315, 0xFF1C1C1E, 0xFF2C2C2E, 0xFF3A3A3C,
      // Dark moody
      0xFF1A1A2E, 0xFF16213E, 0xFF0F3460, 0xFF1B1B3A, 0xFF2D132C,
      // Whites & light neutrals
      0xFFFFFFFF, 0xFFF5F5F5, 0xFFEEEEEE, 0xFFE0E0E0,
      // Warm pastels
      0xFFFFF8E1, 0xFFFFF3E0, 0xFFFBE9E7, 0xFFFCE4EC, 0xFFF3E5F5,
      // Cool pastels
      0xFFE8F5E9, 0xFFE0F2F1, 0xFFE3F2FD, 0xFFE8EAF6, 0xFFEDE7F6,
      // Vibrant
      0xFFFF5252, 0xFFFF6D00, 0xFFFFAB00, 0xFF00C853,
      0xFF00B0FF, 0xFF651FFF, 0xFFD500F9, 0xFFFF1744,
      // Rich & deep
      0xFF1B5E20, 0xFF004D40, 0xFF01579B, 0xFF4A148C,
      0xFF880E4F, 0xFFBF360C, 0xFF3E2723, 0xFF263238,
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF0C0C0C) : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.65,
        minChildSize: 0.4,
        maxChildSize: 0.85,
        expand: false,
        builder: (ctx, scrollController) => SingleChildScrollView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: Container(width: 36, height: 4, margin: const EdgeInsets.only(bottom: 16), decoration: BoxDecoration(color: textColor.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(2)))),
              Text('Background', style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w700, color: textColor)),
              const SizedBox(height: 16),
              Text('COLOR', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: textColor.withValues(alpha: 0.4), letterSpacing: 1)),
              const SizedBox(height: 10),
              Wrap(
              spacing: 10, runSpacing: 10,
              children: bgColors.map((c) {
                final isActive = c == _bgColorValue;
                final isDefault = c == 0;
                return GestureDetector(
                  onTap: () {
                    setState(() {
                      _bgColorValue = c;
                      _bgGradientStart = null;
                      _bgGradientEnd = null;
                    });
                    _emitChange();
                    Navigator.pop(ctx);
                  },
                  child: Container(
                    width: 38, height: 38,
                    decoration: BoxDecoration(
                      color: isDefault ? (isDark ? const Color(0xFF131315) : Colors.white) : Color(c),
                      shape: BoxShape.circle,
                      border: Border.all(color: isActive ? (isDark ? Colors.white : Colors.black) : (isDark ? Colors.white.withValues(alpha: 0.1) : Colors.black.withValues(alpha: 0.08)), width: isActive ? 2.5 : 1),
                    ),
                    child: isDefault ? Icon(CupertinoIcons.clear, size: 14, color: textColor.withValues(alpha: 0.3)) : null,
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 20),
            Text('GRADIENT', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: textColor.withValues(alpha: 0.4), letterSpacing: 1)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10, runSpacing: 10,
              children: _bgGradientPresets.map((g) {
                final isActive = _bgGradientStart == g.$1 && _bgGradientEnd == g.$2;
                return GestureDetector(
                  onTap: () {
                    setState(() {
                      _bgGradientStart = g.$1;
                      _bgGradientEnd = g.$2;
                      _bgGradientDirection = 'top';
                      _bgColorValue = g.$1; // fallback
                    });
                    _emitChange();
                    Navigator.pop(ctx);
                  },
                  child: Container(
                    width: 38, height: 38,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(g.$1), Color(g.$2)],
                      ),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isActive
                            ? (isDark ? Colors.white : Colors.black)
                            : (isDark ? Colors.white.withValues(alpha: 0.1) : Colors.black.withValues(alpha: 0.08)),
                        width: isActive ? 2.5 : 1,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 20),
            Text('IMAGE', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: textColor.withValues(alpha: 0.4), letterSpacing: 1)),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: CupertinoButton(
                    color: isDark ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(12),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    onPressed: () async {
                      Navigator.pop(ctx);
                      final picker = ImagePicker();
                      final picked = await picker.pickImage(source: ImageSource.gallery);
                      if (picked == null || !mounted) return;
                      final bytes = await picked.readAsBytes();
                      if (!mounted) return;
                      final dataUri = 'data:image/jpeg;base64,${base64Encode(bytes)}';
                      setState(() => _bgImageUrl = dataUri);
                      _emitChange();
                      // Background upload
                      if (widget.onUploadImage != null) {
                        final url = await widget.onUploadImage!(bytes);
                        if (url != null && mounted) {
                          setState(() {
                            if (_bgImageUrl == dataUri) _bgImageUrl = url;
                          });
                          _emitChange();
                        }
                      }
                    },
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(CupertinoIcons.photo, size: 18, color: textColor),
                        const SizedBox(width: 8),
                        Text('Choose Image', style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w500, color: textColor)),
                      ],
                    ),
                  ),
                ),
                if (_bgImageUrl.isNotEmpty) ...[
                  const SizedBox(width: 10),
                  CupertinoButton(
                    color: Colors.redAccent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    onPressed: () {
                      setState(() => _bgImageUrl = '');
                      _emitChange();
                      Navigator.pop(ctx);
                    },
                    child: Icon(CupertinoIcons.trash, size: 18, color: Colors.redAccent),
                  ),
                ],
              ],
            ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Sticker picker ──

  void _showStickerPicker() {
    final isDark = widget.isDark;
    final textColor = isDark ? Colors.white : const Color(0xFF111111);

    const categories = <String, List<String>>{
      'Favorites': ['✨', '💖', '🔥', '⭐', '🌟', '💫', '🎉', '🥰', '😍', '🤩', '💯', '🙌'],
      'Hearts & Love': ['❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍', '💕', '💗', '💝', '💘'],
      'Decorative': ['✦', '✧', '◆', '◇', '★', '☆', '●', '○', '♡', '♢', '♤', '♧', '→', '←', '↑', '↓', '∞', '~', '—', '•', '⟡', '❋', '❊', '✿'],
      'Nature': ['🌸', '🌺', '🌻', '🌹', '🌷', '🍀', '🌿', '🍃', '🌈', '☀️', '🌙', '⛅', '🦋', '🐝', '🌊', '❄️'],
      'Expressions': ['😊', '😂', '🥺', '😎', '🤗', '😇', '🤔', '😴', '🥳', '😋', '🫶', '👏', '✌️', '🤟', '👋', '💪'],
      'Objects': ['📸', '🎵', '🎶', '📖', '✏️', '🎨', '☕', '🍰', '🎀', '🏷️', '📌', '💌', '🕯️', '🧸', '🪞', '💐'],
      'Travel': ['✈️', '🗺️', '🏔️', '🏖️', '🌍', '🚗', '🎡', '🏕️', '🌄', '🗼', '🏰', '⛵'],
      'Badges': ['🏅', '🎖️', '🏆', '👑', '💎', '🔑', '🎯', '🚀', '⚡', '🌠', '🎭', '🎪'],
    };

    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF0C0C0C) : Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.55,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36, height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: textColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                'Stickers',
                style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.w700, color: textColor),
              ),
              const SizedBox(height: 4),
              Text(
                'Tap a sticker to place it on the canvas',
                style: GoogleFonts.inter(fontSize: 13, color: textColor.withValues(alpha: 0.4)),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView(
                  children: categories.entries.map((entry) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.key.toUpperCase(),
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: textColor.withValues(alpha: 0.35),
                              letterSpacing: 1,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 4, runSpacing: 4,
                            children: entry.value.map((sticker) {
                              return GestureDetector(
                                onTap: () {
                                  Navigator.pop(ctx);
                                  _addStickerElement(sticker);
                                },
                                child: Container(
                                  width: 44, height: 44,
                                  decoration: BoxDecoration(
                                    color: isDark
                                        ? Colors.white.withValues(alpha: 0.06)
                                        : Colors.black.withValues(alpha: 0.03),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(sticker, style: const TextStyle(fontSize: 24)),
                                ),
                              );
                            }).toList(),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _addStickerElement(String sticker) {
    final element = CanvasElement(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: CanvasElementType.text,
      text: sticker,
      x: 0.3 + Random().nextDouble() * 0.15,
      y: 0.2 + Random().nextDouble() * 0.2,
      width: 0.12,
      height: 0.1,
      fontFamily: 'Inter',
      fontSize: 48,
      textColorValue: 0xFF000000,
      bgColorValue: 0x00000000,
      textAlign: 'center',
      zIndex: _nextZIndex++,
    );
    setState(() {
      _elements.add(element);
      _selectedId = element.id;
    });
    _emitChange();
  }

  // ── Reset canvas ──

  void _resetCanvas() {
    showCupertinoDialog(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text('Clear Canvas', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
        content: Text(
          'This will remove all elements and reset the background. This cannot be undone.',
          style: GoogleFonts.inter(),
        ),
        actions: [
          CupertinoDialogAction(
            child: Text('Cancel', style: GoogleFonts.inter()),
            onPressed: () => Navigator.pop(ctx),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            child: Text('Clear All', style: GoogleFonts.inter()),
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                _elements.clear();
                _selectedId = null;
                _bgColorValue = 0;
                _bgImageUrl = '';
                _bgGradientStart = null;
                _bgGradientEnd = null;
                _bgGradientDirection = 'top';
                _nextZIndex = 1;
              });
              _emitChange();
            },
          ),
        ],
      ),
    );
  }

  // ── AI Generate ──

  void _showAIGenerateDialog() {
    final isDark = widget.isDark;
    final textColor = isDark ? Colors.white : const Color(0xFF111111);
    final accentColor = isDark ? const Color(0xFF5B8DEF) : const Color(0xFF4A6CF7);
    final promptController = TextEditingController();

    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF0C0C0C) : Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
          20, 8, 20, MediaQuery.of(ctx).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36, height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: textColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                Icon(CupertinoIcons.wand_stars, size: 20, color: accentColor),
                const SizedBox(width: 8),
                Text(
                  'Generate with AI',
                  style: GoogleFonts.inter(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: textColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Enter a theme or topic — AI will design a scrapbook page layout around it.',
              style: GoogleFonts.inter(
                fontSize: 13,
                color: textColor.withValues(alpha: 0.5),
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: promptController,
              autofocus: true,
              maxLines: 2,
              style: GoogleFonts.inter(color: textColor, fontSize: 15),
              decoration: InputDecoration(
                hintText: 'e.g. Summer memories, Best friends, Travel diary...',
                hintStyle: GoogleFonts.inter(
                  color: textColor.withValues(alpha: 0.25),
                  fontSize: 14,
                ),
                filled: true,
                fillColor: isDark
                    ? Colors.white.withValues(alpha: 0.06)
                    : Colors.black.withValues(alpha: 0.04),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8, runSpacing: 8,
              children: [
                'About Me', 'Slam Book', 'Travel Journal',
                'Mood Board', 'Quotes & Motivation', 'Birthday Party',
                'Photo Album', 'Recipe Page', 'Favorites List',
                'Memory Lane', 'Getting to Know You', 'Bucket List',
              ].map((suggestion) => GestureDetector(
                onTap: () => promptController.text = suggestion,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    suggestion,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: accentColor,
                    ),
                  ),
                ),
              )).toList(),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: CupertinoButton(
                color: accentColor,
                borderRadius: BorderRadius.circular(12),
                padding: const EdgeInsets.symmetric(vertical: 14),
                onPressed: () {
                  final prompt = promptController.text.trim();
                  if (prompt.isEmpty) return;
                  Navigator.pop(ctx);
                  _generateWithAI(prompt);
                },
                child: Text(
                  'Generate Layout',
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _generateWithAI(String prompt) async {
    setState(() => _aiGenerating = true);
    const maxRetries = 2;
    String lastParseError = '';

    // Save current state so we can restore if generation fails
    final prevElements = List<CanvasElement>.from(_elements);
    final prevBgColor = _bgColorValue;
    final prevBgImage = _bgImageUrl;
    final prevGradStart = _bgGradientStart;
    final prevGradEnd = _bgGradientEnd;
    final prevGradDir = _bgGradientDirection;

    try {
      for (int attempt = 0; attempt <= maxRetries; attempt++) {
        try {
          // For parse errors, tell the AI what went wrong so it can fix it.
          // For API errors (503 etc), just retry with the same prompt.
          final effectivePrompt = (attempt > 0 && lastParseError.isNotEmpty)
              ? '$prompt\n\nIMPORTANT: Return ONLY valid JSON. '
                'Previous attempt had error: "$lastParseError". '
                'No trailing commas, escape special characters in strings, '
                'close all brackets.'
              : prompt;

          final raw = await _gemini.generateCanvasLayout(
            prompt: effectivePrompt,
            bookTitle: widget.bookTitle,
            sectionTitle: widget.sectionTitle,
            otherSectionTitles: widget.otherSectionTitles,
            writingPreview: widget.writingPreview,
          );

          // Parse the response
          final result = _parseAIResponse(raw);
          _postProcessElements(result.elements, result.bgColor);

          setState(() {
            _bgColorValue = result.bgColor;
            _bgGradientStart = result.bgGradientStart;
            _bgGradientEnd = result.bgGradientEnd;
            _bgGradientDirection = result.bgGradientDirection;
            _elements = result.elements;
            _selectedId = null;
          });
          _emitChange();

          if (mounted) {
            _showSnack(
              attempt > 0
                  ? 'Layout generated (fixed after $attempt ${attempt == 1 ? "retry" : "retries"})!'
                  : 'Layout generated! Tap placeholders to add photos.',
            );
          }
          return; // Success
        } on FormatException catch (e, stack) {
          // JSON parse error — retry with error context
          lastParseError = 'Invalid JSON: ${e.message}';
          debugPrint('🔴 AI Canvas [attempt ${attempt + 1}] FormatException: ${e.message}');
          debugPrint('   Stack: $stack');
          if (attempt < maxRetries) {
            if (mounted) _showSnack('Attempt ${attempt + 1}: JSON error — retrying...', seconds: 2);
          } else {
            throw Exception(lastParseError);
          }
        } catch (e, stack) {
          final msg = e.toString().replaceFirst('Exception: ', '');
          debugPrint('🔴 AI Canvas [attempt ${attempt + 1}] Error: $msg');
          debugPrint('   Stack: $stack');

          final isApiError = msg.contains('503') ||
              msg.contains('429') ||
              msg.contains('500') ||
              msg.contains('Network error') ||
              msg.contains('status');

          if (isApiError && attempt < maxRetries) {
            lastParseError = '';
            if (mounted) _showSnack('Server busy — retrying (${attempt + 1}/$maxRetries)...', seconds: 2);
            await Future.delayed(const Duration(seconds: 2));
          } else if (attempt < maxRetries) {
            lastParseError = msg;
            if (mounted) _showSnack('Attempt ${attempt + 1}: $msg — retrying...', seconds: 2);
          } else {
            rethrow;
          }
        }
      }
    } catch (e) {
      // Restore previous canvas state on failure
      setState(() {
        _elements = prevElements;
        _bgColorValue = prevBgColor;
        _bgImageUrl = prevBgImage;
        _bgGradientStart = prevGradStart;
        _bgGradientEnd = prevGradEnd;
        _bgGradientDirection = prevGradDir;
        _selectedId = null;
      });

      final errMsg = e.toString().replaceFirst('Exception: ', '');
      if (mounted) {
        _showSnack('Generation failed: $errMsg', seconds: 5);
      }
    } finally {
      if (mounted) setState(() => _aiGenerating = false);
    }
  }

  void _showSnack(String message, {int seconds = 3}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: GoogleFonts.inter(fontSize: 13)),
        duration: Duration(seconds: seconds),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  /// Parse raw AI text response into bg color and canvas elements.
  _AILayoutResult _parseAIResponse(String raw) {
    debugPrint('🟡 AI Canvas raw response (${raw.length} chars): ${raw.substring(0, min(500, raw.length))}...');

    String jsonStr = raw.trim();

    // Strip markdown code fences if present
    if (jsonStr.startsWith('```')) {
      jsonStr = jsonStr
          .replaceAll(RegExp(r'^```\w*\n?'), '')
          .replaceAll(RegExp(r'\n?```$'), '');
    }

    // Try to extract JSON object if there's extra text around it
    final jsonMatch = RegExp(r'\{[\s\S]*\}').firstMatch(jsonStr);
    if (jsonMatch != null) {
      jsonStr = jsonMatch.group(0)!;
    } else {
      // Possibly truncated — try to find start of JSON object and repair
      final openBrace = jsonStr.indexOf('{');
      if (openBrace >= 0) {
        jsonStr = jsonStr.substring(openBrace);
        jsonStr = _repairTruncatedJson(jsonStr);
        debugPrint('🟡 AI Canvas: No closing brace found, attempted repair');
      } else {
        debugPrint('🔴 AI Canvas: No JSON object found in response');
        throw const FormatException('No JSON object found in response');
      }
    }

    // Try parsing; if it fails, attempt repair
    dynamic data;
    try {
      data = jsonDecode(jsonStr);
    } catch (e) {
      debugPrint('🟡 AI Canvas: JSON parse failed, attempting repair...');
      jsonStr = _repairTruncatedJson(jsonStr);
      try {
        data = jsonDecode(jsonStr);
        debugPrint('🟢 AI Canvas: JSON repair succeeded');
      } catch (e2) {
        debugPrint('🔴 AI Canvas: JSON repair failed: $e2');
        rethrow;
      }
    }
    if (data is! Map) throw Exception('Response is not a JSON object');
    if (data['elements'] == null) throw Exception('Missing "elements" array');

    final elementsList = data['elements'] as List;
    debugPrint('🟢 AI Canvas parsed: bgColor=${data['bgColor']}, ${elementsList.length} elements');

    final bgColor = data['bgColor'] as int? ?? 0;
    final elements = <CanvasElement>[];
    for (final e in elementsList) {
      try {
        final map = Map<String, dynamic>.from(e as Map);
        map['id'] = '${DateTime.now().microsecondsSinceEpoch}_${_nextZIndex}';
        map['zIndex'] = _nextZIndex++;
        map.putIfAbsent('rotation', () => 0.0);
        map.putIfAbsent('hasBorder', () => false);
        map.putIfAbsent('borderColorValue', () => 0x40FFFFFF);
        elements.add(CanvasElement.fromJson(map));
      } catch (e) {
        debugPrint('🟡 AI Canvas: Skipping malformed element: $e');
      }
    }

    if (elements.isEmpty) {
      throw const FormatException('No valid elements parsed from response');
    }

    debugPrint('🟢 AI Canvas: ${elements.length}/${elementsList.length} elements parsed successfully');
    return _AILayoutResult(
      bgColor: bgColor,
      elements: elements,
      bgGradientStart: data['bgGradientStart'] as int?,
      bgGradientEnd: data['bgGradientEnd'] as int?,
      bgGradientDirection: (data['bgGradientDirection'] as String?) ?? 'top',
    );
  }

  /// Attempt to repair truncated JSON by closing unclosed brackets/braces
  /// and removing trailing partial elements.
  String _repairTruncatedJson(String json) {
    // Remove trailing comma before we close brackets
    var repaired = json.trimRight();

    // Remove any trailing partial key-value pair (e.g. `"text":"hello` without closing quote)
    // Find the last complete element by looking for the last `}`
    final lastCloseBrace = repaired.lastIndexOf('}');
    if (lastCloseBrace < repaired.length - 1) {
      // There's trailing garbage after the last }, trim to there
      repaired = repaired.substring(0, lastCloseBrace + 1);
    }

    // Count unclosed brackets and braces
    int openBraces = 0;
    int openBrackets = 0;
    bool inString = false;
    bool escaped = false;

    for (int i = 0; i < repaired.length; i++) {
      final c = repaired[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (c == '\\') {
        escaped = true;
        continue;
      }
      if (c == '"') {
        inString = !inString;
        continue;
      }
      if (inString) continue;
      if (c == '{') openBraces++;
      if (c == '}') openBraces--;
      if (c == '[') openBrackets++;
      if (c == ']') openBrackets--;
    }

    // Remove trailing commas before closing
    repaired = repaired.replaceAll(RegExp(r',\s*$'), '');

    // Close unclosed brackets and braces
    for (int i = 0; i < openBrackets; i++) {
      repaired += ']';
    }
    for (int i = 0; i < openBraces; i++) {
      repaired += '}';
    }

    debugPrint('🟡 JSON repair: closed $openBraces braces, $openBrackets brackets');
    return repaired;
  }

  /// Minimal post-processing: only fix critical issues (bounds, readability).
  /// Trust the AI model for design decisions (borders, colors, layout).
  void _postProcessElements(List<CanvasElement> elements, int bgColor) {
    final bgCol = bgColor != 0 ? Color(bgColor) : Colors.white;

    for (final e in elements) {
      // 1. Clamp positions so nothing goes off-screen
      e.x = e.x.clamp(0.01, 0.85);
      e.y = e.y.clamp(0.01, 0.88);
      e.width = e.width.clamp(0.08, 0.94 - e.x);
      e.height = e.height.clamp(0.03, 0.92 - e.y);

      // 2. Clamp rotation to subtle range
      e.rotation = e.rotation.clamp(-0.08, 0.08);

      // 3. Fix text readability only when contrast is truly bad
      if (e.type == CanvasElementType.text) {
        final hasBg = e.bgColorValue != 0 && e.bgColorValue != 0x00000000;
        final isSticker = e.text.length <= 3 && !RegExp(r'[a-zA-Z]').hasMatch(e.text);

        if (!isSticker) {
          final effectiveBg = hasBg ? Color(e.bgColorValue) : bgCol;
          final effectiveBgLum = effectiveBg.computeLuminance();
          final textLum = Color(e.textColorValue).computeLuminance();

          // Only fix when contrast is really bad (< 0.2 diff)
          if ((effectiveBgLum - textLum).abs() < 0.2) {
            e.textColorValue = effectiveBgLum > 0.4 ? 0xFF1A1A2E : 0xFFF1F5F9;
          }
        }
      }
    }

    // 4. Simple overlap fix: nudge overlapping elements down
    for (int i = 1; i < elements.length; i++) {
      final a = elements[i];
      for (int j = 0; j < i; j++) {
        final b = elements[j];
        if (_overlaps(a, b)) {
          a.y = (b.y + b.height + 0.015).clamp(0.01, 0.85);
        }
      }
    }
  }

  bool _overlaps(CanvasElement a, CanvasElement b) {
    return a.x < b.x + b.width &&
        a.x + a.width > b.x &&
        a.y < b.y + b.height &&
        a.y + a.height > b.y;
  }

  // ── Transform panel ──

  /// Which sub-panel is active in the transform controls.
  int _transformTab = 0; // 0 = rotate, 1 = scale

  Widget _buildTransformPanel({required bool isDark, required Color textColor}) {
    final e = _selected;
    if (e == null) return const SizedBox.shrink();
    final accentColor = isDark ? const Color(0xFF5B8DEF) : const Color(0xFF4A6CF7);
    final mutedBg = isDark ? Colors.white.withValues(alpha: 0.06) : Colors.black.withValues(alpha: 0.04);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: (isDark ? const Color(0xFF1A1A1A) : Colors.white).withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isDark ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.06)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 20, offset: const Offset(0, 4))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Tab switcher: Rotate | Scale ──
          Row(
            children: [
              _transformTabBtn(
                icon: CupertinoIcons.rotate_right,
                label: 'Rotate',
                isActive: _transformTab == 0,
                accent: accentColor,
                textColor: textColor,
                mutedBg: mutedBg,
                onTap: () => setState(() => _transformTab = 0),
              ),
              const SizedBox(width: 6),
              _transformTabBtn(
                icon: CupertinoIcons.resize,
                label: 'Scale',
                isActive: _transformTab == 1,
                accent: accentColor,
                textColor: textColor,
                mutedBg: mutedBg,
                onTap: () => setState(() => _transformTab = 1),
              ),
              const Spacer(),
              // Reset button
              GestureDetector(
                onTap: () {
                  setState(() {
                    if (_transformTab == 0) {
                      e.rotation = 0;
                    } else {
                      final ratio = e.height / e.width;
                      final defaultW = e.type == CanvasElementType.image ? 0.35 : 0.3;
                      e.width = defaultW;
                      e.height = defaultW * ratio;
                    }
                  });
                  _emitChange();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: mutedBg, borderRadius: BorderRadius.circular(8)),
                  child: Text('Reset', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w500, color: textColor.withValues(alpha: 0.5))),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // ── Panel content ──
          if (_transformTab == 0)
            _buildRotationControls(e, accentColor: accentColor, isDark: isDark, textColor: textColor, mutedBg: mutedBg)
          else
            _buildScaleControls(e, accentColor: accentColor, isDark: isDark, textColor: textColor, mutedBg: mutedBg),
        ],
      ),
    );
  }

  Widget _transformTabBtn({
    required IconData icon,
    required String label,
    required bool isActive,
    required Color accent,
    required Color textColor,
    required Color mutedBg,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isActive ? accent.withValues(alpha: 0.15) : mutedBg,
          borderRadius: BorderRadius.circular(8),
          border: isActive ? Border.all(color: accent.withValues(alpha: 0.3)) : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: isActive ? accent : textColor.withValues(alpha: 0.5)),
            const SizedBox(width: 5),
            Text(label, style: GoogleFonts.inter(fontSize: 12, fontWeight: isActive ? FontWeight.w700 : FontWeight.w500, color: isActive ? accent : textColor.withValues(alpha: 0.5))),
          ],
        ),
      ),
    );
  }

  // ── Rotation sub-panel ──

  Widget _buildRotationControls(
    CanvasElement e, {
    required Color accentColor,
    required bool isDark,
    required Color textColor,
    required Color mutedBg,
  }) {
    final degrees = (e.rotation * 180 / pi).roundToDouble();
    final snapAngles = [-90.0, -45.0, 0.0, 45.0, 90.0];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Value display
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(color: accentColor.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
              child: Text('${degrees.toInt()}°', style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w700, color: accentColor)),
            ),
          ],
        ),
        // Slider
        SliderTheme(
          data: SliderThemeData(
            activeTrackColor: accentColor,
            inactiveTrackColor: isDark ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.06),
            thumbColor: accentColor,
            overlayColor: accentColor.withValues(alpha: 0.12),
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
          ),
          child: Slider(
            value: degrees.clamp(-180, 180),
            min: -180,
            max: 180,
            divisions: 72,
            onChanged: (v) { setState(() => e.rotation = v * pi / 180); },
            onChangeEnd: (_) => _emitChange(),
          ),
        ),
        // Quick snap angles
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: snapAngles.map((angle) {
            final isActive = (degrees - angle).abs() < 1;
            return GestureDetector(
              onTap: () { setState(() => e.rotation = angle * pi / 180); _emitChange(); },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: isActive ? accentColor.withValues(alpha: 0.15) : mutedBg,
                  borderRadius: BorderRadius.circular(8),
                  border: isActive ? Border.all(color: accentColor.withValues(alpha: 0.3)) : null,
                ),
                child: Text('${angle.toInt()}°', style: GoogleFonts.inter(fontSize: 12, fontWeight: isActive ? FontWeight.w700 : FontWeight.w500, color: isActive ? accentColor : textColor.withValues(alpha: 0.5))),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  // ── Scale sub-panel ──

  Widget _buildScaleControls(
    CanvasElement e, {
    required Color accentColor,
    required bool isDark,
    required Color textColor,
    required Color mutedBg,
  }) {
    final sizePercent = (e.width * 100).round();
    final ratio = e.height / e.width;
    final presetSizes = [15, 25, 50, 75, 100];

    void setScale(double fraction) {
      setState(() {
        e.width = fraction.clamp(0.05, 1.5);
        e.height = (fraction * ratio).clamp(0.05, 2.0);
      });
      _emitChange();
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Value + stepper buttons
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Decrease
            GestureDetector(
              onTap: () => setScale(e.width - 0.05),
              child: Container(
                width: 32, height: 32,
                decoration: BoxDecoration(color: mutedBg, borderRadius: BorderRadius.circular(8)),
                child: Icon(CupertinoIcons.minus, size: 14, color: textColor.withValues(alpha: 0.6)),
              ),
            ),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              decoration: BoxDecoration(color: accentColor.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
              child: Text('$sizePercent%', style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w700, color: accentColor)),
            ),
            const SizedBox(width: 12),
            // Increase
            GestureDetector(
              onTap: () => setScale(e.width + 0.05),
              child: Container(
                width: 32, height: 32,
                decoration: BoxDecoration(color: mutedBg, borderRadius: BorderRadius.circular(8)),
                child: Icon(CupertinoIcons.plus, size: 14, color: textColor.withValues(alpha: 0.6)),
              ),
            ),
          ],
        ),
        // Slider
        SliderTheme(
          data: SliderThemeData(
            activeTrackColor: accentColor,
            inactiveTrackColor: isDark ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.06),
            thumbColor: accentColor,
            overlayColor: accentColor.withValues(alpha: 0.12),
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
          ),
          child: Slider(
            value: (e.width * 100).clamp(5, 150),
            min: 5,
            max: 150,
            divisions: 29, // 5% increments
            onChanged: (v) => setScale(v / 100),
            onChangeEnd: (_) => _emitChange(),
          ),
        ),
        // Quick preset sizes
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: presetSizes.map((size) {
            final isActive = (sizePercent - size).abs() < 3;
            return GestureDetector(
              onTap: () => setScale(size / 100.0),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: isActive ? accentColor.withValues(alpha: 0.15) : mutedBg,
                  borderRadius: BorderRadius.circular(8),
                  border: isActive ? Border.all(color: accentColor.withValues(alpha: 0.3)) : null,
                ),
                child: Text('$size%', style: GoogleFonts.inter(fontSize: 12, fontWeight: isActive ? FontWeight.w700 : FontWeight.w500, color: isActive ? accentColor : textColor.withValues(alpha: 0.5))),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  // ── Text editor dialog ──

  void _showTextEditor(CanvasElement e) {
    final textCtrl = TextEditingController(text: e.text);
    final isDark = widget.isDark;
    final textColor = isDark ? Colors.white : const Color(0xFF111111);

    // Current state
    String selectedFont = e.fontFamily;
    double selectedSize = e.fontSize;
    bool isBold = e.isBold;
    bool isItalic = e.isItalic;
    String selectedAlign = e.textAlign;
    int selectedColorVal = e.textColorValue;
    int selectedBgColor = e.bgColorValue;
    bool selectedHasBorder = e.hasBorder;
    int selectedBorderColor = e.borderColorValue;

    final fonts = [
      'Inter',
      'Caveat',
      'Dancing Script',
      'Playfair Display',
      'Merriweather',
      'Patrick Hand',
      'Lora',
      'DM Sans',
    ];
    final sizes = [14.0, 18.0, 22.0, 28.0, 36.0, 48.0, 64.0];
    final colors = [
      0xFF000000,
      0xFFFFFFFF,
      0xFF5B8DEF,
      0xFFFF595E,
      0xFF1982C4,
      0xFF8AC926,
      0xFFFFCA3A,
      0xFFFF6B6B,
      0xFFA855F7,
      0xFF06B6D4,
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? const Color(0xFF0C0C0C) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
              left: 20,
              right: 20,
              top: 8,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Handle
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: textColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),

                  Text(
                    'Edit Text Block',
                    style: GoogleFonts.inter(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: textColor,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Text input
                  CupertinoTextField(
                    controller: textCtrl,
                    maxLines: 5,
                    minLines: 2,
                    padding: const EdgeInsets.all(14),
                    style: GoogleFonts.inter(fontSize: 16, color: textColor),
                    placeholder: 'Type something...',
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.06)
                          : Colors.black.withValues(alpha: 0.03),
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Font selection
                  Text(
                    'Font',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: textColor.withValues(alpha: 0.5),
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 38,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: fonts.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 6),
                      itemBuilder: (_, i) {
                        final f = fonts[i];
                        final isActive = f == selectedFont;
                        TextStyle labelStyle;
                        try {
                          labelStyle = GoogleFonts.getFont(
                            f,
                            fontSize: 13,
                            color: isActive ? Colors.white : textColor,
                          );
                        } catch (_) {
                          labelStyle = TextStyle(
                            fontFamily: f,
                            fontSize: 13,
                            color: isActive ? Colors.white : textColor,
                          );
                        }
                        return GestureDetector(
                          onTap: () => setSheetState(() => selectedFont = f),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            decoration: BoxDecoration(
                              color: isActive
                                  ? (isDark
                                        ? const Color(0xFF5B8DEF)
                                        : const Color(0xFF111111))
                                  : (isDark
                                        ? Colors.white.withValues(alpha: 0.06)
                                        : Colors.black.withValues(alpha: 0.04)),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            alignment: Alignment.center,
                            child: Text(f, style: labelStyle),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Size selection
                  Text(
                    'Size',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: textColor.withValues(alpha: 0.5),
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: sizes.map((s) {
                      final isActive = s == selectedSize;
                      return GestureDetector(
                        onTap: () => setSheetState(() => selectedSize = s),
                        child: Container(
                          width: 44,
                          height: 34,
                          decoration: BoxDecoration(
                            color: isActive
                                ? (isDark
                                      ? const Color(0xFF5B8DEF)
                                      : const Color(0xFF111111))
                                : (isDark
                                      ? Colors.white.withValues(alpha: 0.06)
                                      : Colors.black.withValues(alpha: 0.04)),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            '${s.toInt()}',
                            style: GoogleFonts.inter(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: isActive ? Colors.white : textColor,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 14),

                  // Style & alignment
                  Row(
                    children: [
                      // Bold
                      _styleToggle(
                        'B',
                        isBold,
                        () => setSheetState(() => isBold = !isBold),
                        isDark: isDark,
                        textColor: textColor,
                      ),
                      const SizedBox(width: 6),
                      // Italic
                      _styleToggle(
                        'I',
                        isItalic,
                        () => setSheetState(() => isItalic = !isItalic),
                        isDark: isDark,
                        textColor: textColor,
                        isItalic: true,
                      ),
                      const SizedBox(width: 16),
                      // Align
                      for (final a in ['left', 'center', 'right'])
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: GestureDetector(
                            onTap: () => setSheetState(() => selectedAlign = a),
                            child: Container(
                              width: 36,
                              height: 34,
                              decoration: BoxDecoration(
                                color: selectedAlign == a
                                    ? (isDark
                                          ? const Color(
                                              0xFF5B8DEF,
                                            ).withValues(alpha: 0.2)
                                          : const Color(
                                              0xFF111111,
                                            ).withValues(alpha: 0.08))
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                a == 'left'
                                    ? CupertinoIcons.text_alignleft
                                    : a == 'center'
                                    ? CupertinoIcons.text_aligncenter
                                    : CupertinoIcons.text_alignright,
                                size: 17,
                                color: selectedAlign == a
                                    ? (isDark
                                          ? const Color(0xFF5B8DEF)
                                          : const Color(0xFF111111))
                                    : textColor.withValues(alpha: 0.4),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Color
                  Text(
                    'Color',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: textColor.withValues(alpha: 0.5),
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: colors.map((c) {
                      final isActive = c == selectedColorVal;
                      return GestureDetector(
                        onTap: () => setSheetState(() => selectedColorVal = c),
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: Color(c),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isActive
                                  ? (isDark
                                        ? Colors.white
                                        : const Color(0xFF111111))
                                  : Colors.transparent,
                              width: 2.5,
                            ),
                            boxShadow: [
                              if (c == 0xFFFFFFFF)
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.1),
                                  blurRadius: 4,
                                ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 14),

                  // Background fill
                  Text(
                    'Fill',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: textColor.withValues(alpha: 0.5),
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      // Transparent / none
                      GestureDetector(
                        onTap: () => setSheetState(() => selectedBgColor = 0),
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isDark ? const Color(0xFF1A1A1A) : const Color(0xFFF0F0F0),
                            border: Border.all(
                              color: selectedBgColor == 0
                                  ? (isDark ? Colors.white : const Color(0xFF111111))
                                  : Colors.transparent,
                              width: 2.5,
                            ),
                          ),
                          child: Icon(CupertinoIcons.clear, size: 12, color: textColor.withValues(alpha: 0.3)),
                        ),
                      ),
                      for (final c in const [
                        0xFFFFFFFF, 0xFFFFF8E1, 0xFFFFF3E0, 0xFFFBE9E7,
                        0xFFFCE4EC, 0xFFF3E5F5, 0xFFE8F5E9, 0xFFE0F2F1,
                        0xFFE3F2FD, 0xFFEDE7F6,
                        0xFF1A1A2E, 0xFF111111, 0xFF2C2C2E,
                      ])
                        GestureDetector(
                          onTap: () => setSheetState(() => selectedBgColor = c),
                          child: Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              color: Color(c),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: selectedBgColor == c
                                    ? (isDark ? Colors.white : const Color(0xFF111111))
                                    : (c == 0xFFFFFFFF
                                        ? Colors.black.withValues(alpha: 0.1)
                                        : Colors.transparent),
                                width: 2.5,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Border
                  Row(
                    children: [
                      Text(
                        'Border',
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: textColor.withValues(alpha: 0.5),
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(width: 10),
                      GestureDetector(
                        onTap: () => setSheetState(() => selectedHasBorder = !selectedHasBorder),
                        child: Container(
                          width: 40,
                          height: 24,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            color: selectedHasBorder
                                ? const Color(0xFF5B8DEF)
                                : (isDark
                                    ? Colors.white.withValues(alpha: 0.1)
                                    : Colors.black.withValues(alpha: 0.08)),
                          ),
                          child: AnimatedAlign(
                            duration: const Duration(milliseconds: 150),
                            alignment: selectedHasBorder ? Alignment.centerRight : Alignment.centerLeft,
                            child: Container(
                              width: 18,
                              height: 18,
                              margin: const EdgeInsets.symmetric(horizontal: 3),
                              decoration: const BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (selectedHasBorder) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final c in const [
                          0xFF000000, 0xFFFFFFFF, 0xFF5B8DEF,
                          0xFFFF595E, 0xFFFFCA3A, 0xFF28A745,
                          0xFFA855F7, 0xFF06B6D4, 0xFFFF6B6B,
                          0xFFD4A574,
                        ])
                          GestureDetector(
                            onTap: () => setSheetState(() => selectedBorderColor = c),
                            child: Container(
                              width: 30,
                              height: 30,
                              decoration: BoxDecoration(
                                color: Color(c),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: selectedBorderColor == c
                                      ? (isDark ? Colors.white : const Color(0xFF111111))
                                      : (c == 0xFFFFFFFF
                                          ? Colors.black.withValues(alpha: 0.1)
                                          : Colors.transparent),
                                  width: 2.5,
                                ),
                                boxShadow: [
                                  if (c == 0xFFFFFFFF)
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.1),
                                      blurRadius: 4,
                                    ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 20),

                  // Apply button
                  SizedBox(
                    width: double.infinity,
                    child: CupertinoButton(
                      color: isDark ? Colors.white : Colors.black,
                      borderRadius: BorderRadius.circular(12),
                      onPressed: () {
                        setState(() {
                          e.text = textCtrl.text;
                          e.fontFamily = selectedFont;
                          e.fontSize = selectedSize;
                          e.isBold = isBold;
                          e.isItalic = isItalic;
                          e.textAlign = selectedAlign;
                          e.textColorValue = selectedColorVal;
                          e.bgColorValue = selectedBgColor;
                          e.hasBorder = selectedHasBorder;
                          e.borderColorValue = selectedBorderColor;
                        });
                        _emitChange();
                        Navigator.pop(ctx);
                      },
                      child: Text(
                        'Apply',
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.black : Colors.white,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _styleToggle(
    String label,
    bool active,
    VoidCallback onTap, {
    required bool isDark,
    required Color textColor,
    bool isItalic = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 34,
        decoration: BoxDecoration(
          color: active
              ? (isDark
                    ? const Color(0xFF5B8DEF).withValues(alpha: 0.2)
                    : const Color(0xFF111111).withValues(alpha: 0.08))
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 16,
            fontWeight: label == 'B' ? FontWeight.w800 : FontWeight.w500,
            fontStyle: isItalic ? FontStyle.italic : FontStyle.normal,
            color: active
                ? (isDark ? const Color(0xFF5B8DEF) : const Color(0xFF111111))
                : textColor.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
// Small toolbar button
// ═══════════════════════════════════════════════════════════

class _CanvasToolBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _CanvasToolBtn({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      minimumSize: Size.zero,
      onPressed: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Result from parsing an AI-generated layout response.
class _AILayoutResult {
  final int bgColor;
  final int? bgGradientStart;
  final int? bgGradientEnd;
  final String bgGradientDirection;
  final List<CanvasElement> elements;
  const _AILayoutResult({
    required this.bgColor,
    required this.elements,
    this.bgGradientStart,
    this.bgGradientEnd,
    this.bgGradientDirection = 'top',
  });
}
