import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:iconify_flutter/iconify_flutter.dart';
import 'package:iconify_flutter/icons/ph.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/provider/editor_provider.dart';
import 'package:inkspacex/services/analytics_service.dart';
import 'package:inkspacex/services/gemini_service.dart';
import 'package:inkspacex/ui/editor/canvas_editor.dart';
import 'package:inkspacex/ui/editor/image_embed_builder.dart';
import 'package:inkspacex/ui/utilities/responsive_layout.dart';

// Resolved Google Fonts styles, keyed by family name. Quill calls the
// custom style builder per styled span on every paint, and getFont() is
// not free — caching the resolved TextStyle avoids the repeated lookup.
final Map<String, TextStyle> _fontStyleCache = {};
TextStyle _cachedFontStyle(String name) =>
    _fontStyleCache.putIfAbsent(name, () {
      try {
        return GoogleFonts.getFont(name);
      } catch (_) {
        return TextStyle(fontFamily: name);
      }
    });

// ─── Font families available in the editor ───
const _editorFonts = <String, String>{
  'Sans Serif': 'Inter',
  'Serif': 'Merriweather',
  'Display': 'Playfair Display',
  'Handwritten': 'Caveat',
  'Modern': 'DM Sans',
  'Classic': 'Lora',
  'Script': 'Dancing Script',
  'Playful': 'Patrick Hand',
  'Mono': 'JetBrains Mono',
  'Elegant': 'Cormorant Garamond',
};

// ─── Paper Themes ───
enum PaperTheme {
  defaultTheme('Default'),
  sepia('Sepia'),
  warm('Warm'),
  cool('Cool'),
  green('Green'),
  rose('Rose'),
  midnight('Midnight');

  final String label;
  const PaperTheme(this.label);
}

// ─── Writing Prompts ───
const _writingPrompts = [
  'Write about a sound that changed everything.',
  'Describe a place you\'ve never been but can see clearly.',
  'What would you say to your past self?',
  'Write the opening line of a story you\'d want to read.',
  'Describe the color blue without using the word "blue".',
  'Write about a door that should never be opened.',
  'What does silence sound like in your favorite place?',
  'Describe a stranger you\'ll never forget.',
  'Write about the last time you were truly surprised.',
  'What lives in the space between sleeping and waking?',
  'Write about an object you\'ve carried for years.',
  'Describe a meal that felt like coming home.',
  'What would the walls of this room say?',
  'Write about a promise that was kept.',
  'Describe the feeling of rain on skin.',
  'Write about a letter that was never sent.',
  'What does your handwriting say about you?',
  'Describe a moment when time stood still.',
  'Write about a road that only exists at night.',
  'What does courage smell like?',
  'Write about something beautiful that\'s broken.',
  'Describe the space between two heartbeats.',
  'Write about a word that doesn\'t exist but should.',
  'What color is the feeling of nostalgia?',
  'Describe a conversation between the sun and moon.',
  'Write about the first thing you remember.',
  'What does your shadow do when you\'re not looking?',
  'Describe a map to somewhere that can\'t be found.',
  'Write about what the ocean forgets.',
  'What would you plant in a garden of memories?',
];

class EditiorPage extends StatefulWidget {
  const EditiorPage({super.key});

  @override
  State<EditiorPage> createState() => _EditiorPageState();
}

class _EditiorPageState extends State<EditiorPage>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  bool _isReady = false;
  bool _imageUploading = false;
  bool _isCanvasMode = false;
  final _gemini = GeminiService();

  // ── Advanced Writer Features ──
  bool _focusMode = false;
  bool _typewriterMode = false;
  bool _showOutline = false;
  bool _findReplaceOpen = false;
  PaperTheme _paperTheme = PaperTheme.defaultTheme;
  int _sessionStartWords = 0;
  bool _sessionStarted = false;
  int _dailyGoal = 500;
  bool _showGoalWidget = false;
  String? _activePrompt;
  late AnimationController _focusModeController;
  late Animation<double> _focusModeAnimation;
  @override
  void initState() {
    super.initState();
    AnalyticsService.instance.track(
      'editor_opened',
      screen: '/editor',
      action: 'view',
    );
    WidgetsBinding.instance.addObserver(this);
    _focusModeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _focusModeAnimation = CurvedAnimation(
      parent: _focusModeController,
      curve: Curves.easeOutCubic,
    );
    for (final font in _editorFonts.values) {
      try {
        GoogleFonts.getFont(font);
      } catch (_) {}
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      route.animation?.addStatusListener(_routeAnimationListener);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      context.read<EditorProvider>().forceSaveImmediately();
    }
  }

  void _routeAnimationListener(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      ModalRoute.of(context)
          ?.animation
          ?.removeStatusListener(_routeAnimationListener);
      context.read<EditorProvider>().initEditor();
      if (mounted) {
        setState(() => _isReady = true);
        _initSessionTracking();
      }
    }
  }

  void _initSessionTracking() {
    if (_sessionStarted) return;
    final provider = context.read<EditorProvider>();
    final text = provider.controller.document.toPlainText().trim();
    _sessionStartWords = text.isEmpty ? 0 : text.split(RegExp(r'\s+')).length;
    _sessionStarted = true;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focusModeController.dispose();
    super.dispose();
  }

  // ─── Focus Mode ───
  void _toggleFocusMode() {
    setState(() => _focusMode = !_focusMode);
    if (_focusMode) {
      _focusModeController.forward();
      // Hide the sections sidebar
      final provider = context.read<EditorProvider>();
      if (provider.showSectionsList) {
        provider.toggleShowSections();
      }
    } else {
      _focusModeController.reverse();
    }
  }

  // ─── Paper Theme Colors ───
  Color _getPaperColor(bool isDark) {
    if (isDark) {
      switch (_paperTheme) {
        case PaperTheme.defaultTheme:
          return const Color(0xFF131315);
        case PaperTheme.sepia:
          return const Color(0xFF1A1710);
        case PaperTheme.warm:
          return const Color(0xFF1A1412);
        case PaperTheme.cool:
          return const Color(0xFF101318);
        case PaperTheme.green:
          return const Color(0xFF0F1510);
        case PaperTheme.rose:
          return const Color(0xFF181014);
        case PaperTheme.midnight:
          return const Color(0xFF0A0A14);
      }
    } else {
      switch (_paperTheme) {
        case PaperTheme.defaultTheme:
          return Colors.white;
        case PaperTheme.sepia:
          return const Color(0xFFF5ECD7);
        case PaperTheme.warm:
          return const Color(0xFFFFF5EE);
        case PaperTheme.cool:
          return const Color(0xFFF0F4FA);
        case PaperTheme.green:
          return const Color(0xFFF2F7F2);
        case PaperTheme.rose:
          return const Color(0xFFFFF0F3);
        case PaperTheme.midnight:
          return const Color(0xFFEEEEF5);
      }
    }
  }

  Color _getTextColor(bool isDark) {
    if (isDark) {
      switch (_paperTheme) {
        case PaperTheme.sepia:
          return const Color(0xFFE8D5B0);
        case PaperTheme.warm:
          return const Color(0xFFEDD5C8);
        case PaperTheme.cool:
          return const Color(0xFFD0D8EA);
        case PaperTheme.green:
          return const Color(0xFFC8DCC8);
        case PaperTheme.rose:
          return const Color(0xFFE0C8D5);
        default:
          return Colors.white;
      }
    }
    switch (_paperTheme) {
      case PaperTheme.sepia:
        return const Color(0xFF3D2E1C);
      case PaperTheme.warm:
        return const Color(0xFF3A2520);
      case PaperTheme.cool:
        return const Color(0xFF1E2A3A);
      case PaperTheme.green:
        return const Color(0xFF1C2E1C);
      case PaperTheme.rose:
        return const Color(0xFF3A1E2E);
      default:
        return const Color(0xFF111111);
    }
  }

  // ─── Image Insertion (instant preview + background upload) ───
  Future<void> _insertImage() async {
    final auth = context.read<AuthProvider>();
    final editorProvider = context.read<EditorProvider>();
    if (auth.currentUser == null) return;

    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1200,
      imageQuality: 70,
    );
    if (picked == null || !mounted) return;

    final bytes = await picked.readAsBytes();
    if (!mounted) return;

    final dataUri = 'data:image/jpeg;base64,${base64Encode(bytes)}';
    final controller = editorProvider.controller;
    final index = controller.selection.baseOffset;
    final length = controller.selection.extentOffset - index;
    if (length > 0) {
      controller.replaceText(index, length, '', null);
    }
    controller.document.insert(index, BlockEmbed.image(dataUri));
    controller.updateSelection(
      TextSelection.collapsed(offset: index + 1),
      ChangeSource.local,
    );

    setState(() => _imageUploading = true);
    _uploadAndReplace(
      editorProvider: editorProvider,
      userId: auth.currentUser!.id,
      bytes: bytes,
      tempUri: dataUri,
    );
  }

  Future<void> _uploadAndReplace({
    required EditorProvider editorProvider,
    required String userId,
    required Uint8List bytes,
    required String tempUri,
  }) async {
    try {
      final auth = context.read<AuthProvider>();
      final result = await auth.storageService.uploadEditorImage(
        userId,
        bytes,
      );
      final url = result.url;
      if (!mounted) return;

      final delta = editorProvider.controller.document.toDelta();
      final ops = delta.toJson();
      bool replaced = false;
      for (final op in ops) {
        final insert = op['insert'];
        if (insert is Map) {
          final embed = insert;
          final imgVal = embed['image'];
          if (imgVal is String) {
            final hashIdx = imgVal.indexOf('#');
            final base = hashIdx == -1 ? imgVal : imgVal.substring(0, hashIdx);
            final frag = hashIdx == -1 ? '' : imgVal.substring(hashIdx);
            if (base == tempUri) {
              embed['image'] = '$url$frag';
              replaced = true;
              break;
            }
          }
        }
      }
      if (replaced) {
        final sel = editorProvider.controller.selection;
        editorProvider.controller.document = Document.fromJson(ops);
        editorProvider.controller.updateSelection(sel, ChangeSource.local);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Image upload failed — will retry on save'),
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _imageUploading = false);
    }
  }

  // ─── Mode Toggle ───
  void _switchMode(bool toCanvas) {
    if (toCanvas == _isCanvasMode) return;
    final provider = context.read<EditorProvider>();
    if (toCanvas) {
      provider.forceSaveImmediately();
    } else {
      _saveCanvasData();
    }
    setState(() => _isCanvasMode = toCanvas);
  }

  void _saveCanvasData() {
    final provider = context.read<EditorProvider>();
    if (provider.activeSection != null) {
      provider.forceSaveImmediately();
    }
  }

  Widget _modeTab({
    required String label,
    required IconData icon,
    required bool isActive,
    required Color textColor,
    required bool isDark,
    required VoidCallback onTap,
  }) {
    final activeColor =
        isDark ? const Color(0xFF5B8DEF) : const Color(0xFF4A6CF7);

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: isActive ? activeColor.withValues(alpha: 0.15) : null,
          borderRadius: BorderRadius.circular(7),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 13,
              color:
                  isActive ? activeColor : textColor.withValues(alpha: 0.35),
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color:
                    isActive ? activeColor : textColor.withValues(alpha: 0.4),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── AI Panel ───
  void _showAIPanel() {
    final editorProvider = context.read<EditorProvider>();
    final controller = editorProvider.controller;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF111111);
    final mutedColor = isDark
        ? Colors.white.withValues(alpha: 0.45)
        : Colors.black.withValues(alpha: 0.45);
    final surfaceColor =
        isDark ? const Color(0xFF141414) : const Color(0xFFF5F5F7);
    final sheetBg = isDark ? const Color(0xFF0C0C0C) : Colors.white;

    final selection = controller.selection;
    final hasSelection = selection.baseOffset != selection.extentOffset;
    final selectedText = hasSelection
        ? controller.document.getPlainText(
            selection.baseOffset,
            selection.extentOffset - selection.baseOffset,
          )
        : controller.document.toPlainText().trim();

    if (selectedText.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Write some text first, then use AI to enhance it.',
            style: GoogleFonts.inter(),
          ),
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: sheetBg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _AIBottomSheet(
        gemini: _gemini,
        text: selectedText,
        hasSelection: hasSelection,
        isDark: isDark,
        textColor: textColor,
        mutedColor: mutedColor,
        surfaceColor: surfaceColor,
        onApply: (result) {
          Navigator.pop(ctx);
          // Capture inline formatting (font, size, bold, color, …) at the
          // selection start so the AI-generated replacement keeps it.
          final styleOffset = hasSelection ? selection.baseOffset : 0;
          final preservedAttrs = controller.document
              .collectStyle(styleOffset, 0)
              .attributes
              .values
              .where((a) => a.isInline)
              .toList();

          final int replaceIndex;
          final int replaceLength;
          if (hasSelection) {
            replaceIndex = selection.baseOffset;
            replaceLength = selection.extentOffset - selection.baseOffset;
          } else {
            replaceIndex = 0;
            replaceLength = controller.document.length - 1;
          }

          controller.replaceText(
            replaceIndex,
            replaceLength,
            result,
            TextSelection.collapsed(offset: replaceIndex + result.length),
          );

          for (final attr in preservedAttrs) {
            controller.formatText(replaceIndex, result.length, attr);
          }
        },
      ),
    );
  }

  // ─── Document Outline ───
  List<_OutlineHeading> _extractOutline() {
    final provider = context.read<EditorProvider>();
    final doc = provider.controller.document;
    final headings = <_OutlineHeading>[];

    int offset = 0;
    for (final op in doc.toDelta().toList()) {
      final data = op.data;
      final attrs = op.attributes;
      if (data is String) {
        if (attrs != null && attrs.containsKey('header')) {
          final level = attrs['header'] as int;
          final text = data.trim();
          if (text.isNotEmpty) {
            headings.add(_OutlineHeading(
              text: text,
              level: level,
              offset: offset,
            ));
          }
        }
        offset += data.length;
      } else {
        offset += 1;
      }
    }

    // Fallback: scan line by line
    if (headings.isEmpty) {
      final lines = doc.toPlainText().split('\n');
      int pos = 0;
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.length > 2 && trimmed.length < 80) {
          // Check if this position has header attribute
          if (pos < doc.length) {
            try {
              final style = doc.collectStyle(pos, 0);
              final headerAttr = style.attributes[Attribute.header.key];
              if (headerAttr != null && headerAttr.value != null) {
                headings.add(_OutlineHeading(
                  text: trimmed,
                  level: headerAttr.value as int,
                  offset: pos,
                ));
              }
            } catch (_) {}
          }
        }
        pos += line.length + 1;
      }
    }

    return headings;
  }

  void _jumpToOffset(int offset) {
    final provider = context.read<EditorProvider>();
    provider.controller.updateSelection(
      TextSelection.collapsed(offset: offset.clamp(0, provider.controller.document.length - 1)),
      ChangeSource.local,
    );
  }

  // ─── Writing Prompt ───
  void _showRandomPrompt() {
    final random = math.Random();
    setState(() {
      _activePrompt = _writingPrompts[random.nextInt(_writingPrompts.length)];
    });
    Future.delayed(const Duration(seconds: 12), () {
      if (mounted && _activePrompt != null) {
        setState(() => _activePrompt = null);
      }
    });
  }

  // ─── Writer Settings Sheet ───
  void _showWriterSettings() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF111111);
    final mutedColor = isDark
        ? Colors.white.withValues(alpha: 0.45)
        : Colors.black.withValues(alpha: 0.45);
    final sheetBg = isDark ? const Color(0xFF0C0C0C) : Colors.white;
    final surfaceColor =
        isDark ? const Color(0xFF141414) : const Color(0xFFF5F5F7);

    showModalBottomSheet(
      context: context,
      backgroundColor: sheetBg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(ctx).height * 0.75,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Handle
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(top: 8, bottom: 12),
                    decoration: BoxDecoration(
                      color: textColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Header
                        Row(
                          children: [
                            Icon(CupertinoIcons.slider_horizontal_3,
                                size: 20, color: textColor),
                            const SizedBox(width: 10),
                            Text(
                              'Writer Settings',
                              style: GoogleFonts.inter(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: textColor,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),

                        // ── Writing Modes ──
                        Text(
                          'WRITING MODES',
                          style: GoogleFonts.inter(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: mutedColor,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 10),
                        _settingsToggle(
                          icon: CupertinoIcons.eye_slash,
                          label: 'Focus Mode',
                          subtitle: 'Hide everything except your words',
                          value: _focusMode,
                          textColor: textColor,
                          mutedColor: mutedColor,
                          surfaceColor: surfaceColor,
                          isDark: isDark,
                          onChanged: (v) {
                            setSheetState(() {});
                            _toggleFocusMode();
                            Navigator.pop(ctx);
                          },
                        ),
                        const SizedBox(height: 8),
                        _settingsToggle(
                          icon: CupertinoIcons.text_cursor,
                          label: 'Typewriter Mode',
                          subtitle: 'Keep the active line centered',
                          value: _typewriterMode,
                          textColor: textColor,
                          mutedColor: mutedColor,
                          surfaceColor: surfaceColor,
                          isDark: isDark,
                          onChanged: (v) {
                            setSheetState(() {});
                            setState(() => _typewriterMode = v);
                          },
                        ),

                        const SizedBox(height: 24),

                        // ── Paper Theme ──
                        Text(
                          'PAPER THEME',
                          style: GoogleFonts.inter(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: mutedColor,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: PaperTheme.values.map((theme) {
                            final isActive = _paperTheme == theme;
                            return GestureDetector(
                              onTap: () {
                                setSheetState(() {});
                                setState(() => _paperTheme = theme);
                              },
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 10),
                                decoration: BoxDecoration(
                                  color: isActive
                                      ? (isDark
                                          ? const Color(0xFF5B8DEF)
                                              .withValues(alpha: 0.2)
                                          : const Color(0xFF5B8DEF)
                                              .withValues(alpha: 0.1))
                                      : surfaceColor,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: isActive
                                        ? const Color(0xFF5B8DEF)
                                            .withValues(alpha: 0.4)
                                        : Colors.transparent,
                                    width: 1.5,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 16,
                                      height: 16,
                                      decoration: BoxDecoration(
                                        color: _getPaperColor(isDark),
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(
                                          color: isDark
                                              ? Colors.white
                                                  .withValues(alpha: 0.15)
                                              : Colors.black
                                                  .withValues(alpha: 0.1),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      theme.label,
                                      style: GoogleFonts.inter(
                                        fontSize: 13,
                                        fontWeight: isActive
                                            ? FontWeight.w600
                                            : FontWeight.w500,
                                        color: isActive
                                            ? const Color(0xFF5B8DEF)
                                            : textColor
                                                .withValues(alpha: 0.7),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }).toList(),
                        ),

                        const SizedBox(height: 24),

                        // ── Daily Goal ──
                        Text(
                          'DAILY WORD GOAL',
                          style: GoogleFonts.inter(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: mutedColor,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: surfaceColor,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Icon(CupertinoIcons.flame,
                                      size: 18, color: Colors.orange),
                                  const SizedBox(width: 8),
                                  Text(
                                    '$_dailyGoal words',
                                    style: GoogleFonts.inter(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                      color: textColor,
                                    ),
                                  ),
                                  const Spacer(),
                                  CupertinoSwitch(
                                    value: _showGoalWidget,
                                    onChanged: (v) {
                                      setSheetState(() {});
                                      setState(() => _showGoalWidget = v);
                                    },
                                    activeTrackColor: const Color(0xFF5B8DEF),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  for (final goal
                                      in [250, 500, 1000, 1500, 2000])
                                    Expanded(
                                      child: GestureDetector(
                                        onTap: () {
                                          setSheetState(() {});
                                          setState(() => _dailyGoal = goal);
                                        },
                                        child: Container(
                                          margin: const EdgeInsets.symmetric(
                                              horizontal: 2),
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 8),
                                          decoration: BoxDecoration(
                                            color: _dailyGoal == goal
                                                ? const Color(0xFF5B8DEF)
                                                    .withValues(alpha: 0.15)
                                                : isDark
                                                    ? Colors.white.withValues(
                                                        alpha: 0.04)
                                                    : Colors.black.withValues(
                                                        alpha: 0.03),
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            border: Border.all(
                                              color: _dailyGoal == goal
                                                  ? const Color(0xFF5B8DEF)
                                                      .withValues(alpha: 0.3)
                                                  : Colors.transparent,
                                            ),
                                          ),
                                          child: Center(
                                            child: Text(
                                              '$goal',
                                              style: GoogleFonts.inter(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                                color: _dailyGoal == goal
                                                    ? const Color(0xFF5B8DEF)
                                                    : mutedColor,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
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
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _settingsToggle({
    required IconData icon,
    required String label,
    required String subtitle,
    required bool value,
    required Color textColor,
    required Color mutedColor,
    required Color surfaceColor,
    required bool isDark,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: textColor.withValues(alpha: 0.7)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                  ),
                ),
                Text(
                  subtitle,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: mutedColor,
                  ),
                ),
              ],
            ),
          ),
          CupertinoSwitch(
            value: value,
            onChanged: onChanged,
            activeTrackColor: const Color(0xFF5B8DEF),
          ),
        ],
      ),
    );
  }

  // ─── Build ───
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor =
        isDark ? const Color(0xFF0A0A0A) : const Color(0xFFFAFAFA);
    final surfaceColor =
        isDark ? const Color(0xFF111111) : const Color(0xFFF2F2F5);
    final textColor = isDark ? Colors.white : const Color(0xFF111111);
    final mutedColor = isDark
        ? Colors.white.withValues(alpha: 0.4)
        : Colors.black.withValues(alpha: 0.4);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.06);
    final isMobile = Breakpoints.isMobile(MediaQuery.sizeOf(context).width);

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        context.read<EditorProvider>().forceSaveImmediately();
      },
      child: Scaffold(
        backgroundColor: bgColor,
        body: SafeArea(
          child: _isReady
              ? KeyboardListener(
                  focusNode: FocusNode(),
                  onKeyEvent: (event) {
                    if (event is! KeyDownEvent) return;
                    // Escape exits focus mode (or closes find bar).
                    if (event.logicalKey == LogicalKeyboardKey.escape) {
                      if (_findReplaceOpen) {
                        setState(() => _findReplaceOpen = false);
                        return;
                      }
                      if (_focusMode) {
                        _toggleFocusMode();
                        return;
                      }
                    }
                    // Ctrl/Cmd + F → toggle Find & Replace.
                    final isF = event.logicalKey == LogicalKeyboardKey.keyF;
                    final ctrlOrCmd = HardwareKeyboard
                            .instance.isControlPressed ||
                        HardwareKeyboard.instance.isMetaPressed;
                    if (isF && ctrlOrCmd && !_isCanvasMode) {
                      setState(() => _findReplaceOpen = !_findReplaceOpen);
                    }
                  },
                  child: Stack(
                    children: [
                      Column(
                        children: [
                          // ── Top Bar ──
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 400),
                            curve: Curves.easeOutCubic,
                            height: _focusMode ? 0 : 52,
                            clipBehavior: Clip.hardEdge,
                            decoration: const BoxDecoration(),
                            child: _buildTopBar(
                              isDark: isDark,
                              bgColor: bgColor,
                              textColor: textColor,
                              mutedColor: mutedColor,
                              borderColor: borderColor,
                              isMobile: isMobile,
                            ),
                          ),

                          // ── Toolbar (only in Write mode) ──
                          if (!_isCanvasMode && !_focusMode) ...[
                            if (!isMobile)
                              _buildDesktopToolbar(
                                isDark: isDark,
                                bgColor: bgColor,
                                textColor: textColor,
                                mutedColor: mutedColor,
                                borderColor: borderColor,
                                surfaceColor: surfaceColor,
                              ),
                            if (isMobile)
                              _buildMobileToolbar(
                                isDark: isDark,
                                bgColor: bgColor,
                                textColor: textColor,
                                borderColor: borderColor,
                              ),
                          ],

                          // ── Main Workspace ──
                          Expanded(
                            child: _isCanvasMode
                                ? Row(
                                    children: [
                                      if (!isMobile && !_focusMode)
                                        _buildSidebar(
                                          isDark: isDark,
                                          textColor: textColor,
                                          borderColor: borderColor,
                                          surfaceColor: surfaceColor,
                                        ),
                                      Expanded(
                                        child: _buildCanvasMode(
                                          isDark: isDark,
                                          bgColor: bgColor,
                                          textColor: textColor,
                                        ),
                                      ),
                                    ],
                                  )
                                : Row(
                                    children: [
                                      if (!isMobile && !_focusMode)
                                        _buildSidebar(
                                          isDark: isDark,
                                          textColor: textColor,
                                          borderColor: borderColor,
                                          surfaceColor: surfaceColor,
                                        ),
                                      // ── Outline Panel ──
                                      if (_showOutline && !isMobile && !_focusMode)
                                        _buildOutlinePanel(
                                          isDark: isDark,
                                          textColor: textColor,
                                          borderColor: borderColor,
                                          surfaceColor: surfaceColor,
                                        ),
                                      Expanded(
                                        child: Column(
                                          children: [
                                            if (_findReplaceOpen && !_focusMode)
                                              _FindReplaceBar(
                                                controller: context
                                                    .read<EditorProvider>()
                                                    .controller,
                                                isDark: isDark,
                                                textColor: textColor,
                                                borderColor: borderColor,
                                                bgColor: bgColor,
                                                onClose: () => setState(() =>
                                                    _findReplaceOpen = false),
                                              ),
                                            Expanded(
                                              child: _buildEditorArea(
                                                isDark: isDark,
                                                bgColor: bgColor,
                                                textColor: textColor,
                                                isMobile: isMobile,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                          ),

                          // ── Status Bar ──
                          if (!_isCanvasMode && !_focusMode)
                            _buildStatusBar(
                              bgColor: bgColor,
                              textColor: textColor,
                              borderColor: borderColor,
                              mutedColor: mutedColor,
                              isDark: isDark,
                            ),
                        ],
                      ),

                      // ── Writing Prompt Overlay ──
                      if (_activePrompt != null)
                        _buildPromptOverlay(
                          isDark: isDark,
                          textColor: textColor,
                          isMobile: isMobile,
                        ),

                      // ── Daily Goal Progress Widget ──
                      if (_showGoalWidget && !_isCanvasMode && !_focusMode)
                        _buildGoalWidget(
                          isDark: isDark,
                          textColor: textColor,
                          isMobile: isMobile,
                        ),

                      // ── Focus Mode Exit Button ──
                      if (_focusMode)
                        Positioned(
                          top: 14,
                          right: 16,
                          child: FadeTransition(
                            opacity: _focusModeAnimation,
                            child: _FocusExitButton(
                              isDark: isDark,
                              onTap: _toggleFocusMode,
                            ),
                          ),
                        ),

                      // ── Focus Mode Word Counter ──
                      if (_focusMode)
                        Positioned(
                          bottom: 18,
                          left: 0,
                          right: 0,
                          child: FadeTransition(
                            opacity: _focusModeAnimation,
                            child: Center(
                              child: _FocusWordCounter(
                                isDark: isDark,
                                sessionStart: _sessionStartWords,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                )
              : const Center(child: CupertinoActivityIndicator(radius: 14)),
        ),
      ),
    );
  }

  // ─── Top Bar ───
  Widget _buildTopBar({
    required bool isDark,
    required Color bgColor,
    required Color textColor,
    required Color mutedColor,
    required Color borderColor,
    required bool isMobile,
  }) {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: Row(
        children: [
          // Back
          IconButton(
            icon: Icon(CupertinoIcons.arrow_left, size: 20, color: textColor),
            onPressed: () {
              context.read<EditorProvider>().forceSaveImmediately();
              Navigator.pop(context);
            },
          ),

          // Sidebar toggle (desktop) / Sections sheet (mobile)
          if (isMobile)
            IconButton(
              icon:
                  Icon(CupertinoIcons.list_bullet, size: 19, color: textColor),
              onPressed: () => _showSectionsSheet(
                isDark: isDark,
                textColor: textColor,
                borderColor: borderColor,
              ),
            )
          else
            IconButton(
              icon: Icon(
                context.select<EditorProvider, bool>(
                        (p) => p.showSectionsList)
                    ? CupertinoIcons.sidebar_left
                    : CupertinoIcons.sidebar_right,
                size: 19,
                color: textColor,
              ),
              onPressed: () =>
                  context.read<EditorProvider>().toggleShowSections(),
            ),

          const SizedBox(width: 4),

          // Section title — narrowly scoped so typing-burst notifies don't
          // rebuild this subtree.
          Expanded(
            child: Selector<EditorProvider, String>(
              selector: (_, p) => p.activeSection?.title ?? '',
              builder: (context, title, _) {
                return Text(
                  title,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                );
              },
            ),
          ),

          // Write / Creative mode toggle
          Container(
            height: 30,
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.06)
                  : Colors.black.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _modeTab(
                  label: 'Write',
                  icon: CupertinoIcons.pencil,
                  isActive: !_isCanvasMode,
                  textColor: textColor,
                  isDark: isDark,
                  onTap: () => _switchMode(false),
                ),
                _modeTab(
                  label: 'Creative',
                  icon: CupertinoIcons.paintbrush,
                  isActive: _isCanvasMode,
                  textColor: textColor,
                  isDark: isDark,
                  onTap: () => _switchMode(true),
                ),
              ],
            ),
          ),

          const SizedBox(width: 6),

          // Sync status chip — driven off outbox depth + connectivity, not
          // a single saveStatus string.
          //
          // Listens to a small ValueListenable + the two outbox counters
          // instead of the whole EditorProvider. That way the chip can
          // flip "Saved → Typing" without rebuilding the rest of the
          // editor scaffold on the first keystroke of every typing burst.
          Builder(
            builder: (context) {
              final provider = context.read<EditorProvider>();
              return ListenableBuilder(
                listenable: Listenable.merge([
                  provider.syncStatusListenable,
                  provider.pendingOpsCount,
                  provider.failedOpsCount,
                ]),
                builder: (context, _) {
                  final status = provider.syncStatusListenable.value;
                  final pending = provider.pendingOpsCount.value;
                  final failed = provider.failedOpsCount.value;
              IconData icon;
              Color iconColor;
              String label;
              switch (status) {
                case SyncStatus.idle:
                  icon = CupertinoIcons.checkmark_alt_circle;
                  iconColor = Colors.green.withValues(alpha: 0.7);
                  label = 'Saved';
                  break;
                case SyncStatus.typing:
                  icon = CupertinoIcons.pencil;
                  iconColor = Colors.amber.withValues(alpha: 0.8);
                  label = '';
                  break;
                case SyncStatus.saving:
                  icon = CupertinoIcons.cloud_upload;
                  iconColor = mutedColor;
                  label = 'Saving';
                  break;
                case SyncStatus.offline:
                  icon = CupertinoIcons.wifi_slash;
                  iconColor = Colors.amber.withValues(alpha: 0.8);
                  label = 'Offline · $pending pending';
                  break;
                case SyncStatus.syncing:
                  icon = CupertinoIcons.arrow_2_circlepath;
                  iconColor = mutedColor;
                  label = 'Syncing $pending';
                  break;
                case SyncStatus.error:
                  icon = CupertinoIcons.exclamationmark_circle;
                  iconColor = Colors.red.withValues(alpha: 0.8);
                  label = '$failed failed';
                  break;
              }

              final tappable = status == SyncStatus.error;
              final row = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_imageUploading)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CupertinoActivityIndicator(radius: 6),
                          const SizedBox(width: 6),
                          Text(
                            'Uploading',
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              color: mutedColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (status == SyncStatus.saving ||
                      status == SyncStatus.syncing)
                    const CupertinoActivityIndicator(radius: 6)
                  else
                    Icon(icon, size: 14, color: iconColor),
                  if (!isMobile && label.isNotEmpty) ...[
                    const SizedBox(width: 5),
                    Text(
                      label,
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: status == SyncStatus.error
                            ? Colors.red.withValues(alpha: 0.9)
                            : mutedColor,
                      ),
                    ),
                  ],
                ],
              );

                  if (!tappable) return row;
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _showFailedOpsSheet(context, provider),
                    child: row,
                  );
                },
              );
            },
          ),

          const SizedBox(width: 4),

          // New Section
          if (isMobile)
            _ToolbarIconButton(
              icon: CupertinoIcons.add,
              tooltip: 'New Section',
              color: textColor,
              onPressed: _promptNewSection,
            )
          else
            Padding(
              padding: const EdgeInsets.only(left: 4, right: 6),
              child: CupertinoButton(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                color: textColor,
                borderRadius: BorderRadius.circular(10),
                minimumSize: Size.zero,
                onPressed: _promptNewSection,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(CupertinoIcons.add, size: 13, color: bgColor),
                    const SizedBox(width: 5),
                    Text(
                      'New Section',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: bgColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ─── Desktop Toolbar ───
  Widget _buildDesktopToolbar({
    required bool isDark,
    required Color bgColor,
    required Color textColor,
    required Color mutedColor,
    required Color borderColor,
    required Color surfaceColor,
  }) {
    final accentColor =
        isDark ? const Color(0xFF93B4F5) : const Color(0xFF5B8DEF);

    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: Row(
        children: [
          // Image insert
          _ToolbarIconButton(
            iconWidget: Iconify(
              Ph.google_photos_logo_bold,
              size: 19,
              color: textColor,
            ),
            tooltip: 'Insert Image',
            color: textColor,
            onPressed: _insertImage,
          ),

          Container(
            width: 1,
            height: 20,
            margin: const EdgeInsets.symmetric(horizontal: 6),
            color: borderColor,
          ),

          // Quill toolbar
          Expanded(
            child: _buildQuillToolbar(isDark: isDark, textColor: textColor),
          ),

          Container(
            width: 1,
            height: 20,
            margin: const EdgeInsets.symmetric(horizontal: 6),
            color: borderColor,
          ),

          // Outline toggle
          _ToolbarIconButton(
            icon: CupertinoIcons.list_bullet_indent,
            tooltip: 'Document Outline',
            color: _showOutline ? accentColor : textColor,
            onPressed: () => setState(() => _showOutline = !_showOutline),
          ),

          // Writing Prompt
          _ToolbarIconButton(
            icon: CupertinoIcons.lightbulb,
            tooltip: 'Writing Prompt',
            color: Colors.amber.withValues(alpha: 0.8),
            onPressed: _showRandomPrompt,
          ),

          // Focus Mode
          _ToolbarIconButton(
            icon: CupertinoIcons.eye_slash,
            tooltip: 'Focus Mode',
            color: textColor,
            onPressed: _toggleFocusMode,
          ),

          // Writer Settings
          _ToolbarIconButton(
            icon: CupertinoIcons.slider_horizontal_3,
            tooltip: 'Writer Settings',
            color: textColor,
            onPressed: _showWriterSettings,
          ),

          Container(
            width: 1,
            height: 20,
            margin: const EdgeInsets.symmetric(horizontal: 6),
            color: borderColor,
          ),

          // AI Assist
          _ToolbarIconButton(
            icon: CupertinoIcons.wand_stars,
            tooltip: 'AI Assist',
            color: accentColor,
            onPressed: _showAIPanel,
          ),
        ],
      ),
    );
  }

  // ─── Mobile Toolbar ───
  Widget _buildMobileToolbar({
    required bool isDark,
    required Color bgColor,
    required Color textColor,
    required Color borderColor,
  }) {
    final accentColor =
        isDark ? const Color(0xFF93B4F5) : const Color(0xFF5B8DEF);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: Row(
        children: [
          _ToolbarIconButton(
            iconWidget: Iconify(
              Ph.google_photos_logo_bold,
              size: 19,
              color: textColor,
            ),
            tooltip: 'Insert Image',
            color: textColor,
            onPressed: _insertImage,
          ),
          Container(
            width: 1,
            height: 20,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            color: borderColor,
          ),
          Expanded(
            child: _buildQuillToolbar(isDark: isDark, textColor: textColor),
          ),
          Container(
            width: 1,
            height: 20,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            color: borderColor,
          ),
          // Writing Prompt
          _ToolbarIconButton(
            icon: CupertinoIcons.lightbulb,
            tooltip: 'Prompt',
            color: Colors.amber.withValues(alpha: 0.8),
            onPressed: _showRandomPrompt,
          ),
          // Writer Settings (mobile)
          _ToolbarIconButton(
            icon: CupertinoIcons.slider_horizontal_3,
            tooltip: 'Settings',
            color: textColor,
            onPressed: _showWriterSettings,
          ),
          // AI Assist
          _ToolbarIconButton(
            icon: CupertinoIcons.wand_stars,
            tooltip: 'AI Assist',
            color: accentColor,
            onPressed: _showAIPanel,
          ),
        ],
      ),
    );
  }

  // ─── Quill Toolbar (compact, Word-style) ───
  Widget _buildQuillToolbar({required bool isDark, required Color textColor}) {
    final controller = context.read<EditorProvider>().controller;
    return _WordStyleToolbar(
      controller: controller,
      isDark: isDark,
      textColor: textColor,
      onToggleFindReplace: () =>
          setState(() => _findReplaceOpen = !_findReplaceOpen),
      findReplaceOpen: _findReplaceOpen,
    );
  }

  // ─── Canvas Mode (Creative / Scrapbook) ───
  Widget _buildCanvasMode({
    required bool isDark,
    required Color bgColor,
    required Color textColor,
  }) {
    final provider = context.watch<EditorProvider>();
    final section = provider.activeSection;
    if (section == null) {
      return Center(
        child: Text(
          'Select or create a section',
          style: GoogleFonts.inter(
            color: textColor.withValues(alpha: 0.3),
            fontSize: 15,
          ),
        ),
      );
    }

    return CanvasEditor(
      key: ValueKey('canvas_${section.id}'),
      initialData: section.canvasData,
      isDark: isDark,
      writingPreview: provider.getPreviewText(section.content),
      bookTitle: provider.activeBook?.title ?? '',
      sectionTitle: section.title,
      otherSectionTitles: provider.allBooksSection
          .where((s) => s.id != section.id)
          .map((s) => s.title)
          .toList(),
      onChanged: (data) {
        provider.saveCanvasData(data);
      },
      onUploadImage: (bytes) async {
        final auth = context.read<AuthProvider>();
        if (auth.currentUser == null) return null;
        final result = await auth.storageService.uploadEditorImage(
          auth.currentUser!.id,
          bytes,
        );
        // Canvas elements store a single URL string. `result.url` is the
        // medium variant with a `#bh=...` meta fragment — small enough for
        // a thumbnail (no 2400 px memory regression) but still rehydratable
        // back into ImageMeta if the canvas renderer ever wants the
        // blurhash placeholder.
        return result.url;
      },
    );
  }

  // ─── Outline Panel ───
  Widget _buildOutlinePanel({
    required bool isDark,
    required Color textColor,
    required Color borderColor,
    required Color surfaceColor,
  }) {
    final headings = _extractOutline();
    final accentColor =
        isDark ? const Color(0xFF5B8DEF) : const Color(0xFF4A6CF7);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      width: 220,
      decoration: BoxDecoration(
        color: surfaceColor.withValues(alpha: 0.5),
        border: Border(right: BorderSide(color: borderColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
            child: Row(
              children: [
                Icon(CupertinoIcons.list_bullet_indent,
                    size: 14, color: accentColor),
                const SizedBox(width: 8),
                Text(
                  'Outline',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: textColor.withValues(alpha: 0.6),
                    letterSpacing: 0.5,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => setState(() => _showOutline = false),
                  child: Icon(CupertinoIcons.xmark,
                      size: 12, color: textColor.withValues(alpha: 0.3)),
                ),
              ],
            ),
          ),
          Divider(color: borderColor, height: 1),
          Expanded(
            child: headings.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(CupertinoIcons.text_badge_plus,
                            size: 24,
                            color: textColor.withValues(alpha: 0.15)),
                        const SizedBox(height: 8),
                        Text(
                          'Add headings (H1, H2, H3) to build your outline.',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            color: textColor.withValues(alpha: 0.3),
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: headings.length,
                    itemBuilder: (ctx, idx) {
                      final h = headings[idx];
                      final indent = (h.level - 1) * 12.0;
                      return InkWell(
                        onTap: () => _jumpToOffset(h.offset),
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                              16 + indent, 6, 12, 6),
                          child: Row(
                            children: [
                              Container(
                                width: 18,
                                alignment: Alignment.center,
                                child: Text(
                                  'H${h.level}',
                                  style: GoogleFonts.jetBrainsMono(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w600,
                                    color: accentColor.withValues(alpha: 0.6),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  h.text,
                                  style: GoogleFonts.inter(
                                    fontSize: h.level == 1 ? 13 : 12,
                                    fontWeight: h.level == 1
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                    color: textColor.withValues(
                                        alpha: h.level == 1 ? 0.8 : 0.55),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // ─── Editor Area ───
  Widget _buildEditorArea({
    required bool isDark,
    required Color bgColor,
    required Color textColor,
    required bool isMobile,
  }) {
    final paperColor = _getPaperColor(isDark);
    final themedTextColor = _paperTheme == PaperTheme.defaultTheme
        ? textColor
        : _getTextColor(isDark);
    final paperBorder = isDark
        ? Colors.white.withValues(alpha: 0.05)
        : Colors.black.withValues(alpha: 0.06);

    final focusBorder = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.08);

    return Container(
      color: bgColor,
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: _focusMode ? 760 : 820),
        child: Container(
          height: double.infinity,
          margin: EdgeInsets.fromLTRB(
            isMobile ? 0 : (_focusMode ? 24 : 20),
            isMobile ? 0 : (_focusMode ? 24 : 12),
            isMobile ? 0 : (_focusMode ? 24 : 20),
            isMobile ? 0 : (_focusMode ? 24 : 0),
          ),
          decoration: isMobile
              ? BoxDecoration(color: paperColor)
              : _focusMode
                  ? BoxDecoration(
                      color: paperColor,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: focusBorder),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(
                              alpha: isDark ? 0.45 : 0.10),
                          blurRadius: 40,
                          spreadRadius: -8,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    )
                  : BoxDecoration(
                      color: paperColor,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(16),
                      ),
                      border: Border.all(color: paperBorder),
                    ),
          padding: EdgeInsets.fromLTRB(
            isMobile ? 18 : (_focusMode ? 64 : 48),
            _focusMode ? (isMobile ? 56 : 96) : 20,
            isMobile ? 18 : (_focusMode ? 64 : 48),
            0,
          ),
          child: Builder(
            builder: (ctx) {
              final sectionId = ctx.select<EditorProvider, String?>(
                (p) => p.activeSection?.id,
              );
              final bottomPad = MediaQuery.of(ctx).padding.bottom +
                  MediaQuery.of(ctx).viewInsets.bottom +
                  (_typewriterMode ? MediaQuery.sizeOf(ctx).height * 0.4 : 120);

              return QuillEditor.basic(
                key: ValueKey(sectionId ?? 'none'),
                controller: ctx.read<EditorProvider>().controller,
                config: QuillEditorConfig(
                  placeholder: 'Start writing...',
                  embedBuilders: [
                    ImageEmbedBuilder(
                      controller: ctx.read<EditorProvider>().controller,
                    ),
                  ],
                  padding: EdgeInsets.only(bottom: bottomPad),
                  customStyleBuilder: _customStyleBuilder,
                  customStyles: DefaultStyles(
                    placeHolder: DefaultTextBlockStyle(
                      GoogleFonts.inter(
                        fontSize: _focusMode ? 18 : 17,
                        color: themedTextColor.withValues(alpha: 0.22),
                        height: 1.7,
                      ),
                      const HorizontalSpacing(0, 0),
                      const VerticalSpacing(0, 0),
                      const VerticalSpacing(0, 0),
                      null,
                    ),
                    paragraph: DefaultTextBlockStyle(
                      GoogleFonts.inter(
                        fontSize: _focusMode ? 18 : 17,
                        height: _focusMode ? 1.9 : 1.7,
                        color: themedTextColor.withValues(alpha: 0.9),
                      ),
                      const HorizontalSpacing(0, 0),
                      const VerticalSpacing(10, 0),
                      const VerticalSpacing(0, 0),
                      null,
                    ),
                    h1: DefaultTextBlockStyle(
                      GoogleFonts.inter(
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                        height: 1.3,
                        color: themedTextColor,
                      ),
                      const HorizontalSpacing(0, 0),
                      const VerticalSpacing(20, 10),
                      const VerticalSpacing(0, 0),
                      null,
                    ),
                    h2: DefaultTextBlockStyle(
                      GoogleFonts.inter(
                        fontSize: 26,
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                        color: themedTextColor,
                      ),
                      const HorizontalSpacing(0, 0),
                      const VerticalSpacing(16, 8),
                      const VerticalSpacing(0, 0),
                      null,
                    ),
                    h3: DefaultTextBlockStyle(
                      GoogleFonts.inter(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        height: 1.4,
                        color: themedTextColor,
                      ),
                      const HorizontalSpacing(0, 0),
                      const VerticalSpacing(14, 6),
                      const VerticalSpacing(0, 0),
                      null,
                    ),
                    quote: DefaultTextBlockStyle(
                      GoogleFonts.inter(
                        fontSize: 17,
                        fontStyle: FontStyle.italic,
                        height: 1.6,
                        color: themedTextColor.withValues(alpha: 0.7),
                      ),
                      const HorizontalSpacing(0, 0),
                      const VerticalSpacing(10, 10),
                      const VerticalSpacing(0, 0),
                      BoxDecoration(
                        border: Border(
                          left: BorderSide(
                            color: themedTextColor.withValues(alpha: 0.2),
                            width: 3,
                          ),
                        ),
                      ),
                    ),
                    code: DefaultTextBlockStyle(
                      GoogleFonts.jetBrainsMono(
                        fontSize: 14,
                        height: 1.5,
                        color: themedTextColor.withValues(alpha: 0.85),
                      ),
                      const HorizontalSpacing(0, 0),
                      const VerticalSpacing(8, 8),
                      const VerticalSpacing(0, 0),
                      BoxDecoration(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.05)
                            : Colors.black.withValues(alpha: 0.03),
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// Handles Google Fonts rendering for the `font` attribute.
  /// Resolved styles are cached: GoogleFonts.getFont does internal work
  /// (font asset lookup, descriptor parsing) that's not free, and Quill
  /// invokes this builder per styled-span on every paint of the editor.
  TextStyle _customStyleBuilder(Attribute attr) {
    if (attr.key == 'font') {
      final name = attr.value as String?;
      if (name != null && name.isNotEmpty && name != 'Clear') {
        return _cachedFontStyle(name);
      }
    }
    if (attr.key == 'size') {
      final raw = attr.value;
      final size = raw is num
          ? raw.toDouble()
          : double.tryParse(raw?.toString() ?? '');
      if (size != null && size > 0) {
        return TextStyle(fontSize: size);
      }
    }
    return const TextStyle();
  }

  // ─── Sidebar ───
  Widget _buildSidebar({
    required bool isDark,
    required Color textColor,
    required Color borderColor,
    required Color surfaceColor,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      width: context.select<EditorProvider, bool>((p) => p.showSectionsList)
          ? 260
          : 0,
      decoration: BoxDecoration(
        color: surfaceColor.withValues(alpha: 0.5),
        border: Border(right: BorderSide(color: borderColor)),
      ),
      child: ClipRect(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          child: SizedBox(
            width: 260,
            child: _buildSectionsList(
              isDark: isDark,
              textColor: textColor,
              borderColor: borderColor,
            ),
          ),
        ),
      ),
    );
  }

  // ─── Sections List (shared between sidebar & bottom sheet) ───
  Widget _buildSectionsList({
    required bool isDark,
    required Color textColor,
    required Color borderColor,
    VoidCallback? onItemTap,
    ScrollController? scrollController,
  }) {
    return Consumer<EditorProvider>(
      builder: (context, provider, _) {
        final sections = provider.allBooksSection;
        return ListView.separated(
          controller: scrollController,
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
          itemCount: sections.length,
          separatorBuilder: (_, i) => const SizedBox(height: 2),
          itemBuilder: (ctx, idx) {
            final section = sections[idx];
            final isActive = provider.activeSection?.id == section.id;

            return Material(
              color: isActive
                  ? (isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.black.withValues(alpha: 0.04))
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () {
                  if (!isActive) {
                    provider.forceSaveImmediately();
                    provider.setActiveSection(section);
                    provider.initEditor();
                    _initSessionTracking();
                    onItemTap?.call();
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: section.sectionColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              section.title,
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                fontWeight: isActive
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                color: isActive
                                    ? textColor
                                    : textColor.withValues(alpha: 0.75),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (section.content.isNotEmpty) ...[
                              const SizedBox(height: 3),
                              Text(
                                provider.getPreviewText(section.content),
                                style: GoogleFonts.inter(
                                  fontSize: 11,
                                  color: textColor.withValues(alpha: 0.35),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                        ),
                      ),
                      PopupMenuButton<String>(
                        icon: Icon(
                          CupertinoIcons.ellipsis,
                          size: 14,
                          color: textColor.withValues(alpha: 0.3),
                        ),
                        color:
                            isDark ? const Color(0xFF1A1A1A) : Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        onSelected: (value) {
                          if (value == 'rename') {
                            _showTextInputDialog(
                              title: 'Rename Section',
                              initialValue: section.title,
                              onSave: (v) =>
                                  provider.renameSection(section, v),
                            );
                          } else if (value == 'delete') {
                            provider.deleteSection(section);
                            if (provider.allBooksSection.isEmpty) {
                              Navigator.pop(context);
                            }
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'rename',
                            child: Row(
                              children: [
                                Icon(CupertinoIcons.pencil,
                                    size: 16, color: textColor),
                                const SizedBox(width: 10),
                                Text('Rename', style: GoogleFonts.inter()),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: Row(
                              children: [
                                const Icon(CupertinoIcons.trash,
                                    size: 16, color: Colors.redAccent),
                                const SizedBox(width: 10),
                                Text('Delete',
                                    style: GoogleFonts.inter(
                                        color: Colors.redAccent)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ─── Enhanced Status Bar ───
  Widget _buildStatusBar({
    required Color bgColor,
    required Color textColor,
    required Color borderColor,
    required Color mutedColor,
    required bool isDark,
  }) {
    final isMobile = Breakpoints.isMobile(MediaQuery.sizeOf(context).width);

    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(top: BorderSide(color: borderColor)),
      ),
      // Word/char counts. We listen to the QuillController directly so
      // typing updates the counters live without rebuilding the rest of
      // the editor through EditorProvider's broadcast.
      // Selector picks up section switches (which replace the controller)
      // and ListenableBuilder rebuilds locally on document edits.
      child: Selector<EditorProvider, QuillController>(
        selector: (_, p) => p.controller,
        builder: (context, controller, _) => ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
          final text = controller.document.toPlainText().trim();
          final wordCount =
              text.isEmpty ? 0 : text.split(RegExp(r'\s+')).length;
          final charCount = text.length;
          final readTime = (wordCount / 200).ceil();
          final sessionWords = wordCount - _sessionStartWords;

          final style = GoogleFonts.inter(
            fontSize: 11,
            color: textColor.withValues(alpha: 0.3),
          );

          // Use a compact dot separator instead of wide dividers
          Widget dot() => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text('\u00b7',
                    style: GoogleFonts.inter(
                        fontSize: 13,
                        color: textColor.withValues(alpha: 0.15))),
              );

          // Build stat items — fewer on mobile
          final stats = <Widget>[
            Text('$wordCount words', style: style),
            dot(),
            Text('$charCount chars', style: style),
            if (!isMobile) ...[
              dot(),
              Text(
                  '${readTime < 1 ? '<1' : readTime} min read', style: style),
            ],
          ];

          // Session indicator on the right
          Widget? sessionWidget;
          if (sessionWords > 0) {
            sessionWidget = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(CupertinoIcons.arrow_up_right,
                    size: 10,
                    color: Colors.green.withValues(alpha: 0.6)),
                const SizedBox(width: 3),
                Text(
                  '+$sessionWords session',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: Colors.green.withValues(alpha: 0.5),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            );
          } else if (sessionWords < 0) {
            sessionWidget = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(CupertinoIcons.arrow_down_right,
                    size: 10,
                    color: Colors.orange.withValues(alpha: 0.5)),
                const SizedBox(width: 3),
                Text(
                  '$sessionWords session',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: Colors.orange.withValues(alpha: 0.5),
                  ),
                ),
              ],
            );
          }

          return Row(
            children: [
              // Left: scrollable stats so they never overflow
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: stats,
                  ),
                ),
              ),
              // Right: session + optional mode badge
              if (sessionWidget != null || _typewriterMode) ...[
                const SizedBox(width: 8),
                if (_typewriterMode) ...[
                  Icon(CupertinoIcons.text_cursor,
                      size: 10, color: mutedColor),
                  const SizedBox(width: 4),
                ],
                if (sessionWidget != null) sessionWidget,
              ],
            ],
          );
          },
        ),
      ),
    );
  }

  // ─── Writing Prompt Overlay ───
  Widget _buildPromptOverlay({
    required bool isDark,
    required Color textColor,
    required bool isMobile,
  }) {
    return Positioned(
      bottom: isMobile ? 50 : 40,
      left: isMobile ? 16 : null,
      right: isMobile ? 16 : 20,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOutBack,
        builder: (context, value, child) => Transform.translate(
          offset: Offset(0, 20 * (1 - value)),
          child: Opacity(opacity: value, child: child),
        ),
        child: Container(
          constraints: BoxConstraints(maxWidth: isMobile ? double.infinity : 400),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1A1A2E) : const Color(0xFFFFF8E1),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isDark
                  ? Colors.amber.withValues(alpha: 0.15)
                  : Colors.amber.withValues(alpha: 0.3),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.1),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(CupertinoIcons.lightbulb_fill,
                      size: 14, color: Colors.amber),
                  const SizedBox(width: 8),
                  Text(
                    'Writing Prompt',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.amber.withValues(alpha: 0.8),
                      letterSpacing: 0.5,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: _showRandomPrompt,
                    child: Icon(CupertinoIcons.arrow_2_circlepath,
                        size: 14, color: textColor.withValues(alpha: 0.4)),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => setState(() => _activePrompt = null),
                    child: Icon(CupertinoIcons.xmark,
                        size: 13, color: textColor.withValues(alpha: 0.3)),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                _activePrompt ?? '',
                style: GoogleFonts.merriweather(
                  fontSize: 14,
                  height: 1.6,
                  fontStyle: FontStyle.italic,
                  color: isDark
                      ? const Color(0xFFE0D5BA)
                      : const Color(0xFF5D4E37),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Daily Goal Widget ───
  Widget _buildGoalWidget({
    required bool isDark,
    required Color textColor,
    required bool isMobile,
  }) {
    return Positioned(
      top: isMobile ? 56 : 100,
      right: isMobile ? 8 : 20,
      // Live word count via direct controller listening (see status bar
      // for the same pattern). Avoids per-keystroke EditorProvider rebuild.
      child: Selector<EditorProvider, QuillController>(
        selector: (_, p) => p.controller,
        builder: (context, controller, _) => ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
          final text = controller.document.toPlainText().trim();
          final wordCount =
              text.isEmpty ? 0 : text.split(RegExp(r'\s+')).length;
          final sessionWords = (wordCount - _sessionStartWords).clamp(0, _dailyGoal * 2);
          final progress = (sessionWords / _dailyGoal).clamp(0.0, 1.0);
          final isComplete = progress >= 1.0;

          return Container(
            width: isMobile ? 56 : 160,
            padding: EdgeInsets.all(isMobile ? 8 : 12),
            decoration: BoxDecoration(
              color: isDark
                  ? const Color(0xFF141414).withValues(alpha: 0.95)
                  : Colors.white.withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isComplete
                    ? Colors.green.withValues(alpha: 0.3)
                    : (isDark
                        ? Colors.white.withValues(alpha: 0.06)
                        : Colors.black.withValues(alpha: 0.06)),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.08),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: isMobile
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 36,
                        height: 36,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            CircularProgressIndicator(
                              value: progress,
                              strokeWidth: 3,
                              backgroundColor: isDark
                                  ? Colors.white.withValues(alpha: 0.06)
                                  : Colors.black.withValues(alpha: 0.06),
                              valueColor: AlwaysStoppedAnimation(
                                isComplete
                                    ? Colors.green
                                    : const Color(0xFF5B8DEF),
                              ),
                            ),
                            Center(
                              child: isComplete
                                  ? Icon(CupertinoIcons.checkmark,
                                      size: 14, color: Colors.green)
                                  : Text(
                                      '${(progress * 100).toInt()}',
                                      style: GoogleFonts.inter(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        color: textColor,
                                      ),
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Icon(
                            isComplete
                                ? CupertinoIcons.checkmark_seal_fill
                                : CupertinoIcons.flame,
                            size: 14,
                            color: isComplete ? Colors.green : Colors.orange,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              isComplete
                                  ? 'Goal reached!'
                                  : 'Daily Goal',
                              style: GoogleFonts.inter(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: isComplete
                                    ? Colors.green
                                    : textColor.withValues(alpha: 0.6),
                              ),
                            ),
                          ),
                          GestureDetector(
                            onTap: () =>
                                setState(() => _showGoalWidget = false),
                            child: Icon(CupertinoIcons.xmark,
                                size: 10,
                                color: textColor.withValues(alpha: 0.2)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 4,
                          backgroundColor: isDark
                              ? Colors.white.withValues(alpha: 0.06)
                              : Colors.black.withValues(alpha: 0.06),
                          valueColor: AlwaysStoppedAnimation(
                            isComplete
                                ? Colors.green
                                : const Color(0xFF5B8DEF),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '$sessionWords / $_dailyGoal words',
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: textColor.withValues(alpha: 0.4),
                        ),
                      ),
                    ],
                  ),
          );
          },
        ),
      ),
    );
  }

  // ─── Helpers ───

  void _promptNewSection() {
    final provider = context.read<EditorProvider>();
    _showTextInputDialog(
      title: 'New Section',
      initialValue: 'Section ${provider.allBooksSection.length + 1}',
      onSave: (val) => provider.addSection(val, autoSelect: true),
    );
  }

  void _showFailedOpsSheet(BuildContext context, EditorProvider provider) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sheetBg = isDark ? const Color(0xFF0C0C0C) : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black;
    final muted = textColor.withValues(alpha: 0.6);
    showModalBottomSheet(
      context: context,
      backgroundColor: sheetBg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: AnimatedBuilder(
            animation: provider,
            builder: (ctx, _) {
              final ops = provider.failedOps;
              if (ops.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'No failed operations.',
                    style: GoogleFonts.inter(color: muted),
                  ),
                );
              }
              return ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                itemCount: ops.length,
                separatorBuilder: (_, __) => Divider(
                  color: textColor.withValues(alpha: 0.08),
                  height: 24,
                ),
                itemBuilder: (ctx, i) {
                  final op = ops[i];
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              op.kind.name,
                              style: GoogleFonts.inter(
                                fontWeight: FontWeight.w600,
                                color: textColor,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              op.lastError ?? 'unknown error',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                color: muted,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${op.attemptCount} attempts',
                              style: GoogleFonts.inter(
                                fontSize: 11,
                                color: muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        onPressed: () => provider.retryFailedOp(op.id),
                        child: const Text('Retry'),
                      ),
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        onPressed: () => provider.discardFailedOp(op.id),
                        child: Text(
                          'Discard',
                          style: TextStyle(
                              color: Colors.red.withValues(alpha: 0.85)),
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        );
      },
    );
  }

  void _showSectionsSheet({
    required bool isDark,
    required Color textColor,
    required Color borderColor,
  }) {
    final sheetBg = isDark ? const Color(0xFF0C0C0C) : Colors.white;

    showModalBottomSheet(
      context: context,
      backgroundColor: sheetBg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.55,
        minChildSize: 0.3,
        maxChildSize: 0.85,
        expand: false,
        builder: (_, scrollCtrl) => Column(
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 10),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: textColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 8, 8),
              child: Row(
                children: [
                  Text(
                    'Sections',
                    style: GoogleFonts.inter(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: textColor,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(CupertinoIcons.xmark,
                        size: 18, color: textColor),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _buildSectionsList(
                isDark: isDark,
                textColor: textColor,
                borderColor: borderColor,
                onItemTap: () => Navigator.pop(ctx),
                scrollController: scrollCtrl,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showTextInputDialog({
    required String title,
    required String initialValue,
    required Function(String) onSave,
  }) {
    final ctrl = TextEditingController(text: initialValue);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showCupertinoDialog(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text(title),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: CupertinoTextField(
            controller: ctrl,
            autofocus: true,
            placeholder: 'Enter name...',
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: false,
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () {
              if (ctrl.text.trim().isNotEmpty) onSave(ctrl.text.trim());
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// Small shared widgets & data classes
// ════════════════════════════════════════════════════════════════

class _OutlineHeading {
  final String text;
  final int level;
  final int offset;
  const _OutlineHeading({
    required this.text,
    required this.level,
    required this.offset,
  });
}

class _ToolbarIconButton extends StatelessWidget {
  final IconData? icon;
  final Widget? iconWidget;
  final String tooltip;
  final Color color;
  final VoidCallback onPressed;

  const _ToolbarIconButton({
    this.icon,
    this.iconWidget,
    required this.tooltip,
    required this.color,
    required this.onPressed,
  }) : assert(icon != null || iconWidget != null,
            'Provide either icon or iconWidget');

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: iconWidget ?? Icon(icon, size: 19, color: color),
      tooltip: tooltip,
      onPressed: onPressed,
      splashRadius: 18,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      padding: const EdgeInsets.all(6),
    );
  }
}

// ─── Focus Mode: Exit Button (hover-aware, with ESC hint) ───
class _FocusExitButton extends StatefulWidget {
  final bool isDark;
  final VoidCallback onTap;

  const _FocusExitButton({required this.isDark, required this.onTap});

  @override
  State<_FocusExitButton> createState() => _FocusExitButtonState();
}

class _FocusExitButtonState extends State<_FocusExitButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final base = widget.isDark ? Colors.white : Colors.black;
    final fg = base.withValues(alpha: _hover ? 0.85 : 0.35);
    final bg = base.withValues(alpha: _hover ? 0.08 : 0.03);
    final keyBg = base.withValues(alpha: _hover ? 0.12 : 0.06);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding:
              const EdgeInsets.fromLTRB(10, 6, 6, 6),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(CupertinoIcons.eye, size: 13, color: fg),
              const SizedBox(width: 6),
              Text(
                'Exit Focus',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  color: fg,
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: keyBg,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'ESC',
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: fg,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Focus Mode: Subtle Word Counter (live, bottom-center) ───
class _FocusWordCounter extends StatelessWidget {
  final bool isDark;
  final int sessionStart;

  const _FocusWordCounter({
    required this.isDark,
    required this.sessionStart,
  });

  @override
  Widget build(BuildContext context) {
    final base = isDark ? Colors.white : Colors.black;
    return Selector<EditorProvider, QuillController>(
      selector: (_, p) => p.controller,
      builder: (context, controller, _) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final text = controller.document.toPlainText().trim();
          final words = text.isEmpty ? 0 : text.split(RegExp(r'\s+')).length;
          final session = words - sessionStart;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$words',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  color: base.withValues(alpha: 0.32),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                ' words',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  color: base.withValues(alpha: 0.22),
                ),
              ),
              if (session > 0) ...[
                Text(
                  '   ·   ',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: base.withValues(alpha: 0.15),
                  ),
                ),
                Text(
                  '+$session',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: Colors.green.withValues(alpha: 0.5),
                    fontWeight: FontWeight.w500,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                Text(
                  ' session',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: base.withValues(alpha: 0.22),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// AI Bottom Sheet
// ════════════════════════════════════════════════════════════════

// ─── Word-level diff ───

enum _DiffType { equal, added, removed }

class _DiffSpan {
  final _DiffType type;
  final String text;
  const _DiffSpan(this.type, this.text);
}

/// Myers-style word diff. Splits on word boundaries, computes LCS,
/// then produces a list of equal / added / removed spans.
List<_DiffSpan> _computeWordDiff(String oldText, String newText) {
  final oldWords = _tokenize(oldText);
  final newWords = _tokenize(newText);

  final m = oldWords.length;
  final n = newWords.length;
  final dp = List.generate(m + 1, (_) => List.filled(n + 1, 0));
  for (int i = 1; i <= m; i++) {
    for (int j = 1; j <= n; j++) {
      if (oldWords[i - 1] == newWords[j - 1]) {
        dp[i][j] = dp[i - 1][j - 1] + 1;
      } else {
        dp[i][j] = math.max(dp[i - 1][j], dp[i][j - 1]);
      }
    }
  }

  final spans = <_DiffSpan>[];
  int i = m, j = n;
  final temp = <_DiffSpan>[];
  while (i > 0 || j > 0) {
    if (i > 0 && j > 0 && oldWords[i - 1] == newWords[j - 1]) {
      temp.add(_DiffSpan(_DiffType.equal, oldWords[i - 1]));
      i--;
      j--;
    } else if (j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j])) {
      temp.add(_DiffSpan(_DiffType.added, newWords[j - 1]));
      j--;
    } else {
      temp.add(_DiffSpan(_DiffType.removed, oldWords[i - 1]));
      i--;
    }
  }

  for (final s in temp.reversed) {
    if (spans.isNotEmpty && spans.last.type == s.type) {
      spans[spans.length - 1] =
          _DiffSpan(s.type, '${spans.last.text}${s.text}');
    } else {
      spans.add(s);
    }
  }
  return spans;
}

List<String> _tokenize(String text) {
  final tokens = <String>[];
  final re = RegExp(r'\S+\s*|\s+');
  for (final m in re.allMatches(text)) {
    tokens.add(m.group(0)!);
  }
  return tokens;
}

// ─── AI Bottom Sheet with Diff View ───

class _AIBottomSheet extends StatefulWidget {
  final GeminiService gemini;
  final String text;
  final bool hasSelection;
  final bool isDark;
  final Color textColor;
  final Color mutedColor;
  final Color surfaceColor;
  final ValueChanged<String> onApply;

  const _AIBottomSheet({
    required this.gemini,
    required this.text,
    required this.hasSelection,
    required this.isDark,
    required this.textColor,
    required this.mutedColor,
    required this.surfaceColor,
    required this.onApply,
  });

  @override
  State<_AIBottomSheet> createState() => _AIBottomSheetState();
}

// Transform actions return replacement text → show diff + Accept/Decline.
// Feedback actions return advice → show as a card, no diff, no apply.
enum _AIMode { transform, feedback }

class _AIBottomSheetState extends State<_AIBottomSheet> {
  bool _loading = false;
  String? _result;
  String? _error;
  String _activeAction = '';
  List<_DiffSpan>? _diffSpans;
  _AIMode _mode = _AIMode.transform;

  Future<void> _run(
    String label,
    Future<String> Function() action, {
    _AIMode mode = _AIMode.transform,
  }) async {
    setState(() {
      _loading = true;
      _error = null;
      _result = null;
      _diffSpans = null;
      _activeAction = label;
      _mode = mode;
    });
    try {
      final result = await action();
      if (mounted) {
        setState(() {
          _result = result;
          _diffSpans = mode == _AIMode.transform
              ? _computeWordDiff(widget.text, result)
              : null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
            () => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _reset() {
    setState(() {
      _result = null;
      _diffSpans = null;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final accentColor = widget.isDark
        ? const Color(0xFF93B4F5)
        : const Color(0xFF5B8DEF);

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(top: 8, bottom: 12),
                decoration: BoxDecoration(
                  color: widget.textColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Icon(CupertinoIcons.wand_stars,
                            size: 20, color: accentColor),
                        const SizedBox(width: 10),
                        Text(
                          'AI Assist',
                          style: GoogleFonts.inter(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: widget.textColor,
                          ),
                        ),
                        const Spacer(),
                        if (_result != null && !_loading)
                          GestureDetector(
                            onTap: _reset,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(CupertinoIcons.arrow_left,
                                    size: 14, color: widget.mutedColor),
                                const SizedBox(width: 4),
                                Text(
                                  'Try another',
                                  style: GoogleFonts.inter(
                                    fontSize: 12,
                                    color: widget.mutedColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.hasSelection
                          ? 'Working with selected text'
                          : 'Working with full document',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: widget.mutedColor,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (_result == null || _loading) ...[
                      _sectionLabel('SHARPEN'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _aiChip(
                              'Tighten',
                              CupertinoIcons.bolt,
                              () => _run('Tighten',
                                  () => widget.gemini.tighten(widget.text))),
                          _aiChip(
                              'Sharpen opening',
                              CupertinoIcons.text_alignleft,
                              () => _run(
                                  'Sharpen opening',
                                  () => widget.gemini
                                      .sharpenOpening(widget.text))),
                          _aiChip(
                              'Lift the thesis',
                              CupertinoIcons.arrow_up_circle,
                              () => _run(
                                  'Lift the thesis',
                                  () =>
                                      widget.gemini.liftThesis(widget.text))),
                          _aiChip(
                              'Cut throat-clearing',
                              CupertinoIcons.scissors,
                              () => _run(
                                  'Cut throat-clearing',
                                  () => widget.gemini
                                      .cutThroatClearing(widget.text))),
                          _aiChip(
                              'Pick up where I left off',
                              CupertinoIcons.arrow_right_circle,
                              () => _run(
                                  'Pick up where I left off',
                                  () => widget.gemini
                                      .continueWriting(widget.text))),
                        ],
                      ),
                      const SizedBox(height: 14),
                      _sectionLabel('REFRAME'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _aiChip(
                              'For a beginner',
                              null,
                              () => _run(
                                  'For a beginner',
                                  () =>
                                      widget.gemini.forBeginner(widget.text))),
                          _aiChip(
                              'For an expert',
                              null,
                              () => _run('For an expert',
                                  () => widget.gemini.forExpert(widget.text))),
                          _aiChip(
                              'Add an example',
                              null,
                              () => _run('Add an example',
                                  () => widget.gemini.addExample(widget.text))),
                          _aiChip(
                              'Steel-man the other side',
                              null,
                              () => _run('Steel-man the other side',
                                  () => widget.gemini.steelMan(widget.text))),
                        ],
                      ),
                      const SizedBox(height: 14),
                      _sectionLabel('FEEDBACK'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _aiChip(
                              'Critique honestly',
                              CupertinoIcons.chat_bubble_text,
                              () => _run(
                                  'Critique honestly',
                                  () => widget.gemini.critique(widget.text),
                                  mode: _AIMode.feedback)),
                          _aiChip(
                              "What's missing?",
                              CupertinoIcons.question_circle,
                              () => _run(
                                  "What's missing?",
                                  () =>
                                      widget.gemini.whatsMissing(widget.text),
                                  mode: _AIMode.feedback)),
                          _aiChip(
                              'Three new openings',
                              CupertinoIcons.list_number,
                              () => _run(
                                  'Three new openings',
                                  () =>
                                      widget.gemini.threeOpenings(widget.text),
                                  mode: _AIMode.feedback)),
                        ],
                      ),
                      if (_loading) ...[
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            const CupertinoActivityIndicator(radius: 8),
                            const SizedBox(width: 10),
                            Text(
                              '$_activeAction...',
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                color: widget.mutedColor,
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color: Colors.red.withValues(alpha: 0.15)),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                  CupertinoIcons.exclamationmark_triangle,
                                  size: 16,
                                  color: Colors.redAccent),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _error!,
                                  style: GoogleFonts.inter(
                                    fontSize: 13,
                                    color: Colors.redAccent,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                    if (_result != null &&
                        !_loading &&
                        _mode == _AIMode.transform &&
                        _diffSpans != null) ...[
                      Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: const Color(0xFFDC3545)
                                  .withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text('Removed',
                              style: GoogleFonts.inter(
                                  fontSize: 11, color: widget.mutedColor)),
                          const SizedBox(width: 16),
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: const Color(0xFF28A745)
                                  .withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text('Added',
                              style: GoogleFonts.inter(
                                  fontSize: 11, color: widget.mutedColor)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: widget.surfaceColor,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: widget.isDark
                                ? Colors.white.withValues(alpha: 0.06)
                                : Colors.black.withValues(alpha: 0.06),
                          ),
                        ),
                        child: RichText(
                          text: TextSpan(
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              height: 1.7,
                              color:
                                  widget.textColor.withValues(alpha: 0.85),
                            ),
                            children: _diffSpans!.map((span) {
                              switch (span.type) {
                                case _DiffType.removed:
                                  return TextSpan(
                                    text: span.text,
                                    style: TextStyle(
                                      color: widget.isDark
                                          ? const Color(0xFFFF6B6B)
                                          : const Color(0xFFDC3545),
                                      decoration:
                                          TextDecoration.lineThrough,
                                      decorationColor: widget.isDark
                                          ? const Color(0xFFFF6B6B)
                                          : const Color(0xFFDC3545),
                                      backgroundColor: widget.isDark
                                          ? const Color(0xFFDC3545)
                                              .withValues(alpha: 0.12)
                                          : const Color(0xFFDC3545)
                                              .withValues(alpha: 0.08),
                                    ),
                                  );
                                case _DiffType.added:
                                  return TextSpan(
                                    text: span.text,
                                    style: TextStyle(
                                      color: widget.isDark
                                          ? const Color(0xFF6BCB77)
                                          : const Color(0xFF28A745),
                                      backgroundColor: widget.isDark
                                          ? const Color(0xFF28A745)
                                              .withValues(alpha: 0.12)
                                          : const Color(0xFF28A745)
                                              .withValues(alpha: 0.08),
                                    ),
                                  );
                                case _DiffType.equal:
                                  return TextSpan(text: span.text);
                              }
                            }).toList(),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: CupertinoButton(
                              padding: const EdgeInsets.symmetric(
                                  vertical: 12),
                              color: const Color(0xFF28A745),
                              borderRadius: BorderRadius.circular(10),
                              onPressed: () => widget.onApply(_result!),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.center,
                                children: [
                                  const Icon(
                                      CupertinoIcons.checkmark_alt,
                                      size: 16,
                                      color: Colors.white),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Accept Changes',
                                    style: GoogleFonts.inter(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          CupertinoButton(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 12),
                            borderRadius: BorderRadius.circular(10),
                            color: widget.isDark
                                ? const Color(0xFFDC3545)
                                    .withValues(alpha: 0.15)
                                : const Color(0xFFDC3545)
                                    .withValues(alpha: 0.08),
                            onPressed: () => setState(() {
                              _result = null;
                              _diffSpans = null;
                            }),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(CupertinoIcons.xmark,
                                    size: 14,
                                    color: widget.isDark
                                        ? const Color(0xFFFF6B6B)
                                        : const Color(0xFFDC3545)),
                                const SizedBox(width: 6),
                                Text(
                                  'Decline',
                                  style: GoogleFonts.inter(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: widget.isDark
                                        ? const Color(0xFFFF6B6B)
                                        : const Color(0xFFDC3545),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (_result != null &&
                        !_loading &&
                        _mode == _AIMode.feedback) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: widget.surfaceColor,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: widget.isDark
                                ? Colors.white.withValues(alpha: 0.06)
                                : Colors.black.withValues(alpha: 0.06),
                          ),
                        ),
                        child: SelectableText(
                          _result!,
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            height: 1.7,
                            color: widget.textColor.withValues(alpha: 0.9),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      CupertinoButton(
                        padding:
                            const EdgeInsets.symmetric(vertical: 12),
                        borderRadius: BorderRadius.circular(10),
                        color: widget.surfaceColor,
                        onPressed: _reset,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(CupertinoIcons.arrow_left,
                                size: 14, color: widget.mutedColor),
                            const SizedBox(width: 8),
                            Text(
                              'Try another',
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: widget.textColor
                                    .withValues(alpha: 0.85),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) => Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: widget.mutedColor,
          letterSpacing: 1,
        ),
      );

  Widget _aiChip(String label, IconData? icon, VoidCallback onTap) {
    final isActive = _loading && _activeAction == label;
    return GestureDetector(
      onTap: _loading ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: isActive
              ? (widget.isDark
                  ? const Color(0xFF5B8DEF).withValues(alpha: 0.15)
                  : const Color(0xFF5B8DEF).withValues(alpha: 0.08))
              : widget.surfaceColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isActive
                ? const Color(0xFF5B8DEF).withValues(alpha: 0.3)
                : (widget.isDark
                    ? Colors.white.withValues(alpha: 0.06)
                    : Colors.black.withValues(alpha: 0.06)),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: widget.mutedColor),
              const SizedBox(width: 7),
            ],
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: widget.textColor.withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Word-style compact toolbar ───
const List<double> _wordFontSizes = [
  8, 9, 10, 11, 12, 14, 16, 18, 20, 22, 24, 26, 28, 36, 48, 72,
];

class _WordStyleToolbar extends StatefulWidget {
  const _WordStyleToolbar({
    required this.controller,
    required this.isDark,
    required this.textColor,
    required this.onToggleFindReplace,
    required this.findReplaceOpen,
  });

  final QuillController controller;
  final bool isDark;
  final Color textColor;
  final VoidCallback onToggleFindReplace;
  final bool findReplaceOpen;

  @override
  State<_WordStyleToolbar> createState() => _WordStyleToolbarState();
}

class _WordStyleToolbarState extends State<_WordStyleToolbar> {
  static const double _defaultSize = 12;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onSelectionChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onSelectionChanged);
    super.dispose();
  }

  void _onSelectionChanged() {
    if (mounted) setState(() {});
  }

  String get _currentFontFamily {
    final attr =
        widget.controller.getSelectionStyle().attributes[Attribute.font.key];
    if (attr?.value is String && (attr!.value as String).isNotEmpty) {
      for (final entry in _editorFonts.entries) {
        if (entry.value == attr.value) return entry.key;
      }
      return attr.value as String;
    }
    return 'Sans Serif';
  }

  double get _currentFontSize {
    final attr =
        widget.controller.getSelectionStyle().attributes[Attribute.size.key];
    final raw = attr?.value;
    if (raw == null) return _defaultSize;
    final parsed = double.tryParse(raw.toString());
    return parsed ?? _defaultSize;
  }

  void _setFontFamily(String label) {
    final family = _editorFonts[label];
    if (family == null) return;
    widget.controller.formatSelection(Attribute.fromKeyValue(
      Attribute.font.key,
      family,
    ));
    setState(() {});
  }

  void _setFontSize(double size) {
    widget.controller.formatSelection(Attribute.fromKeyValue(
      Attribute.size.key,
      size.toStringAsFixed(0),
    ));
    setState(() {});
  }

  void _stepFontSize(int direction) {
    final current = _currentFontSize;
    int idx = _wordFontSizes.indexWhere((s) => s >= current);
    if (idx < 0) idx = _wordFontSizes.length - 1;
    if (direction > 0) {
      if (_wordFontSizes[idx] == current && idx < _wordFontSizes.length - 1) {
        idx++;
      } else if (_wordFontSizes[idx] < current &&
          idx < _wordFontSizes.length - 1) {
        idx++;
      }
    } else {
      if (_wordFontSizes[idx] >= current && idx > 0) idx--;
    }
    _setFontSize(_wordFontSizes[idx]);
  }

  bool _isInlineActive(Attribute attr) {
    return widget.controller
        .getSelectionStyle()
        .attributes
        .containsKey(attr.key);
  }

  void _toggleInline(Attribute attr) {
    final active = _isInlineActive(attr);
    widget.controller
        .formatSelection(active ? Attribute.clone(attr, null) : attr);
    setState(() {});
  }

  String? _currentListValue() {
    final attr =
        widget.controller.getSelectionStyle().attributes[Attribute.list.key];
    return attr?.value as String?;
  }

  void _toggleList(String value) {
    final current = _currentListValue();
    widget.controller.formatSelection(
      current == value
          ? Attribute.clone(Attribute.list, null)
          : Attribute.fromKeyValue(Attribute.list.key, value),
    );
    setState(() {});
  }

  String? _currentAlignValue() {
    final attr =
        widget.controller.getSelectionStyle().attributes[Attribute.align.key];
    return attr?.value as String?;
  }

  void _setAlign(String value) {
    final current = _currentAlignValue();
    widget.controller.formatSelection(
      current == value
          ? Attribute.clone(Attribute.align, null)
          : Attribute.fromKeyValue(Attribute.align.key, value),
    );
    setState(() {});
  }

  int _currentIndentLevel() {
    final attr =
        widget.controller.getSelectionStyle().attributes[Attribute.indent.key];
    final value = attr?.value;
    if (value is int) return value;
    return 0;
  }

  void _stepIndent(int direction) {
    final level = _currentIndentLevel();
    final next = level + direction;
    if (next <= 0) {
      widget.controller
          .formatSelection(Attribute.clone(Attribute.indent, null));
    } else {
      widget.controller.formatSelection(Attribute.getIndentLevel(next));
    }
    setState(() {});
  }

  void _clearFormatting() {
    final selection = widget.controller.selection;
    if (!selection.isValid) return;
    final attrs =
        widget.controller.getSelectionStyle().attributes.values.toList();
    for (final a in attrs) {
      widget.controller.formatSelection(Attribute.clone(a, null));
    }
    setState(() {});
  }

  // ── Heading / paragraph style ──
  String get _currentHeadingLabel {
    final attrs = widget.controller.getSelectionStyle().attributes;
    final h = attrs[Attribute.header.key]?.value;
    if (h == 1) return 'Heading 1';
    if (h == 2) return 'Heading 2';
    if (h == 3) return 'Heading 3';
    return 'Body';
  }

  void _applyHeading(int? level) {
    if (level == null) {
      widget.controller
          .formatSelection(Attribute.clone(Attribute.header, null));
    } else if (level == 1) {
      widget.controller.formatSelection(Attribute.h1);
    } else if (level == 2) {
      widget.controller.formatSelection(Attribute.h2);
    } else if (level == 3) {
      widget.controller.formatSelection(Attribute.h3);
    }
    setState(() {});
  }

  // ── Color / highlight ──
  Color? _currentColorOf(Attribute<String?> attr) {
    final raw =
        widget.controller.getSelectionStyle().attributes[attr.key]?.value;
    if (raw is String && raw.isNotEmpty) return _hexToColor(raw);
    return null;
  }

  void _applyColor(Attribute<String?> attr, Color? color) {
    if (color == null) {
      widget.controller.formatSelection(Attribute.clone(attr, null));
    } else {
      final hex = '#${_colorToHex(color)}';
      final next = attr.key == Attribute.color.key
          ? ColorAttribute(hex)
          : BackgroundAttribute(hex);
      widget.controller.formatSelection(next);
    }
    setState(() {});
  }

  // ── Script (sub/super) ──
  String? _currentScript() {
    final attr = widget.controller
        .getSelectionStyle()
        .attributes[Attribute.script.key];
    return attr?.value as String?;
  }

  void _toggleScript(ScriptAttributes value) {
    final current = _currentScript();
    final target = value.value;
    if (current == target) {
      widget.controller
          .formatSelection(Attribute.clone(Attribute.script, null));
    } else {
      widget.controller.formatSelection(ScriptAttribute(value));
    }
    setState(() {});
  }

  // ── Link ──
  Future<void> _openLinkDialog() async {
    final selStyle = widget.controller.getSelectionStyle();
    final existing =
        selStyle.attributes[Attribute.link.key]?.value as String?;
    final selection = widget.controller.selection;
    String selectedText = '';
    if (selection.isValid && !selection.isCollapsed) {
      final start = math.min(selection.baseOffset, selection.extentOffset);
      final end = math.max(selection.baseOffset, selection.extentOffset);
      selectedText =
          widget.controller.document.getPlainText(start, end - start);
    }

    final result = await showDialog<_LinkDialogResult>(
      context: context,
      builder: (ctx) => _LinkDialog(
        initialText: selectedText,
        initialUrl: existing ?? '',
        canRemove: existing != null,
        isDark: widget.isDark,
      ),
    );
    if (result == null) return;
    if (result.remove) {
      widget.controller
          .formatSelection(Attribute.clone(Attribute.link, null));
      setState(() {});
      return;
    }
    final url = result.url.trim();
    if (url.isEmpty) return;
    if (selection.isCollapsed) {
      final insertText =
          result.text.trim().isEmpty ? url : result.text;
      final start = selection.baseOffset.clamp(
          0, widget.controller.document.length);
      widget.controller.replaceText(
        start,
        0,
        insertText,
        TextSelection.collapsed(offset: start + insertText.length),
      );
      widget.controller
          .formatText(start, insertText.length, LinkAttribute(url));
    } else {
      widget.controller.formatSelection(LinkAttribute(url));
    }
    setState(() {});
  }

  bool get _hasLink {
    return widget.controller
        .getSelectionStyle()
        .attributes
        .containsKey(Attribute.link.key);
  }

  @override
  Widget build(BuildContext context) {
    final borderColor = widget.isDark
        ? Colors.white.withValues(alpha: 0.18)
        : const Color(0xFFB8BCC4);
    final fillColor =
        widget.isDark ? const Color(0xFF2A2D33) : const Color(0xFFFAFAFA);
    final accentColor = widget.isDark
        ? const Color(0xFF93B4F5)
        : const Color(0xFF5B8DEF);
    final activeBg = widget.isDark
        ? Colors.white.withValues(alpha: 0.08)
        : const Color(0xFFE3EBFB);

    final listValue = _currentListValue();
    final alignValue = _currentAlignValue();

    Widget divider() => Container(
          width: 1,
          height: 18,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          color: borderColor,
        );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _UndoRedoButton(
              controller: widget.controller,
              undo: true,
              textColor: widget.textColor,
            ),
            _UndoRedoButton(
              controller: widget.controller,
              undo: false,
              textColor: widget.textColor,
            ),
            divider(),
            _HeadingMenu(
              current: _currentHeadingLabel,
              borderColor: borderColor,
              fillColor: fillColor,
              textColor: widget.textColor,
              onSelected: _applyHeading,
            ),
            const SizedBox(width: 6),
            _FontFamilyDropdown(
              current: _currentFontFamily,
              items: _editorFonts.keys.toList(),
              borderColor: borderColor,
              fillColor: fillColor,
              textColor: widget.textColor,
              onSelected: _setFontFamily,
            ),
            const SizedBox(width: 6),
            _FontSizeDropdown(
              current: _currentFontSize,
              items: _wordFontSizes,
              borderColor: borderColor,
              fillColor: fillColor,
              textColor: widget.textColor,
              onSelected: _setFontSize,
            ),
            const SizedBox(width: 6),
            _GrowShrinkButton(
              grow: true,
              textColor: widget.textColor,
              onPressed: () => _stepFontSize(1),
            ),
            _GrowShrinkButton(
              grow: false,
              textColor: widget.textColor,
              onPressed: () => _stepFontSize(-1),
            ),
            divider(),
            _FormatToggleButton(
              icon: Icons.format_bold,
              tooltip: 'Bold',
              isActive: _isInlineActive(Attribute.bold),
              textColor: widget.textColor,
              activeBg: activeBg,
              activeColor: accentColor,
              onPressed: () => _toggleInline(Attribute.bold),
            ),
            _FormatToggleButton(
              icon: Icons.format_italic,
              tooltip: 'Italic',
              isActive: _isInlineActive(Attribute.italic),
              textColor: widget.textColor,
              activeBg: activeBg,
              activeColor: accentColor,
              onPressed: () => _toggleInline(Attribute.italic),
            ),
            _FormatToggleButton(
              icon: Icons.format_underline,
              tooltip: 'Underline',
              isActive: _isInlineActive(Attribute.underline),
              textColor: widget.textColor,
              activeBg: activeBg,
              activeColor: accentColor,
              onPressed: () => _toggleInline(Attribute.underline),
            ),
            _FormatToggleButton(
              icon: Icons.format_strikethrough,
              tooltip: 'Strikethrough',
              isActive: _isInlineActive(Attribute.strikeThrough),
              textColor: widget.textColor,
              activeBg: activeBg,
              activeColor: accentColor,
              onPressed: () => _toggleInline(Attribute.strikeThrough),
            ),
            _FormatToggleButton(
              icon: Icons.code,
              tooltip: 'Inline code',
              isActive: _isInlineActive(Attribute.inlineCode),
              textColor: widget.textColor,
              activeBg: activeBg,
              activeColor: accentColor,
              onPressed: () => _toggleInline(Attribute.inlineCode),
            ),
            _FormatToggleButton(
              icon: Icons.subscript,
              tooltip: 'Subscript',
              isActive: _currentScript() == ScriptAttributes.sub.value,
              textColor: widget.textColor,
              activeBg: activeBg,
              activeColor: accentColor,
              onPressed: () => _toggleScript(ScriptAttributes.sub),
            ),
            _FormatToggleButton(
              icon: Icons.superscript,
              tooltip: 'Superscript',
              isActive: _currentScript() == ScriptAttributes.sup.value,
              textColor: widget.textColor,
              activeBg: activeBg,
              activeColor: accentColor,
              onPressed: () => _toggleScript(ScriptAttributes.sup),
            ),
            divider(),
            _ColorSwatchButton(
              icon: Icons.format_color_text,
              tooltip: 'Text color',
              currentColor: _currentColorOf(Attribute.color),
              textColor: widget.textColor,
              isDark: widget.isDark,
              onSelected: (c) => _applyColor(Attribute.color, c),
            ),
            _ColorSwatchButton(
              icon: Icons.format_color_fill,
              tooltip: 'Highlight',
              currentColor: _currentColorOf(Attribute.background),
              textColor: widget.textColor,
              isDark: widget.isDark,
              onSelected: (c) => _applyColor(Attribute.background, c),
            ),
            _FormatToggleButton(
              icon: Icons.link,
              tooltip: 'Insert link',
              isActive: _hasLink,
              textColor: widget.textColor,
              activeBg: activeBg,
              activeColor: accentColor,
              onPressed: _openLinkDialog,
            ),
            divider(),
            _FormatToggleButton(
              icon: Icons.format_list_bulleted,
              tooltip: 'Bulleted list',
              isActive: listValue == 'bullet',
              textColor: widget.textColor,
              activeBg: activeBg,
              activeColor: accentColor,
              onPressed: () => _toggleList('bullet'),
            ),
            _FormatToggleButton(
              icon: Icons.format_list_numbered,
              tooltip: 'Numbered list',
              isActive: listValue == 'ordered',
              textColor: widget.textColor,
              activeBg: activeBg,
              activeColor: accentColor,
              onPressed: () => _toggleList('ordered'),
            ),
            _FormatToggleButton(
              icon: Icons.checklist,
              tooltip: 'Checklist',
              isActive: listValue == 'unchecked' || listValue == 'checked',
              textColor: widget.textColor,
              activeBg: activeBg,
              activeColor: accentColor,
              onPressed: () => _toggleList('unchecked'),
            ),
            _FormatToggleButton(
              icon: Icons.format_indent_decrease,
              tooltip: 'Decrease indent',
              isActive: false,
              textColor: widget.textColor,
              activeBg: activeBg,
              activeColor: accentColor,
              onPressed: () => _stepIndent(-1),
            ),
            _FormatToggleButton(
              icon: Icons.format_indent_increase,
              tooltip: 'Increase indent',
              isActive: false,
              textColor: widget.textColor,
              activeBg: activeBg,
              activeColor: accentColor,
              onPressed: () => _stepIndent(1),
            ),
            divider(),
            _FormatToggleButton(
              icon: Icons.format_align_left,
              tooltip: 'Align left',
              isActive: alignValue == null || alignValue == 'left',
              textColor: widget.textColor,
              activeBg: activeBg,
              activeColor: accentColor,
              onPressed: () => _setAlign('left'),
            ),
            _FormatToggleButton(
              icon: Icons.format_align_center,
              tooltip: 'Align center',
              isActive: alignValue == 'center',
              textColor: widget.textColor,
              activeBg: activeBg,
              activeColor: accentColor,
              onPressed: () => _setAlign('center'),
            ),
            _FormatToggleButton(
              icon: Icons.format_align_right,
              tooltip: 'Align right',
              isActive: alignValue == 'right',
              textColor: widget.textColor,
              activeBg: activeBg,
              activeColor: accentColor,
              onPressed: () => _setAlign('right'),
            ),
            _FormatToggleButton(
              icon: Icons.format_align_justify,
              tooltip: 'Justify',
              isActive: alignValue == 'justify',
              textColor: widget.textColor,
              activeBg: activeBg,
              activeColor: accentColor,
              onPressed: () => _setAlign('justify'),
            ),
            divider(),
            _FormatToggleButton(
              icon: Icons.format_quote,
              tooltip: 'Quote',
              isActive: _isInlineActive(Attribute.blockQuote),
              textColor: widget.textColor,
              activeBg: activeBg,
              activeColor: accentColor,
              onPressed: () => _toggleInline(Attribute.blockQuote),
            ),
            _FormatToggleButton(
              icon: Icons.format_clear,
              tooltip: 'Clear formatting',
              isActive: false,
              textColor: widget.textColor,
              activeBg: activeBg,
              activeColor: accentColor,
              onPressed: _clearFormatting,
            ),
            divider(),
            _FormatToggleButton(
              icon: Icons.search,
              tooltip: 'Find & Replace (Ctrl+F)',
              isActive: widget.findReplaceOpen,
              textColor: widget.textColor,
              activeBg: activeBg,
              activeColor: accentColor,
              onPressed: widget.onToggleFindReplace,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Hex / Color helpers (local copy of flutter_quill internals) ──
Color _hexToColor(String? hexString) {
  if (hexString == null) return Colors.black;
  final hex = hexString.replaceAll('#', '');
  if (!RegExp(r'^([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$').hasMatch(hex)) {
    return Colors.black;
  }
  final buffer = StringBuffer();
  if (hex.length == 6) buffer.write('ff');
  buffer.write(hex);
  return Color(int.tryParse(buffer.toString(), radix: 16) ?? 0xFF000000);
}

String _colorToHex(Color color) {
  int toInt(double x) => (x * 255.0).round() & 0xff;
  final a = toInt(color.a);
  final r = toInt(color.r);
  final g = toInt(color.g);
  final b = toInt(color.b);
  return '${a.toRadixString(16).padLeft(2, '0')}'
          '${r.toRadixString(16).padLeft(2, '0')}'
          '${g.toRadixString(16).padLeft(2, '0')}'
          '${b.toRadixString(16).padLeft(2, '0')}'
      .toUpperCase();
}

// ── Heading menu (Body / H1 / H2 / H3) ──
class _HeadingMenu extends StatelessWidget {
  const _HeadingMenu({
    required this.current,
    required this.borderColor,
    required this.fillColor,
    required this.textColor,
    required this.onSelected,
  });

  final String current;
  final Color borderColor;
  final Color fillColor;
  final Color textColor;
  final ValueChanged<int?> onSelected;

  @override
  Widget build(BuildContext context) {
    final items = <(int?, String, double, FontWeight)>[
      (null, 'Body', 13, FontWeight.normal),
      (1, 'Heading 1', 20, FontWeight.w700),
      (2, 'Heading 2', 17, FontWeight.w700),
      (3, 'Heading 3', 14, FontWeight.w600),
    ];
    return PopupMenuButton<int?>(
      tooltip: 'Paragraph style',
      position: PopupMenuPosition.under,
      onSelected: onSelected,
      itemBuilder: (_) => items
          .map((it) => PopupMenuItem<int?>(
                value: it.$1,
                height: 38,
                child: Text(
                  it.$2,
                  style: GoogleFonts.inter(
                    fontSize: it.$3,
                    fontWeight: it.$4,
                  ),
                ),
              ))
          .toList(),
      child: Container(
        height: 28,
        width: 110,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: fillColor,
          border: Border.all(color: borderColor),
          borderRadius: BorderRadius.circular(2),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                current,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: textColor),
              ),
            ),
            Icon(Icons.arrow_drop_down, size: 18, color: textColor),
          ],
        ),
      ),
    );
  }
}

// ── Undo / Redo ──
class _UndoRedoButton extends StatefulWidget {
  const _UndoRedoButton({
    required this.controller,
    required this.undo,
    required this.textColor,
  });

  final QuillController controller;
  final bool undo;
  final Color textColor;

  @override
  State<_UndoRedoButton> createState() => _UndoRedoButtonState();
}

class _UndoRedoButtonState extends State<_UndoRedoButton> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_listener);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_listener);
    super.dispose();
  }

  void _listener() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.undo
        ? widget.controller.hasUndo
        : widget.controller.hasRedo;
    return Tooltip(
      message: widget.undo ? 'Undo (Ctrl+Z)' : 'Redo (Ctrl+Y)',
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: enabled
            ? () {
                if (widget.undo) {
                  widget.controller.undo();
                } else {
                  widget.controller.redo();
                }
              }
            : null,
        child: Container(
          width: 30,
          height: 28,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          alignment: Alignment.center,
          child: Icon(
            widget.undo ? Icons.undo : Icons.redo,
            size: 17,
            color: widget.textColor.withValues(alpha: enabled ? 1 : 0.3),
          ),
        ),
      ),
    );
  }
}

// ── Color swatch picker (text color / highlight) ──
const List<Color> _swatchColors = <Color>[
  // Row 1 — neutrals
  Color(0xFF000000), Color(0xFF434343), Color(0xFF666666),
  Color(0xFF999999), Color(0xFFCCCCCC), Color(0xFFFFFFFF),
  // Row 2 — saturated
  Color(0xFFE53935), Color(0xFFFB8C00), Color(0xFFFDD835),
  Color(0xFF43A047), Color(0xFF1E88E5), Color(0xFF8E24AA),
  // Row 3 — pastels
  Color(0xFFFFCDD2), Color(0xFFFFE0B2), Color(0xFFFFF9C4),
  Color(0xFFC8E6C9), Color(0xFFBBDEFB), Color(0xFFE1BEE7),
];

class _ColorSwatchButton extends StatelessWidget {
  const _ColorSwatchButton({
    required this.icon,
    required this.tooltip,
    required this.currentColor,
    required this.textColor,
    required this.isDark,
    required this.onSelected,
  });

  final IconData icon;
  final String tooltip;
  final Color? currentColor;
  final Color textColor;
  final bool isDark;
  final ValueChanged<Color?> onSelected;

  @override
  Widget build(BuildContext context) {
    final indicator = currentColor ??
        (icon == Icons.format_color_text
            ? textColor
            : Colors.transparent);
    return PopupMenuButton<int>(
      tooltip: tooltip,
      position: PopupMenuPosition.under,
      padding: EdgeInsets.zero,
      itemBuilder: (popupCtx) => [
        PopupMenuItem<int>(
          enabled: false,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: SizedBox(
            width: 188,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: () {
                    Navigator.pop(popupCtx);
                    onSelected(null);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        vertical: 6, horizontal: 4),
                    child: Row(
                      children: [
                        Icon(Icons.format_color_reset,
                            size: 16,
                            color: isDark ? Colors.white70 : Colors.black87),
                        const SizedBox(width: 8),
                        Text(
                          'Reset',
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            color:
                                isDark ? Colors.white70 : Colors.black87,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 10),
                for (var row = 0; row < 3; row++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        for (var col = 0; col < 6; col++)
                          GestureDetector(
                            onTap: () {
                              Navigator.pop(popupCtx);
                              onSelected(_swatchColors[row * 6 + col]);
                            },
                            child: Container(
                              width: 24,
                              height: 24,
                              margin: const EdgeInsets.all(2),
                              decoration: BoxDecoration(
                                color: _swatchColors[row * 6 + col],
                                borderRadius: BorderRadius.circular(3),
                                border: Border.all(
                                    color: Colors.black.withValues(
                                        alpha: 0.15),
                                    width: 0.5),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
      child: SizedBox(
        width: 30,
        height: 28,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Icon(icon, size: 17, color: textColor),
            Positioned(
              bottom: 3,
              left: 6,
              right: 6,
              child: Container(
                height: 3,
                decoration: BoxDecoration(
                  color: indicator,
                  borderRadius: BorderRadius.circular(1),
                  border: indicator == Colors.transparent
                      ? null
                      : Border.all(
                          color: Colors.black.withValues(alpha: 0.1),
                          width: 0.5),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Insert / edit link dialog ──
class _LinkDialogResult {
  const _LinkDialogResult({
    required this.url,
    required this.text,
    required this.remove,
  });
  final String url;
  final String text;
  final bool remove;
}

class _LinkDialog extends StatefulWidget {
  const _LinkDialog({
    required this.initialText,
    required this.initialUrl,
    required this.canRemove,
    required this.isDark,
  });

  final String initialText;
  final String initialUrl;
  final bool canRemove;
  final bool isDark;

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  late final TextEditingController _urlCtrl;
  late final TextEditingController _textCtrl;

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController(text: widget.initialUrl);
    _textCtrl = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _textCtrl.dispose();
    super.dispose();
  }

  bool get _isValid {
    final v = _urlCtrl.text.trim();
    return v.isNotEmpty && Uri.tryParse(v) != null;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    return AlertDialog(
      backgroundColor: isDark ? const Color(0xFF1C1C1E) : Colors.white,
      title: Text(
        widget.canRemove ? 'Edit Link' : 'Insert Link',
        style: GoogleFonts.inter(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: isDark ? Colors.white : Colors.black87,
        ),
      ),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _textCtrl,
              decoration: const InputDecoration(
                labelText: 'Text to display',
                isDense: true,
              ),
              style: GoogleFonts.inter(fontSize: 14),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _urlCtrl,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'URL',
                hintText: 'https://example.com',
                isDense: true,
              ),
              style: GoogleFonts.inter(fontSize: 14),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (_isValid) {
                  Navigator.pop(
                    context,
                    _LinkDialogResult(
                      url: _urlCtrl.text,
                      text: _textCtrl.text,
                      remove: false,
                    ),
                  );
                }
              },
            ),
          ],
        ),
      ),
      actions: [
        if (widget.canRemove)
          TextButton(
            onPressed: () => Navigator.pop(
              context,
              const _LinkDialogResult(url: '', text: '', remove: true),
            ),
            child: Text(
              'Remove',
              style: GoogleFonts.inter(color: Colors.redAccent),
            ),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'Cancel',
            style: GoogleFonts.inter(
              color: isDark ? Colors.white70 : Colors.black54,
            ),
          ),
        ),
        FilledButton(
          onPressed: _isValid
              ? () => Navigator.pop(
                    context,
                    _LinkDialogResult(
                      url: _urlCtrl.text,
                      text: _textCtrl.text,
                      remove: false,
                    ),
                  )
              : null,
          child: Text(widget.canRemove ? 'Update' : 'Insert'),
        ),
      ],
    );
  }
}

// ── Find & Replace bar ──
class _FindReplaceBar extends StatefulWidget {
  const _FindReplaceBar({
    required this.controller,
    required this.isDark,
    required this.textColor,
    required this.borderColor,
    required this.bgColor,
    required this.onClose,
  });

  final QuillController controller;
  final bool isDark;
  final Color textColor;
  final Color borderColor;
  final Color bgColor;
  final VoidCallback onClose;

  @override
  State<_FindReplaceBar> createState() => _FindReplaceBarState();
}

class _FindReplaceBarState extends State<_FindReplaceBar> {
  final _findCtrl = TextEditingController();
  final _replaceCtrl = TextEditingController();
  final _findFocus = FocusNode();
  bool _showReplace = false;
  bool _caseSensitive = false;
  List<int> _matches = const [];
  int _index = -1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _findFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _findCtrl.dispose();
    _replaceCtrl.dispose();
    _findFocus.dispose();
    super.dispose();
  }

  void _recompute() {
    final query = _findCtrl.text;
    if (query.isEmpty) {
      setState(() {
        _matches = const [];
        _index = -1;
      });
      return;
    }
    final text = widget.controller.document.toPlainText();
    final pattern = RegExp(
      RegExp.escape(query),
      caseSensitive: _caseSensitive,
    );
    final found = pattern.allMatches(text).map((m) => m.start).toList();
    setState(() {
      _matches = found;
      _index = found.isEmpty ? -1 : 0;
    });
    if (_index >= 0) _select(_index);
  }

  void _select(int i) {
    if (i < 0 || i >= _matches.length) return;
    final start = _matches[i];
    final len = _findCtrl.text.length;
    widget.controller.updateSelection(
      TextSelection(baseOffset: start, extentOffset: start + len),
      ChangeSource.local,
    );
  }

  void _next() {
    if (_matches.isEmpty) return;
    setState(() => _index = (_index + 1) % _matches.length);
    _select(_index);
  }

  void _prev() {
    if (_matches.isEmpty) return;
    setState(() => _index = (_index - 1 + _matches.length) % _matches.length);
    _select(_index);
  }

  void _replaceOne() {
    if (_index < 0 || _matches.isEmpty) return;
    final start = _matches[_index];
    final len = _findCtrl.text.length;
    final repl = _replaceCtrl.text;
    widget.controller.replaceText(
      start,
      len,
      repl,
      TextSelection.collapsed(offset: start + repl.length),
    );
    _recompute();
  }

  void _replaceAll() {
    if (_matches.isEmpty) return;
    final len = _findCtrl.text.length;
    final repl = _replaceCtrl.text;
    // Replace from end to start so earlier offsets stay valid.
    for (var i = _matches.length - 1; i >= 0; i--) {
      widget.controller.replaceText(_matches[i], len, repl, null);
    }
    _recompute();
  }

  @override
  Widget build(BuildContext context) {
    final mutedColor = widget.textColor.withValues(alpha: 0.55);
    final fieldFill = widget.isDark
        ? Colors.white.withValues(alpha: 0.05)
        : Colors.black.withValues(alpha: 0.03);
    final countText = _matches.isEmpty
        ? (_findCtrl.text.isEmpty ? '' : 'No results')
        : '${_index + 1} of ${_matches.length}';

    Widget field({
      required TextEditingController controller,
      required String hint,
      required FocusNode? focus,
      ValueChanged<String>? onSubmitted,
    }) {
      return Container(
        height: 32,
        decoration: BoxDecoration(
          color: fieldFill,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: widget.borderColor),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Center(
          child: TextField(
            controller: controller,
            focusNode: focus,
            onChanged: (_) {
              if (controller == _findCtrl) _recompute();
            },
            onSubmitted: onSubmitted,
            decoration: InputDecoration(
              border: InputBorder.none,
              isCollapsed: true,
              hintText: hint,
              hintStyle: GoogleFonts.inter(
                fontSize: 13,
                color: mutedColor,
              ),
            ),
            style: GoogleFonts.inter(
              fontSize: 13,
              color: widget.textColor,
            ),
          ),
        ),
      );
    }

    Widget iconBtn({
      required IconData icon,
      required String tooltip,
      VoidCallback? onTap,
      bool active = false,
    }) {
      return Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: onTap,
          child: Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active
                  ? widget.textColor.withValues(alpha: 0.08)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(
              icon,
              size: 17,
              color: onTap == null
                  ? widget.textColor.withValues(alpha: 0.25)
                  : widget.textColor.withValues(alpha: 0.85),
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: widget.bgColor,
        border: Border(
          bottom: BorderSide(color: widget.borderColor),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              iconBtn(
                icon: _showReplace
                    ? CupertinoIcons.chevron_down
                    : CupertinoIcons.chevron_right,
                tooltip:
                    _showReplace ? 'Hide replace' : 'Show replace',
                onTap: () =>
                    setState(() => _showReplace = !_showReplace),
              ),
              const SizedBox(width: 4),
              SizedBox(
                width: 240,
                child: field(
                  controller: _findCtrl,
                  hint: 'Find',
                  focus: _findFocus,
                  onSubmitted: (_) => _next(),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                countText,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: mutedColor,
                ),
              ),
              const Spacer(),
              iconBtn(
                icon: Icons.text_fields,
                tooltip: 'Match case',
                active: _caseSensitive,
                onTap: () {
                  setState(() => _caseSensitive = !_caseSensitive);
                  _recompute();
                },
              ),
              iconBtn(
                icon: CupertinoIcons.chevron_up,
                tooltip: 'Previous match',
                onTap: _matches.isEmpty ? null : _prev,
              ),
              iconBtn(
                icon: CupertinoIcons.chevron_down,
                tooltip: 'Next match',
                onTap: _matches.isEmpty ? null : _next,
              ),
              iconBtn(
                icon: CupertinoIcons.xmark,
                tooltip: 'Close (Esc)',
                onTap: widget.onClose,
              ),
            ],
          ),
          if (_showReplace) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const SizedBox(width: 34),
                SizedBox(
                  width: 240,
                  child: field(
                    controller: _replaceCtrl,
                    hint: 'Replace with',
                    focus: null,
                    onSubmitted: (_) => _replaceOne(),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _matches.isEmpty ? null : _replaceOne,
                  child: Text(
                    'Replace',
                    style: GoogleFonts.inter(fontSize: 12),
                  ),
                ),
                TextButton(
                  onPressed: _matches.isEmpty ? null : _replaceAll,
                  child: Text(
                    'Replace All',
                    style: GoogleFonts.inter(fontSize: 12),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _FormatToggleButton extends StatelessWidget {
  const _FormatToggleButton({
    required this.icon,
    required this.tooltip,
    required this.isActive,
    required this.textColor,
    required this.activeBg,
    required this.activeColor,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final bool isActive;
  final Color textColor;
  final Color activeBg;
  final Color activeColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onPressed,
        child: Container(
          width: 30,
          height: 28,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: isActive ? activeBg : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(
            icon,
            size: 17,
            color: isActive ? activeColor : textColor,
          ),
        ),
      ),
    );
  }
}

class _FontFamilyDropdown extends StatelessWidget {
  const _FontFamilyDropdown({
    required this.current,
    required this.items,
    required this.borderColor,
    required this.fillColor,
    required this.textColor,
    required this.onSelected,
  });

  final String current;
  final List<String> items;
  final Color borderColor;
  final Color fillColor;
  final Color textColor;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Font',
      position: PopupMenuPosition.under,
      onSelected: onSelected,
      itemBuilder: (_) => items
          .map((label) => PopupMenuItem<String>(
                value: label,
                height: 32,
                child: Text(
                  label,
                  style: GoogleFonts.getFont(
                    _editorFonts[label] ?? 'Inter',
                    fontSize: 13,
                  ),
                ),
              ))
          .toList(),
      child: Container(
        height: 28,
        width: 168,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: fillColor,
          border: Border.all(color: borderColor),
          borderRadius: BorderRadius.circular(2),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                current,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: textColor),
              ),
            ),
            Icon(Icons.arrow_drop_down, size: 18, color: textColor),
          ],
        ),
      ),
    );
  }
}

class _FontSizeDropdown extends StatelessWidget {
  const _FontSizeDropdown({
    required this.current,
    required this.items,
    required this.borderColor,
    required this.fillColor,
    required this.textColor,
    required this.onSelected,
  });

  final double current;
  final List<double> items;
  final Color borderColor;
  final Color fillColor;
  final Color textColor;
  final ValueChanged<double> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<double>(
      tooltip: 'Font size',
      position: PopupMenuPosition.under,
      onSelected: onSelected,
      itemBuilder: (_) => items
          .map((size) => PopupMenuItem<double>(
                value: size,
                height: 30,
                child: Text(
                  size.toStringAsFixed(0),
                  style: const TextStyle(fontSize: 13),
                ),
              ))
          .toList(),
      child: Container(
        height: 28,
        width: 56,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: fillColor,
          border: Border.all(color: borderColor),
          borderRadius: BorderRadius.circular(2),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                current.toStringAsFixed(0),
                style: TextStyle(fontSize: 13, color: textColor),
              ),
            ),
            Icon(Icons.arrow_drop_down, size: 18, color: textColor),
          ],
        ),
      ),
    );
  }
}

class _GrowShrinkButton extends StatelessWidget {
  const _GrowShrinkButton({
    required this.grow,
    required this.textColor,
    required this.onPressed,
  });

  final bool grow;
  final Color textColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: grow ? 'Grow font' : 'Shrink font',
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onPressed,
        child: SizedBox(
          width: 32,
          height: 28,
          child: Center(
            child: RichText(
              textAlign: TextAlign.center,
              text: TextSpan(
                style: TextStyle(color: textColor),
                children: [
                  TextSpan(
                    text: 'A',
                    style: TextStyle(
                      fontSize: grow ? 16 : 11,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                  WidgetSpan(
                    alignment: PlaceholderAlignment.top,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 1, top: 1),
                      child: Icon(
                        grow ? Icons.arrow_upward : Icons.arrow_downward,
                        size: 10,
                        color: textColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
