import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/provider/editor_provider.dart';
import 'package:inkspacex/ui/utilities/responsive_layout.dart';
import 'package:inkspacex/ui/utilities/writing_type_style.dart';
import 'package:inkspacex/ui/widgets/app_spinner.dart';
import 'package:inkspacex/ui/widgets/type_chooser.dart';

class NewBookAddition extends StatefulWidget {
  final WritingType? initialType;
 

  const NewBookAddition({
    super.key,
    this.initialType,
    
  });

  @override
  State<NewBookAddition> createState() => _NewBookAdditionState();
}

class _NewBookAdditionState extends State<NewBookAddition>
    with SingleTickerProviderStateMixin {
  Uint8List? _imageBytes;
  bool _isCreating = false;
  bool _showOptional = false;
  late AnimationController _animController;
  late Animation<double> _fadeIn;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );
    _fadeIn = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOutCubic,
    );
    _animController.forward();

    if (widget.initialType != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final ep = context.read<EditorProvider>();
       
        if (ep.type != widget.initialType) {
          ep.selectWritingType(widget.initialType!);
        }
        if (widget.initialType == WritingType.freestyle &&
            ep.subtype.isEmpty) {
          ep.selectSubtype('freestyle');
        }
      });
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked != null) {
      final bytes = await picked.readAsBytes();
      setState(() => _imageBytes = bytes);
    }
  }

  bool get _canCreate {
    final ep = context.read<EditorProvider>();
    final isFreestyle = ep.type == WritingType.freestyle;
    return ep.titleController.text.trim().isNotEmpty &&
        (isFreestyle || ep.subtype.isNotEmpty) &&
        !_isCreating;
  }

  Future<void> _create() async {
    final editorProvider = context.read<EditorProvider>();
    setState(() => _isCreating = true);
    try {
      await editorProvider.addNewBook();
      if (_imageBytes != null && editorProvider.activeBook != null) {
        await editorProvider.updateBookCoverImage(
          editorProvider.activeBook!,
          _imageBytes!,
        );
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _isCreating = false);
        _showError(e);
      }
    }
  }

  void _showError(Object e) {
    showCupertinoDialog(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text("Something went wrong"),
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            e is Exception
                ? e.toString().replaceFirst('Exception: ', '')
                : e.toString(),
            style: GoogleFonts.inter(),
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF0A0A0A) : const Color(0xFFFAFAFA);
    final surfaceColor = isDark ? const Color(0xFF141414) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF111111);
    final mutedColor = isDark
        ? Colors.white.withValues(alpha: 0.5)
        : Colors.black.withValues(alpha: 0.5);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.08);
    final width = MediaQuery.sizeOf(context).width;
    final isMobile = Breakpoints.isMobile(width);

    return Scaffold(
      backgroundColor: bgColor,
      body: FadeTransition(
        opacity: _fadeIn,
        child: Column(
          children: [
            _TopBar(
              isCreating: _isCreating,
              canCreate: _canCreate,
              onCancel: () => Navigator.pop(context),
              onCreate: _canCreate ? _create : null,
              textColor: textColor,
              bgColor: bgColor,
              mutedColor: mutedColor,
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(horizontal: isMobile ? 20 : 32),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: Consumer<EditorProvider>(
                      builder: (context, ep, _) {
                       
                        final style = styleFor(ep.type);
                        final hasSubtype =
                            ep.subtype.isNotEmpty;

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(height: isMobile ? 16 : 32),

                            // ── Hero ──
                            Text(
                              "What will you write?",
                              style: GoogleFonts.playfairDisplay(
                                fontSize: isMobile ? 32 : 42,
                                fontWeight: FontWeight.w700,
                                color: textColor,
                                height: 1.1,
                                letterSpacing: -0.5,
                              ),
                            ),
                            const SizedBox(height: 8),
                            ep.type == WritingType.freestyle
                                ? const SizedBox.shrink()
                                : Text(
                                    "Choose a form. You can change everything else later.",
                                    style: GoogleFonts.inter(
                                      fontSize: 15,
                                      color: mutedColor,
                                      height: 1.5,
                                    ),
                                  ),
                            ep.type == WritingType.freestyle
                                ? const SizedBox.shrink()
                                : const SizedBox(height: 28),

                            // ── Type cards ──
                             ep.type == WritingType.freestyle
                                ? const SizedBox.shrink()
                                : TypeChooser(
                                    selected: ep.type,
                                    onSelect: ep.selectWritingType,
                                    isDark: isDark,
                                  ),

                            ep.type == WritingType.freestyle
                                ? const SizedBox.shrink()
                                : const SizedBox(height: 28),

                            // ── Format (subtype) ──
                            ep.type == WritingType.freestyle
                                ? const SizedBox.shrink()
                                : Text(
                                    "Format",
                                    style: GoogleFonts.inter(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 1.4,
                                      color: mutedColor,
                                    ),
                                  ),
                             ep.type == WritingType.freestyle
                                ?const SizedBox.shrink()
                                : const SizedBox(height: 12),
                             ep.type == WritingType.freestyle
                                ? const SizedBox.shrink()
                                : _SubtypeWrap(
                                    type: ep.type,
                                    selected: ep.subtype,
                                    accent: style.accent,
                                    onSelect: ep.selectSubtype,
                                    isDark: isDark,
                                    textColor: textColor,
                                    borderColor: borderColor,
                                  ),

                            // ── Divider that appears once a format is chosen ──
                            AnimatedSize(
                              duration: const Duration(milliseconds: 260),
                              curve: Curves.easeOutCubic,
                              alignment: Alignment.topCenter,
                              child: hasSubtype || ep.type == WritingType.freestyle
                                  ? _NameSection(
                                      titleController: ep.titleController,
                                      mutedColor: mutedColor,
                                      textColor: textColor,
                                      borderColor: borderColor,
                                      onChanged: () => setState(() {}),
                                    )
                                  : const SizedBox.shrink(),
                            ),

                            // ── Optional reveal ──
                            AnimatedSize(
                              duration: const Duration(milliseconds: 260),
                              curve: Curves.easeOutCubic,
                              alignment: Alignment.topCenter,
                              child: hasSubtype
                                  ? Padding(
                                      padding: const EdgeInsets.only(top: 20),
                                      child: _OptionalSection(
                                        expanded: _showOptional,
                                        onToggle: () => setState(
                                          () => _showOptional = !_showOptional,
                                        ),
                                        imageBytes: _imageBytes,
                                        onPickImage: _pickImage,
                                        onRemoveImage: () =>
                                            setState(() => _imageBytes = null),
                                        descriptionController:
                                            ep.descriptionController,
                                        isDark: isDark,
                                        textColor: textColor,
                                        mutedColor: mutedColor,
                                        borderColor: borderColor,
                                        surfaceColor: surfaceColor,
                                      ),
                                    )
                                  : const SizedBox.shrink(),
                            ),

                            const SizedBox(height: 60),
                          ],
                        );
                      },
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

// ─── Top bar ────────────────────────────────────────────────────────────────
class _TopBar extends StatelessWidget {
  final bool isCreating;
  final bool canCreate;
  final VoidCallback onCancel;
  final VoidCallback? onCreate;
  final Color textColor;
  final Color bgColor;
  final Color mutedColor;

  const _TopBar({
    required this.isCreating,
    required this.canCreate,
    required this.onCancel,
    required this.onCreate,
    required this.textColor,
    required this.bgColor,
    required this.mutedColor,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderAlpha = canCreate ? 0.0 : (isDark ? 0.12 : 0.1);
    final fillColor = canCreate
        ? textColor
        : (isDark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.04));
    final labelColor = canCreate ? bgColor : mutedColor;

    return SafeArea(
      bottom: false,
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            GestureDetector(
              onTap: onCancel,
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.06)
                      : Colors.black.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(CupertinoIcons.xmark, color: mutedColor, size: 16),
              ),
            ),
            const Spacer(),
            GestureDetector(
              onTap: canCreate ? onCreate : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: fillColor,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isDark
                        ? Colors.white.withValues(alpha: borderAlpha)
                        : Colors.black.withValues(alpha: borderAlpha),
                  ),
                ),
                child: isCreating
                    ? AppSpinner(size: 14, color: labelColor)
                    : Text(
                        "Create",
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: labelColor,
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

// ─── Subtype pills ──────────────────────────────────────────────────────────
class _SubtypeWrap extends StatelessWidget {
  final WritingType type;
  final String selected;
  final Color accent;
  final ValueChanged<String> onSelect;
  final bool isDark;
  final Color textColor;
  final Color borderColor;

  const _SubtypeWrap({
    required this.type,
    required this.selected,
    required this.accent,
    required this.onSelect,
    required this.isDark,
    required this.textColor,
    required this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    final subtypes = getDisplaySubtypesForWritingType(type);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SizeTransition(
          sizeFactor: anim,
          axisAlignment: -1,
          child: child,
        ),
      ),
      child: Wrap(
        key: ValueKey(type),
        spacing: 8,
        runSpacing: 8,
        children: subtypes.map((s) {
          final isSelected = selected == s;
          return GestureDetector(
            onTap: () => onSelect(s),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: isSelected
                    ? accent.withValues(alpha: isDark ? 0.18 : 0.12)
                    : (isDark
                          ? Colors.white.withValues(alpha: 0.04)
                          : Colors.black.withValues(alpha: 0.03)),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: isSelected
                      ? accent.withValues(alpha: 0.6)
                      : borderColor,
                  width: isSelected ? 1.2 : 1,
                ),
              ),
              child: Text(
                s,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                  color: isSelected
                      ? (isDark ? Colors.white : Colors.black87)
                      : textColor.withValues(alpha: 0.75),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ─── Name section ───────────────────────────────────────────────────────────
class _NameSection extends StatelessWidget {
  final TextEditingController titleController;
  final Color mutedColor;
  final Color textColor;
  final Color borderColor;
  final VoidCallback onChanged;

  const _NameSection({
    required this.titleController,
    required this.mutedColor,
    required this.textColor,
    required this.borderColor,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [Expanded(child: Container(height: 1, color: borderColor))],
        ),
        const SizedBox(height: 20),
        Text(
          "Space Name",
          style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.4,
            color: mutedColor,
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: titleController,
          style: GoogleFonts.playfairDisplay(
            fontSize: 32,
            fontWeight: FontWeight.w700,
            color: textColor,
            height: 1.2,
            letterSpacing: -0.3,
          ),
          maxLines: null,
          decoration: InputDecoration(
            hintText: "Give this space a name",
            hintStyle: GoogleFonts.playfairDisplay(
              fontSize: 32,
              fontWeight: FontWeight.w700,
              color: textColor.withValues(alpha: 0.18),
              height: 1.2,
              letterSpacing: -0.3,
            ),
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: EdgeInsets.zero,
          ),
          onChanged: (_) => onChanged(),
        ),
      ],
    );
  }
}

// ─── Optional section (cover + description) ────────────────────────────────
class _OptionalSection extends StatelessWidget {
  final bool expanded;
  final VoidCallback onToggle;
  final Uint8List? imageBytes;
  final VoidCallback onPickImage;
  final VoidCallback onRemoveImage;
  final TextEditingController descriptionController;
  final bool isDark;
  final Color textColor;
  final Color mutedColor;
  final Color borderColor;
  final Color surfaceColor;

  const _OptionalSection({
    required this.expanded,
    required this.onToggle,
    required this.imageBytes,
    required this.onPickImage,
    required this.onRemoveImage,
    required this.descriptionController,
    required this.isDark,
    required this.textColor,
    required this.mutedColor,
    required this.borderColor,
    required this.surfaceColor,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                AnimatedRotation(
                  duration: const Duration(milliseconds: 180),
                  turns: expanded ? 0.25 : 0,
                  child: Icon(
                    CupertinoIcons.chevron_right,
                    size: 12,
                    color: mutedColor,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  "Cover & description",
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: mutedColor,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  "Optional",
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: mutedColor.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: expanded
              ? Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _CoverPicker(
                        imageBytes: imageBytes,
                        onPick: onPickImage,
                        onRemove: onRemoveImage,
                        isDark: isDark,
                        mutedColor: mutedColor,
                        borderColor: borderColor,
                        surfaceColor: surfaceColor,
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: descriptionController,
                        style: GoogleFonts.inter(
                          fontSize: 15,
                          color: textColor.withValues(alpha: 0.8),
                          height: 1.55,
                        ),
                        maxLines: null,
                        minLines: 2,
                        decoration: InputDecoration(
                          hintText:
                              "A short description — what is this space about?",
                          hintStyle: GoogleFonts.inter(
                            fontSize: 15,
                            color: textColor.withValues(alpha: 0.22),
                            height: 1.55,
                          ),
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

class _CoverPicker extends StatelessWidget {
  final Uint8List? imageBytes;
  final VoidCallback onPick;
  final VoidCallback onRemove;
  final bool isDark;
  final Color mutedColor;
  final Color borderColor;
  final Color surfaceColor;

  const _CoverPicker({
    required this.imageBytes,
    required this.onPick,
    required this.onRemove,
    required this.isDark,
    required this.mutedColor,
    required this.borderColor,
    required this.surfaceColor,
  });

  @override
  Widget build(BuildContext context) {
    if (imageBytes == null) {
      return GestureDetector(
        onTap: onPick,
        child: Container(
          height: 72,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: surfaceColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.06)
                      : Colors.black.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(CupertinoIcons.photo, size: 18, color: mutedColor),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      "Add cover image",
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : const Color(0xFF111111),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "1200 × 630px recommended",
                      style: GoogleFonts.inter(fontSize: 12, color: mutedColor),
                    ),
                  ],
                ),
              ),
              Icon(CupertinoIcons.arrow_up_doc, size: 16, color: mutedColor),
            ],
          ),
        ),
      );
    }

    return Stack(
      children: [
        Container(
          height: 180,
          width: double.infinity,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            image: DecorationImage(
              image: MemoryImage(imageBytes!),
              fit: BoxFit.cover,
            ),
          ),
        ),
        Positioned(
          top: 10,
          right: 10,
          child: Row(
            children: [
              _ImageChip(icon: CupertinoIcons.pencil, onTap: onPick),
              const SizedBox(width: 6),
              _ImageChip(icon: CupertinoIcons.xmark, onTap: onRemove),
            ],
          ),
        ),
      ],
    );
  }
}

class _ImageChip extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _ImageChip({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, color: Colors.white, size: 14),
      ),
    );
  }
}
