import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:writer/models/writing_model.dart';
import 'package:writer/provider/editor_provider.dart';

class NewBookAddition extends StatelessWidget {
  const NewBookAddition({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF000000) : const Color(0xFFFAFAFA);
    final cardColor = isDark ? const Color(0xFF1A1A1A) : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black;
    final subtleBorder = isDark
        ? Colors.white.withOpacity(0.08)
        : Colors.black.withOpacity(0.08);

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: Icon(CupertinoIcons.back, color: textColor),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          "New Project",
          style: GoogleFonts.inter(
            fontWeight: FontWeight.w600,
            fontSize: 16,
            color: textColor,
          ),
        ),
        centerTitle: true,
      ),
      body: Center(
        child: SingleChildScrollView(
          child: Container(
            width: 500, // Fixed optimal width for forms on web/desktop
            padding: const EdgeInsets.all(40),
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: subtleBorder),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(isDark ? 0.3 : 0.03),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Consumer<EditorProvider>(
              builder: (context, editorProvider, child) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      "Project Details",
                      style: GoogleFonts.playfairDisplay(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 32),

                    FieldForm(
                      label: "Title",
                      hint: "Enter project title...",
                      controller: editorProvider.titleController,
                    ),
                    const SizedBox(height: 20),

                    FieldForm(
                      label: "Description",
                      hint: "A brief summary of this project...",
                      controller: editorProvider.descriptionController,
                    ),
                    const SizedBox(height: 20),

                    // Styled Dropdown
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white.withOpacity(0.04)
                            : Colors.black.withOpacity(0.03),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: subtleBorder),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<WritingType>(
                          isExpanded: true,
                          dropdownColor: cardColor,
                          borderRadius: BorderRadius.circular(16),
                          icon: Icon(
                            CupertinoIcons.chevron_down,
                            size: 16,
                            color: textColor.withOpacity(0.5),
                          ),
                          style: GoogleFonts.inter(
                            color: textColor,
                            fontSize: 15,
                          ),
                          value: editorProvider.type,
                          items: WritingType.values.map((e) {
                            return DropdownMenuItem(
                              value: e,
                              child: Text(e.displayName),
                            );
                          }).toList(),
                          onChanged: (x) =>
                              editorProvider.selectWritingType(x!),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Chips Section
                    Text(
                      "Format",
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: textColor.withOpacity(0.5),
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 8.0,
                        runSpacing: 8.0,
                        children:
                            getDisplaySubtypesForWritingType(
                              editorProvider.type,
                            ).map((e) {
                              final isSelected = editorProvider.subtype == e;
                              return ChoiceChip(
                                label: Text(e),
                                selected: isSelected,
                                showCheckmark:
                                    false, // Removes the ugly checkmark
                                labelStyle: GoogleFonts.inter(
                                  fontSize: 14,
                                  color: isSelected
                                      ? bgColor
                                      : textColor.withOpacity(0.8),
                                  fontWeight: isSelected
                                      ? FontWeight.w500
                                      : FontWeight.w400,
                                ),
                                backgroundColor: isDark
                                    ? Colors.white.withOpacity(0.04)
                                    : Colors.black.withOpacity(0.03),
                                selectedColor: textColor,
                                side: BorderSide.none,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                onSelected: (selected) =>
                                    editorProvider.selectSubtype(e),
                              );
                            }).toList(),
                      ),
                    ),

                    const SizedBox(height: 48),

                    // Premium Pill Button
                    Material(
                      color: textColor,
                      borderRadius: BorderRadius.circular(24),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(24),
                        onTap: () {
                          try {
                            editorProvider.addNewBook();
                            Navigator.of(context).pop(); // Success
                          } catch (e) {
                            _showError(context, e);
                          }
                        },
                        child: Container(
                          height: 48,
                          width: double.infinity,
                          alignment: Alignment.center,
                          child: Text(
                            "Create Project",
                            style: GoogleFonts.inter(
                              color: bgColor,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  void _showError(BuildContext context, Object e) {
    showDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text("Oops"),
        content: Padding(
          padding: const EdgeInsets.only(top: 8.0),
          child: Text(
            e is Exception
                ? e.toString().replaceFirst('Exception: ', '')
                : e.toString(),
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Okay'),
          ),
        ],
      ),
    );
  }
}

class FieldForm extends StatelessWidget {
  final String label;
  final String hint;
  final TextEditingController controller;

  const FieldForm({
    super.key,
    required this.label,
    required this.hint,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;
    final fillColor = isDark
        ? Colors.white.withOpacity(0.04)
        : Colors.black.withOpacity(0.03);
    final subtleBorder = isDark
        ? Colors.white.withOpacity(0.08)
        : Colors.black.withOpacity(0.08);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: textColor.withOpacity(0.5),
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          style: GoogleFonts.inter(color: textColor, fontSize: 15),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: GoogleFonts.inter(
              color: textColor.withOpacity(0.3),
              fontSize: 15,
            ),
            filled: true,
            fillColor: fillColor,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 16,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: subtleBorder),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: subtleBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: textColor.withOpacity(0.3)),
            ),
          ),
        ),
      ],
    );
  }
}
