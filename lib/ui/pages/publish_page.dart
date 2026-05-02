import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/provider/editor_provider.dart';
import 'package:inkspacex/services/analytics_service.dart';
import 'package:inkspacex/ui/utilities/writing_type_style.dart';
import 'package:inkspacex/ui/widgets/app_network_image.dart';
import 'package:inkspacex/ui/widgets/app_spinner.dart';

class PublishPage extends StatefulWidget {
  final WritingModel book;
  final SectionModel? preselectedSection;

  const PublishPage({
    super.key,
    required this.book,
    this.preselectedSection,
  });

  @override
  State<PublishPage> createState() => _PublishPageState();
}

class _PublishPageState extends State<PublishPage> {
  late final TextEditingController _titleController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _tagInputController;
  Uint8List? _coverBytes;
  final Set<String> _selectedSectionIds = {};
  final List<String> _tags = [];
  bool _isDraft = false;
  bool _isPublishing = false;
  bool _includeWriting = true;
  bool _includeCanvas = true;

  bool _loadingSpace = true;
  FeedItemModel? _existingSpace;
  Set<String> _alreadyPublishedIds = {};

  List<String> get _suggestedTags {
    final subtypes = getDisplaySubtypesForWritingType(widget.book.writingType);
    final seen = <String>{};
    final all = <String>[];
    for (final t in [
      widget.book.writingType.displayName,
      if (widget.book.subtype.isNotEmpty) widget.book.subtype,
      ...subtypes,
    ]) {
      if (seen.add(t) && !_tags.contains(t)) all.add(t);
    }
    return all;
  }

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.book.title);
    _descriptionController =
        TextEditingController(text: widget.book.description);
    _tagInputController = TextEditingController();
    if (widget.preselectedSection != null) {
      _selectedSectionIds.add(widget.preselectedSection!.id);
    }
    _loadExistingSpace();
  }

  Future<void> _loadExistingSpace() async {
    try {
      final provider = context.read<EditorProvider>();
      final existing = await provider.getExistingSpace(widget.book.id);
      if (mounted) {
        setState(() {
          _existingSpace = existing;
          _alreadyPublishedIds = existing != null
              ? existing.sections.map((s) => s.id).toSet()
              : {};
          // Pre-tick sections that are already live so the dialog
          // reflects the current published state ("28 of 28" instead of
          // "0 of 28" for a freshly-ingested book). Tapping a tick
          // becomes an explicit unpublish; without this seeding the
          // republish flow would silently unpublish everything.
          _selectedSectionIds.addAll(_alreadyPublishedIds);
          _loadingSpace = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingSpace = false);
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _tagInputController.dispose();
    super.dispose();
  }

  bool get _hasCover =>
      _coverBytes != null || widget.book.coverImagePath.isNotEmpty;
  bool get _hasAnyWriting =>
      widget.book.sections.any((s) => s.content.trim().isNotEmpty);
  bool get _hasAnyCanvas =>
      widget.book.sections.any((s) => s.canvasData.trim().isNotEmpty);
  bool get _isUpdate => _existingSpace != null;
  bool get _canPublish => _selectedSectionIds.isNotEmpty && _hasCover;

  void _addCustomTag(String value) {
    final tag = value.trim();
    if (tag.isNotEmpty && !_tags.contains(tag)) {
      setState(() {
        _tags.add(tag);
        _tagInputController.clear();
      });
    }
  }

  Future<void> _pickCoverImage() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    setState(() => _coverBytes = bytes);
  }

  Future<void> _publish() async {
    if (_selectedSectionIds.isEmpty) {
      _showAlert(
          "No Sections Selected", "Select at least one section to publish.");
      return;
    }
    if (!_hasCover) {
      _showAlert(
          "Cover Image Required", "Add a cover image before publishing.");
      return;
    }

    setState(() => _isPublishing = true);
    final provider = context.read<EditorProvider>();

    try {
      if (_coverBytes != null) {
        await provider.updateBookCoverImage(widget.book, _coverBytes!);
      }
      if (_titleController.text.trim() != widget.book.title) {
        await provider.renameBookById(
            widget.book, _titleController.text.trim());
      }

      final desc = _descriptionController.text.trim();
      final selectedSections = widget.book.sections
          .where((s) => _selectedSectionIds.contains(s.id))
          .toList();

      final processedSections = selectedSections.map((s) {
        return SectionModel(
          id: s.id,
          title: s.title,
          content: _includeWriting ? s.content : '',
          canvasData: _includeCanvas ? s.canvasData : '',
          sectionColor: s.sectionColor,
          createdAt: s.createdAt,
          updatedAt: s.updatedAt,
        );
      }).toList();

      // Backend bulk-flips Section.is_published for the writing based
      // on this list — ids included get is_published=True, omitted ids
      // get False. Sending the actual ticked set (not just the
      // processed-section ids) so unticking a previously-published
      // chapter at republish time correctly removes it from the
      // public chapter list.
      final publishedSectionIds = _selectedSectionIds.toList();

      await provider.publishCover(
        widget.book,
        processedSections,
        tags: _tags,
        descriptionOverride: desc.isNotEmpty ? desc : null,
        isDraft: _isDraft,
        publishedSectionIds: publishedSectionIds,
      );

      AnalyticsService.instance.track(
        _isDraft ? 'editor_draft_saved' : 'post_published',
        screen: '/publish',
        action: 'success',
        entityType: 'writing',
        entityId: widget.book.id,
        properties: {
          'section_count': processedSections.length,
          'tag_count': _tags.length,
          'is_update': _isUpdate,
          'has_canvas': _includeCanvas,
        },
      );

      if (mounted) {
        Navigator.pop(context);
        showCupertinoDialog(
          context: context,
          builder: (ctx) => CupertinoAlertDialog(
            title: Text(_isDraft ? "Saved as Draft" : "Space Published"),
            content: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _isDraft
                    ? "Your draft has been saved. You can publish it later."
                    : _isUpdate
                        ? "Your Space has been updated with the new content."
                        : "Your Space is now live on the feed!",
                style: GoogleFonts.inter(),
              ),
            ),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("OK"),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      AnalyticsService.instance.track(
        'post_publish_failed',
        screen: '/publish',
        action: 'fail',
        entityType: 'writing',
        entityId: widget.book.id,
      );
      if (mounted) {
        setState(() => _isPublishing = false);
        _showAlert("Error", e.toString().replaceFirst('Exception: ', ''));
      }
    }
  }

  void _showAlert(String title, String message) {
    showCupertinoDialog(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text(title),
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(message, style: GoogleFonts.inter()),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("OK"),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // BUILD
  // ═══════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF0A0A0A) : const Color(0xFFFAFAFA);
    final textColor = isDark ? Colors.white : const Color(0xFF111111);
    final mutedColor = isDark
        ? Colors.white.withValues(alpha: 0.5)
        : Colors.black.withValues(alpha: 0.5);
    final dividerColor = isDark
        ? Colors.white.withValues(alpha: 0.07)
        : Colors.black.withValues(alpha: 0.07);
    final safePad = MediaQuery.of(context).padding;
    final accent = styleFor(widget.book.writingType).accent;

    return Scaffold(
      backgroundColor: bgColor,
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(height: safePad.top + 8),

                      // ── Top bar ──
                      _buildTopBar(
                        isDark: isDark,
                        textColor: textColor,
                        mutedColor: mutedColor,
                        bgColor: bgColor,
                      ),

                      // ── Live banner ──
                      if (!_loadingSpace && _isUpdate)
                        _buildLiveBanner(
                          isDark: isDark,
                          accent: accent,
                          textColor: textColor,
                          mutedColor: mutedColor,
                        ),

                      const SizedBox(height: 8),

                      // ── Cover ──
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: _buildCover(isDark: isDark, mutedColor: mutedColor),
                      ),

                      const SizedBox(height: 24),

                      // ── Title & Description ──
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: _buildDetailsSection(
                          isDark: isDark,
                          textColor: textColor,
                          mutedColor: mutedColor,
                        ),
                      ),

                      _buildDivider(dividerColor),

                      // ── Sections ──
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: _buildSectionsSection(
                          isDark: isDark,
                          accent: accent,
                          textColor: textColor,
                          mutedColor: mutedColor,
                        ),
                      ),

                      _buildDivider(dividerColor),

                      // ── Tags ──
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: _buildTagsSection(
                          isDark: isDark,
                          textColor: textColor,
                          mutedColor: mutedColor,
                        ),
                      ),

                      _buildDivider(dividerColor),

                      // ── Draft toggle ──
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: _buildDraftToggle(
                          isDark: isDark,
                          textColor: textColor,
                          mutedColor: mutedColor,
                        ),
                      ),

                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // ── Bottom CTA ──
          _buildBottomCta(
            isDark: isDark,
            textColor: textColor,
            accent: accent,
            dividerColor: dividerColor,
            safePad: safePad,
            bgColor: bgColor,
          ),
        ],
      ),
    );
  }

  // ── TOP BAR ──
  Widget _buildTopBar({
    required bool isDark,
    required Color textColor,
    required Color mutedColor,
    required Color bgColor,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            CupertinoButton(
              padding: const EdgeInsets.all(8),
              onPressed: () => Navigator.pop(context),
              child: Icon(
                CupertinoIcons.back,
                size: 22,
                color: textColor,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              _isUpdate ? "Update" : "Publish",
              style: GoogleFonts.inter(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: textColor,
              ),
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }

  // ── LIVE BANNER ──
  Widget _buildLiveBanner({
    required bool isDark,
    required Color accent,
    required Color textColor,
    required Color mutedColor,
  }) {
    final space = _existingSpace!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: isDark ? 0.08 : 0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: accent.withValues(alpha: 0.15)),
        ),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: CupertinoColors.activeGreen,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                "Live with ${space.sections.length} section${space.sections.length == 1 ? '' : 's'} · ${space.likesCount} like${space.likesCount == 1 ? '' : 's'}",
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: textColor.withValues(alpha: 0.7),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── COVER ──
  Widget _buildCover({required bool isDark, required Color mutedColor}) {
    final hasNetCover = widget.book.coverImagePath.isNotEmpty ||
        widget.book.coverImageMeta != null;
    return GestureDetector(
      onTap: _pickCoverImage,
      child: AspectRatio(
        aspectRatio: 21 / 9,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_coverBytes != null)
                Image.memory(_coverBytes!, fit: BoxFit.cover)
              else if (hasNetCover)
                LayoutBuilder(
                  builder: (ctx, c) => AppNetworkImage(
                    url: widget.book.coverImagePath,
                    meta: widget.book.coverImageMeta,
                    width: c.maxWidth,
                    height: c.maxHeight,
                    fit: BoxFit.cover,
                  ),
                )
              else
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.1)
                          : Colors.black.withValues(alpha: 0.08),
                    ),
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.03)
                        : Colors.black.withValues(alpha: 0.02),
                  ),
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          CupertinoIcons.camera,
                          size: 18,
                          color: mutedColor.withValues(alpha: 0.6),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          "Add cover",
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: mutedColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_hasCover) ...[
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.4),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 12,
                  bottom: 10,
                  child: _buildSmallChip(
                    icon: CupertinoIcons.camera,
                    label: "Change",
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ── DETAILS ──
  Widget _buildDetailsSection({
    required bool isDark,
    required Color textColor,
    required Color mutedColor,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _titleController,
          style: GoogleFonts.playfairDisplay(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            color: textColor,
            height: 1.2,
            letterSpacing: -0.3,
          ),
          maxLines: null,
          decoration: InputDecoration(
            hintText: "Space title",
            hintStyle: GoogleFonts.playfairDisplay(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              color: textColor.withValues(alpha: 0.18),
              height: 1.2,
            ),
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: _descriptionController,
          style: GoogleFonts.inter(
            fontSize: 15,
            color: textColor.withValues(alpha: 0.7),
            height: 1.5,
          ),
          maxLines: null,
          minLines: 1,
          decoration: InputDecoration(
            hintText: "A brief description for readers...",
            hintStyle: GoogleFonts.inter(
              fontSize: 15,
              color: textColor.withValues(alpha: 0.2),
              height: 1.5,
            ),
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  // ── SECTIONS ──
  Widget _buildSectionsSection({
    required bool isDark,
    required Color accent,
    required Color textColor,
    required Color mutedColor,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _buildSectionLabel("Sections"),
            const Spacer(),
            Text(
              "${_selectedSectionIds.length} of ${widget.book.sections.length}",
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: accent,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),

        ...widget.book.sections.map((section) {
          final isSelected = _selectedSectionIds.contains(section.id);
          final isLive = _alreadyPublishedIds.contains(section.id);

          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: GestureDetector(
              onTap: () {
                setState(() {
                  if (isSelected) {
                    _selectedSectionIds.remove(section.id);
                  } else {
                    _selectedSectionIds.add(section.id);
                  }
                });
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 11),
                decoration: BoxDecoration(
                  color: isSelected
                      ? accent.withValues(alpha: isDark ? 0.1 : 0.05)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isSelected
                        ? accent.withValues(alpha: 0.3)
                        : (isDark
                            ? Colors.white.withValues(alpha: 0.06)
                            : Colors.black.withValues(alpha: 0.05)),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: section.sectionColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        CupertinoIcons.doc_text_fill,
                        size: 14,
                        color: section.sectionColor,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            section.title,
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: textColor,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              if (isLive) ...[
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 5, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: CupertinoColors.activeGreen
                                        .withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    "LIVE",
                                    style: GoogleFonts.inter(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w700,
                                      color: CupertinoColors.activeGreen,
                                      letterSpacing: 0.4,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                              ],
                              Text(
                                _timeAgo(section.updatedAt),
                                style: GoogleFonts.inter(
                                  fontSize: 11,
                                  color: mutedColor.withValues(alpha: 0.7),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: isSelected ? accent : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: isSelected
                              ? accent
                              : mutedColor.withValues(alpha: 0.25),
                          width: 1.5,
                        ),
                      ),
                      child: isSelected
                          ? const Icon(CupertinoIcons.checkmark,
                              size: 12, color: Colors.white)
                          : null,
                    ),
                  ],
                ),
              ),
            ),
          );
        }),

        // ── Include toggles ──
        if (_selectedSectionIds.isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              _buildIncludeChip(
                icon: CupertinoIcons.doc_text_fill,
                label: "Writing",
                active: _includeWriting && _hasAnyWriting,
                enabled: _hasAnyWriting,
                accent: accent,
                isDark: isDark,
                textColor: textColor,
                mutedColor: mutedColor,
                onTap: _hasAnyWriting
                    ? () =>
                        setState(() => _includeWriting = !_includeWriting)
                    : null,
              ),
              const SizedBox(width: 8),
              _buildIncludeChip(
                icon: CupertinoIcons.paintbrush_fill,
                label: "Canvas",
                active: _includeCanvas && _hasAnyCanvas,
                enabled: _hasAnyCanvas,
                accent: accent,
                isDark: isDark,
                textColor: textColor,
                mutedColor: mutedColor,
                onTap: _hasAnyCanvas
                    ? () =>
                        setState(() => _includeCanvas = !_includeCanvas)
                    : null,
              ),
            ],
          ),
        ],

        const SizedBox(height: 8),
      ],
    );
  }

  // ── TAGS ──
  Widget _buildTagsSection({
    required bool isDark,
    required Color textColor,
    required Color mutedColor,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionLabel("Tags"),
        const SizedBox(height: 14),

        // Added tags
        if (_tags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: _tags
                  .map((tag) => Container(
                        padding: const EdgeInsets.only(
                            left: 10, right: 4, top: 6, bottom: 6),
                        decoration: BoxDecoration(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.08)
                              : Colors.black.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              tag,
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: textColor.withValues(alpha: 0.8),
                              ),
                            ),
                            const SizedBox(width: 4),
                            GestureDetector(
                              onTap: () =>
                                  setState(() => _tags.remove(tag)),
                              child: Padding(
                                padding: const EdgeInsets.all(2),
                                child: Icon(
                                  CupertinoIcons.xmark,
                                  size: 11,
                                  color: textColor.withValues(alpha: 0.3),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ))
                  .toList(),
            ),
          ),

        // Input
        Row(
          children: [
            Expanded(
              child: CupertinoTextField(
                controller: _tagInputController,
                placeholder: "Add a tag...",
                placeholderStyle: GoogleFonts.inter(
                  color: mutedColor.withValues(alpha: 0.5),
                  fontSize: 14,
                ),
                style: GoogleFonts.inter(color: textColor, fontSize: 14),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.04)
                      : Colors.black.withValues(alpha: 0.025),
                  borderRadius: BorderRadius.circular(10),
                ),
                onSubmitted: _addCustomTag,
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => _addCustomTag(_tagInputController.text),
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.06)
                      : Colors.black.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  CupertinoIcons.plus,
                  size: 16,
                  color: textColor.withValues(alpha: 0.4),
                ),
              ),
            ),
          ],
        ),

        // Suggestions
        if (_suggestedTags.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: _suggestedTags
                .map((tag) => GestureDetector(
                      onTap: () => setState(() => _tags.add(tag)),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.08)
                                : Colors.black.withValues(alpha: 0.06),
                          ),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(CupertinoIcons.plus,
                                size: 10,
                                color:
                                    textColor.withValues(alpha: 0.35)),
                            const SizedBox(width: 4),
                            Text(
                              tag,
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                color: textColor.withValues(alpha: 0.5),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ))
                .toList(),
          ),
        ],

        const SizedBox(height: 8),
      ],
    );
  }

  // ── DRAFT TOGGLE ──
  Widget _buildDraftToggle({
    required bool isDark,
    required Color textColor,
    required Color mutedColor,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            CupertinoIcons.eye_slash,
            size: 16,
            color: _isDraft
                ? CupertinoColors.activeOrange
                : mutedColor,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Save as Draft",
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: textColor,
                  ),
                ),
                Text(
                  "Won\u2019t appear in the feed yet",
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: mutedColor,
                  ),
                ),
              ],
            ),
          ),
          CupertinoSwitch(
            value: _isDraft,
            activeTrackColor: CupertinoColors.activeOrange,
            onChanged: (v) => setState(() => _isDraft = v),
          ),
        ],
      ),
    );
  }

  // ── BOTTOM CTA ──
  Widget _buildBottomCta({
    required bool isDark,
    required Color textColor,
    required Color accent,
    required Color dividerColor,
    required EdgeInsets safePad,
    required Color bgColor,
  }) {
    final ready = _canPublish;
    final btnBg = _isDraft
        ? CupertinoColors.activeOrange
        : ready
            ? textColor
            : (isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.black.withValues(alpha: 0.04));
    final btnFg = _isDraft || ready
        ? (isDark ? Colors.black : Colors.white)
        : textColor.withValues(alpha: 0.25);

    final label = _isDraft
        ? "Save Draft"
        : _isUpdate
            ? "Update Space"
            : "Publish Space";

    return Container(
      padding:
          EdgeInsets.fromLTRB(20, 12, 20, safePad.bottom.clamp(12, 40)),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(top: BorderSide(color: dividerColor)),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: GestureDetector(
            onTap: _isPublishing || !ready ? null : _publish,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              width: double.infinity,
              height: 48,
              decoration: BoxDecoration(
                color: btnBg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: _isPublishing
                    ? AppSpinner(color: btnFg)
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _isDraft
                                ? CupertinoIcons.doc
                                : CupertinoIcons.paperplane_fill,
                            size: 16,
                            color: btnFg,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            label,
                            style: GoogleFonts.inter(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: btnFg,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ─── Shared helpers ───

  Widget _buildSectionLabel(String text) {
    return Text(
      text.toUpperCase(),
      style: GoogleFonts.inter(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.4,
        color: Theme.of(context).brightness == Brightness.dark
            ? Colors.white.withValues(alpha: 0.4)
            : Colors.black.withValues(alpha: 0.4),
      ),
    );
  }

  Widget _buildDivider(Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Container(height: 1, color: color),
    );
  }

  Widget _buildSmallChip({required IconData icon, required String label}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 13),
          const SizedBox(width: 5),
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
    );
  }

  Widget _buildIncludeChip({
    required IconData icon,
    required String label,
    required bool active,
    required bool enabled,
    required Color accent,
    required bool isDark,
    required Color textColor,
    required Color mutedColor,
    VoidCallback? onTap,
  }) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.4,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: active
                ? accent.withValues(alpha: isDark ? 0.12 : 0.06)
                : (isDark
                    ? Colors.white.withValues(alpha: 0.04)
                    : Colors.black.withValues(alpha: 0.03)),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: active
                  ? accent.withValues(alpha: 0.3)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: active ? accent : mutedColor),
              const SizedBox(width: 6),
              Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  color:
                      active ? accent : textColor.withValues(alpha: 0.5),
                ),
              ),
              if (active) ...[
                const SizedBox(width: 4),
                Icon(CupertinoIcons.checkmark, size: 12, color: accent),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return "just now";
    if (diff.inMinutes < 60) return "${diff.inMinutes}m ago";
    if (diff.inHours < 24) return "${diff.inHours}h ago";
    if (diff.inDays < 7) return "${diff.inDays}d ago";
    return "${dt.month}/${dt.day}/${dt.year}";
  }
}
