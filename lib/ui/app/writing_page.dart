import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:writer/provider/editor_provider.dart';
import 'package:writer/ui/pages/editior_page.dart';
import 'package:writer/ui/pages/new_book_addition.dart';

class WritingPageUI extends StatelessWidget {
  const WritingPageUI({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Consumer<EditorProvider>(
      builder: (context, editProvider, _) {
        if (editProvider.bookLoadingData) {
          return const Center(child: CupertinoActivityIndicator(radius: 16));
        }

        if (editProvider.allBooks.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  "Start your writing journey!",
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 16),
                CupertinoButton.filled(
                  child: const Text("Continue"),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (ctx) => NewBookAddition()),
                  ),
                ),
              ],
            ),
          );
        }

        return Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.secondaryContainer.withAlpha(24),
                      borderRadius: const BorderRadius.only(
                        topRight: Radius.circular(24),
                        bottomRight: Radius.circular(24),
                      ),
                    ),
                    height: double.infinity,
                    width: MediaQuery.of(context).size.width * 0.35,
                    child: Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.only(
                            left: 26,
                            top: 20,
                            right: 16,
                          ),
                        ),
                        Expanded(
                          child: ListView.builder(
                            itemCount: editProvider.allBooks.length,
                            itemBuilder: (context, index) {
                              final book = editProvider.allBooks[index];
                              return GestureDetector(
                                onTap: () {
                                  editProvider.setActiveBook(book);
                                  editProvider.allBooksSection = book.sections;
                                },
                                child: Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 16.0,
                                    vertical: 4,
                                  ),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: editProvider.activeBook == book
                                          ? theme.colorScheme.secondaryContainer
                                                .withAlpha(224)
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(24),
                                    ),
                                    // 🔥 THIS IS THE MAGIC LINE THAT FIXES THE CORNER GLITCH 🔥
                                    clipBehavior: Clip.antiAlias,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 20,
                                            vertical: 16,
                                          ),
                                          color: theme.canvasColor.withAlpha(
                                            editProvider.activeBook == book
                                                ? 145
                                                : 53,
                                          ),

                                          // Slight contrast for header
                                          child: Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceBetween,
                                            crossAxisAlignment:
                                                CrossAxisAlignment.center,
                                            children: [
                                              Text(
                                                book.title,
                                                style: const TextStyle(
                                                  fontSize: 20,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                              Row(
                                                children: [
                                                  IconButton(
                                                    icon: const Icon(
                                                      CupertinoIcons.pencil,
                                                      size: 20,
                                                      color: Colors.grey,
                                                    ),
                                                    onPressed: () =>
                                                        _showTextInputDialog(
                                                          context: context,
                                                          title: "Rename Book",
                                                          initialValue:
                                                              book.title,
                                                          onSave: (newTitle) =>
                                                              editProvider
                                                                  .renameBook(
                                                                    newTitle,
                                                                  ),
                                                        ),
                                                  ),
                                                  IconButton(
                                                    icon: const Icon(
                                                      CupertinoIcons.delete,
                                                      size: 20,
                                                      color: Colors.red,
                                                    ),
                                                    onPressed: () =>
                                                        editProvider.deleteBook(
                                                          book,
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
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),

                  // ==========================================
                  // RIGHT COLUMN: CHAPTERS LIST
                  // ==========================================
                  Expanded(
                    child: editProvider.activeBook == null
                        ? const Center(
                            child: Text("Select a book to view chapters"),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.center,

                            children: [
                              // --- ADD CHAPTER BUTTON HEADER ---
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16.0,
                                  vertical: 12.0,
                                ),
                                child: CupertinoButton(
                                  padding: EdgeInsets.zero,
                                  child: const Row(
                                    children: [
                                      Icon(
                                        CupertinoIcons.add_circled,
                                        size: 20,
                                      ),
                                      SizedBox(width: 6),
                                      Text("New Section"),
                                    ],
                                  ),
                                  onPressed: () => _showTextInputDialog(
                                    context: context,
                                    title: "New Section Name",
                                    initialValue:
                                        "Section ${editProvider.allBooksSection.length + 1}",
                                    onSave: (title) => editProvider
                                        .addSectionToActiveBook(title),
                                  ),
                                ),
                              ),

                              // --- SECTION LIST ---
                              Expanded(
                                child: ListView.builder(
                                  itemCount:
                                      editProvider.allBooksSection.length,
                                  itemBuilder: (context, index) {
                                    final section =
                                        editProvider.allBooksSection[index];

                                    return Padding(
                                      padding: const EdgeInsets.all(8.0),
                                      child: ListTile(
                                        tileColor: section.sectionColor
                                            .withAlpha(12),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ), // 12-16 is industry standard for list items
                                        ),

                                        leading: CircleAvatar(
                                          radius: 8,
                                          backgroundColor: section.sectionColor,
                                        ),
                                        title: Text(section.title),
                                        subtitle: section.content.isEmpty
                                            ? null
                                            : Text(
                                                editProvider.getPreviewText(
                                                  section.content,
                                                ), // Uses the helper we made
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                        onTap: () {
                                          editProvider.setActiveSection(
                                            section,
                                          );
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (ctx) =>
                                                  const EditiorPage(),
                                            ),
                                          );
                                        },

                                        // --- EDIT / DELETE ICONS FOR SECTION ---
                                        trailing: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            IconButton(
                                              icon: const Icon(
                                                CupertinoIcons.pencil,
                                                size: 20,
                                                color: Colors.grey,
                                              ),
                                              onPressed: () =>
                                                  _showTextInputDialog(
                                                    context: context,
                                                    title: "Rename Section",
                                                    initialValue: section.title,
                                                    onSave: (newTitle) =>
                                                        editProvider
                                                            .renameSection(
                                                              section,
                                                              newTitle,
                                                            ),
                                                  ),
                                            ),
                                            IconButton(
                                              icon: const Icon(
                                                CupertinoIcons.trash,
                                                size: 20,
                                                color: Colors.redAccent,
                                              ),
                                              onPressed: () =>
                                                  _showDeleteConfirmation(
                                                    context: context,
                                                    title: "Delete Section",
                                                    content:
                                                        "Delete '${section.title}' forever?",
                                                    onConfirm: () =>
                                                        editProvider
                                                            .deleteSection(
                                                              section,
                                                            ),
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
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  // ==========================================
  // HELPER DIALOGS
  // ==========================================

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
          title: Text(title),
          content: TextField(
            controller: txtCtrl,
            autofocus: true,
            decoration: const InputDecoration(hintText: "Enter name..."),
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
              child: const Text("Save"),
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
          title: Text(title, style: const TextStyle(color: Colors.redAccent)),
          content: Text(content),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
              ),
              onPressed: () {
                onConfirm();
                Navigator.pop(context);
              },
              child: const Text(
                "Delete",
                style: TextStyle(color: Colors.white),
              ),
            ),
          ],
        );
      },
    );
  }
}
