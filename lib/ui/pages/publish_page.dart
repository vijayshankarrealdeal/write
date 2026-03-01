import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/provider/editor_provider.dart';

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
  Uint8List? _coverBytes;
  final Set<String> _selectedSectionIds = {};
  bool _isDraft = false;
  bool _isPublishing = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.book.title);
    if (widget.preselectedSection != null) {
      _selectedSectionIds.add(widget.preselectedSection!.id);
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  bool get _hasCover =>
      _coverBytes != null || widget.book.coverImagePath.isNotEmpty;

  Future<void> _pickCoverImage() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1200,
      imageQuality: 70,
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    setState(() => _coverBytes = bytes);
  }

  Future<void> _publish() async {
    if (_selectedSectionIds.isEmpty) {
      _showAlert("No Sections Selected", "Select at least one section to publish.");
      return;
    }
    if (!_hasCover) {
      _showAlert("Cover Image Required", "Add a cover image before publishing.");
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
          widget.book,
          _titleController.text.trim(),
        );
      }

      for (final sId in _selectedSectionIds) {
        final section = widget.book.sections.firstWhere((s) => s.id == sId);
        await provider.publishSection(widget.book, section);
      }

      if (mounted) {
        Navigator.pop(context);
        showCupertinoDialog(
          context: context,
          builder: (ctx) => CupertinoAlertDialog(
            title: const Text("Published"),
            content: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _selectedSectionIds.length == 1
                    ? "Your section is now live on the feed."
                    : "${_selectedSectionIds.length} sections are now live on the feed.",
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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF000000) : const Color(0xFFF8FAFC);
    final cardColor = isDark ? const Color(0xFF1A1A1A) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final mutedColor = isDark ? Colors.white54 : Colors.black45;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.08);

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: Icon(CupertinoIcons.back, color: textColor),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          "Publish",
          style: GoogleFonts.inter(
            fontWeight: FontWeight.w600,
            fontSize: 16,
            color: textColor,
          ),
        ),
        centerTitle: true,
        actions: [
          if (_isPublishing)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: CupertinoActivityIndicator(),
            )
          else
            CupertinoButton(
              padding: const EdgeInsets.only(right: 16),
              onPressed: _publish,
              child: Text(
                "Post",
                style: GoogleFonts.inter(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: CupertinoColors.activeBlue,
                ),
              ),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // --- COVER IMAGE ---
                _buildSectionLabel("COVER IMAGE", textColor),
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: _pickCoverImage,
                  child: Container(
                    height: 200,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: cardColor,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: borderColor),
                      image: _coverBytes != null
                          ? DecorationImage(
                              image: MemoryImage(_coverBytes!),
                              fit: BoxFit.cover,
                            )
                          : widget.book.coverImagePath.isNotEmpty
                              ? DecorationImage(
                                  image: NetworkImage(widget.book.coverImagePath),
                                  fit: BoxFit.cover,
                                )
                              : null,
                    ),
                    child: _hasCover
                        ? Align(
                            alignment: Alignment.bottomRight,
                            child: Container(
                              margin: const EdgeInsets.all(12),
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(
                                CupertinoIcons.camera,
                                color: Colors.white,
                                size: 18,
                              ),
                            ),
                          )
                        : Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                CupertinoIcons.photo_on_rectangle,
                                size: 40,
                                color: mutedColor,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                "Tap to add cover image",
                                style: GoogleFonts.inter(
                                  color: mutedColor,
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                "Required for publishing",
                                style: GoogleFonts.inter(
                                  color: mutedColor.withValues(alpha: 0.6),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                  ),
                ),

                const SizedBox(height: 28),

                // --- TITLE ---
                _buildSectionLabel("TITLE", textColor),
                const SizedBox(height: 8),
                TextField(
                  controller: _titleController,
                  style: GoogleFonts.inter(color: textColor, fontSize: 16),
                  decoration: InputDecoration(
                    hintText: "Publication title...",
                    hintStyle: GoogleFonts.inter(color: mutedColor),
                    filled: true,
                    fillColor: cardColor,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: borderColor),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: borderColor),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: textColor.withValues(alpha: 0.3),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 28),

                // --- DRAFT TOGGLE ---
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: cardColor,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: borderColor),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        CupertinoIcons.doc_plaintext,
                        size: 20,
                        color: mutedColor,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          "Save as Draft",
                          style: GoogleFonts.inter(
                            color: textColor,
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      CupertinoSwitch(
                        value: _isDraft,
                        activeTrackColor: CupertinoColors.activeGreen,
                        onChanged: (v) => setState(() => _isDraft = v),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 28),

                // --- SELECT SECTIONS ---
                _buildSectionLabel("SECTIONS TO PUBLISH", textColor),
                const SizedBox(height: 4),
                Text(
                  widget.preselectedSection != null
                      ? "Verify the section below before posting"
                      : "Choose which sections to share on the feed",
                  style: GoogleFonts.inter(color: mutedColor, fontSize: 13),
                ),
                const SizedBox(height: 12),

                ...widget.book.sections.map((section) {
                  final isSelected = _selectedSectionIds.contains(section.id);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: isSelected
                          ? (isDark
                              ? CupertinoColors.activeBlue.withValues(alpha: 0.15)
                              : CupertinoColors.activeBlue.withValues(alpha: 0.08))
                          : cardColor,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        onTap: () {
                          setState(() {
                            if (isSelected) {
                              _selectedSectionIds.remove(section.id);
                            } else {
                              _selectedSectionIds.add(section.id);
                            }
                          });
                        },
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isSelected
                                  ? CupertinoColors.activeBlue.withValues(alpha: 0.4)
                                  : borderColor,
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: section.sectionColor.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(
                                  CupertinoIcons.doc_text,
                                  size: 18,
                                  color: section.sectionColor,
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      section.title,
                                      style: GoogleFonts.inter(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w500,
                                        color: textColor,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    if (section.content.isNotEmpty) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        "Last edited ${_timeAgo(section.updatedAt)}",
                                        style: GoogleFonts.inter(
                                          fontSize: 12,
                                          color: mutedColor,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              Icon(
                                isSelected
                                    ? CupertinoIcons.checkmark_circle_fill
                                    : CupertinoIcons.circle,
                                size: 24,
                                color: isSelected
                                    ? CupertinoColors.activeBlue
                                    : mutedColor,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }),

                const SizedBox(height: 32),

                // --- PUBLISH BUTTON ---
                SizedBox(
                  width: double.infinity,
                  child: CupertinoButton(
                    color: isDark ? Colors.white : Colors.black,
                    borderRadius: BorderRadius.circular(14),
                    onPressed: _isPublishing ? null : _publish,
                    child: _isPublishing
                        ? const CupertinoActivityIndicator(color: Colors.white)
                        : Text(
                            _isDraft ? "Save as Draft" : "Publish Now",
                            style: GoogleFonts.inter(
                              color: isDark ? Colors.black : Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 16,
                            ),
                          ),
                  ),
                ),

                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionLabel(String label, Color textColor) {
    return Text(
      label,
      style: GoogleFonts.inter(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: textColor.withValues(alpha: 0.4),
        letterSpacing: 1.0,
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
