import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:inkspacex/models/user_preferences_model.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/provider/feed_provider.dart';

class FeedPreferencesPage extends StatefulWidget {
  const FeedPreferencesPage({super.key});

  @override
  State<FeedPreferencesPage> createState() => _FeedPreferencesPageState();
}

class _FeedPreferencesPageState extends State<FeedPreferencesPage> {
  late List<String> _selectedWritingTypes;
  late List<String> _selectedSubtypes;
  bool _hasChanges = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final prefs =
        context.read<AuthProvider>().currentUser?.preferences ??
        const UserPreferences();
    _selectedWritingTypes = List.from(prefs.preferredWritingTypes);
    _selectedSubtypes = List.from(prefs.preferredGenres);
  }

  void _toggleWritingType(String type) {
    setState(() {
      if (_selectedWritingTypes.contains(type)) {
        _selectedWritingTypes.remove(type);
      } else {
        _selectedWritingTypes.add(type);
      }
      _hasChanges = true;
    });
  }

  void _toggleSubtype(String subtype) {
    setState(() {
      if (_selectedSubtypes.contains(subtype)) {
        _selectedSubtypes.remove(subtype);
      } else {
        _selectedSubtypes.add(subtype);
      }
      _hasChanges = true;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final prefs = UserPreferences(
      preferredGenres: _selectedSubtypes,
      preferredWritingTypes: _selectedWritingTypes,
      interests: [],
    );
    await context.read<AuthProvider>().saveOnboardingPreferences(prefs);
    if (mounted) {
      context.read<FeedProvider>().loadFeed(prefs, forceRefresh: true);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF000000) : const Color(0xFFFAFAFA);
    final textColor = isDark ? Colors.white : Colors.black;
    final cardColor = isDark ? const Color(0xFF1A1A1A) : Colors.white;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: bgColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: textColor),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          "Feed Preferences",
          style: GoogleFonts.inter(
            fontWeight: FontWeight.w600,
            color: textColor,
          ),
        ),
        actions: [
          if (_hasChanges)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: CupertinoButton(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                color: isDark ? Colors.white : Colors.black,
                borderRadius: BorderRadius.circular(20),
                onPressed: _saving ? null : _save,
                child: _saving
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: isDark ? Colors.black : Colors.white,
                        ),
                      )
                    : Text(
                        "Save",
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.black : Colors.white,
                        ),
                      ),
              ),
            ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1080),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                "Choose topics you're interested in. This personalizes your feed.",
                style: GoogleFonts.inter(
                  fontSize: 14,
                  color: textColor.withValues(alpha: 0.6),
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 32),

              _sectionHeader("WRITING TYPES", textColor),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: WritingType.values.map((wt) {
                  final key = wt.name;
                  final selected = _selectedWritingTypes.contains(key);
                  return _ChipButton(
                    label: wt.displayName,
                    selected: selected,
                    isDark: isDark,
                    cardColor: cardColor,
                    textColor: textColor,
                    onTap: () => _toggleWritingType(key),
                  );
                }).toList(),
              ),

              const SizedBox(height: 32),
              _sectionHeader("FORMATS", textColor),
              const SizedBox(height: 12),

              ..._buildSubtypeSections(isDark, cardColor, textColor),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildSubtypeSections(
    bool isDark,
    Color cardColor,
    Color textColor,
  ) {
    final widgets = <Widget>[];
    for (final wt in WritingType.values) {
      final subtypes = getDisplaySubtypesForWritingType(wt);
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 8),
          child: Text(
            wt.displayName,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: textColor.withValues(alpha: 0.5),
            ),
          ),
        ),
      );
      widgets.add(
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: subtypes.map((label) {
            final selected = _selectedSubtypes.contains(label);
            return _ChipButton(
              label: label,
              selected: selected,
              isDark: isDark,
              cardColor: cardColor,
              textColor: textColor,
              onTap: () => _toggleSubtype(label),
            );
          }).toList(),
        ),
      );
    }
    return widgets;
  }

  Widget _sectionHeader(String title, Color textColor) {
    return Text(
      title,
      style: GoogleFonts.inter(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
        color: textColor.withValues(alpha: 0.4),
      ),
    );
  }
}

class _ChipButton extends StatelessWidget {
  final String label;
  final bool selected;
  final bool isDark;
  final Color cardColor;
  final Color textColor;
  final VoidCallback onTap;

  const _ChipButton({
    required this.label,
    required this.selected,
    required this.isDark,
    required this.cardColor,
    required this.textColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? (isDark ? Colors.white : Colors.black) : cardColor,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: selected
                ? Colors.transparent
                : textColor.withValues(alpha: 0.1),
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: selected
                ? (isDark ? Colors.black : Colors.white)
                : textColor.withValues(alpha: 0.8),
          ),
        ),
      ),
    );
  }
}
