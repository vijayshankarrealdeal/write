import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:writer/provider/editor_provider.dart';
import 'package:writer/ui/pages/editior_page.dart';
import 'package:writer/ui/pages/new_book_addition.dart';

class WritingPageUI extends StatelessWidget {
  const WritingPageUI({super.key});

  // Helper to determine theme mode
  bool _isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  @override
  Widget build(BuildContext context) {
    final isDark = _isDark(context);
    final bgColor = isDark ? const Color(0xFF0E0E10) : const Color(0xFFF9F9FB);
    final textColor = isDark ? Colors.white : Colors.black;

    return Scaffold(
      backgroundColor: bgColor,
      body: Consumer<EditorProvider>(
        builder: (context, editProvider, _) {
          // 1. LOADING STATE
          if (editProvider.bookLoadingData) {
            return const Center(child: CupertinoActivityIndicator(radius: 16));
          }

          // 2. EMPTY STATE (No Projects)
          if (editProvider.allBooks.isEmpty) {
            return _buildEmptyState(context, textColor, isDark);
          }

          // 3. MAIN SPLIT VIEW (Projects + Documents)
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // LEFT PANE: Projects Sidebar
              SizedBox(
                width: 320, // Fixed optimal width for sidebars
                child: _buildProjectsSidebar(
                  context,
                  editProvider,
                  textColor,
                  isDark,
                ),
              ),

              // Divider
              Container(
                width: 1,
                color: isDark
                    ? Colors.white.withOpacity(0.05)
                    : Colors.black.withOpacity(0.05),
              ),

              // RIGHT PANE: Documents Area
              Expanded(
                child: _buildDocumentsArea(
                  context,
                  editProvider,
                  textColor,
                  isDark,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ===========================================================================
  // EMPTY STATE (Refined & Minimal)
  // ===========================================================================
  Widget _buildEmptyState(BuildContext context, Color textColor, bool isDark) {
    final cardColor = isDark ? const Color(0xFF161618) : Colors.white;
    final borderColor = isDark
        ? Colors.white.withOpacity(0.08)
        : Colors.black.withOpacity(0.08);

    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 40),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: borderColor),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withOpacity(0.05)
                    : Colors.black.withOpacity(0.03),
                shape: BoxShape.circle,
              ),
              child: Icon(
                CupertinoIcons
                    .square_pencil, // Changed to a general "writing" icon
                size: 32,
                color: textColor.withOpacity(0.7),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              "Start your writing journey",
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: textColor,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              "Create your first project to begin.",
              style: GoogleFonts.inter(
                fontSize: 14,
                color: textColor.withOpacity(0.5),
              ),
            ),
            const SizedBox(height: 32),
            CupertinoButton(
              color: textColor,
              borderRadius: BorderRadius.circular(24),
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
              child: Text(
                "New Project",
                style: GoogleFonts.inter(
                  color: isDark ? Colors.black : Colors.white,
                  fontWeight: FontWeight.w500,
                ),
              ),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (ctx) => NewBookAddition()),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // LEFT PANE: PROJECTS SIDEBAR
  // ===========================================================================
  Widget _buildProjectsSidebar(
    BuildContext context,
    EditorProvider editProvider,
    Color textColor,
    bool isDark,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Sidebar Header
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 32, 16, 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "Workspace", // Changed from My Library to Workspace
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: textColor.withOpacity(0.5),
                  letterSpacing: 1.2,
                  textBaseline: TextBaseline.alphabetic,
                ),
              ),
              IconButton(
                icon: Icon(
                  CupertinoIcons.add,
                  size: 20,
                  color: textColor.withOpacity(0.7),
                ),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (ctx) => NewBookAddition()),
                ),
              ),
            ],
          ),
        ),

        // Projects List
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: editProvider.allBooks.length,
            itemBuilder: (context, index) {
              final project = editProvider.allBooks[index];
              final isActive = editProvider.activeBook == project;

              return Padding(
                padding: const EdgeInsets.only(bottom: 4.0),
                child: Material(
                  color: isActive
                      ? (isDark
                            ? Colors.white.withOpacity(0.1)
                            : Colors.black.withOpacity(0.06))
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      editProvider.setActiveBook(project);
                      editProvider.allBooksSection = project.sections;
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            // Folder icon feels more like a generic project container
                            isActive
                                ? CupertinoIcons.folder_fill
                                : CupertinoIcons.folder,
                            size: 18,
                            color: isActive
                                ? textColor
                                : textColor.withOpacity(0.5),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              project.title,
                              style: GoogleFonts.inter(
                                fontSize: 15,
                                fontWeight: isActive
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                                color: isActive
                                    ? textColor
                                    : textColor.withOpacity(0.8),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          // Subtle Actions
                          if (isActive) ...[
                            _buildActionButton(
                              icon: CupertinoIcons.pencil,
                              onTap: () => _showTextInputDialog(
                                context: context,
                                title: "Rename Project",
                                initialValue: project.title,
                                onSave: (newTitle) =>
                                    editProvider.renameBook(newTitle),
                              ),
                            ),
                            const SizedBox(width: 8),
                            _buildActionButton(
                              icon: CupertinoIcons.trash,
                              isDestructive: true,
                              onTap: () => _showDeleteConfirmation(
                                context: context,
                                title: "Delete Project",
                                content:
                                    "Are you sure you want to delete '${project.title}'?",
                                onConfirm: () =>
                                    editProvider.deleteBook(project),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // ===========================================================================
  // RIGHT PANE: DOCUMENTS AREA
  // ===========================================================================
  Widget _buildDocumentsArea(
    BuildContext context,
    EditorProvider editProvider,
    Color textColor,
    bool isDark,
  ) {
    if (editProvider.activeBook == null) {
      return Center(
        child: Text(
          "Select a project to view its contents.",
          style: GoogleFonts.inter(
            color: textColor.withOpacity(0.4),
            fontSize: 15,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Documents Header
        Padding(
          padding: const EdgeInsets.fromLTRB(40, 40, 40, 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Text(
                  editProvider.activeBook!.title,
                  style: GoogleFonts.playfairDisplay(
                    fontSize: 32,
                    fontWeight: FontWeight.w700,
                    color: textColor,
                    letterSpacing: -0.5,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              CupertinoButton(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                color: isDark
                    ? Colors.white.withOpacity(0.1)
                    : Colors.black.withOpacity(0.05),
                borderRadius: BorderRadius.circular(20),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(CupertinoIcons.add, size: 16, color: textColor),
                    const SizedBox(width: 6),
                    Text(
                      "New Document",
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: textColor,
                      ),
                    ),
                  ],
                ),
                onPressed: () => _showTextInputDialog(
                  context: context,
                  title: "New Document Name",
                  initialValue:
                      "Document ${editProvider.allBooksSection.length + 1}",
                  onSave: (title) => editProvider.addSectionToActiveBook(title),
                ),
              ),
            ],
          ),
        ),

        // Documents List
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 8),
            itemCount: editProvider.allBooksSection.length,
            separatorBuilder: (_, __) => Divider(
              color: isDark
                  ? Colors.white.withOpacity(0.05)
                  : Colors.black.withOpacity(0.05),
              height: 1,
            ),
            itemBuilder: (context, index) {
              final document = editProvider.allBooksSection[index];

              return Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    editProvider.setActiveSection(document);
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (ctx) => const EditiorPage()),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 16,
                      horizontal: 8,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Document Color Indicator
                        Container(
                          margin: const EdgeInsets.only(top: 6),
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: document.sectionColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 16),

                        // Text Content
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                document.title,
                                style: GoogleFonts.inter(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: textColor,
                                ),
                              ),
                              if (document.content.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Text(
                                  editProvider.getPreviewText(document.content),
                                  style: GoogleFonts.inter(
                                    fontSize: 14,
                                    color: textColor.withOpacity(0.5),
                                    height: 1.4,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 16),

                        // Actions (Subtle)
                        Row(
                          children: [
                            _buildActionButton(
                              icon: CupertinoIcons.pencil,
                              onTap: () => _showTextInputDialog(
                                context: context,
                                title: "Rename Document",
                                initialValue: document.title,
                                onSave: (newTitle) => editProvider
                                    .renameSection(document, newTitle),
                              ),
                            ),
                            const SizedBox(width: 4),
                            _buildActionButton(
                              icon: CupertinoIcons.trash,
                              isDestructive: true,
                              onTap: () => _showDeleteConfirmation(
                                context: context,
                                title: "Delete Document",
                                content:
                                    "Are you sure you want to delete '${document.title}'?",
                                onConfirm: () =>
                                    editProvider.deleteSection(document),
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
          ),
        ),
      ],
    );
  }

  // ===========================================================================
  // REUSABLE UI COMPONENTS
  // ===========================================================================
  Widget _buildActionButton({
    required IconData icon,
    required VoidCallback onTap,
    bool isDestructive = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.all(6.0),
        child: Icon(
          icon,
          size: 16,
          color: isDestructive
              ? Colors.redAccent.withOpacity(0.8)
              : Colors.grey,
        ),
      ),
    );
  }

  // ===========================================================================
  // HELPER DIALOGS (Refined)
  // ===========================================================================
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

  void _showDeleteConfirmation({
    required BuildContext context,
    required String title,
    required String content,
    required VoidCallback onConfirm,
  }) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text(
            title,
            style: GoogleFonts.inter(
              color: Colors.redAccent,
              fontWeight: FontWeight.w600,
            ),
          ),
          content: Text(content, style: GoogleFonts.inter()),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () {
                onConfirm();
                Navigator.pop(context);
              },
              child: const Text(
                "Delete",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
