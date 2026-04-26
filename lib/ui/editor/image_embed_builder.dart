import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:inkspacex/models/image_meta.dart';
import 'package:inkspacex/ui/widgets/app_network_image.dart';

/// Renders image embeds inside the QuillEditor with tap-to-adjust
/// resize/rotate controls and drag-to-reposition along the line.
///
/// The image source string may carry transform metadata as a URL fragment:
///   `<src>#w=0.75&r=0.523&x=-0.4`
/// where `w` is a width factor (0.25..1.0), `r` is rotation in radians,
/// and `x` is a horizontal alignment factor (-1.0 = left, 0 = center,
/// 1.0 = right) within the leftover space on its line.
/// Plain URLs / data URIs without a fragment render at full width,
/// zero rotation, centered — preserving backward compatibility.
class ImageEmbedBuilder extends EmbedBuilder {
  ImageEmbedBuilder({required this.controller});

  final QuillController controller;

  @override
  String get key => BlockEmbed.imageType;

  @override
  bool get expanded => false;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    return _EditableImageEmbed(
      controller: controller,
      node: embedContext.node,
    );
  }
}

class _ImageTransform {
  const _ImageTransform({
    required this.src,
    required this.widthFactor,
    required this.rotation,
    required this.xOffset,
    this.imageMeta,
    this.extraFragment = const <String, String>{},
  });

  final String src;
  final double widthFactor; // 0.25..1.0 of available content width
  final double rotation;    // radians, -pi..pi
  final double xOffset;     // -1.0 (left) .. 0 (center) .. 1.0 (right)
  /// Pipeline metadata reconstructed from the URL fragment, when present.
  /// Lets the embed render with a blurhash placeholder + DPR-aware variants
  /// just like model-stored images.
  final ImageMeta? imageMeta;
  /// Any fragment params we don't know about — preserved verbatim across
  /// serialize round-trips so future keys don't get clobbered when the user
  /// drags or resizes.
  final Map<String, String> extraFragment;

  // Keys handled directly by this class — anything else lands in extraFragment.
  static const Set<String> _knownKeys = {'w', 'r', 'x', 'bh', 'dc', 'iw', 'ih', 'vs'};

  static _ImageTransform parse(String data) {
    // base64 data URIs cannot contain '#', so the last '#' is the fragment.
    final hashIdx = data.lastIndexOf('#');
    if (hashIdx == -1) {
      return _ImageTransform(
        src: data,
        widthFactor: 1.0,
        rotation: 0.0,
        xOffset: 0.0,
      );
    }
    final src = data.substring(0, hashIdx);
    final frag = data.substring(hashIdx + 1);
    double w = 1.0;
    double r = 0.0;
    double x = 0.0;
    final extras = <String, String>{};
    for (final part in frag.split('&')) {
      final eq = part.indexOf('=');
      if (eq == -1) continue;
      final key = part.substring(0, eq);
      final raw = part.substring(eq + 1);
      if (key == 'w' || key == 'r' || key == 'x') {
        final val = double.tryParse(raw);
        if (val == null) continue;
        if (key == 'w') w = val.clamp(0.1, 1.0);
        if (key == 'r') r = val.clamp(-math.pi, math.pi);
        if (key == 'x') x = val.clamp(-1.0, 1.0);
      } else if (!_knownKeys.contains(key)) {
        extras[key] = raw;
      }
    }
    return _ImageTransform(
      src: src,
      widthFactor: w,
      rotation: r,
      xOffset: x,
      // Pipeline meta (`bh/dc/iw/ih/vs`) is reconstructed from the *original*
      // string so we don't have to thread the raw values through here.
      imageMeta: ImageMeta.fromInlineUrl(data),
      extraFragment: extras,
    );
  }

  String serialize() {
    final parts = <String>[];
    if ((widthFactor - 1.0).abs() > 1e-4) {
      parts.add('w=${widthFactor.toStringAsFixed(3)}');
    }
    if (rotation.abs() > 1e-4) {
      parts.add('r=${rotation.toStringAsFixed(3)}');
    }
    if (xOffset.abs() > 1e-4) {
      parts.add('x=${xOffset.toStringAsFixed(3)}');
    }
    // Preserve the pipeline meta keys so blurhash/DPR-awareness survive edits.
    final m = imageMeta;
    if (m != null) {
      parts.add('bh=${m.blurhash}');
      parts.add('dc=${m.color.replaceFirst('#', '')}');
      parts.add('iw=${m.width}');
      parts.add('ih=${m.height}');
      // Round-trip the scope name verbatim if we know it; default is fine.
      final vs = extraFragment['vs'];
      if (vs != null && vs.isNotEmpty) {
        parts.add('vs=$vs');
      }
    }
    extraFragment.forEach((k, v) {
      if (k == 'vs') return; // already handled above
      parts.add('$k=$v');
    });
    if (parts.isEmpty) return src;
    return '$src#${parts.join('&')}';
  }

  _ImageTransform copyWith({
    double? widthFactor,
    double? rotation,
    double? xOffset,
  }) =>
      _ImageTransform(
        src: src,
        widthFactor: widthFactor ?? this.widthFactor,
        rotation: rotation ?? this.rotation,
        xOffset: xOffset ?? this.xOffset,
        imageMeta: imageMeta,
        extraFragment: extraFragment,
      );
}

class _EditableImageEmbed extends StatefulWidget {
  const _EditableImageEmbed({
    required this.controller,
    required this.node,
  });

  final QuillController controller;
  final Node node;

  @override
  State<_EditableImageEmbed> createState() => _EditableImageEmbedState();
}

class _EditableImageEmbedState extends State<_EditableImageEmbed> {
  late _ImageTransform _t;

  // Decoded bytes for `data:image/...;base64,...` sources. Cached by src
  // so that every QuillEditor repaint (e.g. from a keystroke) doesn't
  // re-run base64Decode on a multi-MB photo for every inline image.
  Uint8List? _cachedBytes;
  String? _cachedBytesSrc;

  Uint8List? _bytesFor(String src) {
    if (_cachedBytesSrc == src) return _cachedBytes;
    if (!src.startsWith('data:image')) {
      _cachedBytesSrc = src;
      _cachedBytes = null;
      return null;
    }
    try {
      final commaIdx = src.indexOf(',');
      _cachedBytes = base64Decode(src.substring(commaIdx + 1));
    } catch (_) {
      _cachedBytes = null;
    }
    _cachedBytesSrc = src;
    return _cachedBytes;
  }

  @override
  void initState() {
    super.initState();
    _t = _ImageTransform.parse(_dataString);
  }

  @override
  void didUpdateWidget(covariant _EditableImageEmbed old) {
    super.didUpdateWidget(old);
    final next = _ImageTransform.parse(_dataString);
    if (next.src != _t.src ||
        next.widthFactor != _t.widthFactor ||
        next.rotation != _t.rotation ||
        next.xOffset != _t.xOffset) {
      _t = next;
    }
  }

  String get _dataString => (widget.node as Embed).value.data as String;

  void _commit(_ImageTransform next) {
    final serialized = next.serialize();
    if (serialized == _dataString) {
      if (next.widthFactor != _t.widthFactor ||
          next.rotation != _t.rotation ||
          next.xOffset != _t.xOffset) {
        setState(() => _t = next);
      }
      return;
    }
    final controller = widget.controller;
    final offset = widget.node.documentOffset;
    final selection = controller.selection;
    controller.replaceText(offset, 1, BlockEmbed.image(serialized), null);
    if (selection.isValid) {
      controller.updateSelection(selection, ChangeSource.local);
    }
    setState(() => _t = next);
  }

  Future<void> _showAdjustSheet() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sheetBg = isDark ? const Color(0xFF1C1C1E) : Colors.white;
    final labelColor = isDark ? Colors.white70 : Colors.black87;
    final accent =
        isDark ? const Color(0xFF5B8DEF) : const Color(0xFF4A6CF7);

    double tempW = _t.widthFactor;
    double tempR = _t.rotation;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: sheetBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final degrees = (tempR * 180 / math.pi).round();
            final widthPercent = (tempW * 100).round();
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
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
                    'Adjust Image',
                    style: GoogleFonts.inter(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: labelColor,
                    ),
                  ),
                  const SizedBox(height: 20),
                  _sliderRow(
                    icon: CupertinoIcons.arrow_up_left_arrow_down_right,
                    label: 'Size',
                    valueLabel: '$widthPercent%',
                    labelColor: labelColor,
                    accent: accent,
                  ),
                  SliderTheme(
                    data: SliderTheme.of(ctx).copyWith(
                      activeTrackColor: accent,
                      inactiveTrackColor: accent.withValues(alpha: 0.15),
                      thumbColor: accent,
                      overlayColor: accent.withValues(alpha: 0.12),
                      trackHeight: 4,
                    ),
                    child: Slider(
                      value: tempW,
                      min: 0.25,
                      max: 1.0,
                      onChanged: (v) {
                        setSheet(() => tempW = v);
                        setState(() => _t = _t.copyWith(widthFactor: v));
                      },
                      onChangeEnd: (v) =>
                          _commit(_t.copyWith(widthFactor: v)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _sliderRow(
                    icon: CupertinoIcons.rotate_right,
                    label: 'Rotation',
                    valueLabel: '$degrees°',
                    labelColor: labelColor,
                    accent: accent,
                  ),
                  SliderTheme(
                    data: SliderTheme.of(ctx).copyWith(
                      activeTrackColor: accent,
                      inactiveTrackColor: accent.withValues(alpha: 0.15),
                      thumbColor: accent,
                      overlayColor: accent.withValues(alpha: 0.12),
                      trackHeight: 4,
                    ),
                    child: Slider(
                      value: tempR,
                      min: -math.pi,
                      max: math.pi,
                      onChanged: (v) {
                        setSheet(() => tempR = v);
                        setState(() => _t = _t.copyWith(rotation: v));
                      },
                      onChangeEnd: (v) =>
                          _commit(_t.copyWith(rotation: v)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Icon(
                        CupertinoIcons.hand_draw,
                        size: 16,
                        color: labelColor.withValues(alpha: 0.6),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Drag image left or right to reposition',
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          color: labelColor.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: _resetButton(
                          icon: CupertinoIcons.rotate_left,
                          label: 'Reset Angle',
                          color: accent,
                          onTap: () {
                            setSheet(() => tempR = 0);
                            _commit(_t.copyWith(rotation: 0));
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _resetButton(
                          icon: CupertinoIcons.arrow_counterclockwise,
                          label: 'Reset Size',
                          color: accent,
                          onTap: () {
                            setSheet(() => tempW = 1.0);
                            _commit(_t.copyWith(widthFactor: 1.0));
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _resetButton(
                          icon: CupertinoIcons.arrow_left_right,
                          label: 'Center',
                          color: accent,
                          onTap: () =>
                              _commit(_t.copyWith(xOffset: 0)),
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

    // Ensure final preview state is persisted if the sheet was dismissed
    // before any onChangeEnd fired.
    if (_t.serialize() != _dataString) {
      _commit(_t);
    }
  }

  Widget _sliderRow({
    required IconData icon,
    required String label,
    required String valueLabel,
    required Color labelColor,
    required Color accent,
  }) {
    return Row(
      children: [
        Icon(icon, size: 18, color: labelColor),
        const SizedBox(width: 8),
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: labelColor,
          ),
        ),
        const Spacer(),
        Text(
          valueLabel,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: accent,
          ),
        ),
      ],
    );
  }

  Widget _resetButton({
    required IconData icon,
    required String label,
    required Color color,
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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final src = _t.src;

    final errorBox = Container(
      height: 180,
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.04)
            : Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            CupertinoIcons.photo,
            color: isDark ? Colors.white24 : Colors.black26,
            size: 28,
          ),
          const SizedBox(height: 8),
          Text(
            'Image could not be loaded',
            style: TextStyle(
              color: isDark ? Colors.white30 : Colors.black26,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );

    Widget imageWidget;
    if (src.startsWith('data:image')) {
      final bytes = _bytesFor(src);
      imageWidget = bytes == null
          ? errorBox
          : Image.memory(
              bytes,
              width: double.infinity,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, e, s) => errorBox,
            );
    } else {
      imageWidget = LayoutBuilder(
        builder: (ctx, c) => AppNetworkImage(
          url: src,
          meta: _t.imageMeta,
          width: c.maxWidth,
          fit: BoxFit.cover,
          errorWidget: errorBox,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxW = constraints.maxWidth;
          final targetW = maxW * _t.widthFactor;
          final freeSpace = math.max(0.0, maxW - targetW);
          final canDrag = freeSpace > 0.5;
          return Align(
            alignment: Alignment(_t.xOffset, 0),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _showAdjustSheet,
              onHorizontalDragUpdate: !canDrag
                  ? null
                  : (d) {
                      // Each unit of xOffset spans freeSpace/2 pixels.
                      final delta = d.delta.dx * 2 / freeSpace;
                      final next = (_t.xOffset + delta).clamp(-1.0, 1.0);
                      if (next != _t.xOffset) {
                        setState(() => _t = _t.copyWith(xOffset: next));
                      }
                    },
              onHorizontalDragEnd: !canDrag ? null : (_) => _commit(_t),
              child: Transform.rotate(
                angle: _t.rotation,
                child: SizedBox(
                  width: targetW,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: imageWidget,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
