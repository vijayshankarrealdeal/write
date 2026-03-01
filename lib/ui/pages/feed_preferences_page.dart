import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:writer/models/user_preferences_model.dart';
import 'package:writer/provider/auth_provider.dart';
import 'package:writer/provider/feed_provider.dart';

const List<MapEntry<String, String>> _genreOptions = [
  MapEntry('creative', 'Creative'),
  MapEntry('personal', 'Personal'),
  MapEntry('essay', 'Essay'),
  MapEntry('poetry', 'Poetry'),
  MapEntry('digitalContent', 'Digital Content'),
  MapEntry('journal', 'Journal'),
  MapEntry('journalistic', 'Journalistic'),
  MapEntry('marketing', 'Marketing'),
];

const List<MapEntry<String, String>> _writingTypeOptions = [
  MapEntry('creative', 'Creative'),
  MapEntry('digitalContent', 'Digital Content'),
  MapEntry('personal', 'Personal'),
  MapEntry('journalistic', 'Journalistic'),
  MapEntry('marketing', 'Marketing'),
];

class FeedPreferencesPage extends StatefulWidget {
  const FeedPreferencesPage({super.key});

  @override
  State<FeedPreferencesPage> createState() => _FeedPreferencesPageState();
}

class _FeedPreferencesPageState extends State<FeedPreferencesPage> {
  late List<String> _selectedGenres;
  late List<String> _selectedWritingTypes;
  bool _hasChanges = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final prefs = context.read<AuthProvider>().currentUser?.preferences ??
        const UserPreferences();
    _selectedGenres = List.from(prefs.preferredGenres);
    _selectedWritingTypes = List.from(prefs.preferredWritingTypes);
  }

  void _toggleGenre(String genre) {
    setState(() {
      _selectedGenres.contains(genre)
          ? _selectedGenres.remove(genre)
          : _selectedGenres.add(genre);
      _hasChanges = true;
    });
  }

  void _toggleWritingType(String type) {
    setState(() {
      _selectedWritingTypes.contains(type)
          ? _selectedWritingTypes.remove(type)
          : _selectedWritingTypes.add(type);
      _hasChanges = true;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final prefs = UserPreferences(
      preferredGenres: _selectedGenres,
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
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
          constraints: const BoxConstraints(maxWidth: 600),
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
              Text(
                "GENRES",
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                  color: textColor.withValues(alpha: 0.4),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: _genreOptions.map((e) {
                  final selected = _selectedGenres.contains(e.key);
                  return _ChipButton(
                    label: e.value,
                    selected: selected,
                    isDark: isDark,
                    cardColor: cardColor,
                    textColor: textColor,
                    onTap: () => _toggleGenre(e.key),
                  );
                }).toList(),
              ),
              const SizedBox(height: 32),
              Text(
                "WRITING TYPES",
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                  color: textColor.withValues(alpha: 0.4),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: _writingTypeOptions.map((e) {
                  final selected = _selectedWritingTypes.contains(e.key);
                  return _ChipButton(
                    label: e.value,
                    selected: selected,
                    isDark: isDark,
                    cardColor: cardColor,
                    textColor: textColor,
                    onTap: () => _toggleWritingType(e.key),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
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
          color: selected
              ? (isDark ? Colors.white : Colors.black)
              : cardColor,
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
