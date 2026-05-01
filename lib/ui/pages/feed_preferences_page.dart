import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:inkspacex/models/preference_options.dart';
import 'package:inkspacex/models/user_preferences_model.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/provider/feed_provider.dart';
import 'package:inkspacex/ui/widgets/app_spinner.dart';

class FeedPreferencesPage extends StatefulWidget {
  const FeedPreferencesPage({super.key});

  @override
  State<FeedPreferencesPage> createState() => _FeedPreferencesPageState();
}

class _FeedPreferencesPageState extends State<FeedPreferencesPage> {
  late UserPreferences _initial;

  late List<String> _selectedWritingTypes;
  late List<String> _selectedSubtypes;
  late List<String> _selectedGoals;
  late List<String> _selectedMoodThemes;
  String? _primaryRole;
  String? _experienceLevel;
  String? _writingFrequency;
  String? _contentLength;

  bool _hasChanges = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _initial =
        context.read<AuthProvider>().currentUser?.preferences ??
            const UserPreferences();
    _selectedWritingTypes = List.from(_initial.preferredWritingTypes);
    _selectedSubtypes = List.from(_initial.preferredGenres);
    _selectedGoals = List.from(_initial.goals);
    _selectedMoodThemes = List.from(_initial.moodThemes);
    _primaryRole = _initial.primaryRole;
    _experienceLevel = _initial.experienceLevel;
    _writingFrequency = _initial.writingFrequency;
    _contentLength = _initial.contentLengthPreference;
  }

  void _markChanged() {
    if (!_hasChanges) setState(() => _hasChanges = true);
  }

  void _toggleWritingType(String type) {
    setState(() {
      if (_selectedWritingTypes.contains(type)) {
        _selectedWritingTypes.remove(type);
        final wt = WritingType.values.firstWhere((w) => w.name == type);
        final subtypes = getDisplaySubtypesForWritingType(wt).toSet();
        _selectedSubtypes.removeWhere(subtypes.contains);
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

  void _toggleMulti(List<String> bucket, String value) {
    setState(() {
      if (bucket.contains(value)) {
        bucket.remove(value);
      } else {
        bucket.add(value);
      }
      _hasChanges = true;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final prefs = _initial.copyWith(
      preferredGenres: _selectedSubtypes,
      preferredWritingTypes: _selectedWritingTypes,
      primaryRole: _primaryRole,
      experienceLevel: _experienceLevel,
      goals: _selectedGoals,
      moodThemes: _selectedMoodThemes,
      writingFrequency: _writingFrequency,
      contentLengthPreference: _contentLength,
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
                    ? AppSpinner(
                        size: 16,
                        color: isDark ? Colors.black : Colors.white,
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
                "Personalize your feed. Skipped a step at sign-up? Fill it in now — or remove anything that no longer fits.",
                style: GoogleFonts.inter(
                  fontSize: 14,
                  color: textColor.withValues(alpha: 0.6),
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 32),

              _sectionHeader("PRIMARY ROLE", textColor),
              const SizedBox(height: 12),
              _singleSelectChips(
                options: kRoleOptions,
                selected: _primaryRole,
                isDark: isDark,
                cardColor: cardColor,
                textColor: textColor,
                onSelect: (v) {
                  setState(() {
                    _primaryRole = (_primaryRole == v) ? null : v;
                  });
                  _markChanged();
                },
              ),

              const SizedBox(height: 32),
              _sectionHeader("EXPERIENCE LEVEL", textColor),
              const SizedBox(height: 12),
              _singleSelectChips(
                options: kExperienceOptions,
                selected: _experienceLevel,
                isDark: isDark,
                cardColor: cardColor,
                textColor: textColor,
                onSelect: (v) {
                  setState(() {
                    _experienceLevel = (_experienceLevel == v) ? null : v;
                  });
                  _markChanged();
                },
              ),

              const SizedBox(height: 32),
              _sectionHeader("GOALS", textColor),
              const SizedBox(height: 12),
              _multiSelectChips(
                options: kGoalOptions,
                selected: _selectedGoals,
                isDark: isDark,
                cardColor: cardColor,
                textColor: textColor,
                onToggle: (v) => _toggleMulti(_selectedGoals, v),
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

              if (_selectedWritingTypes.isNotEmpty) ...[
                const SizedBox(height: 32),
                _sectionHeader("FORMATS", textColor),
                const SizedBox(height: 12),
                ..._buildSubtypeSections(isDark, cardColor, textColor),
              ],

              const SizedBox(height: 32),
              _sectionHeader("VIBE", textColor),
              const SizedBox(height: 12),
              _multiSelectChips(
                options: kMoodOptions,
                selected: _selectedMoodThemes,
                isDark: isDark,
                cardColor: cardColor,
                textColor: textColor,
                onToggle: (v) => _toggleMulti(_selectedMoodThemes, v),
              ),

              const SizedBox(height: 32),
              _sectionHeader("WRITING FREQUENCY", textColor),
              const SizedBox(height: 12),
              _singleSelectChips(
                options: kFrequencyOptions,
                selected: _writingFrequency,
                isDark: isDark,
                cardColor: cardColor,
                textColor: textColor,
                onSelect: (v) {
                  setState(() {
                    _writingFrequency = (_writingFrequency == v) ? null : v;
                  });
                  _markChanged();
                },
              ),

              const SizedBox(height: 32),
              _sectionHeader("PREFERRED READING LENGTH", textColor),
              const SizedBox(height: 12),
              _singleSelectChips(
                options: kLengthOptions,
                selected: _contentLength,
                isDark: isDark,
                cardColor: cardColor,
                textColor: textColor,
                onSelect: (v) {
                  setState(() {
                    _contentLength = (_contentLength == v) ? null : v;
                  });
                  _markChanged();
                },
              ),

              const SizedBox(height: 48),
            ],
          ),
        ),
      ),
    );
  }

  Widget _singleSelectChips({
    required List<PreferenceOption> options,
    required String? selected,
    required bool isDark,
    required Color cardColor,
    required Color textColor,
    required ValueChanged<String> onSelect,
  }) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: options.map((o) {
        return _ChipButton(
          label: o.label,
          selected: selected == o.value,
          isDark: isDark,
          cardColor: cardColor,
          textColor: textColor,
          onTap: () => onSelect(o.value),
        );
      }).toList(),
    );
  }

  Widget _multiSelectChips({
    required List<PreferenceOption> options,
    required List<String> selected,
    required bool isDark,
    required Color cardColor,
    required Color textColor,
    required ValueChanged<String> onToggle,
  }) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: options.map((o) {
        return _ChipButton(
          label: o.label,
          selected: selected.contains(o.value),
          isDark: isDark,
          cardColor: cardColor,
          textColor: textColor,
          onTap: () => onToggle(o.value),
        );
      }).toList(),
    );
  }

  List<Widget> _buildSubtypeSections(
    bool isDark,
    Color cardColor,
    Color textColor,
  ) {
    final widgets = <Widget>[];
    for (final wt in WritingType.values) {
      if (!_selectedWritingTypes.contains(wt.name)) continue;
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
    // Title-case with a tiny weight bump reads like a section heading
    // instead of a SCREAMING tag — kinder to long lists of preferences.
    return Text(
      _toTitleCase(title),
      style: GoogleFonts.inter(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: textColor,
        letterSpacing: -0.1,
      ),
    );
  }

  String _toTitleCase(String value) {
    final lower = value.toLowerCase();
    return lower
        .split(' ')
        .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
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
              ? const Color(0xFF22C55E)
              : cardColor,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: selected
                ? const Color(0xFF22C55E)
                : textColor.withValues(alpha: 0.1),
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected
                ? Colors.white
                : textColor.withValues(alpha: 0.8),
          ),
        ),
      ),
    );
  }
}
