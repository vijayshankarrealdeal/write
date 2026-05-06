import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/provider/editor_provider.dart';
import 'package:inkspacex/services/multi_section_editing_session.dart';
import 'package:inkspacex/services/scrivenings_scroll_store.dart';

/// Scrivener-style "scrivenings" mode: every publishable chapter / scene
/// in the active book stitched into one continuous scroll of independently
/// editable Quill editors with section title / synopsis dividers.
///
/// Live editing model
/// ==================
/// Each section gets its own [QuillController] owned by [MultiSectionEditingSession]
/// (created in [EditorProvider.enterScrivenningsMode]). Per-section
/// QuillEditors mount lazily as the user scrolls — Flutter's ListView.builder
/// disposes off-screen children outside `cacheExtent`, and our State's
/// `dispose()` flushes any pending autosave for that section before
/// dropping the controller.
///
/// Focus drives chrome
/// ------------------
/// When a section editor receives keyboard focus, it tells the session,
/// which retargets `provider.controller` to that section's controller and
/// promotes it to `activeSection`. The toolbar, find/replace bar, floating
/// format bar, spell-check decoration, slash menu, version history, and
/// section inspector all read `provider.controller` / `activeSection` so
/// they "just work" against whichever section the cursor is in.
///
/// Cursor preservation across reorders
/// -----------------------------------
/// Sections are keyed by `ValueKey(section.id)`. When the binder reorders
/// sections, Flutter keeps the State (and its registration with the
/// session) attached to the same id, so the per-section controller —
/// including its cursor and undo stack — survives the rebuild.
///
/// Scroll position per project
/// ---------------------------
/// On scroll-settle, the scroll offset is debounced and written via
/// [ScrivenningsScrollStore] keyed by `book.id`. On view init, the stored
/// offset (if any) is restored after the first frame.
class ScrivenningsView extends StatefulWidget {
  const ScrivenningsView({
    super.key,
    required this.onJumpToSection,
    this.scrollStore = const ScrivenningsScrollStore(),
    this.bookOverride,
    this.sessionOverride,
  });

  /// Switch the surrounding editor back to Draft mode focused on the
  /// given section. Wired by the parent so this widget stays decoupled
  /// from the editor's view-mode state machine.
  final void Function(SectionModel section) onJumpToSection;

  /// Per-project scroll-position persistence backend. Injectable for
  /// tests; defaults to the SharedPreferences-backed implementation.
  final ScrivenningsScrollStore scrollStore;

  /// Direct book + session injection for widget tests, bypassing the
  /// `Consumer<EditorProvider>` setup. Production callers leave both
  /// null and the view reads from the provider tree.
  @visibleForTesting
  final WritingModel? bookOverride;
  @visibleForTesting
  final MultiSectionEditingSession? sessionOverride;

  @override
  State<ScrivenningsView> createState() => _ScrivenningsViewState();
}

class _ScrivenningsViewState extends State<ScrivenningsView> {
  late final ScrollController _scroll = ScrollController();
  Timer? _persistTimer;
  String? _restoredForBookId;
  String? _activeBookId;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _persistTimer?.cancel();
    _scroll.removeListener(_onScroll);
    _flushScrollImmediately();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_activeBookId == null) return;
    if (!_scroll.hasClients) return;
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 400), () {
      _flushScrollImmediately();
    });
  }

  void _flushScrollImmediately() {
    final bookId = _activeBookId;
    if (bookId == null) return;
    if (!_scroll.hasClients) return;
    widget.scrollStore.write(bookId, _scroll.offset);
  }

  Future<void> _restoreScrollFor(String bookId) async {
    if (_restoredForBookId == bookId) return;
    _restoredForBookId = bookId;
    final saved = await widget.scrollStore.read(bookId);
    if (!mounted) return;
    if (saved == null) return;
    // Wait one frame so the list has actual extent before we jumpTo —
    // jumpTo on an unbuilt sliver is a no-op.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_scroll.hasClients) return;
      final maxExtent = _scroll.position.maxScrollExtent;
      final clamped = saved.clamp(0.0, maxExtent);
      _scroll.jumpTo(clamped);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = theme.textTheme.bodyMedium?.color ?? Colors.black;
    final mutedColor = textColor.withValues(alpha: 0.55);
    final dividerColor = textColor.withValues(alpha: 0.08);

    final overrideBook = widget.bookOverride;
    final overrideSession = widget.sessionOverride;
    if (overrideBook != null && overrideSession != null) {
      return _buildList(overrideBook, overrideSession, isDark, textColor,
          mutedColor, dividerColor);
    }

    return Consumer<EditorProvider>(
      builder: (context, provider, _) {
        final book = provider.activeBook;
        final session = provider.multiSectionSession;
        if (book == null || session == null) {
          return const SizedBox.shrink();
        }
        return _buildList(book, session, isDark, textColor, mutedColor,
            dividerColor);
      },
    );
  }

  Widget _buildList(
    WritingModel book,
    MultiSectionEditingSession session,
    bool isDark,
    Color textColor,
    Color mutedColor,
    Color dividerColor,
  ) {
    if (_activeBookId != book.id) {
      _activeBookId = book.id;
      _restoredForBookId = null;
      unawaited(_restoreScrollFor(book.id));
    }

    final sections = _publishableSections(book);
    if (sections.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Add a chapter or scene to start writing.',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 13,
              color: mutedColor,
            ),
          ),
        ),
      );
    }
    return ListView.separated(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      itemCount: sections.length,
      // Below-the-fold sections still get a hot controller within
      // ~600px of the viewport so a nudge of the wheel doesn't pop
      // the editor. Anything beyond is unmounted and re-mounts when
      // the user scrolls back.
      cacheExtent: 600,
      addAutomaticKeepAlives: false,
      addRepaintBoundaries: true,
      separatorBuilder: (_, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Divider(color: dividerColor, height: 1),
      ),
      itemBuilder: (context, index) {
        final section = sections[index];
        return _LiveScrivenningsSection(
          key: ValueKey('scrivenings:${section.id}'),
          section: section,
          session: session,
          isDark: isDark,
          textColor: textColor,
          mutedColor: mutedColor,
          onEdit: () => widget.onJumpToSection(section),
        );
      },
    );
  }

  /// Manuscript order: every chapter / scene with `includeInPublish ==
  /// true`, sorted by `order`. Mirrors `publish_page._publishableSections`
  /// so the writer's preview matches what readers will see.
  List<SectionModel> _publishableSections(WritingModel book) {
    return book.sections
        .where((s) =>
            s.kind != SectionKind.folder &&
            s.kind != SectionKind.research &&
            s.kind != SectionKind.trash &&
            s.kind != SectionKind.act &&
            s.includeInPublish)
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));
  }
}

class _LiveScrivenningsSection extends StatefulWidget {
  const _LiveScrivenningsSection({
    required super.key,
    required this.section,
    required this.session,
    required this.isDark,
    required this.textColor,
    required this.mutedColor,
    required this.onEdit,
  });

  final SectionModel section;
  final MultiSectionEditingSession session;
  final bool isDark;
  final Color textColor;
  final Color mutedColor;
  final VoidCallback onEdit;

  @override
  State<_LiveScrivenningsSection> createState() =>
      _LiveScrivenningsSectionState();
}

class _LiveScrivenningsSectionState extends State<_LiveScrivenningsSection> {
  QuillController? _controller;
  FocusNode? _focusNode;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(covariant _LiveScrivenningsSection old) {
    super.didUpdateWidget(old);
    // Section id is stable for the same key, but if the underlying
    // SectionModel content changed externally (remote update), the
    // session's refreshSectionContent path will have already written
    // the new doc into our controller. Nothing to do here.
    if (old.session != widget.session) {
      _bind();
    }
  }

  @override
  void dispose() {
    // Defer unregister: the session is shared and cheap to keep around,
    // but we must not unregister while a build is in flight or we'd
    // tear down a controller that's still referenced by chrome reading
    // `provider.controller`. The session's `unregister` is async and
    // handles flush internally.
    final session = widget.session;
    final id = widget.section.id;
    Future.microtask(() {
      if (session.isDisposed) return;
      session.unregister(id);
    });
    super.dispose();
  }

  void _bind() {
    _controller = widget.session.register(widget.section);
    _focusNode = widget.session.focusNode(widget.section);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller!;
    final focusNode = _focusNode!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                widget.section.title.trim().isEmpty
                    ? 'Untitled'
                    : widget.section.title,
                style: GoogleFonts.inter(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: widget.textColor,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Open this section in Draft',
              icon: Icon(
                CupertinoIcons.pencil,
                size: 16,
                color: widget.mutedColor,
              ),
              onPressed: widget.onEdit,
              splashRadius: 18,
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (widget.section.synopsis.trim().isNotEmpty) ...[
          Text(
            widget.section.synopsis,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontStyle: FontStyle.italic,
              color: widget.mutedColor,
            ),
          ),
          const SizedBox(height: 12),
        ] else
          const SizedBox(height: 8),
        QuillEditor(
          controller: controller,
          focusNode: focusNode,
          scrollController: ScrollController(),
          config: const QuillEditorConfig(
            padding: EdgeInsets.zero,
            scrollable: false,
            autoFocus: false,
            expands: false,
            placeholder: 'Start writing…',
          ),
        ),
      ],
    );
  }
}
