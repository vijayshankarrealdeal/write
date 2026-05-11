import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/models/footnote_model.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/provider/editor_provider.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/services/analytics_service.dart';
import 'package:inkspacex/services/api/api_payments_service.dart';
import 'package:inkspacex/services/local_notification_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:inkspacex/ui/utilities/writing_type_style.dart';
import 'package:inkspacex/ui/widgets/app_network_image.dart';
import 'package:inkspacex/ui/widgets/app_spinner.dart';
import 'package:inkspacex/ui/widgets/image_crop_page.dart';
import 'package:inkspacex/ui/widgets/type_chooser.dart';

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
  // Two-step flow: 0 = "Review chapters" (what readers will see), 1 =
  // "Details" (cover, title, description, format, tags). The author
  // confirms the content first, then dresses it up for the audience.
  // Selections + form state are kept across step changes — flipping back
  // and forth is cheap.
  int _step = 0;
  // Which publishable unit is currently shown in the right-pane preview
  // on the desktop split-view review. Initialised lazily on first build
  // so we always default to the first publishable chapter the writer
  // sees in the tree.
  String? _focusedUnitId;

  // Freestyle spaces skip type/subtype at creation; collect them at publish time.
  WritingType? _publishType;
  String _publishSubtype = '';

  bool _loadingSpace = true;
  FeedItemModel? _existingSpace;
  Set<String> _alreadyPublishedIds = {};

  // Monetization. `_isPaid` flips the flow into "set a price + pick free
  // preview chapters". Price is captured in paise to match the backend
  // column (`feed_items.price_cents`). The author can publish a paid
  // book only when `_connectStatus.chargesEnabled` is true; the UI
  // surfaces a "Set up payouts" CTA otherwise that opens the hosted
  // Razorpay activation form via `url_launcher`.
  bool _isPaid = false;
  late final TextEditingController _priceController;
  String _priceCurrency = 'inr';
  final Set<String> _freePreviewSectionIds = {};
  ConnectStatus? _connectStatus;
  bool _payoutsBusy = false;

  List<String> get _suggestedTags {
    final typeForSuggestions = _publishType ?? widget.book.writingType;
    final subtypes = typeForSuggestions == WritingType.freestyle
        ? <String>[]
        : getDisplaySubtypesForWritingType(typeForSuggestions);
    final seen = <String>{};
    final all = <String>[];
    for (final t in [
      typeForSuggestions.displayName,
      if (_publishSubtype.isNotEmpty) _publishSubtype,
      ...subtypes,
    ]) {
      // Case-insensitive dedup so 'Freestyle' and 'freestyle' don't both appear.
      if (seen.add(t.toLowerCase()) && !_tags.contains(t)) all.add(t);
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
    _priceController = TextEditingController();
    // Pre-populate publish-type for non-freestyle spaces.
    if (widget.book.writingType != WritingType.freestyle) {
      _publishType = widget.book.writingType;
      _publishSubtype = widget.book.subtype;
    }
    if (widget.preselectedSection != null) {
      _selectedSectionIds.add(widget.preselectedSection!.id);
    }
    _loadExistingSpace();
    _loadConnectStatus();
  }

  ApiPaymentsService _paymentsService() {
    final auth = context.read<AuthProvider>();
    return ApiPaymentsService(auth.apiClient);
  }

  Future<void> _loadConnectStatus() async {
    try {
      final status = await _paymentsService().getStatus();
      if (!mounted) return;
      setState(() => _connectStatus = status);
    } catch (_) {
      // Silent — the publish dialog still works for free books even
      // when the payments surface is misconfigured (the gate fires
      // server-side before any charge).
    }
  }

  Future<void> _startPayoutsOnboarding() async {
    if (_payoutsBusy) return;
    setState(() => _payoutsBusy = true);
    try {
      final url = await _paymentsService().startOnboarding();
      final ok = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!ok) throw Exception('Could not open the onboarding link.');
    } catch (e) {
      if (mounted) {
        _showAlert(
          'Razorpay setup failed',
          e.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _payoutsBusy = false);
    }
  }

  /// Parse the price field into cents. Returns 0 for an empty / unparseable
  /// field, which the publish gate uses to refuse a paid publish without
  /// silently downgrading to free.
  int get _priceCents {
    final raw = _priceController.text.trim();
    if (raw.isEmpty) return 0;
    final parsed = double.tryParse(raw);
    if (parsed == null || parsed.isNaN || parsed < 0) return 0;
    return (parsed * 100).round();
  }

  bool get _canSell =>
      _connectStatus != null && _connectStatus!.chargesEnabled;

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
          // Initial selection rules:
          //  • If sections are currently live, mirror that state so the
          //    user sees "X of N" and an unticked box becomes an explicit
          //    unpublish.
          //  • If nothing is live (brand-new book OR a previously fully-
          //    unpublished one — the common case for ingest output and
          //    for accidental empty publishes), pre-tick every section
          //    so the default action is "publish everything".
          //
          // Without the second rule, the dialog would land at "0 of N"
          // and a single Publish click would no-op (or, with the prior
          // bug, would unpublish everything that was already live).
          if (_alreadyPublishedIds.isNotEmpty) {
            _selectedSectionIds.addAll(_alreadyPublishedIds);
          } else if (widget.preselectedSection == null) {
            _selectedSectionIds.addAll(_publishableSections.map((s) => s.id));
          }
          // Hydrate pricing + preview state from the existing card so a
          // republish doesn't silently flip the book back to free or
          // wipe the author's preview curation.
          if (existing != null) {
            if (existing.priceCents > 0) {
              _isPaid = true;
              _priceController.text =
                  (existing.priceCents / 100).toStringAsFixed(2);
              _priceCurrency = existing.currency.isNotEmpty
                  ? existing.currency
                  : 'inr';
            }
            for (final s in existing.sections) {
              if (s.isFreePreview) {
                _freePreviewSectionIds.add(s.id);
              }
            }
          }
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
    _priceController.dispose();
    super.dispose();
  }

  bool get _isFreestyle => widget.book.writingType == WritingType.freestyle;
  bool get _hasCover =>
      _coverBytes != null || widget.book.coverImagePath.isNotEmpty;
  bool get _hasAnyCanvas =>
      _publishableSections.any((s) => s.canvasData.trim().isNotEmpty);

  /// Top-level publishable rows for the writer to pick from. A "unit" is
  /// the first non-container hit while walking the binder depth-first
  /// from `Manuscript` (folders/acts are containers; chapters/scenes are
  /// not). Sub-scenes nested *inside* a chapter merge into the chapter's
  /// payload at publish time — they don't appear here as independent
  /// rows. Research / Trash subtrees and any section with
  /// `includeInPublish == false` are skipped.
  ///
  /// This is what readers will see in their chapter list, in order.
  List<SectionModel> get _publishableSections => _publishableUnits;

  List<SectionModel> get _publishableUnits {
    final byParent = <String?, List<SectionModel>>{};
    for (final s in widget.book.sections) {
      byParent.putIfAbsent(s.parentId, () => <SectionModel>[]).add(s);
    }
    for (final list in byParent.values) {
      list.sort((a, b) => a.order.compareTo(b.order));
    }
    final units = <SectionModel>[];
    void walk(String? parentId) {
      final kids = byParent[parentId] ?? const <SectionModel>[];
      for (final k in kids) {
        if (k.kind == SectionKind.research ||
            k.kind == SectionKind.trash) {
          continue;
        }
        if (k.kind == SectionKind.folder || k.kind == SectionKind.act) {
          walk(k.id);
          continue;
        }
        // Chapter or scene whose parent is a container → publishable unit.
        if (!k.includeInPublish) continue;
        units.add(k);
      }
    }
    walk(null);
    return units;
  }

  /// Every chapter / scene nested under [unit] that should merge into
  /// its published Delta, in tree order. Stops at non-publishable
  /// (Research / Trash / `includeInPublish == false`) subtrees.
  List<SectionModel> _descendantsOf(SectionModel unit) {
    final byParent = <String?, List<SectionModel>>{};
    for (final s in widget.book.sections) {
      byParent.putIfAbsent(s.parentId, () => <SectionModel>[]).add(s);
    }
    for (final list in byParent.values) {
      list.sort((a, b) => a.order.compareTo(b.order));
    }
    final result = <SectionModel>[];
    void walk(String parentId) {
      final kids = byParent[parentId] ?? const <SectionModel>[];
      for (final k in kids) {
        if (k.kind == SectionKind.research ||
            k.kind == SectionKind.trash ||
            k.kind == SectionKind.folder ||
            k.kind == SectionKind.act) {
          continue;
        }
        if (!k.includeInPublish) continue;
        result.add(k);
        walk(k.id);
      }
    }
    walk(unit.id);
    return result;
  }

  /// Concatenate [unit]'s own Quill Delta with each descendant's Delta
  /// in tree order, separated by a single newline op so paragraphs
  /// stay distinct without inserting an `* * *` ornament. Author scene
  /// titles (`jello`, `hello`) never leak — they were authoring
  /// scaffolding, not body content. Malformed deltas are silently
  /// skipped so one corrupt scene doesn't poison a chapter.
  String _buildMergedContent(SectionModel unit) {
    final parts = <SectionModel>[unit, ..._descendantsOf(unit)];
    final ops = <dynamic>[];
    for (final s in parts) {
      final raw = s.content.trim();
      if (raw.isEmpty) continue;
      List<dynamic>? sectionOps;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) sectionOps = decoded;
      } catch (_) {
        continue;
      }
      if (sectionOps == null || sectionOps.isEmpty) continue;
      if (ops.isNotEmpty) {
        // One blank line between merged subsections — Quill's renderer
        // collapses consecutive newlines correctly.
        ops.add({'insert': '\n'});
      }
      ops.addAll(sectionOps);
    }
    return jsonEncode(ops);
  }

  /// Open a full-screen sheet that renders [unit]'s merged Delta in
  /// read-only Quill — exactly what the reader will see for this
  /// chapter. The author uses this to confirm the merge looks right
  /// before continuing to the details step.
  void _showChapterPreview(SectionModel unit) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF111111);
    final bgColor = isDark ? const Color(0xFF0A0A0A) : Colors.white;
    final mergedJson = _buildMergedContent(unit);
    QuillController? controller;
    try {
      final decoded = jsonDecode(mergedJson);
      if (decoded is List) {
        controller = QuillController(
          document: Document.fromJson(decoded),
          readOnly: true,
          selection: const TextSelection.collapsed(offset: 0),
        );
      }
    } catch (_) {}
    final sceneCount = _descendantsOf(unit).length;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: bgColor,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetCtx) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetCtx).height * 0.85,
            child: Column(
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 8),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: textColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 12, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Reader preview',
                              style: GoogleFonts.inter(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.0,
                                color:
                                    textColor.withValues(alpha: 0.4),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              unit.title.isEmpty
                                  ? 'Untitled'
                                  : unit.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.playfairDisplay(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: textColor,
                              ),
                            ),
                            if (sceneCount > 0)
                              Padding(
                                padding:
                                    const EdgeInsets.only(top: 2),
                                child: Text(
                                  '$sceneCount scene${sceneCount == 1 ? '' : 's'} merged inline',
                                  style: GoogleFonts.inter(
                                    fontSize: 12,
                                    color: textColor.withValues(
                                        alpha: 0.55),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: Icon(CupertinoIcons.xmark,
                            size: 18,
                            color:
                                textColor.withValues(alpha: 0.7)),
                        onPressed: () => Navigator.pop(sheetCtx),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
                    child: controller == null
                        ? Center(
                            child: Text(
                              'This chapter is empty.',
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                color:
                                    textColor.withValues(alpha: 0.5),
                              ),
                            ),
                          )
                        : QuillEditor.basic(
                            controller: controller,
                            config: const QuillEditorConfig(
                              padding: EdgeInsets.zero,
                              scrollable: true,
                              autoFocus: false,
                              expands: true,
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

  bool get _isUpdate => _existingSpace != null;
  bool get _canPublish =>
      _selectedSectionIds.isNotEmpty &&
      _hasCover &&
      (!_isFreestyle ||
          (_publishType != null && _publishSubtype.isNotEmpty));

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
    final raw = await picked.readAsBytes();
    if (!mounted) return;
    final cropped = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => ImageCropPage(
          imageBytes: raw,
          aspectRatio: 21 / 9,
          title: 'Adjust cover',
          confirmLabel: 'Use this cover',
        ),
      ),
    );
    if (cropped == null) return;
    setState(() => _coverBytes = cropped);
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
    if (_isPaid) {
      if (_priceCents <= 0) {
        _showAlert("Set a price",
            "Enter a price in ${_priceCurrency.toUpperCase()} or switch the book to free.");
        return;
      }
      if (!_canSell) {
        _showAlert(
          "Set up payouts first",
          "Finish Razorpay payouts setup before publishing a paid book. "
              "Tap 'Set up payouts' below to continue.",
        );
        return;
      }
    }

    setState(() => _isPublishing = true);
    final provider = context.read<EditorProvider>();
    final localNotifs = context.read<LocalNotificationService>();

    // Snapshot everything off the form before we tear the page down.
    final desc = _descriptionController.text.trim();
    final newTitle = _titleController.text.trim();
    final coverBytes = _coverBytes;
    // Each "section" we ship to readers is a publishable unit (top-level
    // chapter under Manuscript) with its descendant scenes merged into
    // its Delta. Author scaffolding (folder names, scene titles, scene
    // ordering metadata) never leaves this map.
    final processedSections = _publishableSections
        .where((s) => _selectedSectionIds.contains(s.id))
        .map((s) => SectionModel(
              id: s.id,
              title: s.title,
              content: _includeWriting ? _buildMergedContent(s) : '',
              canvasData: _includeCanvas ? s.canvasData : '',
              sectionColor: s.sectionColor,
              createdAt: s.createdAt,
              updatedAt: s.updatedAt,
              // Footnotes only ride the publish output when the prose
              // body is included (footnotes without their numbered
              // markers in the prose are nonsensical).
              footnotes:
                  _includeWriting ? List.of(s.footnotes) : <FootnoteModel>[],
            ))
        .toList();
    final publishedSectionIds = _selectedSectionIds.toList();
    final tagsCopy = List<String>.from(_tags);
    final freestyleType = _isFreestyle ? _publishType : null;
    final freestyleSubtype = _isFreestyle ? _publishSubtype : null;
    final isDraft = _isDraft;
    final isUpdate = _isUpdate;
    final includeCanvas = _includeCanvas;
    // Free-preview ids are only meaningful for paid books — every
    // chapter is freely readable on a free book, so we send an empty
    // list there to clear any stale flags from a prior paid publish.
    final priceCentsToSend = _isPaid ? _priceCents : 0;
    final freePreviewToSend = _isPaid
        ? _selectedSectionIds
            .where((id) => _freePreviewSectionIds.contains(id))
            .toList()
        : <String>[];
    final currencyToSend = _isPaid ? _priceCurrency : 'inr';

    // Per-publish notification tag — different books / republishes
    // get their own progress slot in the tray.
    final notifTag = 'publish:${widget.book.id}:'
        '${DateTime.now().microsecondsSinceEpoch}';

    // Kick the user back to the previous screen and show the progress
    // notification — the rest happens in the background.
    final book = widget.book;
    Navigator.pop(context);
    unawaited(localNotifs.showUploadProgress(
      tag: notifTag,
      title: isDraft ? 'Saving draft…' : 'Publishing "${book.title}"',
      body: 'Working in the background',
    ));

    unawaited(_runPublishInBackground(
      provider: provider,
      localNotifs: localNotifs,
      notifTag: notifTag,
      book: book,
      coverBytes: coverBytes,
      newTitle: newTitle,
      processedSections: processedSections,
      publishedSectionIds: publishedSectionIds,
      tags: tagsCopy,
      desc: desc,
      freestyleType: freestyleType,
      freestyleSubtype: freestyleSubtype,
      isDraft: isDraft,
      isUpdate: isUpdate,
      includeCanvas: includeCanvas,
      priceCents: priceCentsToSend,
      currency: currencyToSend,
      freePreviewSectionIds: freePreviewToSend,
    ));
  }

  Future<void> _runPublishInBackground({
    required EditorProvider provider,
    required LocalNotificationService localNotifs,
    required String notifTag,
    required WritingModel book,
    required Uint8List? coverBytes,
    required String newTitle,
    required List<SectionModel> processedSections,
    required List<String> publishedSectionIds,
    required List<String> tags,
    required String desc,
    required WritingType? freestyleType,
    required String? freestyleSubtype,
    required bool isDraft,
    required bool isUpdate,
    required bool includeCanvas,
    required int priceCents,
    required String currency,
    required List<String> freePreviewSectionIds,
  }) async {
    try {
      if (freestyleType != null) {
        book.writingType = freestyleType;
        book.subtype = freestyleSubtype ?? '';
      }

      if (coverBytes != null) {
        await localNotifs.showUploadProgress(
          tag: notifTag,
          title: isDraft ? 'Saving draft…' : 'Publishing "${book.title}"',
          body: 'Uploading cover image',
        );
        await provider.updateBookCoverImage(book, coverBytes);
      }
      if (newTitle != book.title) {
        await provider.renameBookById(book, newTitle);
      }

      await localNotifs.showUploadProgress(
        tag: notifTag,
        title: isDraft ? 'Saving draft…' : 'Publishing "${book.title}"',
        body: 'Sending ${processedSections.length} '
            'section${processedSections.length == 1 ? '' : 's'}',
      );

      await provider.publishCover(
        book,
        processedSections,
        tags: tags,
        descriptionOverride: desc.isNotEmpty ? desc : null,
        isDraft: isDraft,
        publishedSectionIds: publishedSectionIds,
        freePreviewSectionIds: freePreviewSectionIds,
        priceCents: priceCents,
        currency: currency,
      );

      AnalyticsService.instance.track(
        isDraft ? 'editor_draft_saved' : 'post_published',
        screen: '/publish',
        action: 'success',
        entityType: 'writing',
        entityId: book.id,
        properties: {
          'section_count': processedSections.length,
          'tag_count': tags.length,
          'is_update': isUpdate,
          'has_canvas': includeCanvas,
        },
      );

      await localNotifs.showUploadResult(
        tag: notifTag,
        title: isDraft ? 'Draft saved' : 'Space published',
        body: isDraft
            ? '"${book.title}" saved as a draft.'
            : isUpdate
                ? '"${book.title}" updated on the feed.'
                : '"${book.title}" is live on the feed.',
        success: true,
      );
    } catch (e) {
      AnalyticsService.instance.track(
        'post_publish_failed',
        screen: '/publish',
        action: 'fail',
        entityType: 'writing',
        entityId: book.id,
      );
      await localNotifs.showUploadResult(
        tag: notifTag,
        title: isDraft ? 'Draft save failed' : 'Publish failed',
        body: e.toString().replaceFirst('Exception: ', ''),
        success: false,
      );
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
      body: LayoutBuilder(
        builder: (context, constraints) {
          // Wide enough to host the split-view review (tree + live
          // preview side by side). Below this threshold we fall back
          // to the centered, single-column form — same UX as before
          // but the preview moves into a modal sheet behind the eye
          // icon so phone screens stay usable.
          final isWide = constraints.maxWidth >= 900;
          return Column(
            children: [
              // Top chrome (top bar + step indicator + live banner)
              // is always centered/constrained even on wide displays
              // because it's chrome, not content.
              SizedBox(height: safePad.top + 8),
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1200),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildTopBar(
                        isDark: isDark,
                        textColor: textColor,
                        mutedColor: mutedColor,
                        bgColor: bgColor,
                      ),
                      _buildStepIndicator(
                        isDark: isDark,
                        textColor: textColor,
                      ),
                      if (!_loadingSpace && _isUpdate)
                        _buildLiveBanner(
                          isDark: isDark,
                          accent: accent,
                          textColor: textColor,
                          mutedColor: mutedColor,
                        ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // Body — wide reviews stretch full screen, everything
              // else stays centered + constrained.
              Expanded(
                child: _step == 0 && isWide
                    ? _buildReviewDesktop(
                        isDark: isDark,
                        accent: accent,
                        textColor: textColor,
                        mutedColor: mutedColor,
                        dividerColor: dividerColor,
                      )
                    : SingleChildScrollView(
                        physics: const BouncingScrollPhysics(
                          parent: AlwaysScrollableScrollPhysics(),
                        ),
                        child: Center(
                          child: ConstrainedBox(
                            constraints:
                                const BoxConstraints(maxWidth: 600),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: _step == 0
                                  ? _buildReviewMobile(
                                      isDark: isDark,
                                      accent: accent,
                                      textColor: textColor,
                                      mutedColor: mutedColor,
                                    )
                                  : _buildDetailsBody(
                                      isDark: isDark,
                                      accent: accent,
                                      textColor: textColor,
                                      mutedColor: mutedColor,
                                      dividerColor: dividerColor,
                                    ),
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
          );
        },
      ),
    );
  }

  List<Widget> _buildReviewMobile({
    required bool isDark,
    required Color accent,
    required Color textColor,
    required Color mutedColor,
  }) {
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: _buildSectionsSection(
          isDark: isDark,
          accent: accent,
          textColor: textColor,
          mutedColor: mutedColor,
        ),
      ),
      const SizedBox(height: 32),
    ];
  }

  List<Widget> _buildDetailsBody({
    required bool isDark,
    required Color accent,
    required Color textColor,
    required Color mutedColor,
    required Color dividerColor,
  }) {
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: _buildCover(isDark: isDark, mutedColor: mutedColor),
      ),
      const SizedBox(height: 24),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: _buildDetailsSection(
          isDark: isDark,
          textColor: textColor,
          mutedColor: mutedColor,
        ),
      ),
      _buildDivider(dividerColor),
      if (_isFreestyle)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _buildFreestyleFormatSection(
            isDark: isDark,
            textColor: textColor,
            mutedColor: mutedColor,
            dividerColor: dividerColor,
            accent: accent,
          ),
        ),
      if (_isFreestyle) _buildDivider(dividerColor),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: _buildTagsSection(
          isDark: isDark,
          textColor: textColor,
          mutedColor: mutedColor,
        ),
      ),
      _buildDivider(dividerColor),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: _buildPricingSection(
          isDark: isDark,
          textColor: textColor,
          mutedColor: mutedColor,
          accent: accent,
        ),
      ),
      _buildDivider(dividerColor),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: _buildDraftToggle(
          isDark: isDark,
          textColor: textColor,
          mutedColor: mutedColor,
        ),
      ),
      const SizedBox(height: 32),
    ];
  }

  // ── TOP BAR ──
  Widget _buildTopBar({
    required bool isDark,
    required Color textColor,
    required Color mutedColor,
    required Color bgColor,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.06)
                      : Colors.black.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  CupertinoIcons.xmark,
                  size: 16,
                  color: mutedColor,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Text(
              _isUpdate ? "Update Space" : "Publish Space",
              style: GoogleFonts.playfairDisplay(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: textColor,
                letterSpacing: -0.3,
              ),
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }

  // ── STEP INDICATOR ──
  // Two-pill progress strip under the top bar so the writer always
  // knows which page they're on. Tappable: jumping to step 0 from
  // step 1 is harmless; jumping forward only works if the gate
  // (`_canAdvanceToDetails`) passes.
  Widget _buildStepIndicator({
    required bool isDark,
    required Color textColor,
  }) {
    // The writing-type `accent` can be pure black (freestyle), which
    // collapses against a dark page bg. Pick a neutral high-contrast
    // tint for the indicator so the active pill is always legible.
    final indicatorTint = isDark ? Colors.white : Colors.black;
    Widget pill(int index, String label) {
      final active = _step == index;
      final pillBg = active
          ? indicatorTint.withValues(alpha: isDark ? 0.10 : 0.06)
          : (isDark
              ? Colors.white.withValues(alpha: 0.04)
              : Colors.black.withValues(alpha: 0.03));
      final borderColor = active
          ? indicatorTint.withValues(alpha: isDark ? 0.30 : 0.20)
          : (isDark
              ? Colors.white.withValues(alpha: 0.10)
              : Colors.black.withValues(alpha: 0.08));
      final circleBg = active
          ? indicatorTint
          : (isDark
              ? Colors.white.withValues(alpha: 0.12)
              : Colors.black.withValues(alpha: 0.08));
      final circleFg = active
          ? (isDark ? Colors.black : Colors.white)
          : textColor.withValues(alpha: 0.7);
      return Expanded(
        child: GestureDetector(
          onTap: () {
            if (index == _step) return;
            if (index == 1 && !_canAdvanceToDetails) return;
            setState(() => _step = index);
          },
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: pillBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: borderColor),
            ),
            child: Row(
              children: [
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: circleBg,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '${index + 1}',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: circleFg,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: active
                          ? textColor
                          : textColor.withValues(alpha: 0.6),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Row(
        children: [
          pill(0, 'Review'),
          const SizedBox(width: 8),
          pill(1, 'Details'),
        ],
      ),
    );
  }

  /// True iff at least one publishable unit is selected. Required
  /// before the writer can move on to the cover/title/format step —
  /// a publish with zero chapters is meaningless.
  bool get _canAdvanceToDetails => _selectedSectionIds.isNotEmpty;

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
          borderRadius: BorderRadius.circular(16),
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
                DecoratedBox(
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
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.06)
                                : Colors.black.withValues(alpha: 0.04),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            CupertinoIcons.camera,
                            size: 18,
                            color: mutedColor,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          "Add a cover",
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: mutedColor,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          "Required to publish",
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            color: mutedColor.withValues(alpha: 0.7),
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
              "${_selectedSectionIds.length} of ${_publishableSections.length}",
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: accent,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),

        ..._publishableSections.map((section) {
          final isSelected = _selectedSectionIds.contains(section.id);
          final isLive = _alreadyPublishedIds.contains(section.id);
          final mergedCount = _descendantsOf(section).length;

          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
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
                    horizontal: 14, vertical: 13),
                decoration: BoxDecoration(
                  color: isSelected
                      ? accent.withValues(alpha: isDark ? 0.1 : 0.05)
                      : (isDark
                          ? Colors.white.withValues(alpha: 0.025)
                          : Colors.black.withValues(alpha: 0.02)),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isSelected
                        ? accent.withValues(alpha: 0.35)
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
                              if (mergedCount > 0) ...[
                                Text(
                                  '  ·  ',
                                  style: GoogleFonts.inter(
                                    fontSize: 11,
                                    color:
                                        mutedColor.withValues(alpha: 0.5),
                                  ),
                                ),
                                Text(
                                  '$mergedCount scene${mergedCount == 1 ? '' : 's'} merged',
                                  style: GoogleFonts.inter(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                    color:
                                        accent.withValues(alpha: 0.85),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _showChapterPreview(section),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        margin: const EdgeInsets.only(right: 6),
                        decoration: BoxDecoration(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.05)
                              : Colors.black.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Icon(
                          CupertinoIcons.eye,
                          size: 13,
                          color: mutedColor,
                        ),
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
          const SizedBox(height: 14),
          Row(
            children: [
              _buildIncludeChip(
                icon: CupertinoIcons.doc_text_fill,
                label: "Writing",
                active: _includeWriting,
                enabled: true,
                accent: accent,
                isDark: isDark,
                textColor: textColor,
                mutedColor: mutedColor,
                onTap: () =>
                    setState(() => _includeWriting = !_includeWriting),
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
  // ── PRICING ──
  // Free / Paid switch + price field + "Set up payouts" CTA. Author
  // also picks which already-selected chapters become the free preview
  // for a paid book — defaults to none, so a paid book starts fully
  // locked. The block disables itself for free publishes.
  Widget _buildPricingSection({
    required bool isDark,
    required Color textColor,
    required Color mutedColor,
    required Color accent,
  }) {
    final feeBps = _connectStatus?.platformFeeBps ?? 2000;
    final feePct = (feeBps / 100).toStringAsFixed(0);
    final tileBg = isDark
        ? Colors.white.withValues(alpha: 0.04)
        : Colors.black.withValues(alpha: 0.03);
    final tileBorder = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);
    final selectedUnits = _publishableSections
        .where((s) => _selectedSectionIds.contains(s.id))
        .toList();
    final price = _priceCents;
    final authorTakeCents =
        price - ((price * feeBps) / 10000).floor();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _buildSectionLabel("Pricing"),
            const Spacer(),
            CupertinoSwitch(
              value: _isPaid,
              activeTrackColor: accent,
              onChanged: (v) => setState(() => _isPaid = v),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          _isPaid
              ? "Readers pay to unlock the book. You receive their "
                  "payment minus a $feePct% platform fee, instantly into "
                  "your Razorpay balance."
              : "Free for everyone. Switch on to charge for this book.",
          style: GoogleFonts.inter(fontSize: 12, color: mutedColor),
        ),
        if (_isPaid) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: tileBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: tileBorder),
            ),
            child: Row(
              children: [
                Text(
                  _priceCurrency.toUpperCase(),
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: mutedColor,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _priceController,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                    decoration: InputDecoration(
                      hintText: '199',
                      hintStyle: GoogleFonts.inter(
                        color: mutedColor.withValues(alpha: 0.6),
                      ),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
          ),
          if (price > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                "You receive ${(authorTakeCents / 100).toStringAsFixed(2)} "
                "${_priceCurrency.toUpperCase()} per sale",
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: mutedColor,
                ),
              ),
            ),
          const SizedBox(height: 14),
          if (!_canSell)
            GestureDetector(
              onTap: _payoutsBusy ? null : _startPayoutsOnboarding,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  // Fixed amber "action-needed" tint — the writing-type
                  // accent can be pure black (freestyle), which would
                  // collapse this CTA into the dark page bg.
                  color: const Color(0xFFF59E0B)
                      .withValues(alpha: isDark ? 0.18 : 0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: const Color(0xFFF59E0B).withValues(alpha: 0.55),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(CupertinoIcons.creditcard,
                        size: 18, color: Color(0xFFF59E0B)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _payoutsBusy
                            ? "Opening Razorpay…"
                            : "Set up payouts to publish a paid book",
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: textColor,
                        ),
                      ),
                    ),
                    const Icon(CupertinoIcons.arrow_up_right_square,
                        size: 16, color: Color(0xFFF59E0B)),
                  ],
                ),
              ),
            )
          else
            Row(
              children: [
                Icon(CupertinoIcons.checkmark_seal_fill,
                    size: 16,
                    color: CupertinoColors.activeGreen),
                const SizedBox(width: 8),
                Text(
                  "Payouts ready",
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                  ),
                ),
              ],
            ),
          const SizedBox(height: 18),
          Text(
            "Free preview chapters",
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            "Tick the chapters anyone can read without buying. "
            "Untick all to lock the book entirely.",
            style: GoogleFonts.inter(fontSize: 12, color: mutedColor),
          ),
          const SizedBox(height: 8),
          if (selectedUnits.isEmpty)
            Text(
              "Select chapters in the Review step first.",
              style: GoogleFonts.inter(
                fontSize: 12,
                fontStyle: FontStyle.italic,
                color: mutedColor,
              ),
            )
          else
            Column(
              children: [
                for (final s in selectedUnits)
                  _buildFreePreviewRow(
                    section: s,
                    isDark: isDark,
                    textColor: textColor,
                    mutedColor: mutedColor,
                    accent: accent,
                  ),
              ],
            ),
        ],
      ],
    );
  }

  Widget _buildFreePreviewRow({
    required SectionModel section,
    required bool isDark,
    required Color textColor,
    required Color mutedColor,
    required Color accent,
  }) {
    final ticked = _freePreviewSectionIds.contains(section.id);
    return InkWell(
      onTap: () {
        setState(() {
          if (ticked) {
            _freePreviewSectionIds.remove(section.id);
          } else {
            _freePreviewSectionIds.add(section.id);
          }
        });
      },
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(
              ticked
                  ? CupertinoIcons.check_mark_circled_solid
                  : CupertinoIcons.circle,
              size: 18,
              color: ticked ? accent : mutedColor,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                section.title.isEmpty ? "Untitled" : section.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: textColor,
                ),
              ),
            ),
            if (ticked)
              Text(
                "FREE",
                style: GoogleFonts.inter(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: accent,
                ),
              ),
          ],
        ),
      ),
    );
  }

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

  // ── DESKTOP REVIEW (split view) ──
  // Two-pane layout: full binder tree on the left (chapters,
  // descendant scenes nested under their merge target, Research /
  // Trash dimmed for transparency about what won't ship), reader-
  // identical Quill preview of the focused chapter on the right.
  // Selecting a row in the tree updates the right pane live so the
  // writer can audit any chapter without leaving the page.
  Widget _buildReviewDesktop({
    required bool isDark,
    required Color accent,
    required Color textColor,
    required Color mutedColor,
    required Color dividerColor,
  }) {
    final units = _publishableUnits;
    // Default focus to the first publishable chapter the first time
    // this page renders. Honours the user's choice afterwards even if
    // selections shift.
    if ((_focusedUnitId == null ||
            !units.any((u) => u.id == _focusedUnitId)) &&
        units.isNotEmpty) {
      _focusedUnitId = units.first.id;
    }
    SectionModel? focused;
    for (final u in units) {
      if (u.id == _focusedUnitId) {
        focused = u;
        break;
      }
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1400),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Left pane: full binder tree ──
              SizedBox(
                width: 360,
                child: _buildBinderTreePane(
                  isDark: isDark,
                  accent: accent,
                  textColor: textColor,
                  mutedColor: mutedColor,
                  dividerColor: dividerColor,
                ),
              ),
              const SizedBox(width: 20),
              // ── Right pane: live preview of focused chapter ──
              Expanded(
                child: _buildLivePreviewPane(
                  isDark: isDark,
                  accent: accent,
                  textColor: textColor,
                  mutedColor: mutedColor,
                  dividerColor: dividerColor,
                  focused: focused,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBinderTreePane({
    required bool isDark,
    required Color accent,
    required Color textColor,
    required Color mutedColor,
    required Color dividerColor,
  }) {
    final book = widget.book;
    // Group children by parent so we can walk the tree depth-first
    // exactly the way the binder renders it.
    final byParent = <String?, List<SectionModel>>{};
    for (final s in book.sections) {
      byParent.putIfAbsent(s.parentId, () => <SectionModel>[]).add(s);
    }
    for (final list in byParent.values) {
      list.sort((a, b) => a.order.compareTo(b.order));
    }
    final rows = <Widget>[];
    void walk(String? parentId, int depth, bool inExcluded) {
      final kids = byParent[parentId] ?? const <SectionModel>[];
      for (final k in kids) {
        final isResearchOrTrash = k.kind == SectionKind.research ||
            k.kind == SectionKind.trash;
        final isContainer = k.kind == SectionKind.folder ||
            k.kind == SectionKind.act;
        final excluded = inExcluded || isResearchOrTrash;
        rows.add(_buildTreeRow(
          isDark: isDark,
          accent: accent,
          textColor: textColor,
          mutedColor: mutedColor,
          section: k,
          depth: depth,
          excluded: excluded,
        ));
        if (isContainer || isResearchOrTrash) {
          walk(k.id, depth + 1, excluded);
        } else {
          // Chapters/scenes can have nested children too — keep walking
          // so scenes nested under a chapter render under it (greyed in
          // a "merges into parent" style).
          walk(k.id, depth + 1, excluded);
        }
      }
    }
    walk(null, 0, false);
    return Container(
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.025)
            : Colors.black.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(
              children: [
                Text(
                  'BINDER',
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                    color: textColor.withValues(alpha: 0.7),
                  ),
                ),
                const Spacer(),
                Text(
                  '${_selectedSectionIds.length} / ${_publishableUnits.length}',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: textColor.withValues(alpha: 0.85),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 6),
              children: rows,
            ),
          ),
          const Divider(height: 1),
          // Writing / Canvas include toggles live in the tree pane so
          // they're visible while the writer audits.
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
            child: Row(
              children: [
                Expanded(
                  child: _buildIncludeChip(
                    icon: CupertinoIcons.doc_text_fill,
                    label: 'Writing',
                    active: _includeWriting,
                    enabled: true,
                    accent: accent,
                    isDark: isDark,
                    textColor: textColor,
                    mutedColor: mutedColor,
                    onTap: () => setState(
                        () => _includeWriting = !_includeWriting),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildIncludeChip(
                    icon: CupertinoIcons.paintbrush_fill,
                    label: 'Canvas',
                    active: _includeCanvas && _hasAnyCanvas,
                    enabled: _hasAnyCanvas,
                    accent: accent,
                    isDark: isDark,
                    textColor: textColor,
                    mutedColor: mutedColor,
                    onTap: _hasAnyCanvas
                        ? () => setState(
                            () => _includeCanvas = !_includeCanvas)
                        : null,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTreeRow({
    required bool isDark,
    required Color accent,
    required Color textColor,
    required Color mutedColor,
    required SectionModel section,
    required int depth,
    required bool excluded,
  }) {
    final isContainer = section.kind == SectionKind.folder ||
        section.kind == SectionKind.act;
    final isResearch = section.kind == SectionKind.research;
    final isTrash = section.kind == SectionKind.trash;
    final isUnit = !isContainer &&
        !isResearch &&
        !isTrash &&
        _publishableUnits.any((u) => u.id == section.id);
    final isMergedDescendant = !isContainer &&
        !isResearch &&
        !isTrash &&
        !isUnit;
    final isFocused = _focusedUnitId == section.id;
    final indent = 8 + depth * 14.0;
    Color rowColor = Colors.transparent;
    if (isFocused) {
      rowColor = accent.withValues(alpha: isDark ? 0.16 : 0.08);
    }
    // Excluded rows (Research / Trash) dim but stay legible — the writer
    // still needs to see them to understand the boundary of what *is*
    // being published.
    final fade = excluded ? 0.7 : 1.0;
    IconData icon;
    Color iconColor;
    if (isContainer) {
      icon = CupertinoIcons.book;
      iconColor = const Color(0xFF5DA0E8).withValues(alpha: fade);
    } else if (isResearch) {
      icon = CupertinoIcons.lightbulb;
      iconColor = const Color(0xFFF4C430).withValues(alpha: fade);
    } else if (isTrash) {
      icon = CupertinoIcons.trash;
      iconColor = const Color(0xFF9AA0A6).withValues(alpha: fade);
    } else if (section.kind == SectionKind.scene) {
      icon = CupertinoIcons.doc;
      iconColor = (isUnit ? textColor : mutedColor).withValues(alpha: fade);
    } else {
      icon = CupertinoIcons.doc_text;
      iconColor = (isUnit ? textColor : mutedColor).withValues(alpha: fade);
    }
    final canTap = isUnit;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: canTap
          ? () => setState(() => _focusedUnitId = section.id)
          : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        padding: EdgeInsets.fromLTRB(indent, 7, 8, 7),
        decoration: BoxDecoration(
          color: rowColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isFocused
                ? accent.withValues(alpha: 0.4)
                : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 13, color: iconColor),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    section.title.isEmpty ? 'Untitled' : section.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 12.5,
                      fontWeight: isFocused
                          ? FontWeight.w700
                          : (isUnit ? FontWeight.w600 : FontWeight.w500),
                      fontStyle:
                          isMergedDescendant ? FontStyle.italic : null,
                      color: textColor.withValues(
                          alpha: isUnit ? fade : 0.85 * fade),
                    ),
                  ),
                  if (isMergedDescendant)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        'merges into parent',
                        style: GoogleFonts.inter(
                          fontSize: 10,
                          color:
                              accent.withValues(alpha: 0.7 * fade),
                        ),
                      ),
                    ),
                  if (excluded && (isResearch || isTrash) && depth == 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        'won\'t be published',
                        style: GoogleFonts.inter(
                          fontSize: 10,
                          color: textColor.withValues(alpha: 0.55),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (isUnit)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() {
                  if (_selectedSectionIds.contains(section.id)) {
                    _selectedSectionIds.remove(section.id);
                  } else {
                    _selectedSectionIds.add(section.id);
                  }
                }),
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: _selectedSectionIds.contains(section.id)
                        ? accent
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color: _selectedSectionIds.contains(section.id)
                          ? accent
                          : mutedColor.withValues(alpha: 0.3),
                      width: 1.4,
                    ),
                  ),
                  child: _selectedSectionIds.contains(section.id)
                      ? const Icon(CupertinoIcons.checkmark,
                          size: 10, color: Colors.white)
                      : null,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLivePreviewPane({
    required bool isDark,
    required Color accent,
    required Color textColor,
    required Color mutedColor,
    required Color dividerColor,
    required SectionModel? focused,
  }) {
    if (focused == null) {
      return Container(
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.025)
              : Colors.black.withValues(alpha: 0.02),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: dividerColor),
        ),
        child: Center(
          child: Text(
            'No publishable chapters in this space yet.',
            style: GoogleFonts.inter(
              fontSize: 13,
              color: textColor.withValues(alpha: 0.5),
            ),
          ),
        ),
      );
    }
    final mergedJson = _buildMergedContent(focused);
    final descendants = _descendantsOf(focused);
    QuillController? controller;
    var hasContent = false;
    try {
      final decoded = jsonDecode(mergedJson);
      if (decoded is List) {
        hasContent = decoded.any((op) {
          if (op is! Map) return false;
          final ins = op['insert'];
          if (ins is String) return ins.trim().isNotEmpty;
          return ins != null; // embed (image / mention)
        });
        if (hasContent) {
          controller = QuillController(
            document: Document.fromJson(decoded),
            readOnly: true,
            selection: const TextSelection.collapsed(offset: 0),
          );
        }
      }
    } catch (_) {}
    return Container(
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.025)
            : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 14, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'READER PREVIEW',
                        style: GoogleFonts.inter(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.2,
                          color: textColor.withValues(alpha: 0.7),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        focused.title.isEmpty
                            ? 'Untitled'
                            : focused.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.playfairDisplay(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: textColor,
                        ),
                      ),
                      if (descendants.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            '${descendants.length} scene${descendants.length == 1 ? '' : 's'} merged inline · ${_wordCount(mergedJson)} words',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color:
                                  textColor.withValues(alpha: 0.55),
                            ),
                          ),
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            '${_wordCount(mergedJson)} words',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color:
                                  textColor.withValues(alpha: 0.55),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 18, 28, 18),
              child: controller == null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            CupertinoIcons.doc_text,
                            size: 28,
                            color: textColor.withValues(alpha: 0.35),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'Nothing to preview yet',
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: textColor.withValues(alpha: 0.8),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Add text to "${focused.title.isEmpty ? 'Untitled' : focused.title}" and it\'ll appear here.',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: textColor.withValues(alpha: 0.55),
                            ),
                          ),
                        ],
                      ),
                    )
                  : QuillEditor.basic(
                      controller: controller,
                      config: const QuillEditorConfig(
                        padding: EdgeInsets.zero,
                        scrollable: true,
                        autoFocus: false,
                        expands: true,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// Approximate word count of a Quill Delta JSON. Splits on whitespace
  /// of the inline-text inserts; image/embed inserts are skipped.
  int _wordCount(String deltaJson) {
    try {
      final ops = jsonDecode(deltaJson);
      if (ops is! List) return 0;
      final buffer = StringBuffer();
      for (final op in ops) {
        if (op is Map && op['insert'] is String) {
          buffer.write(op['insert']);
          buffer.write(' ');
        }
      }
      final words = buffer
          .toString()
          .trim()
          .split(RegExp(r'\s+'))
          .where((w) => w.isNotEmpty);
      return words.length;
    } catch (_) {
      return 0;
    }
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
          child: _step == 0
              ? _buildContinueButton(
                  isDark: isDark,
                  textColor: textColor,
                  accent: accent,
                )
              : _buildPublishRow(
                  isDark: isDark,
                  textColor: textColor,
                  accent: accent,
                ),
        ),
      ),
    );
  }

  /// Step 0 footer: a single "Continue → Details" button. Disabled when
  /// nothing's selected — no point letting the writer walk into the
  /// metadata step with an empty payload.
  Widget _buildContinueButton({
    required bool isDark,
    required Color textColor,
    required Color accent,
  }) {
    final ready = _canAdvanceToDetails;
    final btnBg = ready
        ? textColor
        : (isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.black.withValues(alpha: 0.04));
    final btnFg = ready
        ? (isDark ? Colors.black : Colors.white)
        : textColor.withValues(alpha: 0.25);
    return GestureDetector(
      onTap: ready ? () => setState(() => _step = 1) : null,
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
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Continue',
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: btnFg,
                ),
              ),
              const SizedBox(width: 6),
              Icon(CupertinoIcons.arrow_right, size: 16, color: btnFg),
            ],
          ),
        ),
      ),
    );
  }

  /// Step 1 footer: "← Back" and "Publish/Update/Save Draft" side by side.
  /// Back never strands the writer — selections persist across the hop.
  Widget _buildPublishRow({
    required bool isDark,
    required Color textColor,
    required Color accent,
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

    return Row(
      children: [
        GestureDetector(
          onTap:
              _isPublishing ? null : () => setState(() => _step = 0),
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.12)
                    : Colors.black.withValues(alpha: 0.1),
              ),
            ),
            child: Row(
              children: [
                Icon(CupertinoIcons.arrow_left,
                    size: 16, color: textColor.withValues(alpha: 0.85)),
                const SizedBox(width: 6),
                Text(
                  'Back',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: textColor.withValues(alpha: 0.85),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: GestureDetector(
            onTap: _isPublishing || !ready ? null : _publish,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
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
      ],
    );
  }

  // ── FREESTYLE FORMAT PICKER ──
  Widget _buildFreestyleFormatSection({
    required bool isDark,
    required Color textColor,
    required Color mutedColor,
    required Color dividerColor,
    required Color accent,
  }) {
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.08);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _buildSectionLabel("Format"),
            const SizedBox(width: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: CupertinoColors.activeOrange.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                "Required",
                style: GoogleFonts.inter(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: CupertinoColors.activeOrange,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          "Choose a type so readers can find your work.",
          style: GoogleFonts.inter(
            fontSize: 13,
            color: mutedColor,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 14),

        // Type cards (compact, excludes freestyle itself)
        TypeChooser(
          selected: _publishType,
          onSelect: (t) => setState(() {
            _publishType = t;
            _publishSubtype = '';
          }),
          isDark: isDark,
          compact: true,
        ),

        // Subtype pills — only shown after a type is chosen
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _publishType != null
              ? Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Subtype",
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2,
                          color: mutedColor,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: getDisplaySubtypesForWritingType(
                                _publishType!)
                            .map((s) {
                          final isSelected = _publishSubtype == s;
                          final subAccent = styleFor(_publishType!).accent;
                          return GestureDetector(
                            onTap: () =>
                                setState(() => _publishSubtype = s),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 9),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? subAccent.withValues(
                                        alpha: isDark ? 0.18 : 0.12)
                                    : (isDark
                                        ? Colors.white
                                            .withValues(alpha: 0.04)
                                        : Colors.black
                                            .withValues(alpha: 0.03)),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: isSelected
                                      ? subAccent.withValues(alpha: 0.6)
                                      : borderColor,
                                  width: isSelected ? 1.2 : 1,
                                ),
                              ),
                              child: Text(
                                s,
                                style: GoogleFonts.inter(
                                  fontSize: 13,
                                  fontWeight: isSelected
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                  color: isSelected
                                      ? (isDark
                                          ? Colors.white
                                          : Colors.black87)
                                      : textColor.withValues(alpha: 0.75),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),

        const SizedBox(height: 8),
      ],
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
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
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
    // Some writing types (freestyle) use black as accent — that disappears on a
    // dark publish surface. Fall back to textColor so the active pill always
    // contrasts.
    final activeBg = isDark ? Colors.white : Colors.black;
    final activeFg = isDark ? Colors.black : Colors.white;
    return Opacity(
      opacity: enabled ? 1.0 : 0.4,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: active
                ? activeBg
                : (isDark
                    ? Colors.white.withValues(alpha: 0.05)
                    : Colors.black.withValues(alpha: 0.04)),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: active
                  ? activeBg
                  : (isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.black.withValues(alpha: 0.06)),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 14,
                  color: active ? activeFg : mutedColor),
              const SizedBox(width: 6),
              Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  color:
                      active ? activeFg : textColor.withValues(alpha: 0.55),
                ),
              ),
              if (active) ...[
                const SizedBox(width: 4),
                Icon(CupertinoIcons.checkmark_alt, size: 12, color: activeFg),
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
