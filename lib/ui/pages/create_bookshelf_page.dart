import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/provider/bookshelf_provider.dart';
import 'package:inkspacex/ui/widgets/app_spinner.dart';

class CreateBookshelfPage extends StatefulWidget {
  const CreateBookshelfPage({super.key});

  @override
  State<CreateBookshelfPage> createState() => _CreateBookshelfPageState();
}

class _CreateBookshelfPageState extends State<CreateBookshelfPage> {
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _nameFocus = FocusNode();

  bool _isPrivate = false;
  bool _saving = false;
  Uint8List? _coverBytes;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _nameFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  // ── Cover image picker ──
  Future<void> _pickCover() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    setState(() => _coverBytes = bytes);
  }

  void _removeCover() => setState(() => _coverBytes = null);

  // ── Save ──
  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty || _saving) return;
    HapticFeedback.lightImpact();
    setState(() => _saving = true);
    final shelves = context.read<BookshelfProvider>();
    final shelf = await shelves.create(
      name: name,
      description: _descCtrl.text.trim(),
      isPrivate: _isPrivate,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (shelf == null) {
      showCupertinoDialog(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: const Text('Could not create space'),
          content: const Text('Please try again.'),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    context.pushReplacement('/bookshelf/${shelf.id}');
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final bgColor = isDark ? const Color(0xFF000000) : const Color(0xFFFAFAFA);
    final surfaceColor = isDark ? const Color(0xFF141414) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final mutedColor = isDark ? Colors.white54 : Colors.black54;
    final faintColor = isDark
        ? Colors.white.withValues(alpha: 0.35)
        : Colors.black.withValues(alpha: 0.35);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.08);
    final accent = isDark ? Colors.white : const Color(0xFF0F172A);

    final name = _nameCtrl.text.trim();
    final canSave = name.isNotEmpty && !_saving;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(56),
        child: SafeArea(
          bottom: false,
          child: Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: bgColor,
              border: Border(
                bottom: BorderSide(
                  color: borderColor.withValues(alpha: 0.5),
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              children: [
                _IconBtn(
                  icon: CupertinoIcons.xmark,
                  color: textColor,
                  onTap: () => Navigator.of(context).maybePop(),
                ),
                const Spacer(),
                Text(
                  'New space',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: mutedColor,
                    letterSpacing: 0.1,
                  ),
                ),
                const Spacer(),
                _CreateButton(
                  enabled: canSave,
                  loading: _saving,
                  isDark: isDark,
                  onTap: _save,
                ),
              ],
            ),
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(0, 16, 0, 40),
          children: [
            // ── Hero cover ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: _CoverPicker(
                    bytes: _coverBytes,
                    seedText: name,
                    isDark: isDark,
                    surfaceColor: surfaceColor,
                    borderColor: borderColor,
                    textColor: textColor,
                    mutedColor: mutedColor,
                    onPick: _pickCover,
                    onRemove: _removeCover,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 28),

            // ── Title + description (editorial, inline) ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CupertinoTextField(
                      controller: _nameCtrl,
                      focusNode: _nameFocus,
                      maxLines: 2,
                      minLines: 1,
                      maxLength: 60,
                      onChanged: (_) => setState(() {}),
                      cursorColor: accent,
                      placeholder: 'Name your space',
                      placeholderStyle: GoogleFonts.playfairDisplay(
                        fontSize: 32,
                        fontWeight: FontWeight.w600,
                        color: faintColor,
                        height: 1.15,
                      ),
                      style: GoogleFonts.playfairDisplay(
                        fontSize: 32,
                        fontWeight: FontWeight.w600,
                        color: textColor,
                        height: 1.15,
                      ),
                      decoration: const BoxDecoration(),
                      padding: EdgeInsets.zero,
                    ),
                    const SizedBox(height: 8),
                    CupertinoTextField(
                      controller: _descCtrl,
                      maxLines: 5,
                      minLines: 1,
                      maxLength: 240,
                      onChanged: (_) => setState(() {}),
                      cursorColor: accent,
                      placeholder:
                          'Add a short description — what kind of writing lives here?',
                      placeholderStyle: GoogleFonts.inter(
                        fontSize: 15,
                        color: faintColor,
                        height: 1.45,
                      ),
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        color: textColor,
                        height: 1.45,
                      ),
                      decoration: const BoxDecoration(),
                      padding: EdgeInsets.zero,
                    ),
                    const SizedBox(height: 12),
                    _LiveCounters(
                      nameLen: _nameCtrl.text.length,
                      descLen: _descCtrl.text.length,
                      color: faintColor,
                    ),
                  ],
                ),
                ),
              ),
            ),

            const SizedBox(height: 28),

            // ── Divider ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Container(
                    height: 0.5,
                    color: borderColor,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 24),

            // ── Visibility ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                      'WHO CAN SEE THIS',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: mutedColor,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _VisibilityOption(
                      icon: CupertinoIcons.globe,
                      title: 'Public',
                      subtitle: 'Anyone can discover and follow this space',
                      selected: !_isPrivate,
                      isDark: isDark,
                      surfaceColor: surfaceColor,
                      borderColor: borderColor,
                      textColor: textColor,
                      mutedColor: mutedColor,
                      onTap: () => setState(() => _isPrivate = false),
                    ),
                    const SizedBox(height: 10),
                    _VisibilityOption(
                      icon: CupertinoIcons.lock_fill,
                      title: 'Private',
                      subtitle: 'Only you can see what\u2019s in here',
                      selected: _isPrivate,
                      isDark: isDark,
                      surfaceColor: surfaceColor,
                      borderColor: borderColor,
                      textColor: textColor,
                      mutedColor: mutedColor,
                      onTap: () => setState(() => _isPrivate = true),
                    ),
                  ],
                  ),
                ),
              ),
            ),

            const SizedBox(height: 24),

            // ── Footer hint ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Row(
                    children: [
                      Icon(
                        CupertinoIcons.sparkles,
                        size: 14,
                        color: faintColor,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'You can add writings to your space right after creating it.',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            color: mutedColor,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
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

// ═══════════════════════════════════════════════════════════════
// Cover picker — generates a gradient swatch from the name when empty
// ═══════════════════════════════════════════════════════════════
class _CoverPicker extends StatelessWidget {
  final Uint8List? bytes;
  final String seedText;
  final bool isDark;
  final Color surfaceColor;
  final Color borderColor;
  final Color textColor;
  final Color mutedColor;
  final VoidCallback onPick;
  final VoidCallback onRemove;

  const _CoverPicker({
    required this.bytes,
    required this.seedText,
    required this.isDark,
    required this.surfaceColor,
    required this.borderColor,
    required this.textColor,
    required this.mutedColor,
    required this.onPick,
    required this.onRemove,
  });

  // Deterministic gradient from the seed — keeps the placeholder feeling
  // owned by the user even before they pick an image.
  List<Color> _gradientFor(String seed) {
    final s = seed.trim().isEmpty ? 'space' : seed.trim();
    int hash = 0;
    for (final c in s.codeUnits) {
      hash = (hash * 31 + c) & 0x7fffffff;
    }
    final hue = (hash % 360).toDouble();
    if (isDark) {
      return [
        HSLColor.fromAHSL(1, hue, 0.30, 0.18).toColor(),
        HSLColor.fromAHSL(1, (hue + 40) % 360, 0.35, 0.10).toColor(),
      ];
    }
    return [
      HSLColor.fromAHSL(1, hue, 0.55, 0.88).toColor(),
      HSLColor.fromAHSL(1, (hue + 40) % 360, 0.60, 0.78).toColor(),
    ];
  }

  String get _initial {
    final s = seedText.trim();
    if (s.isEmpty) return '';
    return s.characters.first.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final hasImage = bytes != null;
    final gradient = _gradientFor(seedText);

    return GestureDetector(
      onTap: onPick,
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: borderColor),
            gradient: hasImage
                ? null
                : LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: gradient,
                  ),
            image: hasImage
                ? DecorationImage(
                    image: MemoryImage(bytes!),
                    fit: BoxFit.cover,
                  )
                : null,
            boxShadow: isDark
                ? null
                : [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Initial monogram (only when empty + name has chars)
                if (!hasImage && _initial.isNotEmpty)
                  Center(
                    child: Text(
                      _initial,
                      style: GoogleFonts.playfairDisplay(
                        fontSize: 96,
                        fontWeight: FontWeight.w700,
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.85)
                            : Colors.white,
                        height: 1,
                        shadows: [
                          Shadow(
                            color: Colors.black.withValues(alpha: 0.12),
                            blurRadius: 24,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                    ),
                  ),

                // Empty-state hint (only when no image AND no name yet)
                if (!hasImage && _initial.isEmpty)
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.08)
                                : Colors.white.withValues(alpha: 0.55),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            CupertinoIcons.photo,
                            size: 22,
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.7)
                                : const Color(0xFF0F172A)
                                    .withValues(alpha: 0.7),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Tap to add a cover',
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.75)
                                : const Color(0xFF0F172A)
                                    .withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ),
                  ),

                // Bottom-right action pill
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (hasImage) ...[
                        _OverlayPill(
                          icon: CupertinoIcons.trash,
                          label: 'Remove',
                          onTap: onRemove,
                        ),
                        const SizedBox(width: 8),
                      ],
                      _OverlayPill(
                        icon: hasImage
                            ? CupertinoIcons.camera
                            : CupertinoIcons.add,
                        label: hasImage ? 'Change' : 'Add cover',
                        onTap: onPick,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OverlayPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _OverlayPill({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 13),
            const SizedBox(width: 6),
            Text(
              label,
              style: GoogleFonts.inter(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Visibility option card
// ═══════════════════════════════════════════════════════════════
class _VisibilityOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final bool isDark;
  final Color surfaceColor;
  final Color borderColor;
  final Color textColor;
  final Color mutedColor;
  final VoidCallback onTap;

  const _VisibilityOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.isDark,
    required this.surfaceColor,
    required this.borderColor,
    required this.textColor,
    required this.mutedColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final selectedBorder = isDark ? Colors.white : const Color(0xFF0F172A);
    final selectedTint = isDark
        ? Colors.white.withValues(alpha: 0.04)
        : const Color(0xFF0F172A).withValues(alpha: 0.03);

    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: selected ? selectedTint : surfaceColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? selectedBorder.withValues(alpha: 0.8)
                : borderColor,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.06)
                    : Colors.black.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 18, color: textColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: mutedColor,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? selectedBorder : Colors.transparent,
                border: Border.all(
                  color: selected
                      ? selectedBorder
                      : borderColor.withValues(alpha: 1.5),
                  width: 1.4,
                ),
              ),
              child: selected
                  ? Icon(
                      CupertinoIcons.checkmark,
                      size: 12,
                      color: isDark ? Colors.black : Colors.white,
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// AppBar bits
// ═══════════════════════════════════════════════════════════════
class _IconBtn extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _IconBtn({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 40,
        height: 40,
        child: Icon(icon, color: color, size: 22),
      ),
    );
  }
}

class _CreateButton extends StatelessWidget {
  final bool enabled;
  final bool loading;
  final bool isDark;
  final VoidCallback onTap;

  const _CreateButton({
    required this.enabled,
    required this.loading,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg = enabled
        ? (isDark ? Colors.white : const Color(0xFF0F172A))
        : (isDark
            ? Colors.white.withValues(alpha: 0.12)
            : Colors.black.withValues(alpha: 0.08));
    final fg = enabled
        ? (isDark ? Colors.black : Colors.white)
        : (isDark ? Colors.white38 : Colors.black38);

    return GestureDetector(
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(20),
        ),
        child: loading
            ? AppSpinner(size: 14, color: fg)
            : Text(
                'Create',
                style: GoogleFonts.inter(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: fg,
                  letterSpacing: 0.1,
                ),
              ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// Live character counters — only show when typing
// ═══════════════════════════════════════════════════════════════
class _LiveCounters extends StatelessWidget {
  final int nameLen;
  final int descLen;
  final Color color;
  const _LiveCounters({
    required this.nameLen,
    required this.descLen,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    if (nameLen == 0 && descLen == 0) return const SizedBox.shrink();
    return Row(
      children: [
        if (nameLen > 0)
          Text(
            '$nameLen / 60',
            style: GoogleFonts.inter(
              fontSize: 11,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        if (nameLen > 0 && descLen > 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text('·', style: TextStyle(color: color, fontSize: 11)),
          ),
        if (descLen > 0)
          Text(
            '$descLen / 240 description',
            style: GoogleFonts.inter(
              fontSize: 11,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
      ],
    );
  }
}
