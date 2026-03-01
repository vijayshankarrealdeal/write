import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:writer/provider/editor_provider.dart';

class EditiorPage extends StatefulWidget {
  const EditiorPage({super.key});

  @override
  State<EditiorPage> createState() => _EditiorPageState();
}

class _EditiorPageState extends State<EditiorPage> {
  bool _isReady = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      route.animation?.addStatusListener(_routeAnimationListener);
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
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF0E0E10) : const Color(0xFFF9F9FB);
    final sidebarColor = isDark
        ? const Color(0xFF161618)
        : const Color(0xFFF0F0F3);
    final textColor = isDark ? Colors.white : Colors.black;
    final subtleBorder = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.08);

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        context.read<EditorProvider>().forceSaveImmediately();
      },
      child: Scaffold(
        backgroundColor: bgColor,
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
                              CupertinoIcons.back,
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
                          IconButton(
                            icon: Icon(
                              context.watch<EditorProvider>().showSectionsList
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
                          Container(
                            width: 1,
                            height: 24,
                            margin: const EdgeInsets.symmetric(horizontal: 8),
                            color: subtleBorder,
                          ),

                          // 2. CENTER: Ask AI + Quill Toolbar
                          Expanded(
                            child: Row(
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
                                  child: QuillSimpleToolbar(
                                    controller: context
                                        .read<EditorProvider>()
                                        .controller,
                                    config: const QuillSimpleToolbarConfig(
                                      multiRowsDisplay: false,
                                      showAlignmentButtons: true,
                                      showCenterAlignment: true,
                                      showLink: false,
                                      showInlineCode: false,
                                      showSearchButton:
                                          false, // Turn off if it clutters
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
                              );
                            },
                          ),
                          const SizedBox(width: 16),
                          CupertinoButton(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 0,
                            ),
                            minSize: 32,
                            color: textColor,
                            borderRadius: BorderRadius.circular(16),
                            child: Row(
                              children: [
                                Icon(
                                  CupertinoIcons.add,
                                  size: 12,
                                  color: bgColor,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  "New Document",
                                  style: GoogleFonts.inter(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: bgColor,
                                  ),
                                ),
                              ],
                            ),
                            onPressed: () {
                              final provider = context.read<EditorProvider>();
                              _showTextInputDialog(
                                context: context,
                                title: "New Document Name",
                                initialValue:
                                    "Document ${provider.allBooksSection.length + 1}",
                                onSave: (val) =>
                                    provider.addSection(val, autoSelect: true),
                              );
                            },
                          ),
                          const SizedBox(width: 16),
                        ],
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
                                context.watch<EditorProvider>().showSectionsList
                                ? 280
                                : 0,
                            decoration: BoxDecoration(
                              color: sidebarColor,
                              border: Border(
                                right: BorderSide(color: subtleBorder),
                              ),
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
                                  child: QuillEditor.basic(
                                    controller: context
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

  Widget _buildSidebarList(Color textColor, bool isDark, Color subtleBorder) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      itemCount: context.watch<EditorProvider>().allBooksSection.length,
      separatorBuilder: (context, index) => const SizedBox(height: 4),
      itemBuilder: (ctx, idx) {
        final provider = context.read<EditorProvider>();
        final section = provider.allBooksSection[idx];
        final isActive = provider.activeSection?.id == section.id;

        return Material(
          color: isActive
              ? (isDark
                    ? Colors.white.withValues(alpha: 0.1)
                    : Colors.black.withValues(alpha: 0.06))
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () {
              if (!isActive) {
                provider.forceSaveImmediately();
                provider.setActiveSection(section);
                provider.initEditor();
              }
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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
                          onSave: (val) => provider.renameSection(section, val),
                        );
                      } else if (value == 'delete') {
                        provider.deleteSection(section);
                        if (isActive) {
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
