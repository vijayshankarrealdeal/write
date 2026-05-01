import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/provider/editor_provider.dart';
import 'package:inkspacex/provider/settings_provider.dart';
import 'package:inkspacex/ui/pages/new_book_addition.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/ui/utilities/responsive_layout.dart';
import 'package:inkspacex/ui/widgets/app_spinner.dart';
import 'package:inkspacex/ui/widgets/type_chooser.dart';

class WritingPageUI extends StatelessWidget {
  const WritingPageUI({super.key});

  @override
  Widget build(BuildContext context) {
    return const ResponsiveLayout(
      mobileScaffold: _MobileWritingPage(),
      tabletScaffold: _DesktopWritingPage(isTablet: true),
      desktopScaffold: _DesktopWritingPage(isTablet: false),
    );
  }
}

// ===========================================================================
// MOBILE LAYOUT (iOS Style)
// ===========================================================================
class _MobileWritingPage extends StatelessWidget {
  const _MobileWritingPage();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF000000) : const Color(0xFFF8FAFC);
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);

    return CupertinoPageScaffold(
      backgroundColor: bgColor,
      child: CustomScrollView(
        slivers: [
          CupertinoSliverNavigationBar(
            largeTitle: Text(
              'My Spaces',
              style: GoogleFonts.playfairDisplay(
                fontWeight: FontWeight.bold,
                color: textColor,
              ),
            ),
            backgroundColor: bgColor,
            border: null,
            trailing: CupertinoButton(
              padding: EdgeInsets.zero,
              child: Icon(CupertinoIcons.add, size: 28, color: textColor),
              onPressed: () => _showNewProjectDialog(context),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: Consumer<EditorProvider>(
              builder: (context, provider, _) {
                if (provider.bookLoadingData) {
                  return SliverFillRemaining(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppSpinner(color: textColor),
                        const SizedBox(height: 16),
                        Text(
                          "Loading spaces...",
                          style: GoogleFonts.inter(
                            decoration: TextDecoration.none,
                            color: textColor.withValues(alpha: 0.6),
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  );
                }
                if (provider.allBooks.isEmpty) {
                  return SliverFillRemaining(
                    child: _buildEmptyStateMobile(context, isDark),
                  );
                }
                return SliverList(
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final book = provider.allBooks[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _MobileProjectCard(book: book, isDark: isDark),
                    );
                  }, childCount: provider.allBooks.length),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _showNewProjectDialog(BuildContext context) {
    showCupertinoModalPopup(
      context: context,
      builder: (context) => const NewBookAddition(),
    );
  }
}

class _MobileProjectCard extends StatelessWidget {
  final WritingModel book;
  final bool isDark;

  const _MobileProjectCard({required this.book, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final cardColor = isDark ? const Color(0xFF1A1A1A) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);

    final isActive = context.watch<EditorProvider>().activeBook?.id == book.id;

    return GestureDetector(
      onTap: () {
        context.read<EditorProvider>().setActiveBook(book);
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(16),
          border: isActive
              ? Border.all(color: const Color(0xFF2563EB), width: 2)
              : null,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.05),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.1)
                        : Colors.black.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    CupertinoIcons.book_fill,
                    color: isDark ? Colors.white : Colors.black,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    book.title,
                    style: GoogleFonts.inter(
                      decoration: TextDecoration.none,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: Icon(
                    CupertinoIcons.ellipsis,
                    size: 20,
                    color: textColor.withValues(alpha: 0.6),
                  ),
                  onPressed: () => _showProjectOptionsSheet(
                    context,
                    context.read<EditorProvider>(),
                    book,
                    isDark,
                  ),
                  padding: const EdgeInsets.all(4),
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                ),
              ],
            ),
            if (isActive) ...[
              const SizedBox(height: 16),
              Divider(
                color: isDark ? Colors.white10 : Colors.black12,
                height: 1,
              ),
              const SizedBox(height: 12),
              _buildSectionsListMobile(context, book, isDark),
              const SizedBox(height: 12),
              GestureDetector(
                onTap: () => _showNewSectionDialogMobile(context),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.05)
                        : Colors.black.withValues(alpha: 0.03),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        CupertinoIcons.add,
                        size: 16,
                        color: isDark ? Colors.white54 : Colors.black45,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        "Add Section",
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: isDark ? Colors.white54 : Colors.black45,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showNewSectionDialogMobile(BuildContext context) {
    final controller = TextEditingController();
    showCupertinoDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) => CupertinoAlertDialog(
        title: const Text("New Section"),
        content: Column(
          children: [
            const SizedBox(height: 8),
            const Text("Enter a name for this section"),
            const SizedBox(height: 16),
            CupertinoTextField(
              controller: controller,
              placeholder: "Section Title",
              autofocus: true,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ],
        ),
        actions: [
          CupertinoDialogAction(
            child: const Text("Cancel"),
            onPressed: () => Navigator.pop(context),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                context.read<EditorProvider>().addSection(
                  controller.text.trim(),
                );
                Navigator.pop(context);
              }
            },
            child: const Text("Create"),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionsListMobile(
    BuildContext context,
    WritingModel book,
    bool isDark,
  ) {
    final sections = context.watch<EditorProvider>().allBooksSection;
    if (sections.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8.0),
        child: Text(
          "No sections yet. Tap + to add one.",
          style: GoogleFonts.inter(
            color: isDark ? Colors.white54 : Colors.black45,
          ),
        ),
      );
    }

    return Column(
      children: sections.map((section) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                context.read<EditorProvider>().setActiveSection(section);
                context.push('/editor');
              },
              child: Row(
                children: [
                  Icon(
                    CupertinoIcons.doc_text,
                    size: 16,
                    color: isDark ? Colors.white54 : Colors.black45,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      section.title,
                      style: GoogleFonts.inter(
                        color: isDark ? Colors.white70 : Colors.black87,
                        fontSize: 15,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    CupertinoIcons.chevron_right,
                    size: 14,
                    color: isDark ? Colors.white24 : Colors.black26,
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

Widget _buildEmptyStateMobile(BuildContext context, bool isDark) {
  return _StartWritingHero(isDark: isDark, compact: true);
}

// ===========================================================================
// DESKTOP/TABLET LAYOUT (Sleek & Minimal)
// ===========================================================================
class _DesktopWritingPage extends StatelessWidget {
  final bool isTablet;
  const _DesktopWritingPage({required this.isTablet});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF000000) : const Color(0xFFF8FAFC);
    final sidebarColor = isDark ? const Color(0xFF121212) : Colors.white;
    final dividerColor = isDark
        ? Colors.white.withValues(alpha: 0.05)
        : Colors.black.withValues(alpha: 0.05);

    final bookLoading = context.select<EditorProvider, bool>(
      (p) => p.bookLoadingData,
    );
    final hasProjects =
        context.select<EditorProvider, int>((p) => p.allBooks.length) > 0;
    return Scaffold(
      backgroundColor: bgColor,
      body: bookLoading
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppSpinner(
                    size: 24,
                    color: (isDark ? Colors.white : Colors.black).withValues(
                      alpha: 0.6,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    "Loading spaces...",
                    style: GoogleFonts.inter(
                      color: (isDark ? Colors.white : Colors.black).withValues(
                        alpha: 0.6,
                      ),
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            )
          : Row(
              children: [
                // SIDEBAR (Projects) - only show when there are projects
                if (hasProjects)
                  Container(
                    width: isTablet ? 260 : 400,
                    decoration: BoxDecoration(
                      color: sidebarColor,
                      border: Border(right: BorderSide(color: dividerColor)),
                      borderRadius: BorderRadius.only(
                        topRight: Radius.circular(24),
                        bottomRight: Radius.circular(24),
                      ),
                    ),
                    child: _buildSidebar(context, isDark),
                  ),
                // MAIN CONTENT (Sections Grid/List)
                Expanded(child: _buildMainContent(context, isDark)),
              ],
            ),
    );
  }

  Widget _buildSidebar(BuildContext context, bool isDark) {
    return Column(
      children: [
        // Sidebar Header
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
          child: Row(
            children: [
              Text(
                "My Spaces",
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                  letterSpacing: -0.1,
                ),
              ),
              const Spacer(),
              _buildIconButton(
                context,
                icon: CupertinoIcons.add,
                onTap: () => showDialog(
                  context: context,
                  builder: (_) => const NewBookAddition(),
                ),
                isDark: isDark,
              ),
            ],
          ),
        ),

        // Projects List
        Expanded(
          child: Consumer<EditorProvider>(
            builder: (context, provider, _) {
              if (provider.allBooks.isEmpty) return const SizedBox.shrink();

              return ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: provider.allBooks.length,
                itemBuilder: (context, index) {
                  final book = provider.allBooks[index];
                  final isActive = provider.activeBook?.id == book.id;

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: _SidebarItem(
                      book: book,
                      isSelected: isActive,
                      isDark: isDark,
                      onTap: () {
                        provider.setActiveBook(book);
                      },
                      onPublish: () => _showPublishSheet(
                        context,
                        provider,
                        book,
                        isDark,
                      ),
                      onRename: () => _showRenameProjectDialog(
                        context,
                        provider,
                        book,
                        isDark,
                      ),
                      onDelete: () => _showDeleteProjectDialog(
                        context,
                        provider,
                        book,
                        isDark,
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildMainContent(BuildContext context, bool isDark) {
    final activeBook = context.select<EditorProvider, WritingModel?>(
      (p) => p.activeBook,
    );
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);

    if (activeBook == null) {
      return _buildEmptyStateDesktop(context, isDark);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(40, 40, 40, 24),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            activeBook.title,
                            style: GoogleFonts.playfairDisplay(
                              fontSize: 32,
                              fontWeight: FontWeight.bold,
                              color: textColor,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // IconButton(
                        //   icon: Icon(
                        //     CupertinoIcons.ellipsis_circle,
                        //     color: textColor.withValues(alpha: 0.6),
                        //   ),
                        //   tooltip: "Project options",
                        //   onPressed: () => _showProjectOptionsSheet(
                        //     context,
                        //     context.read<EditorProvider>(),
                        //     activeBook,
                        //     isDark,
                        //   ),
                        // ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Builder(builder: (context) {
                      final count = context.select<EditorProvider, int>((p) => p.allBooksSection.length);
                      return Text(
                        "$count ${count == 1 ? 'section' : 'sections'}",
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: isDark ? Colors.white54 : Colors.black45,
                        ),
                      );
                    }),
                  ],
                ),
              ),
              Consumer<SettingsProvider>(
                builder: (context, settings, _) {
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        onPressed: () => settings.toggleSectionsView(),
                        icon: Icon(
                          settings.sectionsGridView
                              ? CupertinoIcons.square_grid_2x2
                              : CupertinoIcons.list_bullet,
                          color: textColor.withValues(alpha: 0.8),
                        ),
                        tooltip: settings.sectionsGridView
                            ? "Switch to list view"
                            : "Switch to grid view",
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        onPressed: () => _showPublishSheet(
                          context,
                          context.read<EditorProvider>(),
                          activeBook,
                          isDark,
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          foregroundColor: textColor,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 16,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.15)
                                  : Colors.black.withValues(alpha: 0.12),
                            ),
                          ),
                        ),
                        icon: const Icon(CupertinoIcons.share_up, size: 18),
                        label: Text(
                          "Publish",
                          style: GoogleFonts.inter(fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        onPressed: () => _showNewSectionDialog(context),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isDark ? Colors.white : Colors.black,
                          foregroundColor: isDark ? Colors.black : Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 16,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        icon: const Icon(CupertinoIcons.add, size: 20),
                        label: Text(
                          "New Section",
                          style: GoogleFonts.inter(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),

        // Sections Grid or List
        Expanded(
          child: Consumer2<EditorProvider, SettingsProvider>(
            builder: (context, provider, settings, _) {
              if (provider.allBooksSection.isEmpty) {
                return Center(
                  child: Text(
                    "No sections yet. Create one to start writing.",
                    style: GoogleFonts.inter(
                      color: isDark ? Colors.white38 : Colors.black38,
                    ),
                  ),
                );
              }

              if (settings.sectionsGridView) {
                return GridView.builder(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 40,
                    vertical: 0,
                  ),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 260,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 16,
                    childAspectRatio: 1.6,
                  ),
                  itemCount: provider.allBooksSection.length,
                  itemBuilder: (context, index) {
                    final section = provider.allBooksSection[index];
                    return _SectionCard(
                      section: section,
                      isDark: isDark,
                      onTap: () {
                        provider.setActiveSection(section);
                        context.push('/editor');
                      },
                    );
                  },
                );
              }

              return ListView.separated(
                padding: const EdgeInsets.symmetric(
                  horizontal: 40,
                  vertical: 0,
                ),
                itemCount: provider.allBooksSection.length,
                separatorBuilder: (context, index) =>
                    const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final section = provider.allBooksSection[index];
                  return _SectionListTile(
                    section: section,
                    isDark: isDark,
                    onTap: () {
                      provider.setActiveSection(section);
                      context.push('/editor');
                    },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildIconButton(
    BuildContext context, {
    required IconData icon,
    required VoidCallback onTap,
    required bool isDark,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.05)
              : Colors.black.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          icon,
          size: 16,
          color: isDark ? Colors.white70 : Colors.black87,
        ),
      ),
    );
  }

  void _showNewSectionDialog(BuildContext context) {
    showCupertinoDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) {
        final controller = TextEditingController();
        return CupertinoAlertDialog(
          title: const Text("New Section"),
          content: Column(
            children: [
              const SizedBox(height: 8),
              const Text("Enter a name for this section"),
              const SizedBox(height: 16),
              CupertinoTextField(
                controller: controller,
                placeholder: "Section Title",
                autofocus: true,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ],
          ),
          actions: [
            CupertinoDialogAction(
              child: const Text("Cancel"),
              onPressed: () => Navigator.pop(context),
            ),
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () {
                if (controller.text.trim().isNotEmpty) {
                  context.read<EditorProvider>().addSection(
                    controller.text.trim(),
                  );
                  Navigator.pop(context);
                }
              },
              child: const Text("Create"),
            ),
          ],
        );
      },
    );
  }

  Widget _buildEmptyStateDesktop(BuildContext context, bool isDark) {
    return _StartWritingHero(isDark: isDark, compact: false);
  }
}

// ─── Start writing hero (empty state) ───────────────────────────────────────
class _StartWritingHero extends StatelessWidget {
  final bool isDark;
  final bool compact;

  const _StartWritingHero({required this.isDark, required this.compact});

  void _open(BuildContext context, {WritingType? type}) {
    if (compact) {
      showCupertinoModalPopup(
        context: context,
        builder: (_) => NewBookAddition(initialType: type),
      );
    } else {
      showDialog(
        context: context,
        builder: (_) => NewBookAddition(initialType: type),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? Colors.white : const Color(0xFF111111);
    final mutedColor = isDark
        ? Colors.white.withValues(alpha: 0.55)
        : Colors.black.withValues(alpha: 0.55);

    return SafeArea(
      child: Material(
        type: MaterialType.transparency,
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 0 : 48,
            vertical: compact ? 4 : 48,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(height: compact ? 4 : 32),
                Text(
                  "What will you\nwrite today?",
                  style: GoogleFonts.playfairDisplay(
                    fontSize: compact ? 28 : 56,
                    fontWeight: FontWeight.w700,
                    color: textColor,
                    height: 1.05,
                    letterSpacing: -0.8,
                  ),
                ),
                SizedBox(height: compact ? 6 : 16),
                Text(
                  compact
                      ? "Pick a form — you can change everything later."
                      : "Every space begins with a single word.\nPick a form — you can change everything else later.",
                  style: GoogleFonts.inter(
                    fontSize: compact ? 13 : 16,
                    color: mutedColor,
                    height: 1.4,
                  ),
                ),
                SizedBox(height: compact ? 16 : 44),
                TypeChooser(
                  selected: null,
                  onSelect: (t) => _open(context, type: t),
                  isDark: isDark,
                ),
                SizedBox(height: compact ? 14 : 32),
                _BlankSpaceLink(
                  isDark: isDark,
                  onTap: () => _open(context),
                ),
                SizedBox(height: compact ? 4 : 32),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }
}

class _BlankSpaceLink extends StatefulWidget {
  final bool isDark;
  final VoidCallback onTap;

  const _BlankSpaceLink({required this.isDark, required this.onTap});

  @override
  State<_BlankSpaceLink> createState() => _BlankSpaceLinkState();
}

class _BlankSpaceLinkState extends State<_BlankSpaceLink> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final baseColor = widget.isDark
        ? Colors.white.withValues(alpha: 0.55)
        : Colors.black.withValues(alpha: 0.55);
    final hoverColor = widget.isDark ? Colors.white : Colors.black;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 180),
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: _hovering ? hoverColor : baseColor,
            decoration: TextDecoration.none,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("Or start from a blank space"),
              const SizedBox(width: 6),
              Icon(
                CupertinoIcons.arrow_right,
                size: 13,
                color: _hovering ? hoverColor : baseColor,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

void _showProjectOptionsSheet(
  BuildContext context,
  EditorProvider provider,
  WritingModel book,
  bool isDark,
) {
  showCupertinoModalPopup(
    context: context,
    builder: (ctx) => CupertinoActionSheet(
      title: Text(
        book.title,
        style: GoogleFonts.inter(fontWeight: FontWeight.w600),
      ),
      actions: [
        CupertinoActionSheetAction(
          onPressed: () {
            Navigator.pop(ctx);
            _showPublishSheet(context, provider, book, isDark);
          },
          child: const Text("Publish"),
        ),
        CupertinoActionSheetAction(
          onPressed: () {
            Navigator.pop(ctx);
            _showRenameProjectDialog(context, provider, book, isDark);
          },
          child: const Text("Rename"),
        ),
        CupertinoActionSheetAction(
          isDestructiveAction: true,
          onPressed: () {
            Navigator.pop(ctx);
            _showDeleteProjectDialog(context, provider, book, isDark);
          },
          child: const Text("Delete"),
        ),
      ],
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => Navigator.pop(ctx),
        child: const Text("Cancel"),
      ),
    ),
  );
}

void _showRenameProjectDialog(
  BuildContext context,
  EditorProvider provider,
  WritingModel book,
  bool isDark,
) {
  final controller = TextEditingController(text: book.title);
  showCupertinoDialog(
    context: context,
    builder: (ctx) => CupertinoAlertDialog(
      title: const Text("Rename Space"),
      content: Padding(
        padding: const EdgeInsets.only(top: 16),
        child: CupertinoTextField(
          controller: controller,
          placeholder: "Space name",
          autofocus: true,
          style: TextStyle(color: isDark ? Colors.white : Colors.black),
        ),
      ),
      actions: [
        CupertinoDialogAction(
          child: const Text("Cancel"),
          onPressed: () => Navigator.pop(ctx),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () async {
            final name = controller.text.trim();
            if (name.isEmpty) return;
            Navigator.pop(ctx);
            try {
              await provider.renameBookById(book, name);
            } catch (e) {
              if (context.mounted) {
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    content: Text(
                      e.toString().replaceFirst('Exception: ', ''),
                      style: GoogleFonts.inter(),
                    ),
                  ),
                );
              }
            }
          },
          child: const Text("Rename"),
        ),
      ],
    ),
  );
}

void _showDeleteProjectDialog(
  BuildContext context,
  EditorProvider provider,
  WritingModel book,
  bool isDark,
) {
  showCupertinoDialog(
    context: context,
    builder: (ctx) => CupertinoAlertDialog(
      title: const Text("Delete Space"),
      content: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          "Are you sure you want to delete \"${book.title}\"? This cannot be undone.",
          style: GoogleFonts.inter(),
        ),
      ),
      actions: [
        CupertinoDialogAction(
          child: const Text("Cancel"),
          onPressed: () => Navigator.pop(ctx),
        ),
        CupertinoDialogAction(
          isDestructiveAction: true,
          onPressed: () async {
            Navigator.pop(ctx);
            try {
              await provider.deleteBook(book);
            } catch (e) {
              if (context.mounted) {
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    content: Text(
                      e.toString().replaceFirst('Exception: ', ''),
                      style: GoogleFonts.inter(),
                    ),
                  ),
                );
              }
            }
          },
          child: const Text("Delete"),
        ),
      ],
    ),
  );
}

void _showPublishSheet(
  BuildContext context,
  EditorProvider provider,
  WritingModel book,
  bool isDark,
) {
  final sections = book.sections;
  if (sections.isEmpty) {
    showCupertinoDialog(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text("No Sections"),
        content: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            "Add at least one section before publishing.",
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
    return;
  }

  context.push('/publish', extra: book);
}

class _SidebarItem extends StatelessWidget {
  final WritingModel book;
  final bool isSelected;
  final bool isDark;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onPublish;

  const _SidebarItem({
    required this.book,
    required this.isSelected,
    required this.isDark,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
    required this.onPublish,
  });

  @override
  Widget build(BuildContext context) {
    final activeBg = isDark
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.black.withValues(alpha: 0.05);
    final activeText = isDark ? Colors.white : Colors.black;
    final inactiveText = isDark ? Colors.white70 : Colors.black87;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? activeBg : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(
              isSelected ? CupertinoIcons.book_fill : CupertinoIcons.book,
              size: 18,
              color: isSelected
                  ? activeText
                  : (isDark ? Colors.white38 : Colors.black38),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                book.title,
                style: GoogleFonts.inter(
                  decoration: TextDecoration.none,
                  fontSize: 14,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                  color: isSelected ? activeText : inactiveText,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: Icon(
                CupertinoIcons.ellipsis,
                size: 18,
                color: isSelected
                    ? activeText.withAlpha(178)
                    : (isDark ? Colors.white38 : Colors.black38),
              ),
              onPressed: () => _showProjectMenu(context),
              padding: const EdgeInsets.all(4),
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showProjectMenu(BuildContext context) {
    showCupertinoModalPopup(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text(
          book.title,
          style: GoogleFonts.inter(fontWeight: FontWeight.w600),
        ),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(ctx);
              onPublish();
            },
            child: const Text("Publish"),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(ctx);
              onRename();
            },
            child: const Text("Rename"),
          ),
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.pop(ctx);
              onDelete();
            },
            child: const Text("Delete"),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text("Cancel"),
        ),
      ),
    );
  }
}

class _SectionListTile extends StatelessWidget {
  final SectionModel section;
  final bool isDark;
  final VoidCallback onTap;

  const _SectionListTile({
    required this.section,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor = isDark ? const Color(0xFF1A1A1A) : Colors.white;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.05)
        : Colors.black.withValues(alpha: 0.05);

    return Material(
      color: bgColor,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor),
            color: bgColor,
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: section.sectionColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  CupertinoIcons.doc_text,
                  color: section.sectionColor,
                  size: 20,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      section.title,
                      style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "Last edited recently",
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: isDark ? Colors.white38 : Colors.black38,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                CupertinoIcons.chevron_right,
                color: isDark ? Colors.white38 : Colors.black38,
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final SectionModel section;
  final bool isDark;
  final VoidCallback onTap;

  const _SectionCard({
    required this.section,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor = isDark ? const Color(0xFF1A1A1A) : Colors.white;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.05)
        : Colors.black.withValues(alpha: 0.05);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderColor),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.05),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: section.sectionColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                CupertinoIcons.doc_text,
                color: section.sectionColor,
                size: 18,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              section.title,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : const Color(0xFF0F172A),
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              "Last edited recently",
              style: GoogleFonts.inter(
                fontSize: 10,
                color: isDark ? Colors.white38 : Colors.black38,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
