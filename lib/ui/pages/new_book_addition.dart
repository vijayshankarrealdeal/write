import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:writer/models/writing_model.dart';
import 'package:writer/provider/editor_provider.dart';

class NewBookAddition extends StatelessWidget {
  const NewBookAddition({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Write Something New")),
      body: Center(
        child: Container(
          width: MediaQuery.of(context).size.width * 0.5,

          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Consumer<EditorProvider>(
            builder: (context, editorProvider, child) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  // Full-width textfield
                  FieldForm(
                    label: "Title",
                    controller: editorProvider.titleController,
                  ),
                  const SizedBox(height: 16),
                  FieldForm(
                    label: "Description",
                    controller: editorProvider.descriptionController,
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<WritingType>(
                    isExpanded: true,
                    borderRadius: BorderRadius.circular(24),
                    decoration: InputDecoration(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 18,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                    ),
                    initialValue: editorProvider.type,
                    items: WritingType.values.map((e) {
                      return DropdownMenuItem(
                        value: e,
                        child: Text(e.displayName),
                      );
                    }).toList(),
                    onChanged: (x) => editorProvider.selectWritingType(x!),
                  ),
                  const SizedBox(height: 16),
                  // Ensure the chips align with left edge — wrap in Align and set spacing
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 8.0, // horizontal space between chips
                      runSpacing: 8.0, // vertical space between lines
                      children:
                          getDisplaySubtypesForWritingType(editorProvider.type)
                              .map(
                                (e) => ChoiceChip(
                                  label: Text(e),
                                  selected: editorProvider.subtype == e,
                                  onSelected: (selected) =>
                                      editorProvider.selectSubtype(e),
                                ),
                              )
                              .toList(),
                    ),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: () {
                      try {
                        editorProvider.addNewBook();
                      } catch (e) {
                        showDialog(
                          context: context,
                          builder: (context) => CupertinoAlertDialog(
                            content: Padding(
                              padding: const EdgeInsets.all(16.0),
                              child: Text(
                                e is Exception
                                    ? e.toString().replaceFirst(
                                        'Exception: ',
                                        '',
                                      )
                                    : e.toString(),
                              ),
                            ),
                            actions: [
                              CupertinoDialogAction(
                                onPressed: () => Navigator.of(context).pop(),
                                child: const Text('Cancel'),
                              ),
                              CupertinoDialogAction(
                                onPressed: () => Navigator.of(context).pop(),
                                child: const Text('Okay'),
                              ),
                            ],
                          ),
                        );
                      } finally {
                        Navigator.of(context).pop();
                      }
                    },
                    child: const Text("Continue"),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class FieldForm extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  const FieldForm({super.key, required this.label, required this.controller});

  @override
  Widget build(BuildContext context) {
    // Force the TextField to take the available width in the parent container
    return SizedBox(
      width: double.infinity,
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 18,
          ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
        ),
      ),
    );
  }
}
