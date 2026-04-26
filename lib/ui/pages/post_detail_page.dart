import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:inkspacex/ui/editor/image_embed_builder.dart';
import 'package:inkspacex/ui/widgets/app_network_image.dart';
import 'package:inkspacex/ui/widgets/more_like_this_carousel.dart';

import 'package:inkspacex/models/canvas_element_model.dart';
import 'package:inkspacex/models/comment_model.dart';
import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/models/image_meta.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/provider/bookmark_provider.dart';
import 'package:inkspacex/provider/feed_provider.dart';
import 'package:inkspacex/services/api/api_data_service.dart';

// ---------------------------------------------------------------------------
// Custom style builder (matches editor font rendering)
// ---------------------------------------------------------------------------
TextStyle _customStyleBuilder(quill.Attribute attr) {
  if (attr.key == 'font') {
    final name = attr.value as String?;
    if (name != null && name.isNotEmpty && name != 'Clear') {
      try {
        return GoogleFonts.getFont(name);
      } catch (_) {
        return TextStyle(fontFamily: name);
      }
    }
  }
  if (attr.key == 'size') {
    final raw = attr.value;
    final size =
        raw is num ? raw.toDouble() : double.tryParse(raw?.toString() ?? '');
    if (size != null && size > 0) return TextStyle(fontSize: size);
  }
  return const TextStyle();
}

// ---------------------------------------------------------------------------
// Reading time estimator
// ---------------------------------------------------------------------------
int _estimateReadingMinutes(List<FeedItemSection> sections) {
  int totalWords = 0;
  for (final section in sections) {
    if (section.content.isEmpty) continue;
    try {
      final decoded = jsonDecode(section.content);
      if (decoded is List) {
        for (final op in decoded) {
          if (op is Map && op['insert'] is String) {
            totalWords +=
                (op['insert'] as String).split(RegExp(r'\s+')).length;
          }
        }
      }
    } catch (_) {}
  }
  return max(1, (totalWords / 238).ceil());
}

// ---------------------------------------------------------------------------
// Date formatter
// ---------------------------------------------------------------------------
String _formatDate(DateTime dt) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
}

// ============================================================================
// PostDetailPage — two-level: overview → section detail
// ============================================================================
class PostDetailPage extends StatefulWidget {
  final FeedItemModel item;
  const PostDetailPage({super.key, required this.item});

  @override
  State<PostDetailPage> createState() => _PostDetailPageState();
}

class _PostDetailPageState extends State<PostDetailPage>
    with SingleTickerProviderStateMixin {
  // -- Quill controllers (keyed by section index) --
  final Map<int, quill.QuillController> _quillControllers = {};

  // -- Review input --
  final _commentController = TextEditingController();
  final _commentFocus = FocusNode();

  // -- Reading progress persistence --
  late final ApiDataService _dataService;
  Timer? _debounce;
  String? _userId;

  // -- Two-level navigation: null = overview, int = section detail --
  int? _selectedSectionIndex;

  // -- Last read section (for "continue reading" prompt) --
  int? _lastReadSection;

  // -- Scaffold key for endDrawer --
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  // -- PageView controller for section carousel --
  PageController? _pageController;

  // -- Reader font scale (for Aa text size button in reading mode) --
  double _readerFontScale = 1.0;

  // -- Reader theme: 'white' | 'sepia' | 'black' | 'grey' --
  String _readerTheme = 'sepia';

  // -- Reader font family --
  String _readerFont = 'Lora';

  // -- Reader brightness multiplier (0.4–1.0, applied as overlay) --
  double _readerBrightness = 1.0;

  // -- Per-section text highlights: section index -> list of (start, length, colorHex) --
  final Map<int, List<_Highlight>> _highlights = {};

  // -- Double-tap like heart animation --
  late final AnimationController _likeAnimController;

  // -- Accent color (used across reader UI) --
  static const Color _paperAccent = Color(0xFF2F62E0);

  // --------------------------------------------------------------------------
  // Resolve reader palette (bg/text/subtle) from current theme
  // --------------------------------------------------------------------------
  ({Color bg, Color text, Color subtle}) _readerPalette() {
    switch (_readerTheme) {
      case 'white':
        return (
          bg: const Color(0xFFFFFFFF),
          text: const Color(0xFF1A1A1A),
          subtle: Colors.black.withValues(alpha: 0.5),
        );
      case 'black':
        return (
          bg: const Color(0xFF000000),
          text: const Color(0xFFE8E8E8),
          subtle: Colors.white.withValues(alpha: 0.55),
        );
      case 'grey':
        return (
          bg: const Color(0xFF2A2A2A),
          text: const Color(0xFFE8E8E8),
          subtle: Colors.white.withValues(alpha: 0.55),
        );
      case 'sepia':
      default:
        return (
          bg: const Color(0xFFEADCC1),
          text: const Color(0xFF2B2419),
          subtle: const Color(0xFF2B2419).withValues(alpha: 0.55),
        );
    }
  }

  // --------------------------------------------------------------------------
  // Resolve a TextStyle using the current reader font family
  // --------------------------------------------------------------------------
  TextStyle _readerTextStyle({
    double? fontSize,
    FontWeight? fontWeight,
    FontStyle? fontStyle,
    Color? color,
    double? height,
    double? letterSpacing,
  }) {
    try {
      return GoogleFonts.getFont(
        _readerFont,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontStyle: fontStyle,
        color: color,
        height: height,
        letterSpacing: letterSpacing,
      );
    } catch (_) {
      return TextStyle(
        fontFamily: _readerFont,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontStyle: fontStyle,
        color: color,
        height: height,
        letterSpacing: letterSpacing,
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _likeAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    // Default theme: black for dark mode, white for light mode (overridden by saved pref)
    final platformBrightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    _readerTheme = platformBrightness == Brightness.dark ? 'black' : 'white';
    _initQuillControllers();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _dataService = context.read<AuthProvider>().dataService;
      _loadProgress();
      _loadReaderPrefs();
    });
  }

  // --------------------------------------------------------------------------
  // Persisted reader preferences (theme / font / size / brightness)
  // --------------------------------------------------------------------------
  static const _kPrefTheme = 'reader_theme';
  static const _kPrefFont = 'reader_font';
  static const _kPrefScale = 'reader_font_scale';
  static const _kPrefBrightness = 'reader_brightness';

  Future<void> _loadReaderPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _readerTheme = prefs.getString(_kPrefTheme) ?? _readerTheme;
        _readerFont = prefs.getString(_kPrefFont) ?? _readerFont;
        _readerFontScale =
            prefs.getDouble(_kPrefScale) ?? _readerFontScale;
        _readerBrightness =
            prefs.getDouble(_kPrefBrightness) ?? _readerBrightness;
      });
    } catch (_) {}
  }

  Future<void> _saveReaderPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPrefTheme, _readerTheme);
      await prefs.setString(_kPrefFont, _readerFont);
      await prefs.setDouble(_kPrefScale, _readerFontScale);
      await prefs.setDouble(_kPrefBrightness, _readerBrightness);
    } catch (_) {}
  }

  // --------------------------------------------------------------------------
  // Quill controller setup
  // --------------------------------------------------------------------------
  void _initQuillControllers() {
    for (int i = 0; i < widget.item.sections.length; i++) {
      final section = widget.item.sections[i];
      try {
        if (section.content.isNotEmpty) {
          final delta = quill.Document.fromJson(jsonDecode(section.content));
          _quillControllers[i] = quill.QuillController(
            document: delta,
            selection: const TextSelection.collapsed(offset: 0),
          );
        }
      } catch (_) {
        // Skip sections with invalid/empty content
      }
    }
  }

  // --------------------------------------------------------------------------
  // Load reading progress (for "continue reading" prompt, always start on overview)
  // --------------------------------------------------------------------------
  Future<void> _loadProgress() async {
    final auth = context.read<AuthProvider>();
    _userId = auth.currentUser?.id;
    if (_userId == null) return;
    try {
      final progress = await _dataService.getReadingProgress(
        _userId!,
        widget.item.id,
      );
      if (progress != null && mounted) {
        final saved = progress.scrollPosition.round();
        if (saved >= 0 && saved < widget.item.sections.length) {
          setState(() => _lastReadSection = saved);
        }
      }
    } catch (_) {}
    await _loadHighlights();
  }

  // --------------------------------------------------------------------------
  // Load saved highlights from Firestore and re-apply them to Quill docs
  // --------------------------------------------------------------------------
  Future<void> _loadHighlights() async {
    if (_userId == null) return;
    try {
      final rows = await _dataService.getHighlightsForFeedItem(
        userId: _userId!,
        feedItemId: widget.item.id,
      );
      if (!mounted) return;
      for (final h in rows) {
        final sectionIndex = (h['sectionIndex'] as num?)?.toInt();
        final start = (h['start'] as num?)?.toInt();
        final length = (h['length'] as num?)?.toInt();
        final colorHex = (h['colorHex'] as String?) ?? '';
        final id = (h['id'] as String?) ?? '';
        if (sectionIndex == null ||
            start == null ||
            length == null ||
            id.isEmpty ||
            colorHex.isEmpty) {
          continue;
        }
        _highlights.putIfAbsent(sectionIndex, () => []).add(
              _Highlight(
                id: id,
                start: start,
                length: length,
                colorHex: colorHex,
              ),
            );
        final controller = _quillControllers[sectionIndex];
        if (controller != null) {
          try {
            controller.formatText(
              start,
              length,
              quill.BackgroundAttribute(colorHex),
            );
          } catch (_) {}
        }
      }
      if (mounted) setState(() {});
    } catch (_) {}
  }

  // --------------------------------------------------------------------------
  // Remove local + remote highlights overlapping the given range
  // --------------------------------------------------------------------------
  void _removeHighlightsInRange(int sectionIndex, int start, int length) {
    final list = _highlights[sectionIndex];
    if (list == null || list.isEmpty) return;
    final end = start + length;
    final toRemove = list
        .where((h) => h.start < end && (h.start + h.length) > start)
        .toList();
    for (final h in toRemove) {
      list.remove(h);
      if (_userId != null && h.id.isNotEmpty) {
        _dataService.deleteHighlight(
          userId: _userId!,
          highlightId: h.id,
        );
      }
    }
  }

  // --------------------------------------------------------------------------
  // Enter section detail mode (from overview or continue reading)
  // --------------------------------------------------------------------------
  void _enterSectionDetail(int index) {
    _pageController?.dispose();
    _pageController = PageController(initialPage: index);
    setState(() => _selectedSectionIndex = index);
    _saveProgress(index);
  }

  // --------------------------------------------------------------------------
  // Navigate to a section within the carousel (from drawer or dots)
  // --------------------------------------------------------------------------
  void _navigateToSection(int index) {
    setState(() => _selectedSectionIndex = index);
    _saveProgress(index);
    if (_pageController?.hasClients == true) {
      _pageController!.animateToPage(
        index,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  // --------------------------------------------------------------------------
  // Persist current section as reading progress
  // --------------------------------------------------------------------------
  void _saveProgress(int sectionIndex) {
    if (_userId == null) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _dataService.updateReadingProgress(
        _userId!,
        widget.item.id,
        sectionIndex.toDouble(),
      );
    });
  }

  // --------------------------------------------------------------------------
  // Double-tap like with heart animation
  // --------------------------------------------------------------------------
  void _onDoubleTapLike() {
    final auth = context.read<AuthProvider>();
    final feed = context.read<FeedProvider>();
    auth.toggleLike(widget.item.id, feedProvider: feed);
    _likeAnimController.forward(from: 0.0);
  }

  // --------------------------------------------------------------------------
  // Reader settings bottom sheet (brightness · theme · font)
  // --------------------------------------------------------------------------
  void _openReaderTextSizeSheet(bool isDark) {
    const themes = [
      ('white', 'White', Color(0xFFFFFFFF), Color(0xFF1A1A1A)),
      ('sepia', 'Sepia', Color(0xFFEADCC1), Color(0xFF2B2419)),
      ('black', 'Black', Color(0xFF000000), Color(0xFFE8E8E8)),
      ('grey', 'Grey', Color(0xFF2A2A2A), Color(0xFFE8E8E8)),
    ];
    const fonts = ['Lora', 'Georgia', 'Merriweather', 'Inter', 'Playfair Display'];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (sheetCtx, setSheet) {
            // Re-resolve palette on every rebuild so theme changes apply live.
            final palette = _readerPalette();
            final paperBg = palette.bg;
            final paperText = palette.text;
            final paperSubtle = palette.subtle;
            final pillBg = paperText.withValues(alpha: 0.06);
            final pillBorder = paperText.withValues(alpha: 0.12);

            void apply(VoidCallback fn) {
              setSheet(fn);
              setState(fn);
              _saveReaderPrefs();
            }

            return AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              decoration: BoxDecoration(
                color: paperBg,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(24)),
              ),
              padding: EdgeInsets.fromLTRB(
                20, 12, 20, 16 + MediaQuery.of(sheetCtx).padding.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Drag handle
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: paperText.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),

                  // Brightness slider
                  Row(
                    children: [
                      Icon(CupertinoIcons.sun_min,
                          size: 18, color: paperSubtle),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(sheetCtx).copyWith(
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 8,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 14,
                            ),
                          ),
                          child: Slider(
                            value: _readerBrightness,
                            min: 0.4,
                            max: 1.0,
                            activeColor: _paperAccent,
                            inactiveColor: paperText.withValues(alpha: 0.2),
                            onChanged: (v) =>
                                apply(() => _readerBrightness = v),
                          ),
                        ),
                      ),
                      Icon(CupertinoIcons.sun_max_fill,
                          size: 20, color: paperSubtle),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Theme pills
                  Row(
                    children: [
                      for (final t in themes) ...[
                        Expanded(
                          child: GestureDetector(
                            onTap: () => apply(() => _readerTheme = t.$1),
                            child: Container(
                              height: 40,
                              decoration: BoxDecoration(
                                color: t.$3,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: _readerTheme == t.$1
                                      ? _paperAccent
                                      : pillBorder,
                                  width: _readerTheme == t.$1 ? 2 : 1,
                                ),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                t.$2,
                                style: GoogleFonts.inter(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: t.$4,
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (t != themes.last) const SizedBox(width: 8),
                      ],
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Font row: dropdown + size - / +
                  Row(
                    children: [
                      // Font dropdown
                      Expanded(
                        child: GestureDetector(
                          onTap: () => _showFontPickerMenu(
                            sheetCtx, fonts, paperBg, paperText, apply,
                          ),
                          child: Container(
                            height: 44,
                            padding:
                                const EdgeInsets.symmetric(horizontal: 14),
                            decoration: BoxDecoration(
                              color: pillBg,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: pillBorder),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _readerFont,
                                    style: TextStyle(
                                      fontFamily: _readerFont,
                                      fontSize: 15,
                                      color: paperText,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                                Icon(CupertinoIcons.chevron_down,
                                    size: 14, color: paperSubtle),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Decrease font
                      _SizeButton(
                        icon: CupertinoIcons.minus,
                        bg: pillBg,
                        border: pillBorder,
                        color: paperText,
                        onTap: () => apply(() {
                          _readerFontScale =
                              (_readerFontScale - 0.05).clamp(0.85, 1.5);
                        }),
                      ),
                      const SizedBox(width: 8),
                      // Increase font
                      _SizeButton(
                        icon: CupertinoIcons.plus,
                        bg: pillBg,
                        border: pillBorder,
                        color: paperText,
                        onTap: () => apply(() {
                          _readerFontScale =
                              (_readerFontScale + 0.05).clamp(0.85, 1.5);
                        }),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Advanced settings link
                  Center(
                    child: GestureDetector(
                      onTap: () => Navigator.pop(sheetCtx),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          'Advanced settings',
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            color: paperSubtle,
                            decoration: TextDecoration.underline,
                            decorationColor: paperSubtle,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // --------------------------------------------------------------------------
  // Font picker popup (used inside the reader settings sheet)
  // --------------------------------------------------------------------------
  void _showFontPickerMenu(
    BuildContext sheetCtx,
    List<String> fonts,
    Color paperBg,
    Color paperText,
    void Function(VoidCallback) apply,
  ) {
    showModalBottomSheet(
      context: sheetCtx,
      backgroundColor: paperBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final f in fonts)
              ListTile(
                title: Text(
                  f,
                  style: TextStyle(
                    fontFamily: f,
                    fontSize: 16,
                    color: paperText,
                    fontWeight: _readerFont == f
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
                trailing: _readerFont == f
                    ? Icon(CupertinoIcons.check_mark,
                        color: _paperAccent, size: 20)
                    : null,
                onTap: () {
                  apply(() => _readerFont = f);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // Open comments bottom sheet
  // --------------------------------------------------------------------------
  void _openCommentsSheet() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtleColor = isDark ? Colors.white54 : Colors.black45;
    final cardColor = isDark ? const Color(0xFF141414) : Colors.white;
    final item = widget.item;
    final dividerColor = isDark
        ? Colors.white10
        : Colors.black.withValues(alpha: 0.06);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return DraggableScrollableSheet(
          initialChildSize: 0.65,
          minChildSize: 0.35,
          maxChildSize: 0.9,
          builder: (_, scrollController) => Container(
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: Column(
              children: [
                // Drag handle
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 8),
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white24 : Colors.black12,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                // Header
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: Row(
                    children: [
                      Text(
                        'Reviews',
                        style: GoogleFonts.inter(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: textColor,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: () => Navigator.pop(sheetContext),
                        child: Icon(
                          CupertinoIcons.xmark_circle_fill,
                          color: subtleColor,
                          size: 24,
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(color: dividerColor, height: 1),
                // Reviews list
                Expanded(
                  child: StreamBuilder<List<CommentModel>>(
                    stream: context
                        .read<FeedProvider>()
                        .getCommentsStream(item.id),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(child: CupertinoActivityIndicator());
                      }
                      final comments = snapshot.data ?? [];
                      if (comments.isEmpty) {
                        return Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                CupertinoIcons.chat_bubble_2,
                                size: 32,
                                color: subtleColor.withValues(alpha: 0.5),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'No reviews yet',
                                style: GoogleFonts.inter(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: subtleColor,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Be the first to share your thoughts.',
                                style: GoogleFonts.inter(
                                  fontSize: 13,
                                  color: subtleColor.withValues(alpha: 0.7),
                                ),
                              ),
                            ],
                          ),
                        );
                      }
                      return ListView.builder(
                        controller: scrollController,
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                        itemCount: comments.length,
                        itemBuilder: (context, index) {
                          final c = comments[index];
                          return _CommentTile(
                            comment: c,
                            isDark: isDark,
                            isOwn: c.authorId ==
                                context.read<AuthProvider>().currentUser?.id,
                            onDelete: () {
                              context
                                  .read<FeedProvider>()
                                  .deleteComment(item.id, c.id);
                            },
                          );
                        },
                      );
                    },
                  ),
                ),
                // "Write a review" CTA
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    20,
                    12,
                    20,
                    12 + MediaQuery.of(sheetContext).padding.bottom,
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: CupertinoButton(
                      padding: EdgeInsets.zero,
                      borderRadius: BorderRadius.circular(14),
                      color: const Color(0xFF2563EB),
                      onPressed: () => _openWriteReviewDialog(sheetContext),
                      child: Text(
                        'Write a review',
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // --------------------------------------------------------------------------
  // Write review dialog (centered modal: stars + text + submit)
  // --------------------------------------------------------------------------
  Future<void> _openWriteReviewDialog(BuildContext anchor) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtleColor = isDark ? Colors.white54 : Colors.black45;
    final cardColor = isDark ? const Color(0xFF141414) : Colors.white;

    _commentController.clear();
    int rating = 0;
    bool submitting = false;

    final submitted = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (stf, setLocal) => Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(horizontal: 28),
            child: Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(dialogContext).viewInsets.bottom,
              ),
              child: Container(
                padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
                decoration: BoxDecoration(
                  color: cardColor,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                          alpha: isDark ? 0.6 : 0.25),
                      blurRadius: 30,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Did you enjoy this book?',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: textColor,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(5, (i) {
                        final filled = i < rating;
                        return GestureDetector(
                          onTap: () => setLocal(() => rating = i + 1),
                          behavior: HitTestBehavior.opaque,
                          child: Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 4),
                            child: Icon(
                              filled
                                  ? CupertinoIcons.star_fill
                                  : CupertinoIcons.star,
                              size: 32,
                              color: filled
                                  ? const Color(0xFFFBBF24)
                                  : subtleColor.withValues(alpha: 0.5),
                            ),
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 18),
                    CupertinoTextField(
                      controller: _commentController,
                      placeholder: 'Share your thoughts...',
                      placeholderStyle: GoogleFonts.inter(
                        color: subtleColor,
                        fontSize: 15,
                      ),
                      style: GoogleFonts.inter(
                        color: textColor,
                        fontSize: 15,
                      ),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.05)
                            : Colors.black.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      maxLines: 4,
                      minLines: 3,
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: CupertinoButton(
                        padding: EdgeInsets.zero,
                        borderRadius: BorderRadius.circular(12),
                        color: const Color(0xFF2563EB),
                        disabledColor:
                            const Color(0xFF2563EB).withValues(alpha: 0.4),
                        onPressed: (rating == 0 || submitting)
                            ? null
                            : () async {
                                final text = _commentController.text.trim();
                                final auth = context.read<AuthProvider>();
                                final feed = context.read<FeedProvider>();
                                final user = auth.currentUser;
                                if (user == null) return;

                                setLocal(() => submitting = true);
                                try {
                                  final comment = CommentModel(
                                    id: const Uuid().v4(),
                                    feedItemId: widget.item.id,
                                    authorId: user.id,
                                    authorName: user.name,
                                    authorPhotoUrl: user.photoUrl,
                                    text: text,
                                    createdAt: DateTime.now(),
                                    rating: rating,
                                  );
                                  await feed.addComment(comment);
                                  _commentController.clear();
                                  if (dialogContext.mounted) {
                                    Navigator.pop(dialogContext, true);
                                  }
                                } catch (_) {
                                  setLocal(() => submitting = false);
                                }
                              },
                        child: submitting
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : Text(
                                'Submit',
                                style: GoogleFonts.inter(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                  letterSpacing: -0.2,
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );

    if (submitted == true && mounted) {
      _showThankYouSheet();
    }
  }

  // --------------------------------------------------------------------------
  // Thank-you confirmation bottom sheet
  // --------------------------------------------------------------------------
  void _showThankYouSheet() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final cardColor = isDark ? const Color(0xFF141414) : Colors.white;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Container(
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.fromLTRB(
          24,
          16,
          24,
          16 + MediaQuery.of(sheetContext).padding.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: isDark ? Colors.white24 : Colors.black12,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Text(
              'Thank you for your review!',
              textAlign: TextAlign.center,
              style: GoogleFonts.playfairDisplay(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: textColor,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 24),
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    const Color(0xFF2563EB).withValues(alpha: 0.15),
                    const Color(0xFFFBBF24).withValues(alpha: 0.15),
                  ],
                ),
              ),
              child: const Icon(
                CupertinoIcons.star_fill,
                size: 56,
                color: Color(0xFFFBBF24),
              ),
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: CupertinoButton(
                padding: EdgeInsets.zero,
                borderRadius: BorderRadius.circular(14),
                color: const Color(0xFF2563EB),
                onPressed: () => Navigator.pop(sheetContext),
                child: Text(
                  'Done',
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // Build quill editor styles
  // --------------------------------------------------------------------------
  quill.DefaultStyles _quillStyles(
    Color textColor,
    bool isDark, {
    bool paperMode = false,
    double scale = 1.0,
  }) {
    final paragraphStyle = paperMode
        ? _readerTextStyle(
            fontSize: 17 * scale,
            color: textColor,
            height: 1.7,
            letterSpacing: 0.1,
          )
        : GoogleFonts.inter(
            fontSize: 17,
            color: textColor,
            height: 1.8,
            letterSpacing: 0.1,
          );
    return quill.DefaultStyles(
      paragraph: quill.DefaultTextBlockStyle(
        paragraphStyle,
        quill.HorizontalSpacing.zero,
        const quill.VerticalSpacing(10, 0),
        quill.VerticalSpacing.zero,
        null,
      ),
      h1: quill.DefaultTextBlockStyle(
        GoogleFonts.playfairDisplay(
          fontSize: 28 * (paperMode ? scale : 1.0),
          fontWeight: FontWeight.w700,
          color: textColor,
          height: 1.3,
        ),
        quill.HorizontalSpacing.zero,
        const quill.VerticalSpacing(20, 8),
        quill.VerticalSpacing.zero,
        null,
      ),
      h2: quill.DefaultTextBlockStyle(
        GoogleFonts.playfairDisplay(
          fontSize: 24,
          fontWeight: FontWeight.w600,
          color: textColor,
          height: 1.35,
        ),
        quill.HorizontalSpacing.zero,
        const quill.VerticalSpacing(16, 6),
        quill.VerticalSpacing.zero,
        null,
      ),
      h3: quill.DefaultTextBlockStyle(
        GoogleFonts.inter(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: textColor,
          height: 1.4,
        ),
        quill.HorizontalSpacing.zero,
        const quill.VerticalSpacing(14, 4),
        quill.VerticalSpacing.zero,
        null,
      ),
      quote: quill.DefaultTextBlockStyle(
        GoogleFonts.inter(
          fontSize: 17,
          fontStyle: FontStyle.italic,
          color: textColor.withValues(alpha: 0.7),
          height: 1.7,
        ),
        quill.HorizontalSpacing.zero,
        const quill.VerticalSpacing(12, 12),
        quill.VerticalSpacing.zero,
        BoxDecoration(
          border: Border(
            left: BorderSide(
              color: isDark ? Colors.white24 : Colors.black26,
              width: 3,
            ),
          ),
        ),
      ),
      code: quill.DefaultTextBlockStyle(
        GoogleFonts.jetBrainsMono(
          fontSize: 14,
          color: textColor.withValues(alpha: 0.85),
          height: 1.5,
        ),
        quill.HorizontalSpacing.zero,
        const quill.VerticalSpacing(8, 8),
        quill.VerticalSpacing.zero,
        BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.05)
              : Colors.black.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      bold: const TextStyle(fontWeight: FontWeight.w700),
      italic: const TextStyle(fontStyle: FontStyle.italic),
      link: TextStyle(
        color:
            isDark ? const Color(0xFF93C5FD) : const Color(0xFF2563EB),
        decoration: TextDecoration.underline,
        decorationColor: isDark
            ? const Color(0xFF93C5FD).withValues(alpha: 0.4)
            : const Color(0xFF2563EB).withValues(alpha: 0.4),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // Get snippet text from a section (for card previews)
  // --------------------------------------------------------------------------
  String _sectionSnippet(FeedItemSection section) {
    final hasCanvas = section.canvasData.isNotEmpty;
    final hasText = section.content.isNotEmpty;

    if (!hasText && hasCanvas) return 'Tap to view artwork & layout';
    if (!hasText && !hasCanvas) return 'Tap to explore this section';

    try {
      final decoded = jsonDecode(section.content);
      if (decoded is List) {
        final buf = StringBuffer();
        for (final op in decoded) {
          if (op is Map && op['insert'] is String) {
            buf.write(op['insert']);
            if (buf.length > 120) break;
          }
        }
        return buf.toString().trim();
      }
    } catch (_) {}
    return '';
  }

  // --------------------------------------------------------------------------
  // Dispose
  // --------------------------------------------------------------------------
  @override
  void dispose() {
    _debounce?.cancel();
    if (_userId != null && _selectedSectionIndex != null) {
      _dataService.updateReadingProgress(
        _userId!,
        widget.item.id,
        (_selectedSectionIndex ?? 0).toDouble(),
      );
    }
    _pageController?.dispose();
    _likeAnimController.dispose();
    for (final c in _quillControllers.values) {
      c.dispose();
    }
    _commentController.dispose();
    _commentFocus.dispose();
    super.dispose();
  }

  // ==========================================================================
  // BUILD
  // ==========================================================================
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inReader = _selectedSectionIndex != null;
    final palette = _readerPalette();
    final bgColor = inReader
        ? palette.bg
        : (isDark ? const Color(0xFF000000) : const Color(0xFFFAFAFA));
    final textColor = inReader
        ? palette.text
        : (isDark ? Colors.white : const Color(0xFF0F172A));
    final subtleColor = inReader
        ? palette.subtle
        : (isDark ? Colors.white54 : Colors.black45);
    final item = widget.item;

    // Heart animation curves
    final heartScale = TweenSequence<double>([
      TweenSequenceItem(
          tween: Tween(begin: 0.0, end: 1.0)
              .chain(CurveTween(curve: Curves.easeOut)),
          weight: 33),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 34),
      TweenSequenceItem(
          tween: Tween(begin: 1.0, end: 0.0)
              .chain(CurveTween(curve: Curves.easeIn)),
          weight: 33),
    ]).animate(_likeAnimController);

    final heartOpacity = TweenSequence<double>([
      TweenSequenceItem(
          tween: Tween(begin: 0.0, end: 1.0), weight: 33),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 34),
      TweenSequenceItem(
          tween: Tween(begin: 1.0, end: 0.0), weight: 33),
    ]).animate(_likeAnimController);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // Browser/system back: only go from section detail → overview.
        // Never pop the page — the app-bar back button handles leaving.
        if (_selectedSectionIndex != null) {
          _pageController?.dispose();
          _pageController = null;
          setState(() => _selectedSectionIndex = null);
        }
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
      value: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: bgColor,
        appBar: AppBar(
          backgroundColor: bgColor,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          leading: CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: () {
              if (_selectedSectionIndex != null) {
                _pageController?.dispose();
                _pageController = null;
                setState(() => _selectedSectionIndex = null);
              } else {
                Navigator.pop(context);
              }
            },
            child: Icon(CupertinoIcons.back, color: textColor, size: 22),
          ),
          title: inReader
              ? null
              : Text(
                  item.title,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: subtleColor,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
          centerTitle: true,
          actions: [
            if (inReader) ...[
              // Aa: text size adjustment
              CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                onPressed: () => _openReaderTextSizeSheet(isDark),
                child: Text(
                  'Aa',
                  style: GoogleFonts.lora(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                  ),
                ),
              ),
              if (item.sections.length > 1)
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
                  child: Icon(
                    CupertinoIcons.list_bullet,
                    color: textColor,
                    size: 22,
                  ),
                ),
              Consumer<AuthProvider>(
                builder: (context, auth, _) {
                  final sectionIndex = _selectedSectionIndex ?? 0;
                  final key = '${item.id}_$sectionIndex';
                  final bookmarked =
                      auth.currentUser?.sectionBookmarks.contains(key) ?? false;
                  return CupertinoButton(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    onPressed: () =>
                        auth.toggleSectionBookmark(item.id, sectionIndex),
                    child: Icon(
                      bookmarked
                          ? CupertinoIcons.bookmark_fill
                          : CupertinoIcons.bookmark,
                      color: bookmarked ? _paperAccent : textColor,
                      size: 22,
                    ),
                  );
                },
              ),
              Consumer<AuthProvider>(
                builder: (context, auth, _) {
                  final favorited =
                      auth.currentUser?.favoritePosts.contains(item.id) ?? false;
                  return CupertinoButton(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    onPressed: () => auth.toggleFavorite(item.id),
                    child: Icon(
                      favorited
                          ? CupertinoIcons.star_fill
                          : CupertinoIcons.star,
                      color: favorited
                          ? const Color(0xFFFBBF24)
                          : textColor,
                      size: 22,
                    ),
                  );
                },
              ),
            ] else if (item.sections.length > 1 && _selectedSectionIndex != null)
              CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
                child: Icon(
                  CupertinoIcons.list_bullet,
                  color: textColor,
                  size: 22,
                ),
              ),
            const SizedBox(width: 4),
          ],
        ),
        // Sections drawer
        endDrawer: item.sections.length > 1
            ? _buildSectionsDrawer(isDark, textColor, subtleColor, bgColor, item)
            : null,
        body: GestureDetector(
          onDoubleTap: _onDoubleTapLike,
          child: Stack(
            children: [
              // Decide: overview or section detail
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                child: _selectedSectionIndex == null
                    ? _buildOverview(isDark, textColor, subtleColor, bgColor)
                    : _buildSectionsCarousel(
                        isDark,
                        textColor,
                        subtleColor,
                        bgColor,
                      ),
              ),
              // Heart animation overlay
              AnimatedBuilder(
                animation: _likeAnimController,
                builder: (context, child) {
                  if (!_likeAnimController.isAnimating &&
                      _likeAnimController.status !=
                          AnimationStatus.completed) {
                    return const SizedBox.shrink();
                  }
                  return Center(
                    child: Opacity(
                      opacity: heartOpacity.value,
                      child: Transform.scale(
                        scale: heartScale.value,
                        child: const Icon(
                          CupertinoIcons.heart_fill,
                          color: Color(0xFFEF4444),
                          size: 100,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  // ==========================================================================
  // SECTIONS DRAWER
  // ==========================================================================
  Widget _buildSectionsDrawer(
    bool isDark,
    Color textColor,
    Color subtleColor,
    Color bgColor,
    FeedItemModel item,
  ) {
    final inReader = _selectedSectionIndex != null;
    final palette = _readerPalette();
    final drawerBg = inReader
        ? palette.bg
        : (isDark ? const Color(0xFF141414) : Colors.white);
    final drawerText = inReader ? palette.text : textColor;
    final drawerSubtle = inReader ? palette.subtle : subtleColor;
    final dividerColor = drawerText.withValues(alpha: 0.08);
    final highlightCount =
        _highlights.values.fold<int>(0, (a, l) => a + l.length);

    return Drawer(
      backgroundColor: drawerBg,
      child: DefaultTabController(
        length: 4,
        child: SafeArea(
          child: Column(
            children: [
              // Header: title centered with close
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                child: Row(
                  children: [
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      onPressed: () => Navigator.pop(context),
                      child: Icon(CupertinoIcons.back,
                          size: 22, color: drawerText),
                    ),
                    Expanded(
                      child: Center(
                        child: Text(
                          item.title,
                          style: _readerTextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: drawerText,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    const SizedBox(width: 44),
                  ],
                ),
              ),
              // Tabs
              TabBar(
                isScrollable: false,
                labelColor: _paperAccent,
                unselectedLabelColor: drawerSubtle,
                indicatorColor: _paperAccent,
                indicatorSize: TabBarIndicatorSize.label,
                indicatorWeight: 2.5,
                labelStyle: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                unselectedLabelStyle: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
                tabs: const [
                  Tab(text: 'Chapters'),
                  Tab(text: 'Notes'),
                  Tab(text: 'Bookmarks'),
                  Tab(text: 'Quotes'),
                ],
              ),
              Divider(color: dividerColor, height: 1),
              Expanded(
                child: TabBarView(
                  physics: const BouncingScrollPhysics(),
                  children: [
                    // CHAPTERS tab
                    ListView.builder(
                      padding: EdgeInsets.zero,
                      itemCount: item.sections.length,
                      itemBuilder: (context, i) {
                        final isActive = i == _selectedSectionIndex;
                        return InkWell(
                          onTap: () {
                            if (_selectedSectionIndex == null) {
                              _enterSectionDetail(i);
                            } else {
                              _navigateToSection(i);
                            }
                            Navigator.pop(context);
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 14),
                            child: Text(
                              '${i + 1}. ${item.sections[i].title}',
                              style: _readerTextStyle(
                                fontSize: 15,
                                fontWeight: isActive
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                color: isActive ? _paperAccent : drawerText,
                                height: 1.4,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        );
                      },
                    ),

                    // NOTES tab — placeholder
                    _drawerEmptyState(
                      icon: CupertinoIcons.pencil,
                      title: 'No notes yet',
                      subtitle:
                          'Long-press text in the reader to jot a note.',
                      textColor: drawerText,
                      subtleColor: drawerSubtle,
                    ),

                    // BOOKMARKS tab — favorited posts/sections
                    Consumer<AuthProvider>(
                      builder: (context, auth, _) {
                        final favorited = auth.currentUser?.favoritePosts
                                .contains(item.id) ??
                            false;
                        if (!favorited) {
                          return _drawerEmptyState(
                            icon: CupertinoIcons.bookmark,
                            title: 'No bookmarks yet',
                            subtitle:
                                'Tap the bookmark icon in the reader to save this story.',
                            textColor: drawerText,
                            subtleColor: drawerSubtle,
                          );
                        }
                        return ListView(
                          padding: EdgeInsets.zero,
                          children: [
                            ListTile(
                              leading: Icon(CupertinoIcons.bookmark_fill,
                                  color: _paperAccent, size: 20),
                              title: Text(
                                item.title,
                                style: _readerTextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: drawerText,
                                ),
                              ),
                              subtitle: Text(
                                'Saved · tap to open',
                                style: _readerTextStyle(
                                  fontSize: 12,
                                  color: drawerSubtle,
                                ),
                              ),
                              onTap: () => Navigator.pop(context),
                            ),
                          ],
                        );
                      },
                    ),

                    // QUOTES tab — list of in-session highlights
                    highlightCount == 0
                        ? _drawerEmptyState(
                            icon: CupertinoIcons.text_quote,
                            title: 'No quotes yet',
                            subtitle:
                                'Select text in the reader and tap a color to highlight it.',
                            textColor: drawerText,
                            subtleColor: drawerSubtle,
                          )
                        : ListView(
                            padding: EdgeInsets.zero,
                            children: [
                              for (final entry in _highlights.entries)
                                for (final h in entry.value)
                                  ListTile(
                                    leading: Container(
                                      width: 4,
                                      height: 28,
                                      decoration: BoxDecoration(
                                        color: _hexToColor(h.colorHex),
                                        borderRadius:
                                            BorderRadius.circular(2),
                                      ),
                                    ),
                                    title: Text(
                                      'Chapter ${entry.key + 1}',
                                      style: _readerTextStyle(
                                        fontSize: 13,
                                        color: drawerSubtle,
                                      ),
                                    ),
                                    subtitle: Text(
                                      _highlightExcerpt(entry.key, h),
                                      style: _readerTextStyle(
                                        fontSize: 14,
                                        color: drawerText,
                                        height: 1.35,
                                      ),
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    onTap: () {
                                      if (_selectedSectionIndex == null) {
                                        _enterSectionDetail(entry.key);
                                      } else {
                                        _navigateToSection(entry.key);
                                      }
                                      Navigator.pop(context);
                                    },
                                  ),
                            ],
                          ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // Empty state used inside drawer tabs
  // --------------------------------------------------------------------------
  Widget _drawerEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color textColor,
    required Color subtleColor,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: subtleColor.withValues(alpha: 0.6)),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: _readerTextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: _readerTextStyle(
                fontSize: 13,
                color: subtleColor,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // Helpers for highlight previews in the Quotes tab
  // --------------------------------------------------------------------------
  Color _hexToColor(String hex) {
    if (hex.isEmpty) return Colors.transparent;
    final clean = hex.replaceAll('#', '');
    return Color(int.parse('FF$clean', radix: 16));
  }

  String _highlightExcerpt(int sectionIndex, _Highlight h) {
    final controller = _quillControllers[sectionIndex];
    if (controller == null) return '';
    final plain = controller.document.toPlainText();
    final start = h.start.clamp(0, plain.length);
    final end = (h.start + h.length).clamp(0, plain.length);
    return plain.substring(start, end).trim();
  }

  // ==========================================================================
  // LEVEL 1: POST OVERVIEW — Apple Books style detail page
  // ==========================================================================
  Widget _buildOverview(
    bool isDark,
    Color textColor,
    Color subtleColor,
    Color bgColor,
  ) {
    final item = widget.item;
    final readingMinutes = _estimateReadingMinutes(item.sections);
    const contentPadding = 20.0;
    const maxContentWidth = 760.0;
    final cardColor = isDark ? const Color(0xFF141414) : Colors.white;
    final dividerColor =
        isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.06);
    const accentColor = Color(0xFF2563EB);
    final firstExcerpt = _firstExcerpt(item.sections);
    final startIndex =
        (_lastReadSection != null && _lastReadSection! < item.sections.length)
            ? _lastReadSection!
            : 0;

    return Stack(
      key: const ValueKey('overview'),
      children: [
        SingleChildScrollView(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).padding.bottom + 120,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ---- Book header: backdrop + floating cover + title + author ----
              _BookHeader(
                imageUrl: item.imageUrl,
                imageMeta: item.imageMeta,
                title: item.title,
                author: item.author,
                isDark: isDark,
                textColor: textColor,
                subtleColor: subtleColor,
              ),

              // ---- Constrained content column (centered on desktop) ----
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: maxContentWidth),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
              // ---- Stats row (sections · reading time · date) ----
              Padding(
                padding: EdgeInsets.fromLTRB(
                    contentPadding, 24, contentPadding, 0),
                child: _StatsRow(
                  sections: item.sections.length,
                  readingMinutes: readingMinutes,
                  createdAt: item.createdAt,
                  genre: item.genres.isNotEmpty
                      ? item.genres.first
                      : (item.writingTypes.isNotEmpty
                          ? item.writingTypes.first
                          : null),
                  isDark: isDark,
                  textColor: textColor,
                  subtleColor: subtleColor,
                ),
              ),

              // ---- Tags (horizontal scroll) ----
              if (item.genres.isNotEmpty ||
                  item.writingTypes.isNotEmpty ||
                  item.tags.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: SizedBox(
                    height: 30,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding:
                          EdgeInsets.symmetric(horizontal: contentPadding),
                      children: [
                        ...item.writingTypes
                            .map((t) => _TagPill(label: t, isDark: isDark)),
                        ...item.genres
                            .map((g) => _TagPill(label: g, isDark: isDark)),
                        ...item.tags
                            .map((t) => _TagPill(label: t, isDark: isDark)),
                      ]
                          .map((w) => Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: w))
                          .toList(),
                    ),
                  ),
                ),

              // ---- Description ----
              if (item.description.isNotEmpty)
                Padding(
                  padding: EdgeInsets.fromLTRB(
                      contentPadding, 24, contentPadding, 0),
                  child: _ExpandableDescription(
                    text: item.description,
                    textColor: textColor,
                    subtleColor: subtleColor,
                  ),
                ),

              // ---- Action row (like, comment, bookmark, share) ----
              Padding(
                padding: EdgeInsets.fromLTRB(
                    contentPadding, 24, contentPadding, 0),
                child: _ActionRow(
                  item: item,
                  isDark: isDark,
                  textColor: textColor,
                  subtleColor: subtleColor,
                  dividerColor: dividerColor,
                  onCommentTap: _openCommentsSheet,
                ),
              ),

              const SizedBox(height: 28),

              // ---- Featured excerpt card (Apple Books "Quotes" style) ----
              if (firstExcerpt.isNotEmpty)
                Padding(
                  padding: EdgeInsets.fromLTRB(
                      contentPadding, 0, contentPadding, 24),
                  child: _ExcerptCard(
                    excerpt: firstExcerpt,
                    author: item.author,
                    onTap: () => _enterSectionDetail(0),
                  ),
                ),

              // ---- Continue reading banner ----
              if (_lastReadSection != null &&
                  _lastReadSection! > 0 &&
                  _lastReadSection! < item.sections.length)
                Padding(
                  padding: EdgeInsets.fromLTRB(
                      contentPadding, 0, contentPadding, 24),
                  child: GestureDetector(
                    onTap: () => _enterSectionDetail(_lastReadSection!),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: accentColor.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: accentColor.withValues(alpha: 0.2),
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: accentColor.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(
                              CupertinoIcons.book_fill,
                              size: 20,
                              color: accentColor,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Continue reading',
                                  style: GoogleFonts.inter(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: textColor,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Section ${_lastReadSection! + 1} \u00B7 ${item.sections[_lastReadSection!].title}',
                                  style: GoogleFonts.inter(
                                    fontSize: 13,
                                    color: subtleColor,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          const Icon(
                            CupertinoIcons.chevron_right,
                            size: 16,
                            color: accentColor,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              // ---- Chapters header ----
              Padding(
                padding: EdgeInsets.fromLTRB(
                    contentPadding, 4, contentPadding, 12),
                child: Row(
                  children: [
                    Text(
                      'Chapters',
                      style: GoogleFonts.playfairDisplay(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: textColor,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${item.sections.length} ${item.sections.length == 1 ? "section" : "sections"}',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: subtleColor,
                      ),
                    ),
                  ],
                ),
              ),

              // ---- Section cards ----
              ListView.separated(
                physics: const NeverScrollableScrollPhysics(),
                shrinkWrap: true,
                padding: EdgeInsets.symmetric(horizontal: contentPadding),
                itemCount: item.sections.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final section = item.sections[index];
                  final snippet = _sectionSnippet(section);

                  return GestureDetector(
                    onTap: () => _enterSectionDetail(index),
                    child: Container(
                      decoration: BoxDecoration(
                        color: cardColor,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.06)
                              : Colors.black.withValues(alpha: 0.05),
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Row(
                        children: [
                          Container(
                            width: 48,
                            padding:
                                const EdgeInsets.symmetric(vertical: 20),
                            child: Center(
                              child: Text(
                                '${index + 1}',
                                style: GoogleFonts.playfairDisplay(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700,
                                  color: accentColor,
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(4, 14, 16, 14),
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    section.title,
                                    style: GoogleFonts.inter(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: textColor,
                                      height: 1.3,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (snippet.isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      snippet,
                                      style: GoogleFonts.inter(
                                        fontSize: 13,
                                        color: subtleColor,
                                        height: 1.4,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(right: 14),
                            child: Icon(
                              CupertinoIcons.chevron_right,
                              size: 16,
                              color: subtleColor.withValues(alpha: 0.4),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),

              // ---- More like this (semantic neighbours) ----
              Padding(
                padding: EdgeInsets.fromLTRB(
                    contentPadding, 32, contentPadding, 96),
                child: MoreLikeThisCarousel(
                  feedItemId: item.id,
                  isDark: isDark,
                  textColor: textColor,
                  subtleColor: subtleColor,
                ),
              ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),

        // ---- Sticky bottom Read CTA ----
        if (item.sections.isNotEmpty)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _ReadCtaBar(
              isDark: isDark,
              label: _lastReadSection != null && _lastReadSection! > 0
                  ? 'Continue'
                  : 'Read',
              onTap: () => _enterSectionDetail(startIndex),
            ),
          ),
      ],
    );
  }

  // --------------------------------------------------------------------------
  // Pull a short excerpt string from the first section for the featured card
  // --------------------------------------------------------------------------
  String _firstExcerpt(List<FeedItemSection> sections) {
    for (final s in sections) {
      if (s.content.isEmpty) continue;
      try {
        final decoded = jsonDecode(s.content);
        if (decoded is List) {
          final buf = StringBuffer();
          for (final op in decoded) {
            if (op is Map && op['insert'] is String) {
              buf.write(op['insert']);
              if (buf.length > 240) break;
            }
          }
          final text = buf.toString().trim();
          if (text.isNotEmpty) return text;
        }
      } catch (_) {}
    }
    return '';
  }

  // ==========================================================================
  // LEVEL 2: SECTIONS CAROUSEL — swipeable PageView of all sections
  // ==========================================================================
  Widget _buildSectionsCarousel(
    bool isDark,
    Color textColor,
    Color subtleColor,
    Color bgColor,
  ) {
    final item = widget.item;
    final totalSections = item.sections.length;
    final dividerColor =
        isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.06);
    final currentIndex = _selectedSectionIndex ?? 0;

    return Column(
      key: const ValueKey('sections_carousel'),
      children: [
        // Swipeable section content
        Expanded(
          child: PageView.builder(
            controller: _pageController,
            itemCount: totalSections,
            onPageChanged: (index) {
              setState(() => _selectedSectionIndex = index);
              _saveProgress(index);
            },
            itemBuilder: (context, index) {
              return _buildSingleSectionPage(
                index, isDark, textColor, subtleColor,
              );
            },
          ),
        ),

        // Bottom bar: chapter pill + page count + Listen button (book reader style)
        _buildReaderBottomBar(
          isDark: isDark,
          textColor: textColor,
          subtleColor: subtleColor,
          bgColor: bgColor,
          dividerColor: dividerColor,
          currentIndex: currentIndex,
          totalSections: totalSections,
        ),
      ],
    );
  }

  // --------------------------------------------------------------------------
  // Reader bottom bar (chapter / page count / Listen)
  // --------------------------------------------------------------------------
  Widget _buildReaderBottomBar({
    required bool isDark,
    required Color textColor,
    required Color subtleColor,
    required Color bgColor,
    required Color dividerColor,
    required int currentIndex,
    required int totalSections,
  }) {
    final pillBg = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);
    final remaining = totalSections - currentIndex - 1;
    final remainingLabel = remaining <= 0
        ? 'Last page'
        : '$remaining more page${remaining == 1 ? '' : 's'}';

    return Container(
      padding: EdgeInsets.only(
        top: 12,
        bottom: MediaQuery.of(context).padding.bottom + 12,
        left: 20,
        right: 20,
      ),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(top: BorderSide(color: dividerColor)),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              // Chapter pill
              GestureDetector(
                onTap: totalSections > 1
                    ? () => _scaffoldKey.currentState?.openEndDrawer()
                    : null,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: pillBg,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    'Chapter ${currentIndex + 1}',
                    style: GoogleFonts.lora(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                ),
              ),
              const Spacer(),
              // Page counter
              Text(
                '${currentIndex + 1} of $totalSections',
                style: GoogleFonts.lora(
                  fontSize: 13,
                  color: subtleColor,
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 1,
                height: 14,
                color: subtleColor.withValues(alpha: 0.4),
              ),
              const SizedBox(width: 12),
              Text(
                remainingLabel,
                style: GoogleFonts.lora(
                  fontSize: 13,
                  color: subtleColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Listen button (full width, accent blue)
          SizedBox(
            width: double.infinity,
            height: 48,
            child: CupertinoButton(
              padding: EdgeInsets.zero,
              color: _paperAccent,
              borderRadius: BorderRadius.circular(28),
              onPressed: _onListenPressed,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    CupertinoIcons.play_circle_fill,
                    color: Colors.white,
                    size: 22,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Listen',
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // Single section page content (used inside the PageView)
  // --------------------------------------------------------------------------
  Widget _buildSingleSectionPage(
    int sectionIndex,
    bool isDark,
    Color textColor,
    Color subtleColor,
  ) {
    final section = widget.item.sections[sectionIndex];
    const contentPadding = 24.0;
    const maxContentWidth = 720.0;
    final styles = _quillStyles(
      textColor,
      isDark,
      paperMode: true,
      scale: _readerFontScale,
    );

    final body = SingleChildScrollView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      padding: const EdgeInsets.only(bottom: 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: maxContentWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          // Section title — italic serif (book chapter style)
          Padding(
            padding:
                EdgeInsets.fromLTRB(contentPadding, 12, contentPadding, 20),
            child: Text(
              section.title,
              style: _readerTextStyle(
                fontSize: 22 * _readerFontScale,
                fontStyle: FontStyle.italic,
                fontWeight: FontWeight.w600,
                color: textColor,
                height: 1.3,
                letterSpacing: 0.1,
              ),
            ),
          ),

          // Canvas preview (constrained width for desktop)
          if (section.canvasData.isNotEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(
                  contentPadding, 0, contentPadding, 20),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: _CanvasPreview(
                    canvasData: section.canvasData,
                    isDark: isDark,
                  ),
                ),
              ),
            ),

          // Quill content (serif body, highlight-on-select)
          if (_quillControllers.containsKey(sectionIndex))
            Padding(
              padding: EdgeInsets.fromLTRB(
                  contentPadding, 0, contentPadding, 8),
              child: quill.QuillEditor(
                controller: _quillControllers[sectionIndex]!,
                focusNode: FocusNode(canRequestFocus: false),
                scrollController: ScrollController(),
                config: quill.QuillEditorConfig(
                  showCursor: false,
                  autoFocus: false,
                  expands: false,
                  customStyleBuilder: _customStyleBuilder,
                  embedBuilders: [
                    ImageEmbedBuilder(
                      controller: _quillControllers[sectionIndex]!,
                    ),
                  ],
                  padding: EdgeInsets.zero,
                  customStyles: styles,
                  contextMenuBuilder: (ctx, rawState) =>
                      _buildHighlightToolbar(
                    ctx,
                    rawState,
                    sectionIndex,
                  ),
                ),
              ),
            ),
            ],
          ),
        ),
      ),
    );

    if (_readerBrightness >= 0.99) return body;
    final dim = (1.0 - _readerBrightness).clamp(0.0, 0.6);
    return Stack(
      children: [
        body,
        Positioned.fill(
          child: IgnorePointer(
            child: Container(color: Colors.black.withValues(alpha: dim)),
          ),
        ),
      ],
    );
  }

  // --------------------------------------------------------------------------
  // Highlight toolbar shown when text is selected in the reader
  // --------------------------------------------------------------------------
  Widget _buildHighlightToolbar(
    BuildContext context,
    dynamic state, // EditableTextState in Quill 11
    int sectionIndex,
  ) {
    final palette = _readerPalette();
    final controller = _quillControllers[sectionIndex];
    if (controller == null) return const SizedBox.shrink();

    const swatches = <(Color, String)>[
      (Color(0xFFFFE066), '#FFE066'), // yellow
      (Color(0xFFFFB4A2), '#FFB4A2'), // peach
      (Color(0xFFB5EAD7), '#B5EAD7'), // mint
      (Color(0xFFB8C5FF), '#B8C5FF'), // periwinkle
      (Color(0xFFE0B0FF), '#E0B0FF'), // lilac
      (Color(0xFFFFC8DD), '#FFC8DD'), // pink
    ];

    void applyHighlight(String? hex) {
      final sel = controller.selection;
      if (sel.isCollapsed) return;
      final start = sel.start;
      final length = sel.end - sel.start;
      controller.formatText(
        start,
        length,
        hex == null
            ? quill.BackgroundAttribute(null)
            : quill.BackgroundAttribute(hex),
      );
      if (hex == null) {
        _removeHighlightsInRange(sectionIndex, start, length);
      } else {
        final id = const Uuid().v4();
        _highlights.putIfAbsent(sectionIndex, () => []).add(
              _Highlight(
                id: id,
                start: start,
                length: length,
                colorHex: hex,
              ),
            );
        if (_userId != null) {
          _dataService.addHighlight(
            userId: _userId!,
            feedItemId: widget.item.id,
            highlightId: id,
            sectionIndex: sectionIndex,
            start: start,
            length: length,
            colorHex: hex,
          );
        }
      }
      if (mounted) setState(() {});
      // Dismiss the selection menu
      try {
        state.hideToolbar();
      } catch (_) {}
    }

    Offset anchor;
    try {
      anchor = state.contextMenuAnchors.primaryAnchor as Offset;
    } catch (_) {
      anchor = const Offset(120, 200);
    }

    final mq = MediaQuery.of(context);
    const barWidth = 260.0;
    final left = (anchor.dx - barWidth / 2).clamp(12.0, mq.size.width - barWidth - 12);
    final top = (anchor.dy - 56).clamp(mq.padding.top + 8, mq.size.height - 80);

    return Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(28),
            color: palette.bg,
            shadowColor: Colors.black.withValues(alpha: 0.3),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                  color: palette.text.withValues(alpha: 0.1),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final s in swatches) ...[
                    GestureDetector(
                      onTap: () => applyHighlight(s.$2),
                      child: Container(
                        width: 26,
                        height: 26,
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        decoration: BoxDecoration(
                          color: s.$1,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: palette.text.withValues(alpha: 0.15),
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 4),
                  GestureDetector(
                    onTap: () => applyHighlight(null),
                    child: Container(
                      width: 26,
                      height: 26,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: palette.text.withValues(alpha: 0.4),
                        ),
                      ),
                      child: Icon(
                        CupertinoIcons.clear,
                        size: 14,
                        color: palette.text.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // Bookmark this paragraph. Lives on the highlight bar
                  // because the user is already in "I want to mark this
                  // bit" mode — adding a separate long-press path would
                  // double the discovery surface for no extra value.
                  GestureDetector(
                    onTap: () {
                      try {
                        state.hideToolbar();
                      } catch (_) {}
                      _openBookmarkSheet(sectionIndex, controller);
                    },
                    child: Container(
                      width: 26,
                      height: 26,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: palette.text.withValues(alpha: 0.06),
                        border: Border.all(
                          color: palette.text.withValues(alpha: 0.4),
                        ),
                      ),
                      child: Icon(
                        CupertinoIcons.bookmark,
                        size: 14,
                        color: palette.text.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Bottom sheet for naming + colouring a bookmark at the current
  /// selection. Anchor is derived from the selection start: paragraph =
  /// number of newline characters before the cursor; char_offset = chars
  /// since the most recent newline. That maps cleanly to the server's
  /// `(paragraph_idx, char_offset)` schema and survives reflow.
  Future<void> _openBookmarkSheet(
    int sectionIndex,
    quill.QuillController controller,
  ) async {
    final sel = controller.selection;
    final fullText = controller.document.toPlainText();
    final cursor = sel.isValid ? sel.start.clamp(0, fullText.length) : 0;
    final before = fullText.substring(0, cursor);
    final paragraphIdx = '\n'.allMatches(before).length;
    final lastBreak = before.lastIndexOf('\n');
    final charOffset = lastBreak == -1 ? cursor : cursor - lastBreak - 1;

    final defaultLabel = _selectionPreview(controller, max: 60);
    final labelCtl = TextEditingController(text: defaultLabel);
    final palette = _readerPalette();
    String pickedColor = '#FFB300';
    const swatches = <String>[
      '#FFB300', '#7E57C2', '#26A69A', '#EC407A', '#42A5F5', '#66BB6A',
    ];

    final saved = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: palette.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final mq = MediaQuery.of(ctx);
            return Padding(
              padding: EdgeInsets.fromLTRB(
                  20, 16, 20, 16 + mq.viewInsets.bottom),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: palette.text.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Bookmark this paragraph',
                    style: GoogleFonts.inter(
                      color: palette.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: labelCtl,
                    style: GoogleFonts.inter(
                        color: palette.text, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Optional label',
                      hintStyle: GoogleFonts.inter(color: palette.subtle),
                      filled: true,
                      fillColor: palette.text.withValues(alpha: 0.05),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      for (final hex in swatches) ...[
                        GestureDetector(
                          onTap: () => setSheet(() => pickedColor = hex),
                          child: Container(
                            width: 30,
                            height: 30,
                            margin: const EdgeInsets.only(right: 8),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _hexToColor(hex),
                              border: Border.all(
                                width: pickedColor == hex ? 3 : 1,
                                color: pickedColor == hex
                                    ? palette.text
                                    : palette.text.withValues(alpha: 0.2),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: palette.text,
                        foregroundColor: palette.bg,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: Text(
                        'Save bookmark',
                        style: GoogleFonts.inter(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    if (saved != true || !mounted) {
      labelCtl.dispose();
      return;
    }

    final raw = labelCtl.text.trim();
    final label = raw.isEmpty ? null : raw;
    labelCtl.dispose();

    final feedItemId = widget.item.id;
    try {
      await context.read<BookmarkProvider>().addBookmark(
            feedItemId: feedItemId,
            sectionIndex: sectionIndex,
            paragraphIdx: paragraphIdx,
            charOffset: charOffset,
            label: label,
            color: pickedColor,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Bookmark saved',
            style: GoogleFonts.inter(fontSize: 13),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not save bookmark — will retry when online',
            style: GoogleFonts.inter(fontSize: 13),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  String _selectionPreview(quill.QuillController controller, {int max = 60}) {
    final sel = controller.selection;
    if (!sel.isValid || sel.isCollapsed) return '';
    final text = controller.document.toPlainText();
    final start = sel.start.clamp(0, text.length);
    final end = sel.end.clamp(0, text.length);
    final raw = text.substring(start, end).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (raw.length <= max) return raw;
    return '${raw.substring(0, max)}…';
  }

  // --------------------------------------------------------------------------
  // Listen button stub (audio narration)
  // --------------------------------------------------------------------------
  void _onListenPressed() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Audio narration coming soon',
          style: GoogleFonts.lora(fontSize: 14),
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

// ============================================================================
// BOOK HEADER — soft gradient backdrop with floating cover, title, author
// ============================================================================
class _BookHeader extends StatelessWidget {
  final String imageUrl;
  final ImageMeta? imageMeta;
  final String title;
  final String author;
  final bool isDark;
  final Color textColor;
  final Color subtleColor;

  const _BookHeader({
    required this.imageUrl,
    this.imageMeta,
    required this.title,
    required this.author,
    required this.isDark,
    required this.textColor,
    required this.subtleColor,
  });

  @override
  Widget build(BuildContext context) {
    final hasCover = imageUrl.isNotEmpty || imageMeta != null;
    final screenWidth = MediaQuery.of(context).size.width;
    final coverWidth = screenWidth > 720 ? 200.0 : 160.0;
    final coverHeight = coverWidth * 1.45;

    return Stack(
      children: [
        // Blurred backdrop derived from the cover
        Positioned.fill(
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (hasCover)
                  AppNetworkImage(
                    url: imageUrl,
                    meta: imageMeta,
                    width: MediaQuery.sizeOf(context).width,
                    fit: BoxFit.cover,
                    errorWidget: const SizedBox.shrink(),
                  )
                else
                  Container(
                    color: isDark
                        ? const Color(0xFF1A1A1A)
                        : const Color(0xFFE8EAF0),
                  ),
                BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 60, sigmaY: 60),
                  child: Container(
                    color: (isDark ? Colors.black : Colors.white)
                        .withValues(alpha: 0.55),
                  ),
                ),
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        (isDark ? Colors.black : Colors.white)
                            .withValues(alpha: 0.0),
                        (isDark
                                ? const Color(0xFF000000)
                                : const Color(0xFFFAFAFA))
                            .withValues(alpha: 0.9),
                      ],
                      stops: const [0.6, 1.0],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // Foreground content
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 12),
              Center(
                child: Container(
                  width: coverWidth,
                  height: coverHeight,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(
                            alpha: isDark ? 0.6 : 0.25),
                        blurRadius: 30,
                        offset: const Offset(0, 16),
                        spreadRadius: -4,
                      ),
                      BoxShadow(
                        color: Colors.black.withValues(
                            alpha: isDark ? 0.4 : 0.12),
                        blurRadius: 8,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: hasCover
                        ? LayoutBuilder(
                            builder: (ctx, c) => AppNetworkImage(
                              url: imageUrl,
                              meta: imageMeta,
                              width: c.maxWidth,
                              height: c.maxHeight,
                              fit: BoxFit.cover,
                              errorWidget: Container(
                                color: isDark
                                    ? const Color(0xFF1E1E1E)
                                    : const Color(0xFFEDEDED),
                                child: Icon(CupertinoIcons.photo,
                                    size: 36,
                                    color: isDark
                                        ? Colors.white24
                                        : Colors.black26),
                              ),
                            ),
                          )
                        : Container(
                            color: isDark
                                ? const Color(0xFF1E1E1E)
                                : const Color(0xFFEDEDED),
                            child: Center(
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Text(
                                  title,
                                  textAlign: TextAlign.center,
                                  style: GoogleFonts.playfairDisplay(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                    color: textColor,
                                  ),
                                ),
                              ),
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 22),
              Text(
                title,
                textAlign: TextAlign.center,
                style: GoogleFonts.playfairDisplay(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                  height: 1.2,
                  letterSpacing: -0.4,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Text(
                author,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF2563EB),
                  letterSpacing: -0.2,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// STATS ROW — divided metric tiles (sections, reading time, genre/date)
// ============================================================================
class _StatsRow extends StatelessWidget {
  final int sections;
  final int readingMinutes;
  final DateTime createdAt;
  final String? genre;
  final bool isDark;
  final Color textColor;
  final Color subtleColor;

  const _StatsRow({
    required this.sections,
    required this.readingMinutes,
    required this.createdAt,
    required this.genre,
    required this.isDark,
    required this.textColor,
    required this.subtleColor,
  });

  @override
  Widget build(BuildContext context) {
    final dividerColor =
        isDark ? Colors.white12 : Colors.black.withValues(alpha: 0.08);

    final tiles = <Widget>[
      _tile(
        label: sections == 1 ? 'Section' : 'Sections',
        primary: '$sections',
      ),
      _tile(
        label: 'Length',
        primary: '$readingMinutes min',
      ),
      _tile(
        label: 'Published',
        primary: _shortDate(createdAt),
      ),
      if (genre != null)
        _tile(
          label: 'Genre',
          primary: genre!,
          compact: true,
        ),
    ];

    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.04)
            : Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          for (int i = 0; i < tiles.length; i++) ...[
            Expanded(child: tiles[i]),
            if (i < tiles.length - 1)
              Container(width: 1, height: 28, color: dividerColor),
          ],
        ],
      ),
    );
  }

  Widget _tile({
    required String label,
    required String primary,
    bool compact = false,
  }) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          primary,
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
            fontSize: compact ? 13 : 15,
            fontWeight: FontWeight.w700,
            color: textColor,
            letterSpacing: -0.2,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          label.toUpperCase(),
          style: GoogleFonts.inter(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: subtleColor,
            letterSpacing: 0.8,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  String _shortDate(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final now = DateTime.now();
    if (dt.year == now.year) return '${months[dt.month - 1]} ${dt.day}';
    return '${months[dt.month - 1]} ${dt.year}';
  }
}

// ============================================================================
// EXPANDABLE DESCRIPTION
// ============================================================================
class _ExpandableDescription extends StatefulWidget {
  final String text;
  final Color textColor;
  final Color subtleColor;

  const _ExpandableDescription({
    required this.text,
    required this.textColor,
    required this.subtleColor,
  });

  @override
  State<_ExpandableDescription> createState() => _ExpandableDescriptionState();
}

class _ExpandableDescriptionState extends State<_ExpandableDescription> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final style = GoogleFonts.inter(
      fontSize: 15,
      color: widget.textColor.withValues(alpha: 0.85),
      height: 1.55,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final tp = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: 3,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = tp.didExceedMaxLines;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.text,
              style: style,
              maxLines: _expanded ? null : 3,
              overflow: _expanded
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
            ),
            if (overflows)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: GestureDetector(
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Text(
                    _expanded ? 'Less' : 'More',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF2563EB),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

// ============================================================================
// EXCERPT CARD — featured "Quotes" style preview
// ============================================================================
class _ExcerptCard extends StatelessWidget {
  final String excerpt;
  final String author;
  final VoidCallback onTap;

  const _ExcerptCard({
    required this.excerpt,
    required this.author,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final trimmed = excerpt.length > 180
        ? '${excerpt.substring(0, 180).trim()}\u2026'
        : excerpt;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 22),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF1E3A8A),
              Color(0xFF2563EB),
            ],
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF2563EB).withValues(alpha: 0.25),
              blurRadius: 24,
              offset: const Offset(0, 10),
              spreadRadius: -6,
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(100),
                  ),
                  child: Text(
                    'EXCERPT',
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      letterSpacing: 1.4,
                    ),
                  ),
                ),
                const Spacer(),
                Icon(
                  CupertinoIcons.quote_bubble_fill,
                  color: Colors.white.withValues(alpha: 0.5),
                  size: 22,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              trimmed,
              style: GoogleFonts.playfairDisplay(
                fontSize: 18,
                fontStyle: FontStyle.italic,
                fontWeight: FontWeight.w500,
                color: Colors.white,
                height: 1.45,
              ),
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Text(
                  '\u2014 $author',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Colors.white.withValues(alpha: 0.8),
                  ),
                ),
                const Spacer(),
                Text(
                  'Start reading',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(
                  CupertinoIcons.arrow_right,
                  color: Colors.white,
                  size: 14,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// STICKY READ CTA BAR (bottom of overview)
// ============================================================================
class _ReadCtaBar extends StatelessWidget {
  final bool isDark;
  final String label;
  final VoidCallback onTap;

  const _ReadCtaBar({
    required this.isDark,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          padding: EdgeInsets.fromLTRB(20, 14, 20, 14 + bottomPad),
          decoration: BoxDecoration(
            color: (isDark ? Colors.black : Colors.white)
                .withValues(alpha: 0.75),
            border: Border(
              top: BorderSide(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.black.withValues(alpha: 0.06),
              ),
            ),
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: SizedBox(
                height: 52,
                width: double.infinity,
                child: CupertinoButton(
                  padding: EdgeInsets.zero,
                  borderRadius: BorderRadius.circular(14),
                  color: const Color(0xFF2563EB),
                  onPressed: onTap,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        CupertinoIcons.book_fill,
                        color: Colors.white,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        label,
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// TAG PILL
// ============================================================================
class _TagPill extends StatelessWidget {
  final String label;
  final bool isDark;

  const _TagPill({required this.label, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.07)
            : Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(100),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.black.withValues(alpha: 0.06),
          width: 0.5,
        ),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: isDark
              ? Colors.white.withValues(alpha: 0.6)
              : Colors.black.withValues(alpha: 0.5),
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

// ============================================================================
// ACTION ROW (Like / Comment / Bookmark / Share)
// ============================================================================
class _ActionRow extends StatelessWidget {
  final FeedItemModel item;
  final bool isDark;
  final Color textColor;
  final Color subtleColor;
  final Color dividerColor;
  final VoidCallback onCommentTap;

  const _ActionRow({
    required this.item,
    required this.isDark,
    required this.textColor,
    required this.subtleColor,
    required this.dividerColor,
    required this.onCommentTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Divider(color: dividerColor, height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Consumer2<AuthProvider, FeedProvider>(
            builder: (context, auth, feed, _) {
              final liked =
                  auth.currentUser?.likes.contains(item.id) ?? false;
              return Row(
                children: [
                  // Like
                  GestureDetector(
                    onTap: () =>
                        auth.toggleLike(item.id, feedProvider: feed),
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Row(
                        children: [
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 200),
                            child: Icon(
                              liked
                                  ? CupertinoIcons.heart_fill
                                  : CupertinoIcons.heart,
                              key: ValueKey(liked),
                              color: liked
                                  ? const Color(0xFFEF4444)
                                  : subtleColor,
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${(feed.items.where((i) => i.id == item.id).firstOrNull?.likesCount ?? item.likesCount).clamp(0, 999999)}',
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: textColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(width: 24),

                  // Comment
                  GestureDetector(
                    onTap: onCommentTap,
                    behavior: HitTestBehavior.opaque,
                    child: Row(
                      children: [
                        Icon(
                          CupertinoIcons.chat_bubble,
                          color: subtleColor,
                          size: 20,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${item.commentsCount}',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: textColor,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const Spacer(),

                  // Bookmark (save)
                  Builder(
                    builder: (context) {
                      final saved = auth.currentUser?.savedPosts.contains(item.id) ?? false;
                      return GestureDetector(
                        onTap: () => auth.toggleSave(item.id),
                        child: Icon(
                          saved
                              ? CupertinoIcons.bookmark_fill
                              : CupertinoIcons.bookmark,
                          color: saved
                              ? const Color(0xFF2563EB)
                              : subtleColor,
                          size: 20,
                        ),
                      );
                    },
                  ),

                  const SizedBox(width: 20),

                  // Share
                  GestureDetector(
                    onTap: () {
                      final shareUrl = '${Uri.base.origin}/post/${item.id}';
                      Clipboard.setData(
                        ClipboardData(text: shareUrl),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            'Link copied',
                            style: GoogleFonts.inter(fontSize: 14),
                          ),
                          behavior: SnackBarBehavior.floating,
                          duration: const Duration(seconds: 2),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      );
                    },
                    child: Icon(
                      CupertinoIcons.share,
                      color: subtleColor,
                      size: 20,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        Divider(color: dividerColor, height: 1),
      ],
    );
  }
}

// ============================================================================
// COMMENT TILE
// ============================================================================
class _CommentTile extends StatelessWidget {
  final CommentModel comment;
  final bool isDark;
  final bool isOwn;
  final VoidCallback onDelete;

  const _CommentTile({
    required this.comment,
    required this.isDark,
    required this.isOwn,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtleColor = isDark ? Colors.white38 : Colors.black38;

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipOval(
            child: SizedBox(
              width: 34,
              height: 34,
              child: (comment.authorPhotoUrl != null &&
                      comment.authorPhotoUrl!.isNotEmpty)
                  ? AppNetworkImage(
                      url: comment.authorPhotoUrl,
                      meta: comment.authorPhotoMeta,
                      width: 34,
                      height: 34,
                      fit: BoxFit.cover,
                    )
                  : Container(
                      color: const Color(0xFF2563EB),
                      alignment: Alignment.center,
                      child: Text(
                        comment.authorName.isNotEmpty
                            ? comment.authorName[0].toUpperCase()
                            : 'U',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      comment.authorName.isNotEmpty
                          ? comment.authorName
                          : 'User',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _timeAgo(comment.createdAt),
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: subtleColor,
                      ),
                    ),
                    const Spacer(),
                    if (isOwn)
                      GestureDetector(
                        onTap: onDelete,
                        child: Icon(
                          CupertinoIcons.trash,
                          size: 14,
                          color: subtleColor,
                        ),
                      ),
                  ],
                ),
                if (comment.rating > 0) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: List.generate(5, (i) {
                      final filled = i < comment.rating;
                      return Padding(
                        padding: const EdgeInsets.only(right: 2),
                        child: Icon(
                          filled
                              ? CupertinoIcons.star_fill
                              : CupertinoIcons.star,
                          size: 13,
                          color: filled
                              ? const Color(0xFFFBBF24)
                              : subtleColor.withValues(alpha: 0.5),
                        ),
                      );
                    }),
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  comment.text,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    color: textColor.withValues(alpha: 0.85),
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}

// ============================================================================
// CANVAS PREVIEW
// ============================================================================
class _CanvasPreview extends StatelessWidget {
  final String canvasData;
  final bool isDark;

  const _CanvasPreview({required this.canvasData, required this.isDark});

  static const double _kRefWidth = 820.0;

  @override
  Widget build(BuildContext context) {
    Map<String, dynamic>? data;
    try {
      final decoded = jsonDecode(canvasData);
      if (decoded is Map<String, dynamic>) {
        data = decoded;
      } else if (decoded is List) {
        data = {
          'version': 1,
          'bgColor': 0,
          'bgImageUrl': '',
          'elements': decoded
        };
      }
    } catch (_) {
      return const SizedBox.shrink();
    }
    if (data == null) return const SizedBox.shrink();

    final version = data['version'] ?? 1;
    final bgColor = data['bgColor'] ?? 0;
    final bgImageUrl = (data['bgImageUrl'] ?? '') as String;
    final bgGradientStart = data['bgGradientStart'] as int?;
    final bgGradientEnd = data['bgGradientEnd'] as int?;
    final bgGradientDirection =
        (data['bgGradientDirection'] ?? 'top') as String;
    final hasBgGradient = bgGradientStart != null && bgGradientEnd != null;
    final elementsJson = data['elements'] as List? ?? [];
    if (elementsJson.isEmpty) return const SizedBox.shrink();

    final elements = elementsJson
        .map((e) => CanvasElement.fromJson(e as Map<String, dynamic>))
        .toList();

    if (version < 2) {
      for (final e in elements) {
        e.x = e.x / _kRefWidth;
        e.y = e.y / _kRefWidth;
        e.width = e.width / _kRefWidth;
        e.height = e.height / _kRefWidth;
      }
    }

    elements.sort((a, b) => a.zIndex.compareTo(b.zIndex));

    return LayoutBuilder(
      builder: (context, constraints) {
        final canvasWidth = constraints.maxWidth;
        final canvasHeight = canvasWidth * 4 / 3;

        final paperColor = bgColor != 0
            ? Color(bgColor)
            : (isDark ? const Color(0xFF131315) : Colors.white);

        final bgGradientAlign = _gradientAlignment(bgGradientDirection);

        final borderClr = isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.black.withValues(alpha: 0.06);

        return Container(
          width: canvasWidth,
          height: canvasHeight,
          decoration: BoxDecoration(
            color: hasBgGradient ? null : paperColor,
            gradient: hasBgGradient
                ? LinearGradient(
                    begin: bgGradientAlign.$1,
                    end: bgGradientAlign.$2,
                    colors: [
                      Color(bgGradientStart!),
                      Color(bgGradientEnd!)
                    ],
                  )
                : null,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderClr),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              if (bgImageUrl.isNotEmpty && bgImageUrl.startsWith('http'))
                Positioned.fill(
                  child: AppNetworkImage(
                    url: bgImageUrl,
                    meta: ImageMeta.fromInlineUrl(bgImageUrl),
                    width: canvasWidth,
                    height: canvasHeight,
                    fit: BoxFit.cover,
                    errorWidget: const SizedBox.shrink(),
                  ),
                ),
              for (final e in elements)
                _buildPreviewElement(e, canvasWidth, canvasHeight),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPreviewElement(
      CanvasElement e, double canvasWidth, double canvasHeight) {
    final pxX = e.x * canvasWidth;
    final pxY = e.y * canvasHeight;
    final pxW = e.width * canvasWidth;
    final pxH = e.height * canvasHeight;

    return Positioned(
      left: pxX,
      top: pxY,
      child: Transform.rotate(
        angle: e.rotation,
        child: SizedBox(
          width: pxW,
          height: pxH,
          child: e.type == CanvasElementType.image
              ? _buildImagePreview(e)
              : _buildTextPreview(e, canvasWidth),
        ),
      ),
    );
  }

  Widget _buildImagePreview(CanvasElement e) {
    Widget imageWidget;
    if (e.imageUrl.startsWith('data:image')) {
      try {
        final commaIdx = e.imageUrl.indexOf(',');
        final b64 = e.imageUrl.substring(commaIdx + 1);
        final bytes = base64Decode(b64);
        imageWidget =
            Image.memory(Uint8List.fromList(bytes), fit: BoxFit.cover);
      } catch (_) {
        imageWidget = _placeholder();
      }
    } else if (e.imageUrl.startsWith('http')) {
      imageWidget = AppNetworkImage(
        url: e.imageUrl,
        meta: ImageMeta.fromInlineUrl(e.imageUrl),
        fit: BoxFit.cover,
        errorWidget: _placeholder(),
      );
    } else {
      imageWidget = _placeholder();
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

  Widget _buildTextPreview(CanvasElement e, double canvasWidth) {
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

    final align = {
      'left': TextAlign.left,
      'center': TextAlign.center,
      'right': TextAlign.right,
    }[e.textAlign] ??
        TextAlign.left;

    final hasGradient =
        e.gradientStartColor != null && e.gradientEndColor != null;
    final gradientAlign = _gradientAlignment(e.gradientDirection);

    return Container(
      padding: EdgeInsets.all(12 * scale),
      decoration: BoxDecoration(
        color: hasGradient
            ? null
            : (e.bgColorValue == 0x00000000
                ? null
                : Color(e.bgColorValue)),
        gradient: hasGradient
            ? LinearGradient(
                begin: gradientAlign.$1,
                end: gradientAlign.$2,
                colors: [
                  Color(e.gradientStartColor!),
                  Color(e.gradientEndColor!),
                ],
              )
            : null,
        borderRadius: BorderRadius.circular(8 * scale),
        border: e.hasBorder
            ? Border.all(color: Color(e.borderColorValue), width: 1.5)
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

  static (Alignment, Alignment) _gradientAlignment(String direction) {
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

  Widget _placeholder() {
    return Container(
      color: isDark
          ? Colors.white.withValues(alpha: 0.04)
          : Colors.black.withValues(alpha: 0.03),
      child: Center(
        child: Icon(
          CupertinoIcons.photo,
          color: isDark ? Colors.white24 : Colors.black26,
          size: 28,
        ),
      ),
    );
  }
}

// ============================================================================
// Square -/+ pill button for the reader settings font-size row
// ============================================================================
class _SizeButton extends StatelessWidget {
  final IconData icon;
  final Color bg;
  final Color border;
  final Color color;
  final VoidCallback onTap;
  const _SizeButton({
    required this.icon,
    required this.bg,
    required this.border,
    required this.color,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: border),
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 18, color: color),
      ),
    );
  }
}

// ============================================================================
// Reader text highlight model (session-only, per-section)
// ============================================================================
class _Highlight {
  final String id;
  final int start;
  final int length;
  final String colorHex; // '' -> removed
  const _Highlight({
    required this.id,
    required this.start,
    required this.length,
    required this.colorHex,
  });
}
