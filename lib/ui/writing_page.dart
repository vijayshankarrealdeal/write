import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:provider/provider.dart';
import 'package:writer/provider/editor_provider.dart';

class WritingPageUI extends StatelessWidget {
  const WritingPageUI({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Consumer<EditorProvider>(
      builder: (context, editProvider, _) {
        return Padding(
          padding: const EdgeInsets.all(8.0),
          child: Column(
            children: [
              QuillSimpleToolbar(
                controller: editProvider.controller,
                config: QuillSimpleToolbarConfig(
                  toolbarSize: MediaQuery.of(context).size.width < 600
                      ? MediaQuery.of(context).size.width * 0.03
                      : MediaQuery.of(context).size.width * 0.02,
                  multiRowsDisplay: false,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer.withAlpha(65),
                    borderRadius: BorderRadius.circular(28),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 0,
                    vertical: 20,
                  ),
                  child: editProvider.loadingData
                      ? Center(child: CircularProgressIndicator())
                      : QuillEditor.basic(
                          controller: editProvider.controller,
                          config: const QuillEditorConfig(
                            placeholder: "Start writing here...",
                          ),
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
