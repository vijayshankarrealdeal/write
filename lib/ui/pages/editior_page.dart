import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:writer/provider/editor_provider.dart';
import 'package:writer/ui/utilities/responsive_layout.dart';

class EditiorPage extends StatefulWidget {
  const EditiorPage({super.key});

  @override
  State<EditiorPage> createState() => _EditiorPageState();
}

class _EditiorPageState extends State<EditiorPage> with WidgetsBindingObserver {
  bool _isReady = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      context.read<EditorProvider>().forceSaveImmediately();
    }
  }

  void _routeAnimationListener(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      ModalRoute.of(
        context,
      )?.animation?.removeStatusListener(_routeAnimationListener);
      context.read<EditorProvider>().initEditor();
      if (mounted) setState(() => _isReady = true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF010101) : const Color(0xFFFAFAFA);
    final sidebarColor = isDark
        ? const Color(0xFF121212)
        : const Color(0xFFF0F0F3);
    final textColor = isDark ? Colors.white : Colors.black;
    final subtleBorder = isDark
        ? Colors.white.withAlpha(25)
        : Colors.black.withAlpha(25);

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        context.read<EditorProvider>().forceSaveImmediately();
      },
      child: Scaffold(
        backgroundColor: bgColor,
        floatingActionButton:
            Breakpoints.isMobile(MediaQuery.sizeOf(context).width)
            ? Padding(
                padding: const EdgeInsets.only(bottom: 64),
                child: FloatingActionButton(
                  onPressed: () {
                    final provider = context.read<EditorProvider>();
                    _showTextInputDialog(
                      context: context,
                      title: "New Section Name",
                      initialValue:
                          "Section ${provider.allBooksSection.length + 1}",
                      onSave: (val) =>
                          provider.addSection(val, autoSelect: true),
                    );
                  },
                  backgroundColor: isDark ? Colors.white : Colors.black87,
                  foregroundColor: isDark ? Colors.black : Colors.white,
                  child: const Icon(CupertinoIcons.add, size: 28),
                ),
              )
            : null,
        body: SafeArea(
          bottom: false,
          child: _isReady
              ? Column(
                  children: [
                    // --- UNIFIED SOLID TOOLBAR ---
                    Container(
                      height: 56, // Standard solid toolbar height
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: bgColor, // Solid flat color
                        border: Border(
                          bottom: BorderSide(color: subtleBorder),
                        ), // Clean bottom edge
                      ),
                      child: Row(
                        children: [
                          // 1. LEFT: Navigation & Sidebar
                          const SizedBox(width: 8),
                          IconButton(
                            icon: Icon(
                              Icons.arrow_back,
                              size: 20,
                              color: textColor,
                            ),
                            onPressed: () {
                              context
                                  .read<EditorProvider>()
                                  .forceSaveImmediately();
                              Navigator.pop(context);
                            },
                          ),
                          if (Breakpoints.isMobile(
                            MediaQuery.sizeOf(context).width,
                          ))
                            IconButton(
                              icon: Icon(
                                CupertinoIcons.list_bullet,
                                size: 20,
                                color: textColor,
                              ),
                              tooltip: "All Sections",
                              onPressed: () => _showSectionsSheet(
                                context,
                                textColor,
                                isDark,
                                subtleBorder,
                                sidebarColor,
                              ),
                            ),
                          if (!Breakpoints.isMobile(
                            MediaQuery.sizeOf(context).width,
                          ))
                            IconButton(
                              icon: Icon(
                                context.select<EditorProvider, bool>(
                                      (p) => p.showSectionsList,
                                    )
                                    ? CupertinoIcons.sidebar_left
                                    : CupertinoIcons.sidebar_right,
                                size: 20,
                                color: textColor,
                              ),
                              tooltip: "Toggle Sidebar",
                              onPressed: () => context
                                  .read<EditorProvider>()
                                  .toggleShowSections(),
                            ),

                          // Vertical Separator
                          if (!Breakpoints.isMobile(
                            MediaQuery.sizeOf(context).width,
                          ))
                            Container(
                              width: 1,
                              height: 24,
                              margin: const EdgeInsets.symmetric(horizontal: 8),
                              color: subtleBorder,
                            ),

                          // 2. CENTER: Ask AI (desktop) or spacer (mobile - AI moved to right)
                          Expanded(
                            child:
                                Breakpoints.isMobile(
                                  MediaQuery.sizeOf(context).width,
                                )
                                ? const SizedBox.shrink()
                                : Row(
                                    children: [
                                      // Ask AI Button
                                      CupertinoButton(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                        ),
                                        onPressed: () {
                                          // Trigger AI
                                        },
                                        child: Row(
                                          children: [
                                            Icon(
                                              CupertinoIcons.sparkles,
                                              size: 16,
                                              color: isDark
                                                  ? Colors.purpleAccent
                                                  : Colors.deepPurple,
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              "Ask AI",
                                              style: GoogleFonts.inter(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                                color: isDark
                                                    ? Colors.white
                                                    : Colors.black,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),

                                      // Vertical Separator
                                      Container(
                                        width: 1,
                                        height: 24,
                                        margin: const EdgeInsets.only(right: 8),
                                        color: subtleBorder,
                                      ),

                                      // Quill Toolbar (Takes remaining space and scrolls itself)
                                      Expanded(
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: isDark
                                                ? Colors.white.withValues(
                                                    alpha: 0.05,
                                                  )
                                                : Colors.black.withValues(
                                                    alpha: 0.04,
                                                  ),
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                          ),
                                          clipBehavior: Clip.antiAlias,
                                          child: LayoutBuilder(
                                            builder: (context, constraints) {
                                              final w =
                                                  constraints.maxWidth > 400
                                                  ? constraints.maxWidth
                                                  : 400.0;
                                              return SingleChildScrollView(
                                                scrollDirection:
                                                    Axis.horizontal,
                                                child: SizedBox(
                                                  width: w,
                                                  child: QuillSimpleToolbar(
                                                    controller: context
                                                        .read<EditorProvider>()
                                                        .controller,
                                                    config: QuillSimpleToolbarConfig(
                                                      multiRowsDisplay: false,
                                                      showAlignmentButtons:
                                                          true,
                                                      showCenterAlignment: true,
                                                      showLink: false,
                                                      showInlineCode: false,
                                                      showSearchButton: false,
                                                      buttonOptions: QuillSimpleToolbarButtonOptions(
                                                        base: QuillToolbarBaseButtonOptions(
                                                          iconTheme: QuillIconTheme(
                                                            iconButtonSelectedData: IconButtonData(
                                                              style: IconButton.styleFrom(
                                                                backgroundColor:
                                                                    Colors.blue
                                                                        .withValues(
                                                                          alpha:
                                                                              0.1,
                                                                        ),
                                                                foregroundColor:
                                                                    Colors.blue,
                                                                shape:
                                                                    const CircleBorder(),
                                                              ),
                                                              color:
                                                                  Colors.blue,
                                                            ),
                                                            iconButtonUnselectedData:
                                                                IconButtonData(
                                                                  style: IconButton.styleFrom(
                                                                    shape:
                                                                        const CircleBorder(),
                                                                  ),
                                                                ),
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                          ),

                          // Vertical Separator
                          Container(
                            width: 1,
                            height: 24,
                            margin: const EdgeInsets.symmetric(horizontal: 8),
                            color: subtleBorder,
                          ),

                          // Publish Button
                          CupertinoButton(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            onPressed: () async {
                              final provider = context.read<EditorProvider>();
                              if (provider.activeBook == null) return;

                              try {
                                showDialog(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: const Text("Publishing"),
                                    content: Text(
                                      "Publishing.",
                                      style: GoogleFonts.inter(),
                                    ),
                                  ),
                                );

                                await provider.publishActiveBook();
                                if (context.mounted) {
                                  showDialog(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: const Text("Success"),
                                      content: Text(
                                        "Published successfully!",
                                        style: GoogleFonts.inter(),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(ctx),
                                          child: const Text("OK"),
                                        ),
                                      ],
                                    ),
                                  );
                                }
                              } catch (e) {
                                if (context.mounted) {
                                  showDialog(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: const Text("Error"),
                                      content: Text(
                                        e.toString().replaceFirst(
                                          'Exception: ',
                                          '',
                                        ),
                                        style: GoogleFonts.inter(),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(ctx),
                                          child: const Text("OK"),
                                        ),
                                      ],
                                    ),
                                  );
                                }
                              }
                            },
                            child: Row(
                              children: [
                                Icon(
                                  CupertinoIcons.share_up,
                                  size: 18,
                                  color: textColor.withValues(alpha: 0.7),
                                ),
                                if (!Breakpoints.isMobile(
                                  MediaQuery.sizeOf(context).width,
                                )) ...[
                                  const SizedBox(width: 4),
                                  Text(
                                    "Publish",
                                    style: GoogleFonts.inter(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                      color: textColor.withValues(alpha: 0.7),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),

                          Container(
                            width: 1,
                            height: 24,
                            margin: const EdgeInsets.symmetric(horizontal: 8),
                            color: subtleBorder,
                          ),

                          // 3. RIGHT: Save Indicator & New Document
                          Consumer<EditorProvider>(
                            builder: (context, provider, child) {
                              final status = provider.saveStatus;
                              IconData icon = CupertinoIcons.cloud_upload;
                              Color iconColor = textColor.withValues(
                                alpha: 0.4,
                              );
                              String text = "Saved";

                              if (status == "Saving...") {
                                text = "Saving...";
                                iconColor = textColor.withValues(alpha: 0.7);
                              } else if (status == "Typing...") {
                                text = "Unsaved";
                                iconColor = Colors.amber;
                                icon = CupertinoIcons.pencil;
                              } else if (status == "Saved") {
                                icon = CupertinoIcons.checkmark_alt_circle;
                                iconColor = Colors.green;
                              }

                              return Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (status == "Saving...")
                                    const CupertinoActivityIndicator(radius: 6)
                                  else
                                    Icon(icon, size: 14, color: iconColor),
                                  if (!Breakpoints.isMobile(
                                    MediaQuery.sizeOf(context).width,
                                  )) ...[
                                    const SizedBox(width: 6),
                                    Text(
                                      text,
                                      style: GoogleFonts.inter(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                        color: textColor.withValues(alpha: 0.6),
                                      ),
                                    ),
                                  ],
                                ],
                              );
                            },
                          ),
                          const SizedBox(width: 18),
                          Breakpoints.isMobile(MediaQuery.sizeOf(context).width)
                              ? CupertinoButton(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 0,
                                  ),
                                  minSize: 32,
                                  onPressed: () {
                                    // Trigger AI
                                  },
                                  child: Icon(
                                    CupertinoIcons.sparkles,
                                    size: 22,
                                    color: isDark
                                        ? Colors.white70
                                        : Colors.deepPurple,
                                  ),
                                )
                              : CupertinoButton(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 0,
                                  ),
                                  minSize: 32,
                                  color: isDark ? Colors.white : Colors.black87,
                                  borderRadius: BorderRadius.circular(16),
                                  child: Row(
                                    children: [
                                      Icon(
                                        CupertinoIcons.add,
                                        size: 14,
                                        color: isDark
                                            ? Colors.black
                                            : Colors.white,
                                      ),
                                      const SizedBox(width: 14),
                                      Text(
                                        "New Section",
                                        style: GoogleFonts.inter(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: isDark
                                              ? Colors.black
                                              : Colors.white,
                                        ),
                                      ),
                                    ],
                                  ),
                                  onPressed: () {
                                    final provider = context
                                        .read<EditorProvider>();
                                    _showTextInputDialog(
                                      context: context,
                                      title: "New Section Name",
                                      initialValue:
                                          "Section ${provider.allBooksSection.length + 1}",
                                      onSave: (val) => provider.addSection(
                                        val,
                                        autoSelect: true,
                                      ),
                                    );
                                  },
                                ),
                          const SizedBox(width: 16),
                        ],
                      ),
                    ),

                    // --- MOBILE: Full toolbar in writing area ---
                    if (Breakpoints.isMobile(MediaQuery.sizeOf(context).width))
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: bgColor,
                          borderRadius: BorderRadius.circular(25),
                          border: Border(
                            bottom: BorderSide(color: subtleBorder),
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Container(
                              decoration: BoxDecoration(
                                color: bgColor,
                                borderRadius: BorderRadius.circular(25),
                                border: Border(
                                  bottom: BorderSide(color: subtleBorder),
                                ),
                              ),
                              clipBehavior: Clip.antiAlias,

                              width: MediaQuery.sizeOf(context).width,
                              child: QuillSimpleToolbar(
                                controller: context
                                    .read<EditorProvider>()
                                    .controller,
                                config: QuillSimpleToolbarConfig(
                                  multiRowsDisplay: false,
                                  showAlignmentButtons: true,
                                  showCenterAlignment: true,
                                  showLink: false,
                                  showInlineCode: false,
                                  showSearchButton: false,
                                  buttonOptions:
                                      QuillSimpleToolbarButtonOptions(
                                        base: QuillToolbarBaseButtonOptions(
                                          iconTheme: QuillIconTheme(
                                            iconButtonSelectedData:
                                                IconButtonData(
                                                  style: IconButton.styleFrom(
                                                    backgroundColor: Colors.blue
                                                        .withValues(alpha: 0.1),
                                                    foregroundColor:
                                                        Colors.blue,
                                                    shape: const CircleBorder(),
                                                  ),
                                                  color: Colors.blue,
                                                ),
                                            iconButtonUnselectedData:
                                                IconButtonData(
                                                  style: IconButton.styleFrom(
                                                    shape: const CircleBorder(),
                                                  ),
                                                ),
                                          ),
                                        ),
                                      ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),

                    // --- MAIN WORKSPACE ---
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Animated Sidebar
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.fastOutSlowIn,
                            width:
                                context.select<EditorProvider, bool>(
                                  (p) => p.showSectionsList,
                                )
                                ? 280
                                : 0,
                            decoration: BoxDecoration(
                              color: sidebarColor,
                              borderRadius: const BorderRadius.only(
                                topRight: Radius.circular(24),
                                bottomRight: Radius.circular(24),
                              ),
                              // border: Border(
                              //   right: BorderSide(color: subtleBorder),
                              // ),
                            ),
                            child: ClipRect(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                physics: const NeverScrollableScrollPhysics(),
                                child: SizedBox(
                                  width: 280,
                                  child: _buildSidebarList(
                                    textColor,
                                    isDark,
                                    subtleBorder,
                                  ),
                                ),
                              ),
                            ),
                          ),

                          // Editor Canvas
                          Expanded(
                            child: Container(
                              color: bgColor,
                              alignment: Alignment.topCenter,
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 800,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    40,
                                    24,
                                    40,
                                    0,
                                  ),
                                  child: Builder(
                                    builder: (ctx) {
                                      final sectionId = ctx
                                          .select<EditorProvider, String?>(
                                            (p) => p.activeSection?.id,
                                          );
                                      return QuillEditor.basic(
                                        key: ValueKey(sectionId ?? 'none'),
                                        controller: ctx
                                            .read<EditorProvider>()
                                            .controller,
                                        config: QuillEditorConfig(
                                          placeholder: "Start typing here...",
                                          padding: const EdgeInsets.only(
                                            bottom: 100,
                                          ),
                                          customStyles: DefaultStyles(
                                            placeHolder: DefaultTextBlockStyle(
                                              GoogleFonts.inter(
                                                fontSize: 18,
                                                color: textColor.withValues(
                                                  alpha: 0.3,
                                                ),
                                              ),
                                              const HorizontalSpacing(0, 0),
                                              const VerticalSpacing(0, 0),
                                              const VerticalSpacing(0, 0),
                                              null,
                                            ),
                                            paragraph: DefaultTextBlockStyle(
                                              GoogleFonts.inter(
                                                fontSize: 18,
                                                height: 1.6,
                                                color: textColor.withValues(
                                                  alpha: 0.9,
                                                ),
                                              ),
                                              const HorizontalSpacing(0, 0),
                                              const VerticalSpacing(16, 0),
                                              const VerticalSpacing(0, 0),
                                              null,
                                            ),
                                          ),
                                        ),
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
                  ],
                )
              : const Center(child: CupertinoActivityIndicator(radius: 14)),
        ),
      ),
    );
  }

  void _showSectionsSheet(
    BuildContext context,
    Color textColor,
    bool isDark,
    Color subtleBorder,
    Color sidebarColor,
  ) {
    showModalBottomSheet(
      context: context,
      backgroundColor: sidebarColor,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (_, scrollController) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    "All Sections",
                    style: GoogleFonts.inter(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                  IconButton(
                    icon: Icon(CupertinoIcons.xmark, color: textColor),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _buildSidebarList(
                textColor,
                isDark,
                subtleBorder,
                onItemTap: () => Navigator.pop(ctx),
                scrollController: scrollController,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSidebarList(
    Color textColor,
    bool isDark,
    Color subtleBorder, {
    VoidCallback? onItemTap,
    ScrollController? scrollController,
  }) {
    return Consumer<EditorProvider>(
      builder: (context, provider, _) {
        final sections = provider.allBooksSection;
        return ListView.separated(
          controller: scrollController,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
          itemCount: sections.length,
          separatorBuilder: (context, index) => const SizedBox(height: 4),
          itemBuilder: (ctx, idx) {
            final section = sections[idx];
            final isActive = provider.activeSection?.id == section.id;

            return Material(
              color: isActive
                  ? (isDark
                        ? Colors.white.withAlpha(25)
                        : Colors.black.withAlpha(15))
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(20),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () {
                  if (!isActive) {
                    provider.forceSaveImmediately();
                    provider.setActiveSection(section);
                    provider.initEditor();
                    onItemTap?.call();
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: section.sectionColor,
                          shape: BoxShape.circle,
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
                                fontWeight: isActive
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                color: isActive
                                    ? textColor
                                    : textColor.withValues(alpha: 0.8),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (section.content.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                provider.getPreviewText(section.content),
                                style: GoogleFonts.inter(
                                  fontSize: 12,
                                  color: textColor.withValues(alpha: 0.5),
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
                          CupertinoIcons.ellipsis_vertical,
                          size: 16,
                          color: textColor.withValues(alpha: 0.4),
                        ),
                        color: isDark ? const Color(0xFF1E1E20) : Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        onSelected: (value) {
                          if (value == 'rename') {
                            _showTextInputDialog(
                              context: context,
                              title: "Rename Document",
                              initialValue: section.title,
                              onSave: (val) =>
                                  provider.renameSection(section, val),
                            );
                          } else if (value == 'delete') {
                            provider.deleteSection(section);
                            if (provider.allBooksSection.isEmpty) {
                              Navigator.pop(context);
                            }
                          }
                        },
                        itemBuilder: (BuildContext context) => [
                          PopupMenuItem(
                            value: 'rename',
                            child: Text('Rename', style: GoogleFonts.inter()),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: Text(
                              'Delete',
                              style: GoogleFonts.inter(color: Colors.redAccent),
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

  void _showTextInputDialog({
    required BuildContext context,
    required String title,
    required String initialValue,
    required Function(String) onSave,
  }) {
    final TextEditingController txtCtrl = TextEditingController(
      text: initialValue,
    );
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text(
            title,
            style: GoogleFonts.inter(fontWeight: FontWeight.w600),
          ),
          content: TextField(
            controller: txtCtrl,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: "Enter name...",
              border: UnderlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () {
                if (txtCtrl.text.trim().isNotEmpty) {
                  onSave(txtCtrl.text.trim());
                }
                Navigator.pop(context);
              },
              child: const Text(
                "Save",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );
  }
}
