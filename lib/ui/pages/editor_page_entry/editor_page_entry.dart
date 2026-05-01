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
import 'package:shared_preferences/shared_preferences.dart';
import 'package:inkspacex/models/editor_annotation_model.dart';
import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/provider/annotation_provider.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/provider/editor_provider.dart';
import 'package:inkspacex/provider/spell_check_provider.dart';
import 'package:inkspacex/provider/version_history_provider.dart';
import 'package:inkspacex/services/spell_check_service.dart' as spellsvc;
import 'package:inkspacex/services/analytics_service.dart';
import 'package:inkspacex/services/gemini_service.dart';
import 'package:inkspacex/ui/editor/command_palette.dart';
import 'package:inkspacex/ui/editor/floating_format_bar.dart';
import 'package:inkspacex/ui/editor/image_embed_builder.dart';
import 'package:inkspacex/ui/editor/slash_menu.dart';
import 'package:inkspacex/ui/utilities/responsive_layout.dart';
import 'package:inkspacex/ui/widgets/app_spinner.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/canvas_page/canvas_editor.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/ai_bottom_sheet.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/annotations_panel.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/comment_compose_dialog.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/editor_constants.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/find_replace_bar.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/focus_widgets.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/ruler_bar.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/side_actions_pill.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/spell_check_sheet.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/toolbar_icon_button.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/toolbar_widgets.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/version_history_widgets.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/word_style_toolbar.dart';

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
  bool _showAnnotations = false;
  bool _findReplaceOpen = false;
  // Tracks the section the AnnotationProvider is currently loaded for so we
  // only reload when the active section actually changes.
  String? _annotationSectionId;
  // Mirrors the same idea for the version-history provider, plus a Quill
  // listener handle so we can detach when the page disposes or the section
  // changes.
  String? _versionSectionId;
  VoidCallback? _docListener;
  QuillController? _listenerAttachedTo;
  String? _spellSectionId;
  PaperTheme _paperTheme = PaperTheme.defaultTheme;
  int _sessionStartWords = 0;
  bool _sessionStarted = false;
  int _dailyGoal = 500;
  bool _showGoalWidget = false;
  String? _activePrompt;
  late AnimationController _focusModeController;
  late Animation<double> _focusModeAnimation;
  SlashMenuController? _slashMenu;

  // ── Page margins (functional ruler) ──
  // Live values; dragging the ruler triangles updates these and the page
  // card padding updates synchronously. Persisted in SharedPreferences so
  // the layout the user dialed in survives reload.
  static const double _defaultMargin = 48;
  double _leftMargin = _defaultMargin;
  double _rightMargin = _defaultMargin;
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
    for (final font in editorFonts) {
      try {
        GoogleFonts.getFont(font);
      } catch (_) {}
    }
    HardwareKeyboard.instance.addHandler(_handleGlobalKey);
    _loadMargins();
  }

  // ── Margin persistence ──
  static const _kLeftMarginKey = 'editor_left_margin_v1';
  static const _kRightMarginKey = 'editor_right_margin_v1';

  Future<void> _loadMargins() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _leftMargin = prefs.getDouble(_kLeftMarginKey) ?? _defaultMargin;
      _rightMargin = prefs.getDouble(_kRightMarginKey) ?? _defaultMargin;
    });
  }

  void _setMargins(double left, double right) {
    setState(() {
      _leftMargin = left;
      _rightMargin = right;
    });
    SharedPreferences.getInstance().then((p) {
      p.setDouble(_kLeftMarginKey, left);
      p.setDouble(_kRightMarginKey, right);
    });
  }

  // Global key handler — runs even while the Quill editor has focus, where
  // a wrapping KeyboardListener with an unfocused FocusNode silently never
  // fires. Returning `true` marks the event handled so it stops bubbling.
  bool _handleGlobalKey(KeyEvent event) {
    if (!mounted) return false;
    // Don't steal keys if a dialog or sheet is on top.
    if (ModalRoute.of(context)?.isCurrent != true) return false;

    // Slash menu eats arrows / Enter / Esc when open.
    if (_slashMenu?.handleKey(event) ?? false) return true;
    if (event is! KeyDownEvent) return false;

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_findReplaceOpen) {
        setState(() => _findReplaceOpen = false);
        return true;
      }
      if (_focusMode) {
        _toggleFocusMode();
        return true;
      }
      return false;
    }

    final ctrlOrCmd = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (!ctrlOrCmd) return false;

    if (event.logicalKey == LogicalKeyboardKey.keyF && !_isCanvasMode) {
      setState(() => _findReplaceOpen = !_findReplaceOpen);
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyK) {
      _openCommandPalette();
      return true;
    }
    return false;
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
      // Capture a snapshot for the version history too — the user may
      // not return, and an idle-timer snapshot won't fire if the app is
      // suspended before the timer expires.
      final controller = context.read<EditorProvider>().controller;
      context.read<VersionHistoryProvider>().flush(controller);
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
        _initSlashMenu();
      }
    }
  }

  void _initSlashMenu() {
    _slashMenu?.dispose();
    _slashMenu = SlashMenuController(
      controller: context.read<EditorProvider>().controller,
      context: context,
      onAction: _applySlashAction,
    );
  }

  // ─── Annotations ───
  // Yellow background tint applied to the anchored range as a visual marker.
  // Quill's background attribute travels with the text through edits, so the
  // marker stays in sync without us shifting offsets.
  static const String _annotationHighlightHex = '#FFE066';

  /// Reload annotations whenever the active section changes. Called from
  /// the build method so it stays in sync with provider changes.
  void _syncAnnotationSection(SectionModel? section) {
    if (section == null) {
      if (_annotationSectionId != null) {
        _annotationSectionId = null;
        context.read<AnnotationProvider>().clear();
      }
      return;
    }
    if (_annotationSectionId == section.id) return;
    _annotationSectionId = section.id;
    final controller = context.read<EditorProvider>().controller;
    final plain = controller.document.toPlainText();
    context.read<AnnotationProvider>().loadForSection(section.id, plain);
  }

  Future<void> _addAnnotationFromSelection() async {
    final auth = context.read<AuthProvider>();
    final editor = context.read<EditorProvider>();
    final section = editor.activeSection;
    if (section == null) return;
    final controller = editor.controller;
    final selection = controller.selection;
    if (!selection.isValid || selection.isCollapsed) return;
    final start = math.min(selection.baseOffset, selection.extentOffset);
    final end = math.max(selection.baseOffset, selection.extentOffset);
    final length = end - start;
    if (length <= 0) return;
    final anchored = controller.document.getPlainText(start, length);

    final body = await showDialog<String>(
      context: context,
      builder: (ctx) => CommentComposeDialog(
        anchoredText: anchored,
        isDark: Theme.of(ctx).brightness == Brightness.dark,
      ),
    );
    if (body == null || body.trim().isEmpty || !mounted) return;

    // Make sure the provider is loaded for this section before adding.
    final ann = context.read<AnnotationProvider>();
    if (ann.sectionId != section.id) {
      ann.loadForSection(section.id, controller.document.toPlainText());
    }
    final user = auth.currentUser;
    await ann.add(
      authorId: user?.id ?? 'local',
      authorName: user?.name ?? 'You',
      body: body.trim(),
      anchorStart: start,
      anchorLength: length,
      anchoredText: anchored,
    );

    // Paint the marker. BackgroundAttribute moves with the text on edits.
    controller.formatText(
      start,
      length,
      const BackgroundAttribute(_annotationHighlightHex),
    );

    if (mounted && !_showAnnotations) {
      setState(() => _showAnnotations = true);
    }
  }

  void _jumpToAnnotation(EditorAnnotation a) {
    final controller = context.read<EditorProvider>().controller;
    final text = controller.document.toPlainText();
    int start = a.anchorStart;
    int length = a.anchorLength;
    final inBounds = start >= 0 && start + length <= text.length;
    final stillMatches = inBounds &&
        text.substring(start, start + length) == a.anchoredText;
    if (!stillMatches && a.anchoredText.isNotEmpty) {
      final found = text.indexOf(a.anchoredText);
      if (found >= 0) {
        start = found;
        length = a.anchoredText.length;
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Original text was removed from the document.')),
        );
        return;
      }
    }
    controller.updateSelection(
      TextSelection(baseOffset: start, extentOffset: start + length),
      ChangeSource.local,
    );
  }

  // ─── Version history ───
  // Auto-snapshots ride on the document's `changes` listener: every keystroke
  // resets a 30s idle timer in the provider; the snapshot fires once typing
  // stops. Section switches load that section's history; app pause flushes.

  void _syncVersionSection(SectionModel? section) {
    final vh = context.read<VersionHistoryProvider>();
    final controller = context.read<EditorProvider>().controller;
    if (section == null) {
      _detachDocListener();
      if (_versionSectionId != null) {
        _versionSectionId = null;
        vh.clear();
      }
      return;
    }
    if (_versionSectionId == section.id &&
        _listenerAttachedTo == controller) {
      return;
    }
    _versionSectionId = section.id;
    vh.loadForSection(section.id);
    _attachDocListener(controller, vh);
  }

  void _attachDocListener(QuillController controller, VersionHistoryProvider vh) {
    if (_listenerAttachedTo == controller && _docListener != null) return;
    _detachDocListener();
    void listener() {
      vh.scheduleSnapshot(controller);
    }
    controller.addListener(listener);
    _docListener = listener;
    _listenerAttachedTo = controller;
  }

  void _detachDocListener() {
    final l = _docListener;
    final c = _listenerAttachedTo;
    if (l != null && c != null) {
      c.removeListener(l);
    }
    _docListener = null;
    _listenerAttachedTo = null;
  }

  // ─── Spell check ───
  // Provider holds the current section's misspellings; the editor wires
  // it to the active QuillController on each section change. Status bar
  // surfaces the count and opens a sheet for navigation + replace.
  void _syncSpellSection(SectionModel? section) {
    final sp = context.read<SpellCheckProvider>();
    if (section == null) {
      if (_spellSectionId != null) {
        _spellSectionId = null;
        sp.detach();
      }
      return;
    }
    if (_spellSectionId == section.id) return;
    _spellSectionId = section.id;
    sp.attach(context.read<EditorProvider>().controller);
  }

  void _replaceMisspelling(spellsvc.Misspelling m, String replacement) {
    final controller = context.read<EditorProvider>().controller;
    final text = controller.document.toPlainText();
    int start = m.start;
    int length = m.length;
    final inBounds = start >= 0 && start + length <= text.length;
    final stillMatches = inBounds &&
        text.substring(start, start + length).toLowerCase() ==
            text.substring(start, start + length).toLowerCase() &&
        text.substring(start, start + length).toLowerCase().contains(
            m.word.toLowerCase());
    if (!stillMatches) {
      // Re-find by word — closest occurrence to original offset.
      final lower = text.toLowerCase();
      final candidate = lower.indexOf(m.word.toLowerCase());
      if (candidate < 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('That misspelling is no longer in the document.')),
        );
        return;
      }
      start = candidate;
      length = m.word.length;
    }
    controller.replaceText(
      start,
      length,
      replacement,
      TextSelection.collapsed(offset: start + replacement.length),
    );
  }

  void _showSpellCheckSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (sheetCtx, scroll) => SpellCheckSheet(
          scrollController: scroll,
          isDark: Theme.of(context).brightness == Brightness.dark,
          onJump: (m) {
            final controller = context.read<EditorProvider>().controller;
            controller.updateSelection(
              TextSelection(
                  baseOffset: m.start, extentOffset: m.start + m.length),
              ChangeSource.local,
            );
          },
          onReplace: _replaceMisspelling,
          onIgnore: (m) =>
              context.read<SpellCheckProvider>().ignoreWord(m.word),
        ),
      ),
    );
  }

  Future<void> _saveManualVersion() async {
    final controller = context.read<EditorProvider>().controller;
    final label = await showDialog<String>(
      context: context,
      builder: (ctx) => VersionLabelDialog(
        isDark: Theme.of(ctx).brightness == Brightness.dark,
      ),
    );
    if (label == null || !mounted) return;
    final v = await context
        .read<VersionHistoryProvider>()
        .captureManual(controller, label: label);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(v == null
            ? 'No changes since last version.'
            : 'Saved version "${label.isEmpty ? 'untitled' : label}".'),
      ),
    );
  }

  void _showVersionHistory() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (sheetCtx, scroll) => VersionHistorySheet(
          scrollController: scroll,
          isDark: Theme.of(context).brightness == Brightness.dark,
          onSaveCurrent: () async {
            Navigator.pop(sheetCtx);
            await _saveManualVersion();
          },
          onRestore: (v) async {
            final ok = await showDialog<bool>(
              context: sheetCtx,
              builder: (dctx) => AlertDialog(
                title: const Text('Restore this version?'),
                content: const Text(
                  'The current document will be saved as a new version first '
                  'so this is reversible.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dctx, false),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(dctx, true),
                    child: const Text('Restore'),
                  ),
                ],
              ),
            );
            if (ok != true || !mounted) return;
            final controller = context.read<EditorProvider>().controller;
            await context.read<VersionHistoryProvider>().restore(v, controller);
            if (!mounted) return;
            if (sheetCtx.mounted) Navigator.pop(sheetCtx);
          },
        ),
      ),
    );
  }

  Future<void> _deleteAnnotation(EditorAnnotation a) async {
    final controller = context.read<EditorProvider>().controller;
    final text = controller.document.toPlainText();
    int start = a.anchorStart;
    int length = a.anchorLength;
    final inBounds = start >= 0 && start + length <= text.length;
    final stillMatches = inBounds &&
        text.substring(start, start + length) == a.anchoredText;
    if (!stillMatches && a.anchoredText.isNotEmpty) {
      final found = text.indexOf(a.anchoredText);
      if (found >= 0) {
        start = found;
        length = a.anchoredText.length;
      } else {
        // Anchor lost — just drop the data record; nothing to repaint.
        await context.read<AnnotationProvider>().remove(a.id);
        return;
      }
    }
    // Strip the highlight tint we added on creation.
    controller.formatText(
      start,
      length,
      const BackgroundAttribute(null),
    );
    await context.read<AnnotationProvider>().remove(a.id);
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
    HardwareKeyboard.instance.removeHandler(_handleGlobalKey);
    WidgetsBinding.instance.removeObserver(this);
    _focusModeController.dispose();
    _slashMenu?.dispose();
    _detachDocListener();
    super.dispose();
  }

  // ─── Link dialog (used by floating selection bar) ───
  Future<void> _openLinkDialogShortcut() async {
    final controller = context.read<EditorProvider>().controller;
    final selection = controller.selection;
    if (!selection.isValid) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selStyle = controller.getSelectionStyle();
    final existing =
        selStyle.attributes[Attribute.link.key]?.value as String?;
    String selectedText = '';
    if (!selection.isCollapsed) {
      final start = math.min(selection.baseOffset, selection.extentOffset);
      final end = math.max(selection.baseOffset, selection.extentOffset);
      selectedText = controller.document.getPlainText(start, end - start);
    }
    final result = await showDialog<LinkDialogResult>(
      context: context,
      builder: (ctx) => LinkDialog(
        initialText: selectedText,
        initialUrl: existing ?? '',
        canRemove: existing != null,
        isDark: isDark,
      ),
    );
    if (result == null) return;
    if (result.remove) {
      controller.formatSelection(Attribute.clone(Attribute.link, null));
      return;
    }
    final url = result.url.trim();
    if (url.isEmpty) return;
    if (selection.isCollapsed) {
      final insertText = result.text.trim().isEmpty ? url : result.text;
      final start = selection.baseOffset.clamp(0, controller.document.length);
      controller.replaceText(
        start,
        0,
        insertText,
        TextSelection.collapsed(offset: start + insertText.length),
      );
      controller.formatText(start, insertText.length, LinkAttribute(url));
    } else {
      controller.formatSelection(LinkAttribute(url));
    }
  }

  // ─── Slash menu action handler ───
  void _applySlashAction(SlashAction action) {
    final controller = context.read<EditorProvider>().controller;
    switch (action) {
      case SlashAction.h1:
        controller.formatSelection(Attribute.h1);
        break;
      case SlashAction.h2:
        controller.formatSelection(Attribute.h2);
        break;
      case SlashAction.h3:
        controller.formatSelection(Attribute.h3);
        break;
      case SlashAction.body:
        controller.formatSelection(Attribute.clone(Attribute.header, null));
        break;
      case SlashAction.bullet:
        controller.formatSelection(
            Attribute.fromKeyValue(Attribute.list.key, 'bullet')!);
        break;
      case SlashAction.numbered:
        controller.formatSelection(
            Attribute.fromKeyValue(Attribute.list.key, 'ordered')!);
        break;
      case SlashAction.checklist:
        controller.formatSelection(
            Attribute.fromKeyValue(Attribute.list.key, 'unchecked')!);
        break;
      case SlashAction.quote:
        controller.formatSelection(Attribute.blockQuote);
        break;
      case SlashAction.code:
        controller.formatSelection(Attribute.codeBlock);
        break;
      case SlashAction.divider:
        final idx = controller.selection.baseOffset;
        controller.replaceText(
          idx,
          0,
          '\n———\n',
          TextSelection.collapsed(offset: idx + 5),
        );
        break;
      case SlashAction.image:
        _insertImage();
        break;
    }
  }

  // ─── Command palette (Cmd/Ctrl+K) ───
  void _openCommandPalette() {
    final controller = context.read<EditorProvider>().controller;
    final provider = context.read<EditorProvider>();

    void apply(Attribute attr) {
      controller.formatSelection(attr);
    }

    void clear(Attribute attr) {
      controller.formatSelection(Attribute.clone(attr, null));
    }

    final commands = <PaletteCommand>[
      // ── Format ──
      PaletteCommand(
        id: 'h1',
        group: 'Format',
        label: 'Heading 1',
        icon: Icons.title,
        keywords: const ['title', 'h1'],
        run: () => apply(Attribute.h1),
      ),
      PaletteCommand(
        id: 'h2',
        group: 'Format',
        label: 'Heading 2',
        icon: Icons.title,
        keywords: const ['subtitle', 'h2'],
        run: () => apply(Attribute.h2),
      ),
      PaletteCommand(
        id: 'h3',
        group: 'Format',
        label: 'Heading 3',
        icon: Icons.title,
        run: () => apply(Attribute.h3),
      ),
      PaletteCommand(
        id: 'body',
        group: 'Format',
        label: 'Body text',
        icon: Icons.notes,
        keywords: const ['paragraph'],
        run: () => clear(Attribute.header),
      ),
      PaletteCommand(
        id: 'bold',
        group: 'Format',
        label: 'Bold',
        icon: Icons.format_bold,
        shortcut: '⌘B',
        run: () => apply(Attribute.bold),
      ),
      PaletteCommand(
        id: 'italic',
        group: 'Format',
        label: 'Italic',
        icon: Icons.format_italic,
        shortcut: '⌘I',
        run: () => apply(Attribute.italic),
      ),
      PaletteCommand(
        id: 'underline',
        group: 'Format',
        label: 'Underline',
        icon: Icons.format_underline,
        shortcut: '⌘U',
        run: () => apply(Attribute.underline),
      ),
      PaletteCommand(
        id: 'strike',
        group: 'Format',
        label: 'Strikethrough',
        icon: Icons.format_strikethrough,
        run: () => apply(Attribute.strikeThrough),
      ),
      PaletteCommand(
        id: 'code',
        group: 'Format',
        label: 'Inline code',
        icon: Icons.code,
        run: () => apply(Attribute.inlineCode),
      ),
      PaletteCommand(
        id: 'quote',
        group: 'Format',
        label: 'Blockquote',
        icon: Icons.format_quote,
        run: () => apply(Attribute.blockQuote),
      ),
      PaletteCommand(
        id: 'codeblock',
        group: 'Format',
        label: 'Code block',
        icon: Icons.code,
        run: () => apply(Attribute.codeBlock),
      ),

      // ── Insert ──
      PaletteCommand(
        id: 'image',
        group: 'Insert',
        label: 'Insert image',
        icon: Icons.image,
        keywords: const ['photo', 'picture'],
        run: _insertImage,
      ),
      PaletteCommand(
        id: 'bullet',
        group: 'Insert',
        label: 'Bulleted list',
        icon: Icons.format_list_bulleted,
        run: () =>
            apply(Attribute.fromKeyValue(Attribute.list.key, 'bullet')!),
      ),
      PaletteCommand(
        id: 'numbered',
        group: 'Insert',
        label: 'Numbered list',
        icon: Icons.format_list_numbered,
        run: () =>
            apply(Attribute.fromKeyValue(Attribute.list.key, 'ordered')!),
      ),
      PaletteCommand(
        id: 'checklist',
        group: 'Insert',
        label: 'Checklist',
        icon: Icons.checklist,
        keywords: const ['todo', 'task'],
        run: () =>
            apply(Attribute.fromKeyValue(Attribute.list.key, 'unchecked')!),
      ),

      // ── View ──
      PaletteCommand(
        id: 'focus',
        group: 'View',
        label: _focusMode ? 'Exit focus mode' : 'Enter focus mode',
        icon: CupertinoIcons.eye_slash,
        keywords: const ['distraction', 'zen'],
        run: _toggleFocusMode,
      ),
      PaletteCommand(
        id: 'outline',
        group: 'View',
        label: _showOutline ? 'Hide outline' : 'Show outline',
        icon: CupertinoIcons.list_bullet_indent,
        run: () => setState(() => _showOutline = !_showOutline),
      ),
      PaletteCommand(
        id: 'find',
        group: 'View',
        label: 'Find & replace',
        icon: Icons.search,
        shortcut: '⌘F',
        run: () => setState(() => _findReplaceOpen = !_findReplaceOpen),
      ),
      PaletteCommand(
        id: 'mode',
        group: 'View',
        label: _isCanvasMode ? 'Switch to Write mode' : 'Switch to Creative mode',
        icon: _isCanvasMode ? CupertinoIcons.pencil : CupertinoIcons.paintbrush,
        run: () => _switchMode(!_isCanvasMode),
      ),
      PaletteCommand(
        id: 'sections',
        group: 'View',
        label: 'Toggle sections sidebar',
        icon: CupertinoIcons.sidebar_left,
        run: provider.toggleShowSections,
      ),
      PaletteCommand(
        id: 'prompt',
        group: 'View',
        label: 'Surface a writing prompt',
        icon: CupertinoIcons.lightbulb,
        run: _showRandomPrompt,
      ),

      // ── Actions ──
      PaletteCommand(
        id: 'newSection',
        group: 'Actions',
        label: 'New section',
        icon: CupertinoIcons.add,
        run: _promptNewSection,
      ),
      PaletteCommand(
        id: 'save',
        group: 'Actions',
        label: 'Save now',
        icon: CupertinoIcons.cloud_upload,
        shortcut: '⌘S',
        run: provider.forceSaveImmediately,
      ),
      PaletteCommand(
        id: 'ai',
        group: 'Actions',
        label: 'AI assist',
        icon: CupertinoIcons.wand_stars,
        run: _showAIPanel,
      ),

      // ── Jump to section ──
      for (final s in provider.allBooksSection)
        PaletteCommand(
          id: 'jump_${s.id}',
          group: 'Jump to section',
          label: s.title.isEmpty ? 'Untitled' : s.title,
          icon: CupertinoIcons.text_alignleft,
          keywords: const ['go', 'navigate'],
          run: () {
            provider.forceSaveImmediately();
            provider.setActiveSection(s);
            provider.initEditor();
            _initSessionTracking();
          },
        ),
    ];

    showCommandPalette(context: context, commands: commands);
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
    final picked = await picker.pickImage(source: ImageSource.gallery);
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
      builder: (ctx) => AIBottomSheet(
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
  List<OutlineHeading> _extractOutline() {
    final provider = context.read<EditorProvider>();
    final doc = provider.controller.document;
    final headings = <OutlineHeading>[];

    int offset = 0;
    for (final op in doc.toDelta().toList()) {
      final data = op.data;
      final attrs = op.attributes;
      if (data is String) {
        if (attrs != null && attrs.containsKey('header')) {
          final level = attrs['header'] as int;
          final text = data.trim();
          if (text.isNotEmpty) {
            headings.add(OutlineHeading(
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
                headings.add(OutlineHeading(
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
      _activePrompt = writingPrompts[random.nextInt(writingPrompts.length)];
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

                        const SizedBox(height: 22),
                        Text(
                          'EDITING ASSIST',
                          style: GoogleFonts.inter(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: mutedColor,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Consumer<SpellCheckProvider>(
                          builder: (_, sp, _) => _settingsToggle(
                            icon: CupertinoIcons.checkmark_seal,
                            label: 'Spell check',
                            subtitle:
                                'Underline misspellings and suggest fixes (offline)',
                            value: sp.enabled,
                            textColor: textColor,
                            mutedColor: mutedColor,
                            surfaceColor: surfaceColor,
                            isDark: isDark,
                            onChanged: (v) {
                              setSheetState(() {});
                              sp.setEnabled(v);
                            },
                          ),
                        ),

                        const SizedBox(height: 22),
                        Text(
                          'DOCUMENT',
                          style: GoogleFonts.inter(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: mutedColor,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 10),
                        InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () {
                            Navigator.pop(ctx);
                            _showVersionHistory();
                          },
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: surfaceColor,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                Icon(CupertinoIcons.clock,
                                    size: 18, color: textColor),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Version history',
                                        style: GoogleFonts.inter(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: textColor,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'Browse and restore earlier snapshots of this section',
                                        style: GoogleFonts.inter(
                                          fontSize: 11.5,
                                          color: mutedColor,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(CupertinoIcons.chevron_right,
                                    size: 14, color: mutedColor),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () {
                            Navigator.pop(ctx);
                            _saveManualVersion();
                          },
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: surfaceColor,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                Icon(CupertinoIcons.bookmark,
                                    size: 18, color: textColor),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    'Save current as named version',
                                    style: GoogleFonts.inter(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: textColor,
                                    ),
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

    // Reload annotations whenever the active section changes. Using
    // context.select keeps this rebuild-cheap — only fires when id changes.
    final activeSection =
        context.select<EditorProvider, SectionModel?>((p) => p.activeSection);
    if (activeSection?.id != _annotationSectionId ||
        activeSection?.id != _versionSectionId ||
        activeSection?.id != _spellSectionId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _syncAnnotationSection(activeSection);
        _syncVersionSection(activeSection);
        _syncSpellSection(activeSection);
      });
    }

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        context.read<EditorProvider>().forceSaveImmediately();
      },
      child: Scaffold(
        backgroundColor: bgColor,
        body: SafeArea(
          child: _isReady
              ? Stack(
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
                          // Desktop keeps the unified toolbar at the top.
                          // Mobile splits: secondary actions (image / AI /
                          // prompt / outline / focus / settings) at the
                          // top, formatting toolbar pinned to the bottom
                          // above the keyboard so it doesn't compete with
                          // the writing surface.
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
                              _buildMobileTopActions(
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
                                              FindReplaceBar(
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
                                              child: Stack(
                                                children: [
                                                  _buildEditorArea(
                                                    isDark: isDark,
                                                    bgColor: bgColor,
                                                    textColor: textColor,
                                                    isMobile: isMobile,
                                                  ),
                                                  if (!isMobile)
                                                    Positioned(
                                                      top: 0,
                                                      left: 0,
                                                      right: 0,
                                                      child: Center(
                                                        child: FloatingFormatBar(
                                                          controller: context
                                                              .read<EditorProvider>()
                                                              .controller,
                                                          isDark: isDark,
                                                          onOpenLink:
                                                              _openLinkDialogShortcut,
                                                          onAI: _showAIPanel,
                                                          onComment:
                                                              _addAnnotationFromSelection,
                                                        ),
                                                      ),
                                                    ),
                                                  // Side pill is desktop-only:
                                                  // on mobile it covered the
                                                  // writing surface, so those
                                                  // actions live in the new
                                                  // top-actions row instead.
                                                  if (!_focusMode && !isMobile)
                                                    Positioned(
                                                      top: 60,
                                                      right: 28,
                                                      child: Consumer<
                                                          AnnotationProvider>(
                                                        builder: (_, ann, _) =>
                                                            SideActionsPill(
                                                          isDark: isDark,
                                                          outlineActive:
                                                              _showOutline,
                                                          focusActive:
                                                              _focusMode,
                                                          annotationsActive:
                                                              _showAnnotations,
                                                          annotationCount:
                                                              ann.unresolvedCount,
                                                          onAI: _showAIPanel,
                                                          onPrompt:
                                                              _showRandomPrompt,
                                                          onToggleOutline: () =>
                                                              setState(() =>
                                                                  _showOutline =
                                                                      !_showOutline),
                                                          onToggleFocus:
                                                              _toggleFocusMode,
                                                          onToggleAnnotations:
                                                              () => setState(
                                                                  () => _showAnnotations =
                                                                      !_showAnnotations),
                                                        ),
                                                      ),
                                                    ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (_showAnnotations &&
                                          !isMobile &&
                                          !_focusMode)
                                        AnnotationsPanel(
                                          isDark: isDark,
                                          textColor: textColor,
                                          borderColor: borderColor,
                                          surfaceColor: surfaceColor,
                                          onJump: _jumpToAnnotation,
                                          onResolveToggle: (a) => context
                                              .read<AnnotationProvider>()
                                              .setResolved(a.id, !a.resolved),
                                          onDelete: _deleteAnnotation,
                                          onClose: () => setState(() =>
                                              _showAnnotations = false),
                                        ),
                                    ],
                                  ),
                          ),

                          // ── Mobile formatting toolbar (BOTTOM) ──
                          // Anchored above the keyboard via Scaffold's
                          // resizeToAvoidBottomInset (default true).
                          if (isMobile && !_isCanvasMode && !_focusMode)
                            _buildMobileToolbar(
                              isDark: isDark,
                              bgColor: bgColor,
                              textColor: textColor,
                              borderColor: borderColor,
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
                            child: FocusExitButton(
                              isDark: isDark,
                              onTap: _toggleFocusMode,
                            ),
                          ),
                        ),

                    ],
                  )
              : const Center(child: AppSpinner(size: 28)),
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
                          const AppSpinner(size: 12),
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
                    const AppSpinner(size: 12)
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
            ToolbarIconButton(
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
          ToolbarIconButton(
            iconWidget: Iconify(
              Ph.google_photos_logo_bold,
              size: 19,
              color: textColor,
            ),
            tooltip: 'Insert Image',
            color: textColor,
            onPressed: _insertImage,
          ),

          // Sections sidebar toggle — paired with the image insert so the
          // top bar stays focused on title + status + new section.
          ToolbarIconButton(
            icon: context.select<EditorProvider, bool>(
                    (p) => p.showSectionsList)
                ? CupertinoIcons.sidebar_left
                : CupertinoIcons.sidebar_right,
            tooltip: 'Toggle sections sidebar',
            color: textColor,
            onPressed: () =>
                context.read<EditorProvider>().toggleShowSections(),
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

          // Writer Settings (paper themes / typewriter / goal etc.)
          // Outline / Prompt / Focus mode / AI live in the side pill —
          // keeping them here too creates the "wall of icons" feel.
          ToolbarIconButton(
            icon: CupertinoIcons.slider_horizontal_3,
            tooltip: 'Writer Settings',
            color: textColor,
            onPressed: _showWriterSettings,
          ),
        ],
      ),
    );
  }

  // ─── Mobile bottom toolbar (formatting only) ───
  // Pinned to the bottom of the body. Image / AI / prompt / outline /
  // focus / settings live in `_buildMobileTopActions` so this row is
  // pure text formatting — comfortable to thumb while typing.
  Widget _buildMobileToolbar({
    required bool isDark,
    required Color bgColor,
    required Color textColor,
    required Color borderColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(top: BorderSide(color: borderColor)),
      ),
      child: _buildQuillToolbar(isDark: isDark, textColor: textColor),
    );
  }

  // ─── Mobile top secondary actions ───
  // Sits between the top bar and the editor. Holds the actions that
  // were previously duplicated in the side pill plus the image insert.
  Widget _buildMobileTopActions({
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
          ToolbarIconButton(
            iconWidget: Iconify(
              Ph.google_photos_logo_bold,
              size: 19,
              color: textColor,
            ),
            tooltip: 'Insert Image',
            color: textColor,
            onPressed: _insertImage,
          ),
          ToolbarIconButton(
            icon: CupertinoIcons.sidebar_right,
            tooltip: 'Sections',
            color: textColor,
            onPressed: () => _showSectionsSheet(
              isDark: isDark,
              textColor: textColor,
              borderColor: borderColor,
            ),
          ),
          Container(
            width: 1,
            height: 20,
            margin: const EdgeInsets.symmetric(horizontal: 6),
            color: borderColor,
          ),
          const Spacer(),
          ToolbarIconButton(
            icon: CupertinoIcons.wand_stars,
            tooltip: 'AI assist',
            color: accentColor,
            onPressed: _showAIPanel,
          ),
          ToolbarIconButton(
            icon: CupertinoIcons.lightbulb,
            tooltip: 'Writing prompt',
            color: Colors.amber.withValues(alpha: 0.85),
            onPressed: _showRandomPrompt,
          ),
          ToolbarIconButton(
            icon: CupertinoIcons.list_bullet_indent,
            tooltip: _showOutline ? 'Hide outline' : 'Show outline',
            color: _showOutline ? accentColor : textColor,
            onPressed: () =>
                setState(() => _showOutline = !_showOutline),
          ),
          ToolbarIconButton(
            icon: CupertinoIcons.eye_slash,
            tooltip: 'Focus mode',
            color: textColor,
            onPressed: _toggleFocusMode,
          ),
          ToolbarIconButton(
            icon: CupertinoIcons.slider_horizontal_3,
            tooltip: 'Writer settings',
            color: textColor,
            onPressed: _showWriterSettings,
          ),
        ],
      ),
    );
  }

  // ─── Quill Toolbar (compact, Word-style) ───
  Widget _buildQuillToolbar({required bool isDark, required Color textColor}) {
    final controller = context.read<EditorProvider>().controller;
    return WordStyleToolbar(
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

    final showRuler = !isMobile && !_focusMode;
    final padL = isMobile ? 18.0 : (_focusMode ? 64.0 : _leftMargin);
    final padR = isMobile ? 18.0 : (_focusMode ? 64.0 : _rightMargin);

    return Container(
      color: bgColor,
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: _focusMode ? 760 : 820),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            isMobile ? 0 : (_focusMode ? 24 : 20),
            isMobile ? 0 : (_focusMode ? 24 : 12),
            isMobile ? 0 : (_focusMode ? 24 : 20),
            isMobile ? 0 : (_focusMode ? 24 : 0),
          ),
          child: Column(
            children: [
              if (showRuler)
                RulerBar(
                  isDark: isDark,
                  leftMargin: _leftMargin,
                  rightMargin: _rightMargin,
                  onChanged: _setMargins,
                ),
              Expanded(
                child: _buildPageCard(
                  isDark: isDark,
                  isMobile: isMobile,
                  padL: padL,
                  padR: padR,
                  paperColor: paperColor,
                  paperBorder: paperBorder,
                  focusBorder: focusBorder,
                  themedTextColor: themedTextColor,
                ),
              ),
              if (_focusMode)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: FadeTransition(
                    opacity: _focusModeAnimation,
                    child: FocusWordCounter(
                      isDark: isDark,
                      sessionStart: _sessionStartWords,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPageCard({
    required bool isDark,
    required bool isMobile,
    required double padL,
    required double padR,
    required Color paperColor,
    required Color paperBorder,
    required Color focusBorder,
    required Color themedTextColor,
  }) {
    return Container(
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
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: paperBorder),
                  // Soft floating-paper shadow — sells the page metaphor
                  // without the high-contrast slab Material defaults to.
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                          alpha: isDark ? 0.35 : 0.08),
                      blurRadius: 32,
                      spreadRadius: -10,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
      padding: EdgeInsets.fromLTRB(
        padL,
        _focusMode ? (isMobile ? 56 : 96) : 20,
        padR,
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
        return cachedFontStyle(name);
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
              // Right: spell-check chip + session + optional mode badge
              Consumer<SpellCheckProvider>(
                builder: (_, sp, _) {
                  if (!sp.enabled) return const SizedBox.shrink();
                  final issues = sp.issues.length;
                  final color = issues == 0
                      ? Colors.green.withValues(alpha: 0.55)
                      : const Color(0xFFE26A4A).withValues(alpha: 0.85);
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: issues == 0 ? null : _showSpellCheckSheet,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            issues == 0
                                ? CupertinoIcons.checkmark_seal
                                : CupertinoIcons.exclamationmark_circle,
                            size: 11,
                            color: color,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            issues == 0
                                ? 'No issues'
                                : '$issues issue${issues == 1 ? '' : 's'}',
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              color: color,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              if (sessionWidget != null || _typewriterMode) ...[
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
