import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:iconify_flutter/iconify_flutter.dart';
import 'package:iconify_flutter/icons/carbon.dart';
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

      if (mounted) {
        setState(() {
          _isReady = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvoked: (didPop) {
        context.read<EditorProvider>().forceSaveImmediately();
      },
      child: Scaffold(
        appBar: AppBar(
          title: _isReady
              ? Row(
                  children: [
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(CupertinoIcons.collections),
                          tooltip: "Collections",
                          onPressed: () {
                            context.read<EditorProvider>().toggleShowSections();
                          },
                        ),
                        IconButton(
                          onPressed: () {},
                          icon: const Icon(CupertinoIcons.star),
                          tooltip: "AI",
                        ),

                        Consumer<EditorProvider>(
                          builder: (context, editProvider, child) {
                            Widget iconContent;
                            String tooltipText;

                            if (editProvider.saveStatus == "Saving...") {
                              // Show a premium spinning indicator while saving
                              iconContent = const CupertinoActivityIndicator(
                                radius: 10,
                              );
                              tooltipText = "Saving to cloud...";
                            } else if (editProvider.saveStatus == "Typing...") {
                              // Fade the cloud slightly to show there are unsaved changes
                              iconContent = Icon(
                                CupertinoIcons.cloud,
                                color: Colors.white.withOpacity(0.4), // Faded
                              );
                              tooltipText = "Unsaved changes";
                            } else {
                              // Default / Saved state - Solid white cloud
                              iconContent = const Icon(
                                CupertinoIcons.cloud,
                                color: Colors.white,
                              );
                              tooltipText = "Saved to cloud";
                            }

                            return IconButton(
                              onPressed: () {
                                // Optional: Allow user to manually click it to force a save
                                if (editProvider.saveStatus == "Typing...") {
                                  editProvider.forceSaveImmediately();
                                }
                              },
                              tooltip: tooltipText,
                              icon: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 300),
                                child:
                                    iconContent, // Automatically animates icon changes
                              ),
                            );
                          },
                        ),
                        // TOOD:: Make the section and switch to it.
                        Consumer<EditorProvider>(
                          builder: (context, editProvider, child) {
                            return IconButton(
                              tooltip: "Add New Section",
                              onPressed: () => editProvider.addSection(
                                "Untitled Section ${editProvider.allBooksSection.length + 1}",
                              ),
                              icon: Icon(CupertinoIcons.add),
                            );
                          },
                        ),
                      ],
                    ),

                    // --- QUILL TOOLBAR ---
                    Expanded(
                      child: QuillSimpleToolbar(
                        controller: context.read<EditorProvider>().controller,
                        config: QuillSimpleToolbarConfig(
                          toolbarSize: MediaQuery.of(
                            context,
                          ).size.width.clamp(20.0, 40.0),
                          multiRowsDisplay: false,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(28),
                          ),
                        ),
                      ),
                    ),
                  ],
                )
              : const SizedBox.shrink(),
        ),
        body: _isReady
            ? AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeInOut,
                child: Row(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: Theme.of(context).primaryColor.withAlpha(120),
                        borderRadius: const BorderRadius.only(
                          topRight: Radius.circular(28),
                          bottomRight: Radius.circular(28),
                        ),
                      ),
                      height: double.infinity,
                      width: context.watch<EditorProvider>().showSectionsList
                          ? MediaQuery.of(context).size.width * 0.2
                          : 0,
                      child: context.watch<EditorProvider>().showSectionsList
                          ? Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 8.0,
                                horizontal: 4,
                              ),
                              child: ListView.builder(
                                itemCount: context
                                    .watch<EditorProvider>()
                                    .allBooksSection
                                    .length,
                                itemBuilder: (ctx, idx) {
                                  final provider = context
                                      .read<EditorProvider>();
                                  final section = provider.allBooksSection[idx];
                                  final isCurrentlyOpen =
                                      provider.activeSection?.id == section.id;

                                  return ListTile(
                                    leading: CircleAvatar(
                                      radius: 6,
                                      backgroundColor: section.sectionColor
                                          .withAlpha(120),
                                    ),
                                    title: Text(
                                      section.title,
                                      style: TextStyle(
                                        fontWeight: isCurrentlyOpen
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                      ),
                                    ),
                                    subtitle: section.content.isEmpty
                                        ? null
                                        : Text(
                                            provider.getPreviewText(
                                              section.content,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                    trailing: PopupMenuButton<String>(
                                      icon: const Icon(
                                        CupertinoIcons.ellipsis_vertical,
                                      ),
                                      onSelected: (value) {
                                        if (value == 'rename') {
                                          _showTextInputDialog(
                                            context: context,
                                            title: "Rename Section",
                                            initialValue: section.title,
                                            onSave: (val) => provider
                                                .renameSection(section, val),
                                          );
                                        } else if (value == 'delete') {
                                          provider.deleteSection(section);
                                          // If they delete the section they are currently editing, close the editor
                                          if (isCurrentlyOpen) {
                                            Navigator.pop(
                                              context,
                                            ); // close sheet
                                            Navigator.pop(
                                              context,
                                            ); // close editor
                                          }
                                        }
                                      },
                                      itemBuilder: (BuildContext context) => [
                                        const PopupMenuItem(
                                          value: 'rename',
                                          child: Text('Rename'),
                                        ),
                                        const PopupMenuItem(
                                          value: 'delete',
                                          child: Text(
                                            'Delete',
                                            style: TextStyle(
                                              color: Colors.redAccent,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    onTap: () {
                                      // JUMP TO DIFFERENT CHAPTER
                                      if (!isCurrentlyOpen) {
                                        provider
                                            .forceSaveImmediately(); // Save current work
                                        provider.setActiveSection(
                                          section,
                                        ); // Switch section
                                        provider
                                            .initEditor(); // Load new content
                                      }
                                    },
                                  );
                                },
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Container(
                          height: double.infinity,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(28),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 15,
                              vertical: 20,
                            ),
                            child: QuillEditor.basic(
                              controller: context
                                  .read<EditorProvider>()
                                  .controller,
                              config: const QuillEditorConfig(
                                placeholder: "Start writing here...",
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              )
            : const Center(child: CupertinoActivityIndicator(radius: 14)),
      ),
    );
  }

  // Add this inside your EditiorPage State class, below build():

  void _showCollectionsBottomSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return FractionallySizedBox(
          heightFactor: 0.8, // Takes up 80% of screen height
          child: Consumer<EditorProvider>(
            builder: (context, provider, child) {
              if (provider.activeBook == null) return const SizedBox();

              return Column(
                children: [
                  // --- HEADER: BOOK TITLE & ACTIONS ---
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            provider.activeBook!.title,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        // Edit Book Name
                        IconButton(
                          tooltip: "Rename Book",
                          icon: const Icon(CupertinoIcons.pencil),
                          onPressed: () => _showTextInputDialog(
                            context: context,
                            title: "Rename Book",
                            initialValue: provider.activeBook!.title,
                            onSave: (val) => provider.renameBook(val),
                          ),
                        ),

                        // Delete Book
                      ],
                    ),
                  ),
                  const Divider(height: 1),

                  // --- LIST OF CHAPTERS ---
                  Expanded(
                    child: ListView.builder(
                      itemCount: provider.allBooksSection.length,
                      itemBuilder: (context, index) {
                        final section = provider.allBooksSection[index];
                        final isCurrentlyOpen =
                            provider.activeSection?.id == section.id;

                        return ListTile(
                          selected: isCurrentlyOpen,
                          selectedTileColor: section.sectionColor.withAlpha(30),
                          leading: GestureDetector(
                            onTap: () {
                              showDialog(
                                context: context,
                                builder: (ctx) {
                                  return Dialog();
                                },
                              );
                            },
                            child: CircleAvatar(
                              radius: 8,
                              backgroundColor: section.sectionColor.withAlpha(
                                120,
                              ),
                            ),
                          ),
                          title: Text(
                            section.title,
                            style: TextStyle(
                              fontWeight: isCurrentlyOpen
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                          subtitle: section.content.isEmpty
                              ? null
                              : Text(
                                  provider.getPreviewText(section.content),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          trailing: PopupMenuButton<String>(
                            icon: const Icon(CupertinoIcons.ellipsis_vertical),
                            onSelected: (value) {
                              if (value == 'rename') {
                                _showTextInputDialog(
                                  context: context,
                                  title: "Rename Section",
                                  initialValue: section.title,
                                  onSave: (val) =>
                                      provider.renameSection(section, val),
                                );
                              } else if (value == 'delete') {
                                provider.deleteSection(section);
                                // If they delete the section they are currently editing, close the editor
                                if (isCurrentlyOpen) {
                                  Navigator.pop(context); // close sheet
                                  Navigator.pop(context); // close editor
                                }
                              }
                            },
                            itemBuilder: (BuildContext context) => [
                              const PopupMenuItem(
                                value: 'rename',
                                child: Text('Rename'),
                              ),
                              const PopupMenuItem(
                                value: 'delete',
                                child: Text(
                                  'Delete',
                                  style: TextStyle(color: Colors.redAccent),
                                ),
                              ),
                            ],
                          ),
                          onTap: () {
                            // JUMP TO DIFFERENT CHAPTER
                            if (!isCurrentlyOpen) {
                              provider
                                  .forceSaveImmediately(); // Save current work
                              provider.setActiveSection(
                                section,
                              ); // Switch section
                              provider.initEditor(); // Load new content
                              Navigator.pop(context); // Close sheet
                            }
                          },
                        );
                      },
                    ),
                  ),

                  // --- FOOTER: ADD NEW CHAPTER ---
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: SizedBox(
                      width: double.infinity,
                      child: CupertinoButton(
                        color: Theme.of(context).primaryColor,
                        onPressed: () => _showTextInputDialog(
                          context: context,
                          title: "New Section Name",
                          initialValue: "",
                          onSave: (val) => provider.addSection(val),
                        ),
                        child: const Text("Add New Section"),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  // Helper function to show a reusable text input dialog for renaming/adding
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
}
